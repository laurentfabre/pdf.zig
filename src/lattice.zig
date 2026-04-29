//! v1.2 Pass B: lattice-path table extraction.
//!
//! Detects ruled tables on born-digital PDFs by scanning the content
//! stream for stroke ops (`m`/`l`/`re`) and clustering parallel
//! horizontal + vertical strokes into a cell grid. Implements the
//! Camelot-style approach described in
//! `docs/v1.2-table-detection-design.md` §3.2.
//!
//! Pipeline:
//!   1. Walk the content stream once with `interpreter.ContentLexer`,
//!      tracking the current transformation matrix (CTM) via a
//!      `q`/`Q`-aware stack so all coordinates land in user-space.
//!   2. Collect every horizontal and vertical stroke (lines and
//!      rectangle edges).
//!   3. Cluster strokes by collinearity (within `coord_tolerance` pt)
//!      then look for closed rectangular regions formed by ≥2 parallel
//!      horizontals + ≥2 parallel verticals.
//!   4. For each closed region, count interior horizontals (row
//!      separators) and verticals (column separators) → cell grid.
//!   5. Emit one `tables.Table` per region.
//!
//! Cell text assignment is **not** done in Pass B v1; the v1.2 evaluator
//! gates on structural shape (rows × cols × header_rows). Cell text
//! comes from a follow-up pass that intersects glyph centers with cell
//! bboxes (Pass-B-text, deferred).

const std = @import("std");
const interpreter = @import("interpreter.zig");
const tables = @import("tables.zig");
const parser = @import("parser.zig");
const pagetree = @import("pagetree.zig");
const decompress = @import("decompress.zig");
const xref_mod = @import("xref.zig");
const layout = @import("layout.zig");

const COORD_TOLERANCE: f64 = 1.0; // 1 pt (≈0.35 mm)
const MIN_STROKE_LEN: f64 = 4.0; // ignore strokes shorter than 4 pt

/// Hard cap on Form XObject `Do` recursion. Mirrors the constant used by
/// the text-extraction path in root.zig (`ExtractionContext.MAX_DEPTH`).
/// PDF spec allows nested XObjects; 10 frames is comfortably above any
/// realistic template nesting and below the point where stack pressure
/// matters.
pub const MAX_XOBJECT_DEPTH: u8 = 10;

/// Document-level state needed to resolve indirect references when
/// recursing into Form XObjects. All fields point at long-lived storage
/// owned by the `Document`; lattice never frees them.
pub const DocState = struct {
    /// Allocator the parser uses for resolved object dictionaries that
    /// land in `object_cache`. Must outlive the recursion.
    parse_allocator: std.mem.Allocator,
    /// Allocator for transient buffers (decompressed Form content).
    /// Freed by `collectStrokes` before returning.
    scratch_allocator: std.mem.Allocator,
    /// Raw PDF bytes — parser reads object data straight from this.
    data: []const u8,
    xref_table: *const xref_mod.XRefTable,
    object_cache: *std.AutoHashMap(u32, parser.Object),
};

/// Optional context for `collectStrokes`. Default is the legacy
/// page-content-only behaviour: `Do` operators are ignored.
///
/// Provide `resources` + `doc` to opt into Form XObject recursion.
pub const CollectContext = struct {
    /// Currently in-scope Resources dict — the page's at the outermost
    /// call, or the resolved Form Resources dict during recursion.
    /// Used to resolve `/XObject/<name>` for `Do` operators in the
    /// content stream being walked.
    resources: ?parser.Object.Dict = null,
    /// The PAGE Resources dict — preserved across recursion frames.
    /// Per ISO 32000-1 §7.8.3, when a Form XObject omits its own
    /// `/Resources` (or sets it to .null per §7.3.9), the fallback
    /// is the resources of the page on which the form appears,
    /// NOT the calling form's resources. PDFBox and MuPDF agree.
    /// Defaults to `resources` when set by the outermost caller via
    /// `collectStrokesIn` (see initializer there); recursion preserves
    /// it explicitly.
    page_resources: ?parser.Object.Dict = null,
    /// Document-level state for indirect-reference resolution.
    /// Must be non-null whenever `resources` is set; both are required
    /// for recursion to fire.
    doc: ?DocState = null,
    /// Current recursion depth. The public entry point starts at 0;
    /// each `Do` increments by 1. Recursion stops at MAX_XOBJECT_DEPTH.
    depth: u8 = 0,
    /// Initial CTM applied before walking `content`. Default identity.
    /// Used to inject the parent's CTM × the Form's `/Matrix` when
    /// recursing.
    initial_ctm: Mat = .{},
    /// Visited set (object numbers) for cycle detection across the
    /// whole recursion. The outermost call passes `null`; the worker
    /// allocates a local set and threads it through.
    visited: ?*std.AutoHashMap(u32, void) = null,
};

pub const Stroke = struct {
    /// Two endpoints in user-space.
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,

    fn isHorizontal(self: Stroke) bool {
        return @abs(self.y1 - self.y0) <= COORD_TOLERANCE and
            @abs(self.x1 - self.x0) >= MIN_STROKE_LEN;
    }
    fn isVertical(self: Stroke) bool {
        return @abs(self.x1 - self.x0) <= COORD_TOLERANCE and
            @abs(self.y1 - self.y0) >= MIN_STROKE_LEN;
    }
};

const Mat = struct {
    a: f64 = 1.0,
    b: f64 = 0.0,
    c: f64 = 0.0,
    d: f64 = 1.0,
    e: f64 = 0.0,
    f: f64 = 0.0,

    fn apply(self: Mat, x: f64, y: f64) struct { x: f64, y: f64 } {
        return .{
            .x = self.a * x + self.c * y + self.e,
            .y = self.b * x + self.d * y + self.f,
        };
    }
    fn mul(self: Mat, other: Mat) Mat {
        return .{
            .a = self.a * other.a + self.b * other.c,
            .b = self.a * other.b + self.b * other.d,
            .c = self.c * other.a + self.d * other.c,
            .d = self.c * other.b + self.d * other.d,
            .e = self.e * other.a + self.f * other.c + other.e,
            .f = self.e * other.b + self.f * other.d + other.f,
        };
    }
    /// Compute the inverse of this affine matrix. Returns null when
    /// the matrix is singular (det ≈ 0). PDF user-space matrices that
    /// fall through here are rotation / scale / shear / translation
    /// composites; non-singular by construction in well-formed PDFs.
    fn inverse(self: Mat) ?Mat {
        const det = self.a * self.d - self.b * self.c;
        if (!std.math.isFinite(det)) return null;
        if (@abs(det) < 1e-12) return null;
        const inv_det = 1.0 / det;
        return Mat{
            .a = self.d * inv_det,
            .b = -self.b * inv_det,
            .c = -self.c * inv_det,
            .d = self.a * inv_det,
            .e = (self.c * self.f - self.d * self.e) * inv_det,
            .f = (self.b * self.e - self.a * self.f) * inv_det,
        };
    }
    fn isFinite(self: Mat) bool {
        return std.math.isFinite(self.a) and std.math.isFinite(self.b) and
            std.math.isFinite(self.c) and std.math.isFinite(self.d) and
            std.math.isFinite(self.e) and std.math.isFinite(self.f);
    }
};

/// Walk a content stream and return every horizontal/vertical stroke
/// in user-space, ignoring text + colour + clip ops. Caller frees.
///
/// This is the legacy entry point: `Do` operators are silently ignored,
/// so any tables drawn inside Form XObjects are invisible. Use
/// `collectStrokesIn` to opt into Form XObject recursion.
pub fn collectStrokes(allocator: std.mem.Allocator, content: []const u8) ![]Stroke {
    return collectStrokesIn(allocator, content, .{});
}

/// Resource-aware variant of `collectStrokes`.
///
/// When `ctx.resources` AND `ctx.doc` are both set, `Do` operators
/// resolve the named XObject from the page Resources, push the parent
/// CTM × the Form's `/Matrix` onto the graphics state, and recurse into
/// the Form content stream. Recursion is depth-capped at
/// `MAX_XOBJECT_DEPTH` and cycle-guarded via a visited set keyed on
/// indirect-reference object numbers.
///
/// All recursion errors are swallowed — a corrupt or unsupported
/// XObject must not poison the surrounding stroke collection.
pub fn collectStrokesIn(
    allocator: std.mem.Allocator,
    content: []const u8,
    ctx: CollectContext,
) ![]Stroke {
    var strokes: std.ArrayList(Stroke) = .empty;
    errdefer strokes.deinit(allocator);

    // The outermost call owns the visited set; nested calls borrow it.
    var owned_visited: std.AutoHashMap(u32, void) = std.AutoHashMap(u32, void).init(allocator);
    defer if (ctx.visited == null) owned_visited.deinit();
    const visited = ctx.visited orelse &owned_visited;

    // Default `page_resources` to the caller's in-scope resources when
    // unset. The outermost caller passes the page's resources via
    // `ctx.resources`; the page IS the page in that frame, so they
    // are equal at depth 0. Recursive frames preserve the original
    // page_resources so a deeply nested Form's absent/null
    // /Resources still falls back to the page, not its callers.
    var seeded_ctx = ctx;
    if (seeded_ctx.page_resources == null) seeded_ctx.page_resources = ctx.resources;

    try collectStrokesWalk(allocator, content, seeded_ctx, visited, &strokes);
    return strokes.toOwnedSlice(allocator);
}

