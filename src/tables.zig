//! v1.2 Pass A: tagged-path table extraction.
//!
//! Walks the document's structure tree (`/StructTreeRoot`) and collects
//! every `/Table` → `/TR` → `/TH` / `/TD` substructure into the canonical
//! Table record. Designed to match `docs/v1.2-table-detection-design.md`
//! §3.1 — the cheapest, highest-precision pass.
//!
//! Pass B (lattice — vector strokes) and Pass C (stream — x-anchor) live
//! in separate files (not yet implemented). The dispatcher in
//! `extractDocumentTables` calls Pass A only for tagged PDFs and bails
//! gracefully when no `/StructTreeRoot` exists.

const std = @import("std");
const structtree = @import("structtree.zig");
const parser = @import("parser.zig");
const xref_mod = @import("xref.zig");
const pagetree = @import("pagetree.zig");

const Object = parser.Object;
const ObjRef = parser.ObjRef;

pub const Engine = enum { tagged, lattice, stream };

pub const Cell = struct {
    r: u32,
    c: u32,
    rowspan: u32 = 1,
    colspan: u32 = 1,
    is_header: bool = false,
    /// Cell text content. Populated by Pass C (and Pass A once MCID-to-bbox
    /// lookup lands); Pass B leaves it null until Pass-B-text is added.
    /// Owned by the table's allocator; freed by `freeTables`.
    text: ?[]const u8 = null,
};

pub const ContinuationLink = struct {
    page: u32,
    table_id: u32,
};

pub const Table = struct {
    /// 1-based page number (matches NDJSON convention).
    page: u32,
    /// Incremental id per page; first table on a page is 0.
    id: u32,
    n_rows: u32,
    n_cols: u32,
    header_rows: u32,
    cells: []Cell,
    engine: Engine,
    /// 0..1; 1.0 for tagged, lower for lattice/stream.
    confidence: f32,
    /// Bounding box in user-space PDF points: [x0, y0, x1, y1].
    /// Origin is bottom-left. Optional — Pass A doesn't compute it yet.
    bbox: ?[4]f64 = null,
    /// Multi-page continuation links. Set by `linkContinuations` after
    /// Passes A/B/C dispatch. `continued_from` points at the previous
    /// page's last-table-of-the-chain; `continued_to` points at the
    /// next page's first-table-of-the-chain.
    continued_from: ?ContinuationLink = null,
    continued_to: ?ContinuationLink = null,
};

/// Lookup signature for resolving a page's MediaBox. `page` is the
/// 1-based page number stored in `Table.page`. Returns `[x0, y0, x1, y1]`
/// in PDF user space (y0 = bottom, y1 = top). Pass `null`/`null` to
/// linkContinuations to opt out of the bbox-y constraint (legacy
/// behavior — column-count rule only).
pub const PageMediaBoxFn = *const fn (ctx: *const anyopaque, page: u32) ?[4]f64;

/// Fraction of page height that counts as "near a boundary".
/// 20% per docs/ROADMAP.md PR-2 acceptance gate. Tables whose
/// boundary edges fall outside this band are NOT linked even if the
/// column-count rule would otherwise match.
const BOUNDARY_BAND: f64 = 0.20;

