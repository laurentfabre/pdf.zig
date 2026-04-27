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

/// Walk a page-sorted table list and link consecutive tables that
/// look like continuations of each other. Heuristic for v1.2-rc3:
/// next table is the first on its page (id == 0), prev table is the
/// last on the previous page, and their column counts match within
/// ±1. Refinements (column-anchor proximity, near-bottom-of-page /
/// near-top-of-page geometry) land in v1.2-rc4 once page-height
/// context is threaded through.
pub fn linkContinuations(list: []Table) void {
    if (list.len < 2) return;
    // Find the LAST table on each page.
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

/// Walk the structure tree and emit one `Table` record per `/Table`
/// element. `page_lookup` maps an `/Pg` ObjRef to the document's
/// 0-based page index; pass `null` to skip page resolution (the
/// emitted `page` field will be 0, useful only for unit tests).
pub fn extractTaggedTables(
    allocator: std.mem.Allocator,
    tree: *const structtree.StructTree,
    page_lookup_ctx: ?*const anyopaque,
    page_lookup_fn: ?*const fn (ctx: *const anyopaque, page_ref: ?ObjRef) ?u32,
) ![]Table {
    var out: std.ArrayList(Table) = .empty;
    errdefer {
        for (out.items) |t| allocator.free(t.cells);
        out.deinit(allocator);
    }

    if (tree.root) |root| {
        var per_page_counter = std.AutoHashMap(u32, u32).init(allocator);
        defer per_page_counter.deinit();
        try walkForTables(allocator, root, &out, &per_page_counter, page_lookup_ctx, page_lookup_fn);
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
) anyerror!void {
    if (isTableElement(elem.struct_type)) {
        if (try buildTableFromElement(allocator, elem, page_lookup_ctx, page_lookup_fn)) |raw| {
            var tbl = raw;
            const pg_zero_based: u32 = if (tbl.page == 0) 0 else tbl.page - 1;
            const next_id = per_page_counter.get(pg_zero_based) orelse 0;
            tbl.id = next_id;
            try per_page_counter.put(pg_zero_based, next_id + 1);
            try out.append(allocator, tbl);
        }
        // Don't recurse into nested tables yet; v1.2.W2 follow-up.
        return;
    }

    for (elem.children) |child| {
        switch (child) {
            .element => |sub| try walkForTables(allocator, sub, out, per_page_counter, page_lookup_ctx, page_lookup_fn),
            .mcid => {},
        }
    }
}

fn buildTableFromElement(
    allocator: std.mem.Allocator,
    table_elem: *const structtree.StructElement,
    page_lookup_ctx: ?*const anyopaque,
    page_lookup_fn: ?*const fn (ctx: *const anyopaque, page_ref: ?ObjRef) ?u32,
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
    errdefer cells.deinit(allocator);

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

            try cells.append(allocator, .{
                .r = @intCast(ri),
                .c = col,
                .rowspan = rowspan,
                .colspan = colspan,
                .is_header = is_header,
            });
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
    var page1: u32 = 0;
    if (page_lookup_fn) |f| {
        const ctx = page_lookup_ctx.?;
        if (f(ctx, table_elem.page_ref)) |p0| page1 = p0 + 1;
        if (page1 == 0) {
            // Inherit from first child whose page_ref resolves.
            for (rows.items) |row| {
                if (f(ctx, row.page_ref)) |p0| {
                    page1 = p0 + 1;
                    break;
                }
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
    const tables = try extractTaggedTables(std.testing.allocator, &tree, null, null);
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
    const tables = try extractTaggedTables(a, &tree, null, null);
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
    const tables = try extractTaggedTables(a, &tree, null, null);
    defer freeTables(a, tables);

    try std.testing.expectEqual(@as(u32, 2), tables[0].n_rows);
    try std.testing.expectEqual(@as(u32, 2), tables[0].n_cols);
    try std.testing.expectEqual(@as(u32, 1), tables[0].header_rows);
    try std.testing.expectEqual(@as(usize, 4), tables[0].cells.len);
    try std.testing.expect(tables[0].cells[0].is_header);
    try std.testing.expect(!tables[0].cells[2].is_header);
}