/// Inner worker. Walks a single content stream and appends to `out`.
/// `Do` triggers a recursive call into the worker on the resolved Form
/// XObject's content stream. CTM stack is local to this frame.
fn collectStrokesWalk(
    allocator: std.mem.Allocator,
    content: []const u8,
    ctx: CollectContext,
    visited: *std.AutoHashMap(u32, void),
    out: *std.ArrayList(Stroke),
) anyerror!void {
    var lexer = interpreter.ContentLexer.init(allocator, content);
    var operands: std.ArrayList(f64) = .empty;
    defer operands.deinit(allocator);
    var ctm_stack: std.ArrayList(Mat) = .empty;
    defer ctm_stack.deinit(allocator);
    try ctm_stack.append(allocator, ctx.initial_ctm);

    // Most-recent name token. PDF operators consume the immediately-
    // preceding name (e.g. `Do`, `Tf`, `gs`). Reset after each operator
    // so a stale name from three ops ago can't be misread as the
    // operand of the next `Do`.
    var last_name: []const u8 = "";

    var path_x: f64 = 0;
    var path_y: f64 = 0;
    var subpath_start_x: f64 = 0;
    var subpath_start_y: f64 = 0;
    var path_segments: std.ArrayList(Stroke) = .empty;
    defer path_segments.deinit(allocator);

    while (try lexer.next()) |tok| {
        switch (tok) {
            .number => |n| try operands.append(allocator, n),
            .name => |n| {
                last_name = n;
                operands.clearRetainingCapacity();
            },
            .string, .hex_string, .array => operands.clearRetainingCapacity(),
            .operator => |op| {
                defer {
                    operands.clearRetainingCapacity();
                    last_name = "";
                }
                if (op.len == 0) continue;
                const ctm = ctm_stack.items[ctm_stack.items.len - 1];

                // q / Q — graphics state push/pop
                if (std.mem.eql(u8, op, "q")) {
                    try ctm_stack.append(allocator, ctm);
                } else if (std.mem.eql(u8, op, "Q")) {
                    if (ctm_stack.items.len > 1) _ = ctm_stack.pop();
                } else if (std.mem.eql(u8, op, "cm") and operands.items.len >= 6) {
                    const m = Mat{
                        .a = operands.items[0], .b = operands.items[1],
                        .c = operands.items[2], .d = operands.items[3],
                        .e = operands.items[4], .f = operands.items[5],
                    };
                    ctm_stack.items[ctm_stack.items.len - 1] = m.mul(ctm);
                } else if (std.mem.eql(u8, op, "m") and operands.items.len >= 2) {
                    const p = ctm.apply(operands.items[0], operands.items[1]);
                    path_x = p.x; path_y = p.y;
                    subpath_start_x = p.x; subpath_start_y = p.y;
                } else if (std.mem.eql(u8, op, "l") and operands.items.len >= 2) {
                    const p = ctm.apply(operands.items[0], operands.items[1]);
                    try path_segments.append(allocator, .{ .x0 = path_x, .y0 = path_y, .x1 = p.x, .y1 = p.y });
                    path_x = p.x; path_y = p.y;
                } else if (std.mem.eql(u8, op, "h")) {
                    // close path: implicit line from current to subpath start
                    if (path_x != subpath_start_x or path_y != subpath_start_y) {
                        try path_segments.append(allocator, .{ .x0 = path_x, .y0 = path_y, .x1 = subpath_start_x, .y1 = subpath_start_y });
                    }
                    path_x = subpath_start_x; path_y = subpath_start_y;
                } else if (std.mem.eql(u8, op, "re") and operands.items.len >= 4) {
                    const x = operands.items[0];
                    const y = operands.items[1];
                    const w = operands.items[2];
                    const h = operands.items[3];
                    const p00 = ctm.apply(x, y);
                    const p10 = ctm.apply(x + w, y);
                    const p11 = ctm.apply(x + w, y + h);
                    const p01 = ctm.apply(x, y + h);
                    try path_segments.append(allocator, .{ .x0 = p00.x, .y0 = p00.y, .x1 = p10.x, .y1 = p10.y });
                    try path_segments.append(allocator, .{ .x0 = p10.x, .y0 = p10.y, .x1 = p11.x, .y1 = p11.y });
                    try path_segments.append(allocator, .{ .x0 = p11.x, .y0 = p11.y, .x1 = p01.x, .y1 = p01.y });
                    try path_segments.append(allocator, .{ .x0 = p01.x, .y0 = p01.y, .x1 = p00.x, .y1 = p00.y });
                } else if (std.mem.eql(u8, op, "S") or std.mem.eql(u8, op, "s") or
                    std.mem.eql(u8, op, "B") or std.mem.eql(u8, op, "B*") or
                    std.mem.eql(u8, op, "b") or std.mem.eql(u8, op, "b*"))
                {
                    // s, b, b* implicitly close the current subpath before
                    // stroking. Add the close-path segment if the cursor
                    // hasn't already returned to the subpath start.
                    const implicit_close =
                        std.mem.eql(u8, op, "s") or
                        std.mem.eql(u8, op, "b") or
                        std.mem.eql(u8, op, "b*");
                    if (implicit_close) {
                        if (path_x != subpath_start_x or path_y != subpath_start_y) {
                            try path_segments.append(allocator, .{ .x0 = path_x, .y0 = path_y, .x1 = subpath_start_x, .y1 = subpath_start_y });
                        }
                        path_x = subpath_start_x; path_y = subpath_start_y;
                    }
                    // Path stroked — keep horizontal+vertical segments only.
                    for (path_segments.items) |seg| {
                        if (seg.isHorizontal() or seg.isVertical()) {
                            try out.append(allocator, seg);
                        }
                    }
                    path_segments.clearRetainingCapacity();
                } else if (std.mem.eql(u8, op, "n") or std.mem.eql(u8, op, "f") or
                    std.mem.eql(u8, op, "f*") or std.mem.eql(u8, op, "F"))
                {
                    // Unstroked path — discard segments.
                    path_segments.clearRetainingCapacity();
                } else if (std.mem.eql(u8, op, "Do") and last_name.len > 0) {
                    handleDoOperator(allocator, last_name, ctx, ctm, visited, out) catch |err| {
                        // OOM must propagate; everything else is a soft
                        // failure that should not abort outer collection.
                        if (err == error.OutOfMemory) return err;
                    };
                }
            },
        }
    }
}

/// Resolve an indirect reference, preserving `error.OutOfMemory` while
/// converting domain errors (CorruptObject etc.) into a soft `null`
/// return so callers can gracefully fall through.
///
/// Codex review v1.2-rc4 round 2 [P2]: previously each `catch return`
/// or `catch break` masked OOM as well, downgrading allocator pressure
/// to a silent skip. The contract for the lattice helpers is
/// "OOM bubbles, all other errors soft-fail" — this helper enforces it.
fn resolveRefSoft(doc: DocState, ref: parser.ObjRef) error{OutOfMemory}!?parser.Object {
    return pagetree.resolveRef(doc.parse_allocator, doc.data, doc.xref_table, ref, doc.object_cache) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return null;
    };
}

/// Decompress a stream's body, preserving `error.OutOfMemory` while
/// converting domain errors (corrupt filter chain, bad params) into a
/// `null` return.
fn decompressStreamSoft(
    doc: DocState,
    body: []const u8,
    filter: ?parser.Object,
    params: ?parser.Object,
) error{OutOfMemory}!?[]u8 {
    return decompress.decompressStream(doc.scratch_allocator, body, filter, params) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return null;
    };
}