/// Walk a page-sorted table list and link consecutive tables that
/// look like continuations of each other. The base heuristic
/// (v1.2-rc3): next table is the first on its page (id == 0), prev
/// table is the last on the previous page, and their column counts
/// match within ±1.
///
/// PR-2 [feat]: when `media_box_ctx` + `media_box_fn` are provided,
/// also require `a` to sit near the bottom of its page AND `b` to
/// sit near the top of the next page. Without this constraint, two
/// unrelated price tables on consecutive pages would be linked just
/// because their column counts happen to match. Tables without a
/// bbox (Pass A pre-bbox) bypass this geometry check so we don't
/// regress tagged-PDF dedup.
///
/// The "near a boundary" band is `BOUNDARY_BAND` × page-height
/// (currently 20%). PDF coordinate convention: y0 = bottom, y1 = top,
/// y increases upward.
pub fn linkContinuations(
    list: []Table,
    media_box_ctx: ?*const anyopaque,
    media_box_fn: ?PageMediaBoxFn,
) void {
    if (list.len < 2) return;
    var i: usize = 0;
    while (i + 1 < list.len) : (i += 1) {
        const a = &list[i];
        const b = &list[i + 1];
        if (a.page == 0 or b.page == 0) continue;
        if (b.page != a.page + 1) continue;
        if (b.id != 0) continue; // next must be the first on its page
        // Check that `a` is the last table on its page.
        if (i + 2 < list.len and list[i + 2].page == a.page) continue;
        // Column-count match (±1).
        const dcol: i64 = @as(i64, @intCast(a.n_cols)) - @as(i64, @intCast(b.n_cols));
        if (dcol < -1 or dcol > 1) continue;

        // PR-2 [feat]: bbox-y proximity constraint. Skip when ctx
        // + fn are unset (legacy / unit-test path) or when either
        // table has no bbox (Pass A pre-bbox falls back to
        // column-count rule alone).
        if (media_box_fn) |mbf| if (a.bbox != null and b.bbox != null) {
            const ctx = media_box_ctx.?;
            const mb_a = mbf(ctx, a.page) orelse continue;
            const mb_b = mbf(ctx, b.page) orelse continue;
            const h_a = mb_a[3] - mb_a[1];
            const h_b = mb_b[3] - mb_b[1];
            if (h_a <= 0 or h_b <= 0) continue; // degenerate page

            // a near BOTTOM of page p: a.bbox.y0 (table's lower
            // edge) must sit within BOUNDARY_BAND × h_a of the
            // page's lower edge mb_a.y0.
            const a_bottom_gap = a.bbox.?[1] - mb_a[1];
            if (a_bottom_gap > BOUNDARY_BAND * h_a) continue;

            // b near TOP of page p+1: b.bbox.y1 (table's upper
            // edge) must sit within BOUNDARY_BAND × h_b of the
            // page's upper edge mb_b.y1.
            const b_top_gap = mb_b[3] - b.bbox.?[3];
            if (b_top_gap > BOUNDARY_BAND * h_b) continue;
        };

        a.continued_to = .{ .page = b.page, .table_id = b.id };
        b.continued_from = .{ .page = a.page, .table_id = a.id };
    }
}

/// Free a slice returned by `extractDocumentTables`.
pub fn freeTables(allocator: std.mem.Allocator, tables: []Table) void {
    for (tables) |t| {
        for (t.cells) |c| if (c.text) |txt| allocator.free(txt);
        allocator.free(t.cells);
    }
    allocator.free(tables);
}

/// Hard cap on Cell-text MCID-walk depth. The PDF structure tree has
/// no formal limit, but well-formed Tables nest <= 4 levels deep
/// (TD → P → Span → mcid). 8 frames absorbs realistic nesting and
/// caps adversarial recursion.
const CELL_MCID_DEPTH_CAP: u8 = 8;

/// Codex review v1.2-rc4 PR-3 round 1 [P2]: walk ALL MCID descendants
/// of a Cell, not just its direct .mcid children. Tagged tables
/// frequently nest content under /P, /Span, etc. (ISO 32000-1 §14.7.4).
/// `inherited_page` is the page_ref carried down from ancestors;
/// inner elements may override it via their own .page_ref.
fn collectMcidText(
    allocator: std.mem.Allocator,
    elem: *const structtree.StructElement,
    inherited_page: ?ObjRef,
    lookup_ctx: *anyopaque,
    lookup: McidTextLookupFn,
    out: *std.ArrayList(u8),
    depth: u8,
) anyerror!void {
    if (depth >= CELL_MCID_DEPTH_CAP) return;
    const my_page = elem.page_ref orelse inherited_page;

    for (elem.children) |child| {
        switch (child) {
            .element => |sub| try collectMcidText(allocator, sub, my_page, lookup_ctx, lookup, out, depth + 1),
            .mcid => |mcr| {
                // Codex review v1.2-rc4 PR-3 round 5 [P2]: an MCR
                // with a non-null /Stm refers to a marked-content
                // sequence inside a Form XObject's content stream,
                // not the page's. Looking it up against the page-
                // content extractor would either miss or — worse —
                // collide with a page-content MCID that happens to
                // share the same integer. Skip these for now;
                // resolving /Stm content streams is a v1.x follow-up
                // (the lookup needs to key on (page, stream) pairs
                // and parse the referenced stream).
                if (mcr.stream_ref != null) continue;
                const page_ref = mcr.page_ref orelse my_page;
                const mcid_text = (try lookup(lookup_ctx, page_ref, mcr.mcid)) orelse continue;
                if (mcid_text.len == 0) continue;
                if (out.items.len > 0) try out.append(allocator, ' ');
                try out.appendSlice(allocator, mcid_text);
            },
        }
    }
}

