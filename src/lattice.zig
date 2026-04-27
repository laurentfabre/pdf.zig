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
    /// Page (or parent Form XObject) Resources dict. Used to resolve
    /// `/XObject/<name>` lookups when the content stream emits `Do`.
    resources: ?parser.Object.Dict = null,
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

    try collectStrokesWalk(allocator, content, ctx, visited, &strokes);
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

/// Recurse into the Form XObject named `name`, appending strokes to
/// `out` in the parent's user-space coordinate frame.
///
/// All non-OOM errors are returned to the caller for the soft-fail
/// pattern at the call site. The function is conservative — any
/// resource lookup miss, missing Subtype, decode failure, or visited-
/// reference cycle results in a no-op return.
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
            const resolved = pagetree.resolveRef(doc.parse_allocator, doc.data, doc.xref_table, ref, doc.object_cache) catch return;
            break :blk switch (resolved) {
                .dict => |d| d,
                else => return,
            };
        },
        else => return,
    };

    // Look up the named XObject (also possibly a reference).
    const xobj = xobjects.get(name) orelse return;
    var xobj_ref_num: ?u32 = null;
    const xobj_resolved = switch (xobj) {
        .stream => |s| s,
        .reference => |ref| blk: {
            xobj_ref_num = ref.num;
            // Cycle guard: if we're already inside this XObject, bail.
            if (visited.contains(ref.num)) return;
            const resolved = pagetree.resolveRef(doc.parse_allocator, doc.data, doc.xref_table, ref, doc.object_cache) catch return;
            break :blk switch (resolved) {
                .stream => |s| s,
                else => return,
            };
        },
        else => return,
    };

    // Form XObjects only — Image / PS XObjects don't contribute strokes.
    const subtype = xobj_resolved.dict.getName("Subtype") orelse return;
    if (!std.mem.eql(u8, subtype, "Form")) return;

    // Decompress the Form content stream into scratch memory.
    const filter = xobj_resolved.dict.get("Filter");
    const params = xobj_resolved.dict.get("DecodeParms");
    const form_content = decompress.decompressStream(doc.scratch_allocator, xobj_resolved.data, filter, params) catch return;
    defer doc.scratch_allocator.free(form_content);

    // Compose the effective CTM for the Form's own content. Per PDF
    // spec §8.10: the Form's `/Matrix` (default identity) is applied
    // BEFORE the parent's CTM, i.e. effective = parent_ctm × form_matrix.
    const form_matrix = readMatrix(xobj_resolved.dict, doc);
    const effective_ctm = form_matrix.mul(parent_ctm);

    // Form Resources: inline dict, indirect ref, or absent (inherit
    // from parent). Codex review v1.2-rc4 [P2]: the previous version
    // used `getDict("Resources")` which silently returned null on the
    // legal `.reference` shape, falling back to the *parent's*
    // resources. Nested `Do` inside that form would then either miss
    // its child XObjects entirely or resolve the wrong one from the
    // page-level dictionary. Resolve the reference explicitly.
    const form_resources = blk: {
        const obj = xobj_resolved.dict.get("Resources") orelse break :blk resources;
        break :blk switch (obj) {
            .dict => |d| d,
            .reference => |ref| ref_blk: {
                const resolved = pagetree.resolveRef(doc.parse_allocator, doc.data, doc.xref_table, ref, doc.object_cache) catch break :ref_blk resources;
                break :ref_blk switch (resolved) {
                    .dict => |d| d,
                    else => resources,
                };
            },
            else => resources,
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
        .doc = doc,
        .depth = ctx.depth + 1,
        .initial_ctm = effective_ctm,
        .visited = visited,
    };
    try collectStrokesWalk(allocator, form_content, child_ctx, visited, out);
}

/// Read a Form XObject's `/Matrix` entry into a `Mat`.
/// Falls back to identity when missing or malformed.
///
/// Codex review v1.2-rc4 [P2]: `/Matrix` is legally allowed to be an
/// indirect reference (e.g. `/Matrix 8 0 R`). The previous version
/// only matched `.array` and silently fell back to identity in that
/// case, which projected scaled/translated form strokes into the
/// wrong user-space coordinates. Now resolves indirect references
/// before consuming.
fn readMatrix(dict: parser.Object.Dict, doc: DocState) Mat {
    const obj = dict.get("Matrix") orelse return Mat{};
    const arr = switch (obj) {
        .array => |a| a,
        .reference => |ref| blk: {
            const resolved = pagetree.resolveRef(doc.parse_allocator, doc.data, doc.xref_table, ref, doc.object_cache) catch return Mat{};
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
        v[i] = switch (arr[i]) {
            .real => |r| r,
            .integer => |n| @floatFromInt(n),
            else => return Mat{},
        };
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
    for (filtered.items) |s| {
        const c = if (s.isHorizontal()) s.y0 else s.x0;
        if (@abs(c - current_coord) > COORD_TOLERANCE) {
            try out.append(allocator, current);
            current_coord = c;
            current = Cluster{ .coord = c, .members = .empty };
        }
        try current.members.append(allocator, s);
    }
    try out.append(allocator, current);
    return out.toOwnedSlice(allocator);
}

const PageGrid = struct {
    /// 1-based page number to attach to emitted tables.
    page: u32,
};

/// Detect tables in a single page's stroke set. Returns slice of Table
/// records (engine = .lattice). Caller frees via `tables.freeTables`.
pub fn extractFromStrokes(
    allocator: std.mem.Allocator,
    strokes: []const Stroke,
    page: u32,
) ![]tables.Table {
    var out: std.ArrayList(tables.Table) = .empty;
    errdefer {
        for (out.items) |t| allocator.free(t.cells);
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

    // Build a synthetic cells array (no text yet — Pass-B-text deferred).
    var cells = try allocator.alloc(tables.Cell, @as(usize, n_rows) * @as(usize, n_cols));
    var idx: usize = 0;
    var r: u32 = 0;
    while (r < n_rows) : (r += 1) {
        var c: u32 = 0;
        while (c < n_cols) : (c += 1) {
            cells[idx] = .{ .r = r, .c = c, .rowspan = 1, .colspan = 1, .is_header = false };
            idx += 1;
        }
    }

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
    const out = try extractFromStrokes(a, &strokes, 1);
    defer tables.freeTables(a, out);

    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqual(@as(u32, 2), out[0].n_rows);
    try std.testing.expectEqual(@as(u32, 3), out[0].n_cols);
    try std.testing.expectEqual(@as(usize, 6), out[0].cells.len);
    try std.testing.expectEqual(tables.Engine.lattice, out[0].engine);
}

test "extractFromStrokes returns no table when fewer than 2 cluster lines on either axis" {
    const a = std.testing.allocator;
    const strokes = [_]Stroke{
        .{ .x0 = 50, .y0 = 100, .x1 = 350, .y1 = 100 },
        .{ .x0 = 50, .y0 = 100, .x1 = 50, .y1 = 300 },
    };
    const out = try extractFromStrokes(a, &strokes, 1);
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