/// Recurse into the Form XObject named `name`, appending strokes to
/// `out` in the parent's user-space coordinate frame.
///
/// `error.OutOfMemory` propagates so allocator pressure can't be silently
/// masked. All other errors (corrupt object stream, bad indirect ref,
/// missing Subtype, decode failure, visited cycle) result in a no-op
/// return.
fn handleDoOperator(
    allocator: std.mem.Allocator,
    name: []const u8,
    ctx: CollectContext,
    parent_ctm: Mat,
    visited: *std.AutoHashMap(u32, void),
    out: *std.ArrayList(Stroke),
) anyerror!void {
    if (ctx.depth >= MAX_XOBJECT_DEPTH) return;
    const resources = ctx.resources orelse return;
    const doc = ctx.doc orelse return;

    // Resolve `/XObject` dict (may be inline or an indirect reference).
    const xobjects_obj = resources.get("XObject") orelse return;
    const xobjects = switch (xobjects_obj) {
        .dict => |d| d,
        .reference => |ref| blk: {
            const resolved = (try resolveRefSoft(doc, ref)) orelse return;
            break :blk switch (resolved) {
                .dict => |d| d,
                else => return,
            };
        },
        else => return,
    };

    // Look up the named XObject (also possibly a reference).
    //
    // Codex round 20 [P2]: PDF spec §7.3.5 lets names in the content
    // stream use `#xx` escapes for special characters (e.g.
    // `/Fm#31 Do` is the same name as `/Fm1`). The dictionary parser
    // (`parser.zig::scanName`) decodes those escapes when building
    // resource keys, but `interpreter.ContentLexer.scanName` does
    // not — so a raw lookup with the lexer's bytes can miss a
    // legitimate match.
    //
    // PDFBox, MuPDF, and pdf.js all decode at the matching boundary.
    // Decode-then-lookup; if the name has no escapes the helper
    // returns the input slice unchanged (no allocation).
    var name_buf: [256]u8 = undefined;
    const decoded_name = decodePdfName(name, &name_buf);
    const xobj = xobjects.get(decoded_name) orelse return;
    var xobj_ref_num: ?u32 = null;
    const xobj_resolved = switch (xobj) {
        .stream => |s| s,
        .reference => |ref| blk: {
            xobj_ref_num = ref.num;
            // Cycle guard: if we're already inside this XObject, bail.
            if (visited.contains(ref.num)) return;
            const resolved = (try resolveRefSoft(doc, ref)) orelse return;
            break :blk switch (resolved) {
                .stream => |s| s,
                else => return,
            };
        },
        else => return,
    };

    // Form XObjects only — Image / PS XObjects don't contribute strokes.
    // Codex review v1.2-rc4 round 10 [P2]: /Subtype, /Filter, and
    // /DecodeParms can each be stored as an indirect reference per
    // PDF spec §7.3.10. Resolve them through resolveRefSoft (single
    // level) before consuming so a Form with `/Subtype 99 0 R` is
    // still recognized and a stream with `/Filter 99 0 R` is still
    // decoded.
    const subtype_obj = (try dictGetResolvedSoft(xobj_resolved.dict, "Subtype", doc)) orelse return;
    const subtype = switch (subtype_obj) {
        .name => |n| n,
        else => return,
    };
    if (!std.mem.eql(u8, subtype, "Form")) return;

    // Decompress the Form content stream into scratch memory.
    // Round 10 [P2] resolved indirect /Filter and /DecodeParms at the
    // dict-entry level. Round 11 [P2] additionally normalizes per-
    // element indirect refs inside their array shape so chains like
    // `/Filter [12 0 R]` survive through the decompressor. Round 18
    // [P2] adds inner-dict resolution for /DecodeParms — entries
    // like `/Predictor N 0 R` or `/Columns N 0 R` are now resolved
    // before the decompressor reads them.
    const filter_raw = try dictGetResolvedSoft(xobj_resolved.dict, "Filter", doc);
    const params_raw = try dictGetResolvedSoft(xobj_resolved.dict, "DecodeParms", doc);
    const filter = try normalizeFilterChain(filter_raw, doc);
    const params = try normalizeDecodeParms(params_raw, doc);
    const form_content = (try decompressStreamSoft(doc, xobj_resolved.data, filter, params)) orelse return;
    defer doc.scratch_allocator.free(form_content);

    // Compose the effective CTM for the Form's own content. Per PDF
    // spec §8.10: the Form's `/Matrix` (default identity) is applied
    // BEFORE the parent's CTM, i.e. effective = parent_ctm × form_matrix.
    const form_matrix = try readMatrix(xobj_resolved.dict, doc);
    const effective_ctm = form_matrix.mul(parent_ctm);

    // Form Resources lookup, four-state result:
    //   - Key ABSENT       → fall back to PAGE resources (§7.8.3).
    //   - Key PRESENT, .null → equivalent to absent per §7.3.9
    //     ("specifying the null object as the value of a dictionary
    //     entry shall be equivalent to omitting the entry entirely")
    //     → fall back to PAGE resources.
    //   - Key PRESENT, resolves to a Dict → use that dict.
    //   - Key PRESENT, non-null and non-dict (or indirect ref to
    //     non-dict / non-null) → fail closed: the Form declared its
    //     own (broken) resource scope and must NOT silently access
    //     the parent's /XObject map.
    //
    // Codex review v1.2-rc4 round 9 [P2]: parent-fallback for every
    // non-Dict shape was too permissive — fixed.
    // Round 16 [P2]: round-9 over-corrected by including .null;
    // spec §7.3.9 says .null == absent. Fixed.
    // Round 17 [P2]: when Form Resources is absent/null, the spec-
    // correct fallback is the PAGE Resources (preserved as
    // ctx.page_resources), not the calling Form's resources.
    // PDFBox and MuPDF agree. Previously we used `resources`
    // (= calling frame's), which differed only for nested Forms
    // where the outer Form shadowed page-level /XObject names.
    const page_fallback = ctx.page_resources orelse resources;
    const form_resources: ?parser.Object.Dict = blk: {
        const obj = xobj_resolved.dict.get("Resources") orelse break :blk page_fallback;
        break :blk switch (obj) {
            .dict => |d| d,
            .null => page_fallback,
            .reference => |ref| ref_blk: {
                const resolved = (try resolveRefSoft(doc, ref)) orelse break :ref_blk page_fallback;
                break :ref_blk switch (resolved) {
                    .dict => |d| d,
                    .null => page_fallback,
                    else => null,
                };
            },
            else => null,
        };
    };

    // Mark this XObject visited for the duration of the recursion so
    // that mutual references can't loop.
    if (xobj_ref_num) |n| try visited.put(n, {});
    defer {
        if (xobj_ref_num) |n| _ = visited.remove(n);
    }

    const child_ctx = CollectContext{
        .resources = form_resources,
        .page_resources = ctx.page_resources, // preserved across recursion
        .doc = doc,
        .depth = ctx.depth + 1,
        .initial_ctm = effective_ctm,
        .visited = visited,
    };

    // Codex review v1.2-rc4 round 4 [P2]: per PDF spec §8.10, a Form
    // XObject's `/BBox` is a *mandatory* clip region — content drawn
    // outside is invisible to the rasterizer. Lattice ignored this
    // and counted out-of-BBox strokes, which could surface phantom
    // tables that never render.
    //
    // Snapshot the stroke list length, run the recursion, then drop
    // strokes that fall entirely outside the BBox transformed into
    // user-space. Strokes crossing the boundary are kept (partial
    // visibility still contributes to row/column clusters).
    const snapshot = out.items.len;
    try collectStrokesWalk(allocator, form_content, child_ctx, visited, out);

    if (try readBBox(xobj_resolved.dict, doc)) |bbox_form| {
        // Codex review v1.2-rc4 round 6 [P2]: clipping against the
        // user-space AABB of a transformed /BBox is conservative —
        // for non-orthogonal CTMs (rotation, shear) it admits strokes
        // that fall outside the true rotated quadrilateral. Round-trip
        // each user-space stroke back to form-space via inverse_ctm,
        // clip against the form-space (axis-aligned) /BBox there, then
        // map clipped endpoints back to user-space.
        //
        // When effective_ctm is singular (det ≈ 0) we fall back to the
        // user-space AABB approach: the form is degenerate (collapsed
        // to a line or point), so any clipping policy will produce
        // collinear strokes that downstream filters drop anyway.
        if (effective_ctm.inverse()) |inv_ctm| {
            var write: usize = snapshot;
            var read: usize = snapshot;
            while (read < out.items.len) : (read += 1) {
                if (clipStrokeInFormSpace(out.items[read], bbox_form, inv_ctm, effective_ctm)) |clipped| {
                    out.items[write] = clipped;
                    write += 1;
                }
            }
            out.shrinkRetainingCapacity(write);
        } else {
            const clip_user = transformBBox(bbox_form, effective_ctm);
            var write: usize = snapshot;
            var read: usize = snapshot;
            while (read < out.items.len) : (read += 1) {
                if (clipStrokeToBox(out.items[read], clip_user)) |clipped| {
                    out.items[write] = clipped;
                    write += 1;
                }
            }
            out.shrinkRetainingCapacity(write);
        }
    }
}

/// Round-trip a user-space stroke into form-space, clip against the
/// axis-aligned form-space /BBox, then map back to user-space.
///
/// A form-space rotated `/BBox` is exact for any non-singular CTM —
/// strokes that touch the visible quadrilateral survive (with their
/// out-of-quad portions trimmed); strokes fully outside drop. After
/// the round-trip, axis-aligned strokes in form-space remain axis-
/// aligned in user-space too (the CTM is invertible affine), so
/// downstream `isHorizontal`/`isVertical` filters still apply.
fn clipStrokeInFormSpace(
    s: Stroke,
    bbox_form: [4]f64,
    inv_ctm: Mat,
    fwd_ctm: Mat,
) ?Stroke {
    // User-space → form-space.
    const a_form = inv_ctm.apply(s.x0, s.y0);
    const b_form = inv_ctm.apply(s.x1, s.y1);
    if (!std.math.isFinite(a_form.x) or !std.math.isFinite(a_form.y) or
        !std.math.isFinite(b_form.x) or !std.math.isFinite(b_form.y)) return null;

    const form_stroke = Stroke{
        .x0 = a_form.x, .y0 = a_form.y,
        .x1 = b_form.x, .y1 = b_form.y,
    };
    const clipped_form = clipStrokeToBox(form_stroke, bbox_form) orelse return null;

    // Form-space → user-space via the forward CTM.
    const a_back = fwd_ctm.apply(clipped_form.x0, clipped_form.y0);
    const b_back = fwd_ctm.apply(clipped_form.x1, clipped_form.y1);
    if (!std.math.isFinite(a_back.x) or !std.math.isFinite(a_back.y) or
        !std.math.isFinite(b_back.x) or !std.math.isFinite(b_back.y)) return null;

    return Stroke{
        .x0 = a_back.x, .y0 = a_back.y,
        .x1 = b_back.x, .y1 = b_back.y,
    };
}