/// Walk all MCID descendants of `elem` and yield the first non-null
/// `.page_ref` on either an inner element OR an inner MCID. Used as
/// a fallback when the table itself and its rows don't carry /Pg —
/// some producers attach /Pg only to the leaf TD/TH or the MCID
/// itself (Codex round 1 [P2]).
fn firstDescendantPageRef(
    elem: *const structtree.StructElement,
    depth: u8,
) ?ObjRef {
    if (depth >= CELL_MCID_DEPTH_CAP) return null;
    if (elem.page_ref) |p| return p;
    for (elem.children) |child| {
        switch (child) {
            .element => |sub| if (firstDescendantPageRef(sub, depth + 1)) |p| return p,
            .mcid => |mcr| if (mcr.page_ref) |p| return p,
        }
    }
    return null;
}

/// Lookup signature for resolving an MCID's accumulated text on a given
/// page. The text returned is borrowed (owned by the lookup's backing
/// store, e.g. a `MarkedContentExtractor`); `extractTaggedTables`
/// `dupe`s it before placing it into `Cell.text` so the cell owns its
/// allocation.
///
/// Codex review v1.2-rc4 PR-3 round 2 [P2]: errorable signature so
/// allocator failure during the lookup (e.g. lazy per-page extractor
/// build) surfaces at the public `getTables` boundary instead of
/// being collapsed into a missing-text null. Domain errors (corrupt
/// page stream, missing font) still soft-fail to null.
pub const McidTextLookupFn = *const fn (
    ctx: *anyopaque,
    page_ref: ?ObjRef,
    mcid: i32,
) error{OutOfMemory}!?[]const u8;

/// Walk the structure tree and emit one `Table` record per `/Table`
/// element. `page_lookup` maps an `/Pg` ObjRef to the document's
/// 0-based page index; pass `null` to skip page resolution (the
/// emitted `page` field will be 0, useful only for unit tests).
///
/// `mcid_text_lookup` is used to populate `Cell.text` on Pass A
/// (tagged path). When provided, each TD/TH's MCID children are
/// resolved via the lookup; their texts are concatenated with single-
/// space separators. Codex review v1.2-rc4 PR-3 [P2 deferred from
/// rc4 roadmap]: this closes the v1.2-rc1 "Pass A leaves text=null"
/// known limitation.
pub fn extractTaggedTables(
    allocator: std.mem.Allocator,
    tree: *const structtree.StructTree,
    page_lookup_ctx: ?*const anyopaque,
    page_lookup_fn: ?*const fn (ctx: *const anyopaque, page_ref: ?ObjRef) ?u32,
    mcid_text_lookup_ctx: ?*anyopaque,
    mcid_text_lookup_fn: ?McidTextLookupFn,
) ![]Table {
    var out: std.ArrayList(Table) = .empty;
    errdefer {
        for (out.items) |t| {
            for (t.cells) |c| if (c.text) |txt| allocator.free(txt);
            allocator.free(t.cells);
        }
        out.deinit(allocator);
    }

    if (tree.root) |root| {
        var per_page_counter = std.AutoHashMap(u32, u32).init(allocator);
        defer per_page_counter.deinit();
        try walkForTables(allocator, root, &out, &per_page_counter, page_lookup_ctx, page_lookup_fn, mcid_text_lookup_ctx, mcid_text_lookup_fn);
    }

    return out.toOwnedSlice(allocator);
}

fn walkForTables(
    allocator: std.mem.Allocator,
    elem: *const structtree.StructElement,
    out: *std.ArrayList(Table),
    per_page_counter: *std.AutoHashMap(u32, u32),
    page_lookup_ctx: ?*const anyopaque,
    page_lookup_fn: ?*const fn (ctx: *const anyopaque, page_ref: ?ObjRef) ?u32,
    mcid_text_lookup_ctx: ?*anyopaque,
    mcid_text_lookup_fn: ?McidTextLookupFn,
) anyerror!void {
    if (isTableElement(elem.struct_type)) {
        if (try buildTableFromElement(allocator, elem, page_lookup_ctx, page_lookup_fn, mcid_text_lookup_ctx, mcid_text_lookup_fn)) |raw| {
            var tbl = raw;
            // Codex review v1.2-rc4 PR-3 round 3 [P2]: guard the
            // built-but-not-yet-appended table against OOM in the
            // intervening per_page_counter.put. Without this, an
            // OOM there leaks the table's cells + cell texts.
            var appended = false;
            errdefer if (!appended) {
                for (tbl.cells) |c| if (c.text) |txt| allocator.free(txt);
                allocator.free(tbl.cells);
            };
            const pg_zero_based: u32 = if (tbl.page == 0) 0 else tbl.page - 1;
            const next_id = per_page_counter.get(pg_zero_based) orelse 0;
            tbl.id = next_id;
            try per_page_counter.put(pg_zero_based, next_id + 1);
            try out.append(allocator, tbl);
            appended = true;
        }
        // Don't recurse into nested tables yet; v1.2.W2 follow-up.
        return;
    }

    for (elem.children) |child| {
        switch (child) {
            .element => |sub| try walkForTables(allocator, sub, out, per_page_counter, page_lookup_ctx, page_lookup_fn, mcid_text_lookup_ctx, mcid_text_lookup_fn),
            .mcid => {},
        }
    }
}