/// Decode PDF name escapes (`#xx` → byte 0xXX) per ISO 32000-1
/// §7.3.5. The output is written into `out_buf`; if the input
/// contains no `#` byte the input slice is returned as-is (no
/// copy). On invalid escapes (truncated, non-hex), copies the raw
/// `#` byte through — same conservative recovery PDFBox uses.
///
/// Codex review v1.2-rc4 round 20 [P2]: ContentLexer.scanName does
/// not decode escapes, but parser.zig::scanName does, so dict keys
/// like `/Fm1` won't match a content-stream name like `/Fm#31`.
/// Apply this decoder at the lookup boundary.
fn decodePdfName(name: []const u8, out_buf: []u8) []const u8 {
    if (std.mem.indexOfScalar(u8, name, '#') == null) return name;
    var w: usize = 0;
    var i: usize = 0;
    while (i < name.len and w < out_buf.len) : (w += 1) {
        if (name[i] == '#' and i + 2 < name.len) {
            const hi = std.fmt.charToDigit(name[i + 1], 16) catch {
                out_buf[w] = name[i];
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(name[i + 2], 16) catch {
                out_buf[w] = name[i];
                i += 1;
                continue;
            };
            out_buf[w] = (hi << 4) | lo;
            i += 3;
        } else {
            out_buf[w] = name[i];
            i += 1;
        }
    }
    return out_buf[0..w];
}

/// Look up `key` in `dict`, following one level of indirect reference.
/// Returns null when the key is absent or the indirect target can't be
/// resolved. Codex review v1.2-rc4 round 10 [P2]: PDF dictionary
/// values like `/Subtype`, `/Filter`, `/DecodeParms` can legally be
/// indirect refs; this helper unifies the resolution policy.
fn dictGetResolvedSoft(dict: parser.Object.Dict, key: []const u8, doc: DocState) error{OutOfMemory}!?parser.Object {
    const obj = dict.get(key) orelse return null;
    return switch (obj) {
        .reference => |ref| try resolveRefSoft(doc, ref),
        else => obj,
    };
}

/// Normalize a filter-chain Object into a shape `decompress.decompressStream`
/// can consume — every member resolved through one level of indirect
/// reference.
///
/// Codex review v1.2-rc4 round 11 [P2]: `/Filter` and `/DecodeParms`
/// can be `[N 0 R N 0 R ...]` arrays where each element is itself an
/// indirect reference. Round-10 only resolved the outer dict entry;
/// any array members stayed as `.reference` and decompressStream
/// silently dropped them.
///
/// Allocates a fresh array on `doc.scratch_allocator` only when needed
/// (i.e. an indirect array member is found). Direct `.name` arrays
/// pass through unchanged.
fn normalizeFilterChain(obj: ?parser.Object, doc: DocState) error{OutOfMemory}!?parser.Object {
    const o = obj orelse return null;
    return switch (o) {
        .array => |arr| blk: {
            // First pass: do any elements need resolving?
            var needs_alloc = false;
            for (arr) |el| {
                if (el == .reference) {
                    needs_alloc = true;
                    break;
                }
            }
            if (!needs_alloc) break :blk o;

            // Second pass: build a new array with resolved elements.
            const out = doc.scratch_allocator.alloc(parser.Object, arr.len) catch return error.OutOfMemory;
            for (arr, 0..) |el, i| {
                out[i] = switch (el) {
                    .reference => |ref| (try resolveRefSoft(doc, ref)) orelse parser.Object{ .null = {} },
                    else => el,
                };
            }
            break :blk parser.Object{ .array = out };
        },
        else => o,
    };
}

/// Like `normalizeFilterChain`, but for `/DecodeParms`. Each member
/// of a `/DecodeParms` is itself a dict (e.g. FlateDecode params:
/// `<< /Predictor N /Columns N /Colors N /BitsPerComponent N >>`).
/// Per ISO 32000-1 §7.3.10, those inner entry values may legally be
/// indirect references. PDFBox dereferences them via FilterParameters;
/// pdf.js dereferences via parser auto-resolution; MuPDF documents
/// the same.
///
/// Codex review v1.2-rc4 round 18 [P2]: previously the lattice path
/// resolved the outer `/DecodeParms` and any wrapping array members
/// but left dict entries unresolved, so `decompressStream()`
/// (which reads `Predictor`/`Columns`/etc. with direct-only get)
/// silently used wrong values, post-predictor bytes leaked into
/// the parser, and tables were missed.
///
/// Allocations are scratch-allocated only when at least one inner
/// reference needs resolving. Direct-only inputs pass through
/// unchanged (slice ptr identity preserved).
fn normalizeDecodeParms(obj: ?parser.Object, doc: DocState) error{OutOfMemory}!?parser.Object {
    const o = obj orelse return null;
    return switch (o) {
        .dict => |d| try normalizeParamsDict(d, doc),
        .array => |arr| blk: {
            // Walk array; if any member is a dict that needs
            // normalization, build a fresh array with each dict
            // (recursively) normalized.
            var needs_alloc = false;
            for (arr) |el| {
                switch (el) {
                    .dict => |d| {
                        if (paramsDictNeedsAlloc(d)) {
                            needs_alloc = true;
                            break;
                        }
                    },
                    .reference => {
                        needs_alloc = true;
                        break;
                    },
                    else => {},
                }
            }
            if (!needs_alloc) break :blk o;

            const out = doc.scratch_allocator.alloc(parser.Object, arr.len) catch return error.OutOfMemory;
            for (arr, 0..) |el, i| {
                out[i] = switch (el) {
                    .reference => |ref| ref_blk: {
                        // Round 19 [P2]: when an array member resolves
                        // to a dict, normalize THAT dict's entries too
                        // so inner /Predictor N 0 R etc. don't survive.
                        const resolved = (try resolveRefSoft(doc, ref)) orelse break :ref_blk parser.Object{ .null = {} };
                        break :ref_blk switch (resolved) {
                            .dict => |d| try normalizeParamsDict(d, doc),
                            else => resolved,
                        };
                    },
                    .dict => |d| try normalizeParamsDict(d, doc),
                    else => el,
                };
            }
            break :blk parser.Object{ .array = out };
        },
        else => o,
    };
}

fn paramsDictNeedsAlloc(d: parser.Object.Dict) bool {
    for (d.entries) |e| if (e.value == .reference) return true;
    return false;
}

fn normalizeParamsDict(d: parser.Object.Dict, doc: DocState) error{OutOfMemory}!parser.Object {
    if (!paramsDictNeedsAlloc(d)) return parser.Object{ .dict = d };

    const new_entries = doc.scratch_allocator.alloc(parser.Object.Dict.Entry, d.entries.len) catch return error.OutOfMemory;
    for (d.entries, 0..) |e, i| {
        new_entries[i] = .{
            .key = e.key,
            .value = switch (e.value) {
                .reference => |ref| (try resolveRefSoft(doc, ref)) orelse parser.Object{ .null = {} },
                else => e.value,
            },
        };
    }
    return parser.Object{ .dict = .{ .entries = new_entries } };
}

/// Resolve a numeric Object element to f64, following one level of
/// indirect reference. Returns null on non-numeric / non-finite /
/// missing target. Codex review v1.2-rc4 round 8 [P2]: PDF arrays
/// can legally contain indirect numeric refs (e.g. `/BBox [11 0 R
/// 12 0 R 13 0 R 14 0 R]`). Both `readBBox` and `readMatrix` now
/// route per-element through this helper.
fn readNumberMaybeIndirect(obj: parser.Object, doc: DocState) error{OutOfMemory}!?f64 {
    const concrete = switch (obj) {
        .real, .integer => obj,
        .reference => |ref| (try resolveRefSoft(doc, ref)) orelse return null,
        else => return null,
    };
    const v: f64 = switch (concrete) {
        .real => |r| r,
        .integer => |n| @floatFromInt(n),
        else => return null,
    };
    if (!std.math.isFinite(v)) return null;
    return v;
}

/// Read a Form XObject's `/BBox` entry. Same indirect-ref + OOM
/// discipline as `readMatrix`. Returns null when missing or malformed
/// (treated as "no clip" — same as inline page content).
fn readBBox(dict: parser.Object.Dict, doc: DocState) error{OutOfMemory}!?[4]f64 {
    const obj = dict.get("BBox") orelse return null;
    const arr = switch (obj) {
        .array => |a| a,
        .reference => |ref| blk: {
            const resolved = (try resolveRefSoft(doc, ref)) orelse return null;
            break :blk switch (resolved) {
                .array => |a| a,
                else => return null,
            };
        },
        else => return null,
    };
    if (arr.len < 4) return null;
    var v: [4]f64 = undefined;
    for (0..4) |i| {
        v[i] = (try readNumberMaybeIndirect(arr[i], doc)) orelse return null;
    }
    // Normalize to [x_min, y_min, x_max, y_max] — PDF spec doesn't
    // require any particular corner ordering.
    return [4]f64{
        @min(v[0], v[2]),
        @min(v[1], v[3]),
        @max(v[0], v[2]),
        @max(v[1], v[3]),
    };
}

/// Transform a form-space bbox by the effective CTM into user-space.
/// All four corners are mapped (CTM may rotate), then the AABB is
/// returned. Conservative — a rotated form's true clip region is a
/// tilted rectangle, but treating it as the AABB is sound (it only
/// preserves *more* strokes than strictly needed, never drops a
/// visible one).
fn transformBBox(bb: [4]f64, ctm: Mat) [4]f64 {
    const c0 = ctm.apply(bb[0], bb[1]);
    const c1 = ctm.apply(bb[2], bb[1]);
    const c2 = ctm.apply(bb[2], bb[3]);
    const c3 = ctm.apply(bb[0], bb[3]);
    return [4]f64{
        @min(@min(c0.x, c1.x), @min(c2.x, c3.x)),
        @min(@min(c0.y, c1.y), @min(c2.y, c3.y)),
        @max(@max(c0.x, c1.x), @max(c2.x, c3.x)),
        @max(@max(c0.y, c1.y), @max(c2.y, c3.y)),
    };
}

/// True iff the stroke's AABB is fully outside the user-space clip box.
fn strokeOutsideBox(s: Stroke, box: [4]f64) bool {
    const min_x = @min(s.x0, s.x1);
    const max_x = @max(s.x0, s.x1);
    const min_y = @min(s.y0, s.y1);
    const max_y = @max(s.y0, s.y1);
    return max_x < box[0] or min_x > box[2] or
        max_y < box[1] or min_y > box[3];
}

/// Clip an arbitrary line segment to an axis-aligned box using the
/// Liang–Barsky algorithm. Returns null if the segment is fully
/// outside; otherwise returns the visible portion.
///
/// Codex review v1.2-rc4 round 7 [P2]: the previous axis-aligned-only
/// clipper handled horizontal/vertical strokes correctly but left
/// diagonal segments untouched. After the form-space round-trip
/// (round 6) a user-space axis-aligned stroke can become a diagonal
/// form-space segment that crosses the /BBox boundary; the old
/// helper would keep it at full length, leaking invisible tails back
/// into user-space and inflating the detected table bbox.
///
/// Liang–Barsky handles arbitrary line orientations against an AABB
/// in O(1) and falls through to a clean axis-aligned clamp when
/// `dx` or `dy` is zero (parallel-to-edge case).
fn clipStrokeToBox(s: Stroke, box: [4]f64) ?Stroke {
    const dx = s.x1 - s.x0;
    const dy = s.y1 - s.y0;
    if (!std.math.isFinite(dx) or !std.math.isFinite(dy)) return null;
    var t0: f64 = 0.0;
    var t1: f64 = 1.0;

    // p[i] is the directional gradient against edge i; q[i] is the
    // signed distance from the start point to edge i. The four edges
    // are: left (xmin), right (xmax), bottom (ymin), top (ymax).
    const p = [4]f64{ -dx, dx, -dy, dy };
    const q = [4]f64{
        s.x0 - box[0],
        box[2] - s.x0,
        s.y0 - box[1],
        box[3] - s.y0,
    };

    inline for (0..4) |i| {
        if (p[i] == 0.0) {
            // Line is parallel to this edge AND start point is outside.
            if (q[i] < 0.0) return null;
        } else {
            const t = q[i] / p[i];
            if (p[i] < 0.0) {
                if (t > t1) return null;
                if (t > t0) t0 = t;
            } else {
                if (t < t0) return null;
                if (t < t1) t1 = t;
            }
        }
    }
    if (t0 > t1) return null;

    return Stroke{
        .x0 = s.x0 + t0 * dx,
        .y0 = s.y0 + t0 * dy,
        .x1 = s.x0 + t1 * dx,
        .y1 = s.y0 + t1 * dy,
    };
}

/// Read a Form XObject's `/Matrix` entry into a `Mat`.
/// Falls back to identity when missing or malformed.
///
/// Codex review v1.2-rc4 round 1 [P2]: `/Matrix` is legally allowed to
/// be an indirect reference (e.g. `/Matrix 8 0 R`). Round 2 [P2]: the
/// indirect-ref resolution must propagate `error.OutOfMemory` rather
/// than masking it as a soft identity-fallback. Returns an error
/// union now; the caller `try`s.
fn readMatrix(dict: parser.Object.Dict, doc: DocState) error{OutOfMemory}!Mat {
    const obj = dict.get("Matrix") orelse return Mat{};
    const arr = switch (obj) {
        .array => |a| a,
        .reference => |ref| blk: {
            const resolved = (try resolveRefSoft(doc, ref)) orelse return Mat{};
            break :blk switch (resolved) {
                .array => |a| a,
                else => return Mat{},
            };
        },
        else => return Mat{},
    };
    if (arr.len < 6) return Mat{};
    var v: [6]f64 = undefined;
    for (0..6) |i| {
        v[i] = (try readNumberMaybeIndirect(arr[i], doc)) orelse return Mat{};
    }
    return Mat{ .a = v[0], .b = v[1], .c = v[2], .d = v[3], .e = v[4], .f = v[5] };
}

const Cluster = struct { coord: f64, members: std.ArrayList(Stroke) };

/// Cluster horizontal strokes by Y, vertical strokes by X. Returns
/// arrays of clusters sorted by coord ascending. Each cluster's
/// `members.items` are the strokes that share that coord (within
/// COORD_TOLERANCE).
///
/// Codex review v1.2-rc1 [P1]: clustering walks a coord-sorted copy of
/// the strokes, not the original stream-order list. Without the sort
/// step, strokes painted in interleaved order (e.g. cell-by-cell rule
/// drawing where y=100 strokes appear before, after, and between y=200
/// strokes) start a new cluster on each occurrence and the row-count
/// blows up.
fn clusterByCoord(
    allocator: std.mem.Allocator,
    strokes: []const Stroke,
    horizontal: bool,
) ![]Cluster {
    var filtered: std.ArrayList(Stroke) = .empty;
    defer filtered.deinit(allocator);
    for (strokes) |s| {
        if (horizontal != s.isHorizontal()) continue;
        try filtered.append(allocator, s);
    }
    if (filtered.items.len == 0) return &.{};

    const coordLessThan = struct {
        fn lt(_: void, a: Stroke, b: Stroke) bool {
            const ca = if (a.isHorizontal()) a.y0 else a.x0;
            const cb = if (b.isHorizontal()) b.y0 else b.x0;
            return ca < cb;
        }
    }.lt;
    std.mem.sort(Stroke, filtered.items, {}, coordLessThan);

    var out: std.ArrayList(Cluster) = .empty;
    errdefer {
        for (out.items) |*c| c.members.deinit(allocator);
        out.deinit(allocator);
    }
    const first_c = if (filtered.items[0].isHorizontal()) filtered.items[0].y0 else filtered.items[0].x0;
    var current_coord = first_c;
    var current = Cluster{ .coord = current_coord, .members = .empty };
    // Codex review v1.2-rc4 PR-4 round 2 [P3 fallout]: `current` holds
    // an in-flight ArrayList that is NOT yet owned by `out`. Without
    // this guard, an OOM from `current.members.append` or the next
    // `out.append(current)` leaks `current.members`'s buffer. Cleared
    // after each successful transfer of `current` into `out`.
    var current_owned = true;
    errdefer if (current_owned) current.members.deinit(allocator);
    for (filtered.items) |s| {
        const c = if (s.isHorizontal()) s.y0 else s.x0;
        if (@abs(c - current_coord) > COORD_TOLERANCE) {
            try out.append(allocator, current);
            current_owned = false;
            current_coord = c;
            current = Cluster{ .coord = c, .members = .empty };
            current_owned = true;
        }
        try current.members.append(allocator, s);
    }
    try out.append(allocator, current);
    current_owned = false;
    return out.toOwnedSlice(allocator);
}

const PageGrid = struct {
    /// 1-based page number to attach to emitted tables.
    page: u32,
};

/// PR-4 [feat]: build lattice cells with per-cell text by
/// intersecting `extractTextWithBounds` spans against each cell's
/// bbox. Mirrors stream_table.zig::buildCellsWithText but uses
/// rectangular bbox containment (cells have explicit bboxes from
/// the lattice grid) instead of x-anchor matching.
///
/// A span is assigned to a cell iff its glyph CENTER lands inside
/// the cell's `[col_lines[c], row_lines[r], col_lines[c+1],
/// row_lines[r+1]]` rectangle. Glyph centers landing exactly on a
/// boundary stick to the cell whose lower-left corner is closer
/// (i.e. inclusive on left/bottom, exclusive on right/top) — this
/// matches Pass C's `anchorIndex` tie-breaking.
///
/// Span order within each cell is the input span order (typically
/// PDF stream order via `extractTextWithBounds`), so concatenated
/// text reads naturally. Spans are joined by single spaces; empty
/// cells get `text = null`.
///
/// Codex review v1.2-rc4 PR-4 round 0 [P2 anticipated]: spans whose
/// centers fall outside ALL cells (i.e. between table borders or
/// outside the table bbox) are dropped silently — they're outside
/// the structured table's scope and would be picked up by Pass C
/// or normal text extraction if needed.
fn buildLatticeCellsWithText(
    allocator: std.mem.Allocator,
    n_rows: u32,
    n_cols: u32,
    row_lines: []const f64,
    col_lines: []const f64,
    spans: []const layout.TextSpan,
) ![]tables.Cell {
    const total = @as(usize, n_rows) * @as(usize, n_cols);
    const cells = try allocator.alloc(tables.Cell, total);
    errdefer allocator.free(cells);

    // Per-cell text accumulators.
    const bufs = try allocator.alloc(std.ArrayList(u8), total);
    defer allocator.free(bufs);
    for (bufs) |*b| b.* = .empty;
    errdefer for (bufs) |*b| b.deinit(allocator);

    // Assign spans to cells via glyph-center bbox containment.
    for (spans) |span| {
        if (!std.math.isFinite(span.x0) or !std.math.isFinite(span.y0)) continue;
        if (!std.math.isFinite(span.x1) or !std.math.isFinite(span.y1)) continue;
        const cx = (span.x0 + span.x1) * 0.5;
        const cy = (span.y0 + span.y1) * 0.5;

        // Find row: r such that row_lines[r] <= cy < row_lines[r+1].
        // Inclusive on lower edge, exclusive on upper — same
        // tie-breaking discipline as Pass C's anchorIndex.
        const r = locateBin(row_lines, cy) orelse continue;
        if (r >= n_rows) continue;
        const c = locateBin(col_lines, cx) orelse continue;
        if (c >= n_cols) continue;

        const idx = @as(usize, r) * @as(usize, n_cols) + @as(usize, c);
        if (bufs[idx].items.len > 0) try bufs[idx].append(allocator, ' ');
        try bufs[idx].appendSlice(allocator, span.text);
    }

    // Materialise cells. Codex review v1.2-rc4 PR-4 round 1 [P2]:
    // each successful `bufs[idx].toOwnedSlice` transfers ownership
    // to `cells[idx].text`; if a LATER toOwnedSlice fails the
    // already-materialised text would leak (the bufs errdefer only
    // covers ArrayLists still holding their buffer, and the cells
    // errdefer only frees the slice header). Track the count and
    // free initialised cell texts on error.
    var cells_initialised: usize = 0;
    errdefer for (cells[0..cells_initialised]) |c| {
        if (c.text) |txt| allocator.free(txt);
    };
    // Codex review v1.2-rc4 PR-4d round 0 [P1 latent]: parallel to
    // stream_table.zig — do NOT call `bufs[idx].deinit(allocator)`
    // for empty cells. ArrayList.deinit sets `self.* = undefined`
    // (0xaa under safe build); a subsequent toOwnedSlice failure
    // would re-fire the bufs errdefer and dereference the poisoned
    // entries. Empty bufs (capacity = 0) are no-op-deinit at the
    // errdefer site anyway, so dropping the explicit call is safe.
    // This was unreached in the existing FailingAllocator test
    // because the test data places all non-empty cells before
    // empty ones, but the latent bug would surface with different
    // data; keep the fix in lock-step with stream_table.
    var idx: usize = 0;
    var r: u32 = 0;
    while (r < n_rows) : (r += 1) {
        var c: u32 = 0;
        while (c < n_cols) : (c += 1) {
            const text = if (bufs[idx].items.len > 0) try bufs[idx].toOwnedSlice(allocator) else null;
            cells[idx] = .{ .r = r, .c = c, .rowspan = 1, .colspan = 1, .is_header = false, .text = text };
            idx += 1;
            cells_initialised += 1;
        }
    }
    return cells;
}

/// Locate the bin index `i` such that `lines[i] <= value < lines[i+1]`.
/// Returns null when `value` is outside `[lines[0], lines[len-1])` or
/// when `lines.len < 2`.
fn locateBin(lines: []const f64, value: f64) ?u32 {
    if (lines.len < 2) return null;
    if (value < lines[0]) return null;
    if (value >= lines[lines.len - 1]) return null;
    // Linear scan — `lines.len` is bounded by the row/col count of a
    // single table, typically ≤ 30.
    var i: usize = 0;
    while (i + 1 < lines.len) : (i += 1) {
        if (value >= lines[i] and value < lines[i + 1]) return @intCast(i);
    }
    return null;
}

/// Detect tables in a single page's stroke set. Returns slice of Table
/// records (engine = .lattice). Caller frees via `tables.freeTables`.
///
/// PR-4 [feat]: when `spans` is non-empty, every detected cell's
/// `.text` is populated by intersecting glyph centers against the
/// cell's bbox. Pass `&.{}` from unit tests / call sites that
/// don't have spans (cells get text=null, the legacy v1.2-rc3
/// behavior). `spans` are typically the result of
/// `Document.extractTextWithBounds` on the same page; iteration
/// order is preserved within each cell so concatenated text reads
/// in stream order.
pub fn extractFromStrokes(
    allocator: std.mem.Allocator,
    strokes: []const Stroke,
    page: u32,
    spans: []const layout.TextSpan,
) ![]tables.Table {
    var out: std.ArrayList(tables.Table) = .empty;
    errdefer {
        for (out.items) |t| {
            for (t.cells) |c| if (c.text) |txt| allocator.free(txt);
            allocator.free(t.cells);
        }
        out.deinit(allocator);
    }
    if (strokes.len < 4) return out.toOwnedSlice(allocator); // ≥2 H + ≥2 V required

    const h_clusters = try clusterByCoord(allocator, strokes, true);
    defer {
        for (h_clusters) |*c| c.members.deinit(allocator);
        allocator.free(h_clusters);
    }
    const v_clusters = try clusterByCoord(allocator, strokes, false);
    defer {
        for (v_clusters) |*c| c.members.deinit(allocator);
        allocator.free(v_clusters);
    }

    if (h_clusters.len < 2 or v_clusters.len < 2) {
        return out.toOwnedSlice(allocator);
    }

    // Find table extent: the bounding rect of strokes that have at
    // least one match on both axes. Simple v1: take the outermost
    // horizontals as top/bottom and outermost verticals as left/right
    // of one big table. This handles the common single-table-per-page
    // case (spa price lists, factsheets). Multi-table-per-page is a
    // v1.2.W3 follow-up.
    const top = h_clusters[h_clusters.len - 1].coord;
    const bottom = h_clusters[0].coord;
    const left = v_clusters[0].coord;
    const right = v_clusters[v_clusters.len - 1].coord;

    if (top - bottom < MIN_STROKE_LEN or right - left < MIN_STROKE_LEN) {
        return out.toOwnedSlice(allocator);
    }

    // Filter h_clusters that span at least 50% of (left..right) — these
    // are real row separators; tiny stubs are kerning rules etc.
    var row_lines: std.ArrayList(f64) = .empty;
    defer row_lines.deinit(allocator);
    const min_h_span = (right - left) * 0.5;
    for (h_clusters) |cl| {
        var max_span: f64 = 0;
        for (cl.members.items) |s| {
            const span = @abs(s.x1 - s.x0);
            if (span > max_span) max_span = span;
        }
        if (max_span >= min_h_span) try row_lines.append(allocator, cl.coord);
    }

    // Same for verticals — must span at least 50% of (bottom..top).
    var col_lines: std.ArrayList(f64) = .empty;
    defer col_lines.deinit(allocator);
    const min_v_span = (top - bottom) * 0.5;
    for (v_clusters) |cl| {
        var max_span: f64 = 0;
        for (cl.members.items) |s| {
            const span = @abs(s.y1 - s.y0);
            if (span > max_span) max_span = span;
        }
        if (max_span >= min_v_span) try col_lines.append(allocator, cl.coord);
    }

    if (row_lines.items.len < 2 or col_lines.items.len < 2) {
        return out.toOwnedSlice(allocator);
    }

    const n_rows: u32 = @intCast(row_lines.items.len - 1);
    const n_cols: u32 = @intCast(col_lines.items.len - 1);

    // PR-4 [feat]: build the cells array with text from glyph-center
    // intersection. row_lines/col_lines are sorted ascending; they
    // come from clusterByCoord. Per the existing convention, r=0 is
    // the BOTTOM row (smallest y), c=0 is the LEFT column (smallest
    // x). Cell (r, c) bbox = [col_lines[c], row_lines[r],
    // col_lines[c+1], row_lines[r+1]].
    const cells = try buildLatticeCellsWithText(
        allocator,
        n_rows,
        n_cols,
        row_lines.items,
        col_lines.items,
        spans,
    );
    // Codex review v1.2-rc4 PR-4 round 1 [P1]: ownership transfer
    // guard. Until `out.append` succeeds, this errdefer owns
    // `cells`; after, ownership lives in `out.items` and the outer
    // errdefer (which now also frees per-cell text) is the sole
    // owner. Without the flag, an OOM from `out.toOwnedSlice` would
    // double-free `cells`.
    var cells_owned = true;
    errdefer if (cells_owned) {
        for (cells) |c| if (c.text) |txt| allocator.free(txt);
        allocator.free(cells);
    };

    try out.append(allocator, .{
        .page = page,
        .id = 0,
        .n_rows = n_rows,
        .n_cols = n_cols,
        .header_rows = 0,
        .cells = cells,
        .engine = .lattice,
        .confidence = 0.85, // baseline; refined by Pass D heuristics
        .bbox = .{ left, bottom, right, top },
    });
    cells_owned = false;

    return out.toOwnedSlice(allocator);
}

// ---- tests ----

test "isHorizontal/Vertical classify strokes within tolerance" {
    const h = Stroke{ .x0 = 10, .y0 = 100, .x1 = 200, .y1 = 100 };
    const v = Stroke{ .x0 = 50, .y0 = 50, .x1 = 50, .y1 = 250 };
    try std.testing.expect(h.isHorizontal());
    try std.testing.expect(!h.isVertical());
    try std.testing.expect(v.isVertical());
    try std.testing.expect(!v.isHorizontal());
}

test "collectStrokes from a synthetic 'm 10 100 m 200 100 l S' content stream" {
    const a = std.testing.allocator;
    const content = "10 100 m 200 100 l S\n";
    const got = try collectStrokes(a, content);
    defer a.free(got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expect(got[0].isHorizontal());
}

test "collectStrokes on an `re` rectangle yields 4 segments (2H + 2V)" {
    const a = std.testing.allocator;
    const content = "10 50 200 100 re S\n"; // x=10 y=50 w=200 h=100
    const got = try collectStrokes(a, content);
    defer a.free(got);
    try std.testing.expectEqual(@as(usize, 4), got.len);
    var horiz: usize = 0;
    var vert: usize = 0;
    for (got) |s| {
        if (s.isHorizontal()) horiz += 1;
        if (s.isVertical()) vert += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), horiz);
    try std.testing.expectEqual(@as(usize, 2), vert);
}

test "extractFromStrokes builds a 2x3 grid from synthetic strokes" {
    const a = std.testing.allocator;
    // 3 horizontal lines (y=100, 200, 300) + 4 vertical lines (x=50, 150, 250, 350)
    // → 2 rows × 3 cols
    const strokes = [_]Stroke{
        .{ .x0 = 50, .y0 = 100, .x1 = 350, .y1 = 100 },
        .{ .x0 = 50, .y0 = 200, .x1 = 350, .y1 = 200 },
        .{ .x0 = 50, .y0 = 300, .x1 = 350, .y1 = 300 },
        .{ .x0 = 50, .y0 = 100, .x1 = 50, .y1 = 300 },
        .{ .x0 = 150, .y0 = 100, .x1 = 150, .y1 = 300 },
        .{ .x0 = 250, .y0 = 100, .x1 = 250, .y1 = 300 },
        .{ .x0 = 350, .y0 = 100, .x1 = 350, .y1 = 300 },
    };
    const out = try extractFromStrokes(a, &strokes, 1, &.{});
    defer tables.freeTables(a, out);

    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqual(@as(u32, 2), out[0].n_rows);
    try std.testing.expectEqual(@as(u32, 3), out[0].n_cols);
    try std.testing.expectEqual(@as(usize, 6), out[0].cells.len);
    try std.testing.expectEqual(tables.Engine.lattice, out[0].engine);
}

// Codex review v1.2-rc4 PR-4 round 2 [P3]: stress R1/R2/R3 errdefer
// paths with FailingAllocator. Each fail_index from 0..N forces
// allocator.alloc to fail at exactly that step, exercising every
// errdefer between buildLatticeCellsWithText (toOwnedSlice failure
// scenarios) and extractFromStrokes (cells_owned flag flip).
test "extractFromStrokes survives every allocation failure index" {
    const strokes = [_]Stroke{
        .{ .x0 = 50, .y0 = 100, .x1 = 350, .y1 = 100 },
        .{ .x0 = 50, .y0 = 200, .x1 = 350, .y1 = 200 },
        .{ .x0 = 50, .y0 = 300, .x1 = 350, .y1 = 300 },
        .{ .x0 = 50, .y0 = 100, .x1 = 50, .y1 = 300 },
        .{ .x0 = 150, .y0 = 100, .x1 = 150, .y1 = 300 },
        .{ .x0 = 250, .y0 = 100, .x1 = 250, .y1 = 300 },
        .{ .x0 = 350, .y0 = 100, .x1 = 350, .y1 = 300 },
    };
    // Spans place glyph centers in 4 of the 6 cells (2×3 grid).
    const spans = [_]layout.TextSpan{
        .{ .x0 = 95, .y0 = 145, .x1 = 105, .y1 = 155, .text = "a", .font_size = 10 },
        .{ .x0 = 195, .y0 = 145, .x1 = 205, .y1 = 155, .text = "bc", .font_size = 10 },
        .{ .x0 = 295, .y0 = 145, .x1 = 305, .y1 = 155, .text = "def", .font_size = 10 },
        .{ .x0 = 95, .y0 = 245, .x1 = 105, .y1 = 255, .text = "ghij", .font_size = 10 },
    };

    var fail_index: usize = 0;
    while (fail_index < 128) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const result = extractFromStrokes(failing.allocator(), &strokes, 1, &spans);
        if (result) |out| {
            tables.freeTables(failing.allocator(), out);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
        // Either way, FailingAllocator's underlying gpa would have
        // detected leaks at deinit; std.testing.allocator is a leak-
        // checking allocator, so any leak crashes the test.
    }
}

test "extractFromStrokes populates cell text from spans" {
    const a = std.testing.allocator;
    const strokes = [_]Stroke{
        .{ .x0 = 50, .y0 = 100, .x1 = 350, .y1 = 100 },
        .{ .x0 = 50, .y0 = 200, .x1 = 350, .y1 = 200 },
        .{ .x0 = 50, .y0 = 300, .x1 = 350, .y1 = 300 },
        .{ .x0 = 50, .y0 = 100, .x1 = 50, .y1 = 300 },
        .{ .x0 = 150, .y0 = 100, .x1 = 150, .y1 = 300 },
        .{ .x0 = 250, .y0 = 100, .x1 = 250, .y1 = 300 },
        .{ .x0 = 350, .y0 = 100, .x1 = 350, .y1 = 300 },
    };
    const spans = [_]layout.TextSpan{
        .{ .x0 = 100, .y0 = 150, .x1 = 110, .y1 = 160, .text = "ab", .font_size = 10 },
    };
    const out = try extractFromStrokes(a, &strokes, 1, &spans);
    defer tables.freeTables(a, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "extractFromStrokes returns no table when fewer than 2 cluster lines on either axis" {
    const a = std.testing.allocator;
    const strokes = [_]Stroke{
        .{ .x0 = 50, .y0 = 100, .x1 = 350, .y1 = 100 },
        .{ .x0 = 50, .y0 = 100, .x1 = 50, .y1 = 300 },
    };
    const out = try extractFromStrokes(a, &strokes, 1, &.{});
    defer tables.freeTables(a, out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

// ----- Form XObject Do recursion (PR-1) -----

test "collectStrokes (legacy entry) ignores Do operator without context" {
    // Backward-compat guard: the no-ctx public entry must treat `Do`
    // as a silent no-op so existing callers see zero behavioural change.
    const a = std.testing.allocator;
    const content = "10 100 m 200 100 l S\n/Foo Do\n";
    const got = try collectStrokes(a, content);
    defer a.free(got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expect(got[0].isHorizontal());
}

test "collectStrokesIn with empty context ignores Do" {
    // ctx = .{} ⇒ resources = null and doc = null; the Do handler must
    // bail before doing any allocation or lookup.
    const a = std.testing.allocator;
    const content = "/Foo Do\n10 100 m 200 100 l S\n";
    const got = try collectStrokesIn(a, content, .{});
    defer a.free(got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
}

test "collectStrokesIn with empty content returns no strokes and no leak" {
    const a = std.testing.allocator;
    const got = try collectStrokesIn(a, "", .{});
    defer a.free(got);
    try std.testing.expectEqual(@as(usize, 0), got.len);
}

test "Do without a preceding name is ignored" {
    // last_name is reset after every operator, so a bare `Do` with no
    // preceding /Name has nothing to look up. Must not crash, must not
    // leak a partial entry into the visited set.
    const a = std.testing.allocator;
    const content = "Do\n10 100 m 200 100 l S\n";
    const got = try collectStrokesIn(a, content, .{});
    defer a.free(got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
}

test "MAX_XOBJECT_DEPTH is non-zero" {
    // Sanity guard against accidental zeroing — depth cap = 0 would
    // disable Form XObject recursion entirely.
    try std.testing.expect(MAX_XOBJECT_DEPTH >= 1);
}

// ----- clipStrokeToBox (Liang–Barsky, PR-1 round 7 [P2] regression) -----

test "clipStrokeToBox axis-aligned horizontal stroke fully inside" {
    const s = Stroke{ .x0 = 50, .y0 = 100, .x1 = 200, .y1 = 100 };
    const r = clipStrokeToBox(s, .{ 0, 0, 300, 300 }) orelse unreachable;
    try std.testing.expectEqual(@as(f64, 50), r.x0);
    try std.testing.expectEqual(@as(f64, 200), r.x1);
}

test "clipStrokeToBox axis-aligned horizontal stroke crossing right edge" {
    const s = Stroke{ .x0 = 50, .y0 = 100, .x1 = 500, .y1 = 100 };
    const r = clipStrokeToBox(s, .{ 0, 0, 300, 300 }) orelse unreachable;
    try std.testing.expectApproxEqAbs(@as(f64, 50), r.x0, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 300), r.x1, 1e-9);
}

test "clipStrokeToBox axis-aligned vertical stroke crossing both edges" {
    const s = Stroke{ .x0 = 50, .y0 = -10, .x1 = 50, .y1 = 400 };
    const r = clipStrokeToBox(s, .{ 0, 0, 300, 300 }) orelse unreachable;
    try std.testing.expectApproxEqAbs(@as(f64, 0), r.y0, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 300), r.y1, 1e-9);
}

test "clipStrokeToBox stroke fully outside box returns null" {
    const s = Stroke{ .x0 = -50, .y0 = -50, .x1 = -10, .y1 = -10 };
    try std.testing.expect(clipStrokeToBox(s, .{ 0, 0, 100, 100 }) == null);
}

test "clipStrokeToBox diagonal stroke crossing box clamps both endpoints" {
    // Codex round-7 counterexample: form-space segment (0,0)→(100,100)
    // clipped against /BBox [0,0,50,50] should yield (0,0)→(50,50).
    const s = Stroke{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 100 };
    const r = clipStrokeToBox(s, .{ 0, 0, 50, 50 }) orelse unreachable;
    try std.testing.expectApproxEqAbs(@as(f64, 0), r.x0, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), r.y0, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 50), r.x1, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 50), r.y1, 1e-9);
}

test "clipStrokeToBox diagonal stroke trimmed at near and far edges" {
    // (-50, -50) → (150, 150) intersects [0,0,100,100] at (0,0) and (100,100).
    const s = Stroke{ .x0 = -50, .y0 = -50, .x1 = 150, .y1 = 150 };
    const r = clipStrokeToBox(s, .{ 0, 0, 100, 100 }) orelse unreachable;
    try std.testing.expectApproxEqAbs(@as(f64, 0), r.x0, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), r.y0, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 100), r.x1, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 100), r.y1, 1e-9);
}