fn buildTableFromElement(
    allocator: std.mem.Allocator,
    table_elem: *const structtree.StructElement,
    page_lookup_ctx: ?*const anyopaque,
    page_lookup_fn: ?*const fn (ctx: *const anyopaque, page_ref: ?ObjRef) ?u32,
    mcid_text_lookup_ctx: ?*anyopaque,
    mcid_text_lookup_fn: ?McidTextLookupFn,
) !?Table {
    // Collect rows: walk children, treating /TR nodes as rows.
    // The PDF spec also allows /THead /TBody /TFoot as wrappers — flatten them.
    var rows: std.ArrayList(*const structtree.StructElement) = .empty;
    defer rows.deinit(allocator);
    try collectRows(allocator, table_elem, &rows);
    if (rows.items.len == 0) return null;

    var n_cols: u32 = 0;
    var header_rows: u32 = 0;
    var cells: std.ArrayList(Cell) = .empty;
    // Codex review v1.2-rc4 PR-3 round 3 [P2]: PR-3 populates Cell.text
    // with caller-allocator-owned slices. The previous bare
    // `cells.deinit(allocator)` errdefer leaked every prior cell's
    // text on a downstream OOM (later append, mcid lookup, or
    // toOwnedSlice). Free per-cell text before the deinit.
    errdefer {
        for (cells.items) |c| if (c.text) |txt| allocator.free(txt);
        cells.deinit(allocator);
    }

    // Per-row column counter, accounting for spans propagated from previous rows.
    var col_carry: [128]u32 = undefined; // rowspan-carry per column; capped at 128 cols
    var carry_len: u32 = 0;
    @memset(&col_carry, 0);

    var only_header_so_far = true;

    for (rows.items, 0..) |row, ri| {
        var col: u32 = 0;
        var row_is_all_header = true;
        var row_has_any_cell = false;

        for (row.children) |child| {
            const cell_elem = switch (child) {
                .element => |sub| sub,
                .mcid => continue,
            };
            const is_header = std.mem.eql(u8, cell_elem.struct_type, "TH");
            const is_data = std.mem.eql(u8, cell_elem.struct_type, "TD");
            if (!is_header and !is_data) continue;

            // Skip columns with active rowspan from earlier rows.
            while (col < carry_len and col_carry[col] > 0) : (col += 1) col_carry[col] -= 1;

            const rowspan: u32 = 1; // span attribute parsing deferred
            const colspan: u32 = 1;

            // PR-3 [feat]: populate cell text by walking the cell's
            // MCID descendants (recursive — Codex round 1 [P2]:
            // valid tagged PDFs nest structure elements like
            // <TD><P><Span> ... MCID ... </Span></P></TD>; ISO
            // 32000-1 §14.7.2/§14.7.4 allow structure-element kids
            // alongside content-item kids under /K).
            //
            // Concatenates each MCID's accumulated text via the
            // optional lookup. Falls back to text=null when the
            // lookup is absent (legacy behavior preserved for
            // unit-test call sites). Each MCID's text is separated
            // by a single space; consecutive empty MCIDs collapse
            // cleanly.
            var cell_text: ?[]u8 = null;
            errdefer if (cell_text) |t| allocator.free(t);
            if (mcid_text_lookup_fn) |lookup| {
                var buf: std.ArrayList(u8) = .empty;
                errdefer buf.deinit(allocator);
                try collectMcidText(
                    allocator,
                    cell_elem,
                    cell_elem.page_ref orelse table_elem.page_ref,
                    mcid_text_lookup_ctx.?,
                    lookup,
                    &buf,
                    0,
                );
                if (buf.items.len > 0) {
                    cell_text = try buf.toOwnedSlice(allocator);
                } else {
                    buf.deinit(allocator);
                }
            }

            try cells.append(allocator, .{
                .r = @intCast(ri),
                .c = col,
                .rowspan = rowspan,
                .colspan = colspan,
                .is_header = is_header,
                .text = cell_text,
            });
            // Cell now owns the text slice; clear our local handle so
            // the errdefer above doesn't double-free if a later append
            // fails (toOwnedSlice already prevented buf.deinit from
            // freeing the slice, but cell_text still aliases it).
            cell_text = null;
            row_has_any_cell = true;
            if (!is_header) row_is_all_header = false;

            if (rowspan > 1 and col < col_carry.len) {
                col_carry[col] = rowspan - 1;
                if (col + 1 > carry_len) carry_len = col + 1;
            }
            col += colspan;
        }
        if (col > n_cols) n_cols = col;
        if (only_header_so_far and row_has_any_cell and row_is_all_header) {
            header_rows += 1;
        } else {
            only_header_so_far = false;
        }
    }

    // Resolve page number via callback (1-based for emission).
    //
    // Codex round 1 [P2]: producers often attach /Pg only to leaf
    // TD/TH or the MCID itself, not the table or rows. Walk
    // descendants when the table+rows path comes back empty.
    var page1: u32 = 0;
    if (page_lookup_fn) |f| {
        const ctx = page_lookup_ctx.?;
        if (f(ctx, table_elem.page_ref)) |p0| page1 = p0 + 1;
        if (page1 == 0) {
            for (rows.items) |row| {
                if (f(ctx, row.page_ref)) |p0| {
                    page1 = p0 + 1;
                    break;
                }
            }
        }
        if (page1 == 0) {
            if (firstDescendantPageRef(table_elem, 0)) |p_ref| {
                if (f(ctx, p_ref)) |p0| page1 = p0 + 1;
            }
        }
    }
    return .{
        .page = page1,
        .id = 0,
        .n_rows = @intCast(rows.items.len),
        .n_cols = n_cols,
        .header_rows = header_rows,
        .cells = try cells.toOwnedSlice(allocator),
        .engine = .tagged,
        .confidence = 1.0,
    };
}

fn collectRows(
    allocator: std.mem.Allocator,
    elem: *const structtree.StructElement,
    out: *std.ArrayList(*const structtree.StructElement),
) !void {
    for (elem.children) |child| {
        const sub = switch (child) {
            .element => |s| s,
            .mcid => continue,
        };
        if (std.mem.eql(u8, sub.struct_type, "TR")) {
            try out.append(allocator, sub);
        } else if (std.mem.eql(u8, sub.struct_type, "THead") or
            std.mem.eql(u8, sub.struct_type, "TBody") or
            std.mem.eql(u8, sub.struct_type, "TFoot"))
        {
            try collectRows(allocator, sub, out);
        }
        // Other unexpected children inside /Table are ignored (e.g. /Caption).
    }
}

fn isTableElement(t: []const u8) bool {
    return std.mem.eql(u8, t, "Table");
}

// ---- tests ----

test "empty struct tree → no tables" {
    var tree = structtree.StructTree{
        .root = null,
        .elements = &.{},
        .allocator = std.testing.allocator,
    };
    const tables = try extractTaggedTables(std.testing.allocator, &tree, null, null, null, null);
    defer freeTables(std.testing.allocator, tables);
    try std.testing.expectEqual(@as(usize, 0), tables.len);
}

test "minimal Table with 2 TR each containing 3 TD" {
    const a = std.testing.allocator;

    const td1 = try a.create(structtree.StructElement);
    td1.* = .{ .struct_type = "TD", .children = &.{} };
    const td2 = try a.create(structtree.StructElement);
    td2.* = .{ .struct_type = "TD", .children = &.{} };
    const td3 = try a.create(structtree.StructElement);
    td3.* = .{ .struct_type = "TD", .children = &.{} };
    defer a.destroy(td1);
    defer a.destroy(td2);
    defer a.destroy(td3);

    const tr1_children = try a.alloc(structtree.StructChild, 3);
    tr1_children[0] = .{ .element = td1 };
    tr1_children[1] = .{ .element = td2 };
    tr1_children[2] = .{ .element = td3 };
    defer a.free(tr1_children);

    const tr1 = try a.create(structtree.StructElement);
    tr1.* = .{ .struct_type = "TR", .children = tr1_children };
    defer a.destroy(tr1);

    const td4 = try a.create(structtree.StructElement);
    td4.* = .{ .struct_type = "TD", .children = &.{} };
    const td5 = try a.create(structtree.StructElement);
    td5.* = .{ .struct_type = "TD", .children = &.{} };
    const td6 = try a.create(structtree.StructElement);
    td6.* = .{ .struct_type = "TD", .children = &.{} };
    defer a.destroy(td4);
    defer a.destroy(td5);
    defer a.destroy(td6);

    const tr2_children = try a.alloc(structtree.StructChild, 3);
    tr2_children[0] = .{ .element = td4 };
    tr2_children[1] = .{ .element = td5 };
    tr2_children[2] = .{ .element = td6 };
    defer a.free(tr2_children);

    const tr2 = try a.create(structtree.StructElement);
    tr2.* = .{ .struct_type = "TR", .children = tr2_children };
    defer a.destroy(tr2);

    const table_children = try a.alloc(structtree.StructChild, 2);
    table_children[0] = .{ .element = tr1 };
    table_children[1] = .{ .element = tr2 };
    defer a.free(table_children);

    const table_elem = try a.create(structtree.StructElement);
    table_elem.* = .{ .struct_type = "Table", .children = table_children };
    defer a.destroy(table_elem);

    var tree = structtree.StructTree{
        .root = table_elem,
        .elements = &.{},
        .allocator = a,
    };
    const tables = try extractTaggedTables(a, &tree, null, null, null, null);
    defer freeTables(a, tables);

    try std.testing.expectEqual(@as(usize, 1), tables.len);
    try std.testing.expectEqual(@as(u32, 2), tables[0].n_rows);
    try std.testing.expectEqual(@as(u32, 3), tables[0].n_cols);
    try std.testing.expectEqual(@as(u32, 0), tables[0].header_rows); // all TD, no TH
    try std.testing.expectEqual(@as(usize, 6), tables[0].cells.len);
    try std.testing.expectEqual(Engine.tagged, tables[0].engine);
}