test "clipStrokeToBox diagonal stroke entirely outside (parallel-but-displaced)" {
    // 45° line above the box.
    const s = Stroke{ .x0 = 200, .y0 = 250, .x1 = 250, .y1 = 300 };
    try std.testing.expect(clipStrokeToBox(s, .{ 0, 0, 100, 100 }) == null);
}

test "clipStrokeToBox horizontal-on-edge stroke survives" {
    // Stroke runs ON the bottom edge — q[i] == 0 path.
    const s = Stroke{ .x0 = 10, .y0 = 0, .x1 = 90, .y1 = 0 };
    const r = clipStrokeToBox(s, .{ 0, 0, 100, 100 }) orelse unreachable;
    try std.testing.expectEqual(@as(f64, 10), r.x0);
    try std.testing.expectEqual(@as(f64, 90), r.x1);
}

test "clipStrokeToBox NaN endpoint returns null" {
    const s = Stroke{ .x0 = std.math.nan(f64), .y0 = 0, .x1 = 100, .y1 = 100 };
    try std.testing.expect(clipStrokeToBox(s, .{ 0, 0, 100, 100 }) == null);
}

// ----- Mat.inverse (PR-1 round 6 [P2] regression) -----

test "Mat.inverse on identity returns identity" {
    const m = Mat{};
    const inv = m.inverse() orelse unreachable;
    try std.testing.expectApproxEqAbs(@as(f64, 1), inv.a, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0), inv.b, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0), inv.c, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1), inv.d, 1e-12);
}