test "Table with TH header row + TD rows → header_rows = 1" {
    const a = std.testing.allocator;

    const th1 = try a.create(structtree.StructElement);
    th1.* = .{ .struct_type = "TH", .children = &.{} };
    const th2 = try a.create(structtree.StructElement);
    th2.* = .{ .struct_type = "TH", .children = &.{} };
    defer a.destroy(th1);
    defer a.destroy(th2);

    const tr_h_kids = try a.alloc(structtree.StructChild, 2);
    tr_h_kids[0] = .{ .element = th1 };
    tr_h_kids[1] = .{ .element = th2 };
    defer a.free(tr_h_kids);
    const tr_h = try a.create(structtree.StructElement);
    tr_h.* = .{ .struct_type = "TR", .children = tr_h_kids };
    defer a.destroy(tr_h);

    const td1 = try a.create(structtree.StructElement);
    td1.* = .{ .struct_type = "TD", .children = &.{} };
    const td2 = try a.create(structtree.StructElement);
    td2.* = .{ .struct_type = "TD", .children = &.{} };
    defer a.destroy(td1);
    defer a.destroy(td2);

    const tr_d_kids = try a.alloc(structtree.StructChild, 2);
    tr_d_kids[0] = .{ .element = td1 };
    tr_d_kids[1] = .{ .element = td2 };
    defer a.free(tr_d_kids);
    const tr_d = try a.create(structtree.StructElement);
    tr_d.* = .{ .struct_type = "TR", .children = tr_d_kids };
    defer a.destroy(tr_d);

    const tbl_kids = try a.alloc(structtree.StructChild, 2);
    tbl_kids[0] = .{ .element = tr_h };
    tbl_kids[1] = .{ .element = tr_d };
    defer a.free(tbl_kids);
    const tbl = try a.create(structtree.StructElement);
    tbl.* = .{ .struct_type = "Table", .children = tbl_kids };
    defer a.destroy(tbl);

    var tree = structtree.StructTree{ .root = tbl, .elements = &.{}, .allocator = a };
    const tables = try extractTaggedTables(a, &tree, null, null, null, null);
    defer freeTables(a, tables);

    try std.testing.expectEqual(@as(u32, 2), tables[0].n_rows);
    try std.testing.expectEqual(@as(u32, 2), tables[0].n_cols);
    try std.testing.expectEqual(@as(u32, 1), tables[0].header_rows);
    try std.testing.expectEqual(@as(usize, 4), tables[0].cells.len);
    try std.testing.expect(tables[0].cells[0].is_header);
    try std.testing.expect(!tables[0].cells[2].is_header);
}