test "Mat.inverse round-trip on translation+rotation" {
    // 90° CCW + translate (e=10, f=20).
    const m = Mat{ .a = 0, .b = 1, .c = -1, .d = 0, .e = 10, .f = 20 };
    const inv = m.inverse() orelse unreachable;
    const p = m.apply(5, 7);
    const back = inv.apply(p.x, p.y);
    try std.testing.expectApproxEqAbs(@as(f64, 5), back.x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 7), back.y, 1e-9);
}

test "Mat.inverse on singular matrix returns null" {
    // Two columns linearly dependent → det = 0.
    const m = Mat{ .a = 1, .b = 2, .c = 2, .d = 4, .e = 0, .f = 0 };
    try std.testing.expect(m.inverse() == null);
}

// ----- CTM concatenation invariant (PR-1 round 15) -----
//
// Per PDF Reference §4.2.3 / PDF 2.0 §8.3.2: the cm operator
// concatenates a matrix to the CTM such that the new CTM is
// `M × CTM_old`, where M is the operand. In row-vector form
// (used by PDF and `Mat.apply`), this means subsequent points are
// transformed as `x × M × CTM_old` — the most-recent cm is applied
// FIRST to the local coordinates, the earlier CTM is applied
// SECOND. PDFBox, MuPDF, and pdf.js all use this convention.
//
// Codex round 15 [P2] claimed `m.mul(ctm)` was reversed; that
// finding was REJECTED as a spec misread. This test locks in
// the correct semantics.
test "CTM concatenation: scale then translate maps x=0 to 100" {
    var ctm = Mat{}; // identity
    // First cm: scale by 2.
    const m1 = Mat{ .a = 2, .b = 0, .c = 0, .d = 2, .e = 0, .f = 0 };
    ctm = m1.mul(ctm);
    // Second cm: translate by +50 in x.
    const m2 = Mat{ .a = 1, .b = 0, .c = 0, .d = 1, .e = 50, .f = 0 };
    ctm = m2.mul(ctm);
    // Local origin (0, 0) → device:
    //   apply translate first: (0,0) → (50,0)
    //   apply scale second:    (50,0) → (100,0)
    const p = ctm.apply(0, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 100), p.x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), p.y, 1e-9);
}

// ----- decodePdfName (PR-1 round 20 [P2] regression) -----

test "decodePdfName passes plain names unchanged (no allocation)" {
    var buf: [16]u8 = undefined;
    const out = decodePdfName("Fm1", &buf);
    // Slice identity: result points at the input, no copy.
    try std.testing.expect(out.ptr == "Fm1".ptr);
    try std.testing.expectEqualStrings("Fm1", out);
}

test "decodePdfName decodes #xx hex escapes" {
    var buf: [16]u8 = undefined;
    // #31 = 0x31 = '1' → "Fm1"
    try std.testing.expectEqualStrings("Fm1", decodePdfName("Fm#31", &buf));
    // #20 = 0x20 = ' ' → "A B"
    try std.testing.expectEqualStrings("A B", decodePdfName("A#20B", &buf));
    // ## sequence → "#" (decodes #23 = '#')
    try std.testing.expectEqualStrings("#", decodePdfName("#23", &buf));
}

test "decodePdfName tolerates malformed trailing escape" {
    var buf: [16]u8 = undefined;
    // Truncated `#3` (missing second hex digit) — pass # through.
    const out = decodePdfName("Fm#3", &buf);
    try std.testing.expectEqualStrings("Fm#3", out);
}

test "decodePdfName tolerates non-hex escape" {
    var buf: [16]u8 = undefined;
    // `#zz` — invalid hex → pass # through and continue.
    try std.testing.expectEqualStrings("F#zz", decodePdfName("F#zz", &buf));
}

test "CTM concatenation: distinct point shows scale applied after translate" {
    var ctm = Mat{};
    const m1 = Mat{ .a = 2, .b = 0, .c = 0, .d = 2, .e = 0, .f = 0 };
    ctm = m1.mul(ctm);
    const m2 = Mat{ .a = 1, .b = 0, .c = 0, .d = 1, .e = 50, .f = 0 };
    ctm = m2.mul(ctm);
    // Local x=10 → translate gives 60 → scale gives 120.
    const p = ctm.apply(10, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 120), p.x, 1e-9);
}

// ----- normalizeFilterChain (PR-1 round 11 [P2] regression) -----

test "normalizeFilterChain passes null through" {
    var cache = std.AutoHashMap(u32, parser.Object).init(std.testing.allocator);
    defer cache.deinit();
    var xref = xref_mod.XRefTable.init(std.testing.allocator);
    defer xref.deinit();
    const doc = DocState{
        .parse_allocator = std.testing.allocator,
        .scratch_allocator = std.testing.allocator,
        .data = "",
        .xref_table = &xref,
        .object_cache = &cache,
    };
    try std.testing.expect(try normalizeFilterChain(null, doc) == null);
}

test "normalizeFilterChain leaves a direct .name unchanged" {
    var cache = std.AutoHashMap(u32, parser.Object).init(std.testing.allocator);
    defer cache.deinit();
    var xref = xref_mod.XRefTable.init(std.testing.allocator);
    defer xref.deinit();
    const doc = DocState{
        .parse_allocator = std.testing.allocator,
        .scratch_allocator = std.testing.allocator,
        .data = "",
        .xref_table = &xref,
        .object_cache = &cache,
    };
    const inp = parser.Object{ .name = "FlateDecode" };
    const out = (try normalizeFilterChain(inp, doc)) orelse unreachable;
    try std.testing.expect(out == .name);
    try std.testing.expectEqualStrings("FlateDecode", out.name);
}

test "normalizeFilterChain leaves a direct-only .array unchanged" {
    var cache = std.AutoHashMap(u32, parser.Object).init(std.testing.allocator);
    defer cache.deinit();
    var xref = xref_mod.XRefTable.init(std.testing.allocator);
    defer xref.deinit();
    const doc = DocState{
        .parse_allocator = std.testing.allocator,
        .scratch_allocator = std.testing.allocator,
        .data = "",
        .xref_table = &xref,
        .object_cache = &cache,
    };
    var arr = [_]parser.Object{
        .{ .name = "ASCII85Decode" },
        .{ .name = "FlateDecode" },
    };
    const inp = parser.Object{ .array = &arr };
    const out = (try normalizeFilterChain(inp, doc)) orelse unreachable;
    try std.testing.expect(out == .array);
    // No allocation needed → the returned array slice points at the
    // same storage as the input.
    try std.testing.expect(out.array.ptr == &arr);
}
