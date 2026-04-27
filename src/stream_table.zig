//! v1.2 Pass C: stream-layout table extraction.
//!
//! For unruled tables (the typical hotel menu / spa price list with no
//! horizontal/vertical rules), look for consecutive runs of text rows
//! whose span x-anchors line up. Per design §3.3:
//!
//!   1. Group spans into rows by Y proximity.
//!   2. For each consecutive run of ≥3 multi-span rows, build an
//!      x-anchor histogram across all rows in the run.
//!   3. Bins with hits in ≥50% of rows = column anchors.
//!   4. ≥2 anchors → table candidate; rows × anchors = grid.
//!
//! Confidence baseline: 0.6, with bonuses for (a) ≥4 rows, (b) all
//! rows have exactly N_cols spans, (c) decimal-point or currency
//! alignment in the rightmost column. Bonuses lift toward 0.85.
//!
//! Cell text assignment is **not** done in v1; the v1.2 evaluator
//! gates on structural shape (rows × cols × header_rows).

const std = @import("std");
const layout = @import("layout.zig");
const tables = @import("tables.zig");

const ROW_Y_TOLERANCE_RATIO: f64 = 0.7;  // rows are within 0.7 × font size
const COL_X_BIN_WIDTH: f64 = 5.0;        // 5 pt histogram bin width
const MIN_ROWS: usize = 3;
const MIN_COLS_PER_ROW: usize = 2;
const MIN_TABLE_ROWS: u32 = 3;
const MIN_TABLE_COLS: u32 = 2;
const COL_HIT_RATIO_FLOOR: f64 = 0.5;    // anchor must hit ≥50% of rows

const Row = struct {
    y: f64,
    spans: []const layout.TextSpan,
};

/// Detect tables on a single page from its sorted span list. Returns
/// slice of Table records with engine = .stream. Caller frees via
/// `tables.freeTables`.
pub fn extractFromSpans(
    allocator: std.mem.Allocator,
    spans: []const layout.TextSpan,
    page: u32,
) ![]tables.Table {
    var out: std.ArrayList(tables.Table) = .empty;
    errdefer {
        for (out.items) |t| allocator.free(t.cells);
        out.deinit(allocator);
    }
    if (spans.len < MIN_ROWS * MIN_COLS_PER_ROW) return out.toOwnedSlice(allocator);

    const rows = try groupIntoRows(allocator, spans);
    defer {
        for (rows) |row| allocator.free(row.spans);
        allocator.free(rows);
    }
    if (rows.len < MIN_ROWS) return out.toOwnedSlice(allocator);

    // Walk consecutive rows; when we see ≥MIN_ROWS consecutive multi-span
    // rows whose x-anchors cluster into ≥MIN_TABLE_COLS column peaks, emit
    // one candidate table.
    var i: usize = 0;
    var table_id: u32 = 0;
    while (i < rows.len) {
        if (rows[i].spans.len < MIN_COLS_PER_ROW) {
            i += 1;
            continue;
        }
        // Extend run while subsequent rows are also multi-span.
        var j = i;
        while (j < rows.len and rows[j].spans.len >= MIN_COLS_PER_ROW) j += 1;
        if (j - i < MIN_ROWS) {
            i = j + 1;
            continue;
        }

        // Build x-anchor histogram over rows [i..j).
        const peaks = try findColumnAnchors(allocator, rows[i..j]);
        defer allocator.free(peaks);

        if (peaks.len >= MIN_TABLE_COLS) {
            const n_rows: u32 = @intCast(j - i);
            const n_cols: u32 = @intCast(peaks.len);
            const conf = scoreConfidence(rows[i..j], peaks);

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
                .id = table_id,
                .n_rows = n_rows,
                .n_cols = n_cols,
                .header_rows = 0,
                .cells = cells,
                .engine = .stream,
                .confidence = @floatCast(conf),
            });
            table_id += 1;
        }
        i = j + 1;
    }

    return out.toOwnedSlice(allocator);
}

/// Group spans into rows by Y coordinate. Sorts Y descending (top to
/// bottom) and groups spans whose Y differs by ≤ ROW_Y_TOLERANCE_RATIO
/// × max(font_size). `spans` is read-only; caller owns lifetime.
fn groupIntoRows(allocator: std.mem.Allocator, spans: []const layout.TextSpan) ![]Row {
    if (spans.len == 0) return &.{};

    // Copy + sort by Y descending, then X ascending.
    const sorted = try allocator.alloc(layout.TextSpan, spans.len);
    errdefer allocator.free(sorted);
    @memcpy(sorted, spans);
    std.mem.sort(layout.TextSpan, sorted, {}, comptime struct {
        fn lt(_: void, a: layout.TextSpan, b: layout.TextSpan) bool {
            if (@abs(a.y0 - b.y0) > 1.0) return a.y0 > b.y0;
            return a.x0 < b.x0;
        }
    }.lt);

    var rows: std.ArrayList(Row) = .empty;
    errdefer {
        for (rows.items) |r| allocator.free(r.spans);
        rows.deinit(allocator);
    }

    var run_start: usize = 0;
    var run_y = sorted[0].y0;
    var run_font = sorted[0].font_size;
    var k: usize = 1;
    while (k <= sorted.len) : (k += 1) {
        const finalize = k == sorted.len or
            @abs(sorted[k].y0 - run_y) > @max(run_font, 8.0) * ROW_Y_TOLERANCE_RATIO;
        if (finalize) {
            const span_slice = try allocator.dupe(layout.TextSpan, sorted[run_start..k]);
            try rows.append(allocator, .{ .y = run_y, .spans = span_slice });
            if (k < sorted.len) {
                run_start = k;
                run_y = sorted[k].y0;
                run_font = sorted[k].font_size;
            }
        }
    }
    allocator.free(sorted);
    return rows.toOwnedSlice(allocator);
}

/// Build a histogram of span x-starts across all rows in `run`; return
/// the bin centers whose hit count is ≥ COL_HIT_RATIO_FLOOR × len(run).
/// Sorted ascending. Caller frees.
fn findColumnAnchors(allocator: std.mem.Allocator, run: []const Row) ![]f64 {
    var bins = std.AutoHashMap(i32, u32).init(allocator);
    defer bins.deinit();

    for (run) |row| {
        for (row.spans) |span| {
            const bin: i32 = @intFromFloat(span.x0 / COL_X_BIN_WIDTH);
            const e = try bins.getOrPut(bin);
            if (!e.found_existing) e.value_ptr.* = 0;
            e.value_ptr.* += 1;
        }
    }

    const threshold = @as(u32, @intFromFloat(@as(f64, @floatFromInt(run.len)) * COL_HIT_RATIO_FLOOR));
    var peaks: std.ArrayList(f64) = .empty;
    errdefer peaks.deinit(allocator);

    var it = bins.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* >= @max(threshold, 2)) {
            const x = (@as(f64, @floatFromInt(entry.key_ptr.*)) + 0.5) * COL_X_BIN_WIDTH;
            try peaks.append(allocator, x);
        }
    }
    std.mem.sort(f64, peaks.items, {}, comptime std.sort.asc(f64));

    // Merge adjacent peaks within 1.5 × bin width — a misaligned span
    // can spread across two bins and we don't want to double-count.
    var merged: std.ArrayList(f64) = .empty;
    errdefer merged.deinit(allocator);
    for (peaks.items) |p| {
        if (merged.items.len > 0 and p - merged.items[merged.items.len - 1] < COL_X_BIN_WIDTH * 1.5) {
            merged.items[merged.items.len - 1] = (merged.items[merged.items.len - 1] + p) / 2.0;
        } else {
            try merged.append(allocator, p);
        }
    }
    peaks.deinit(allocator);
    return merged.toOwnedSlice(allocator);
}

/// Confidence in [0, 1]. Base 0.6; +0.05 per row beyond MIN_ROWS up to
/// 0.20; +0.10 if every row has exactly len(peaks) spans.
fn scoreConfidence(run: []const Row, peaks: []const f64) f64 {
    var conf: f64 = 0.6;
    const beyond_floor: f64 = @floatFromInt(@max(0, @as(isize, @intCast(run.len)) - MIN_ROWS));
    conf += @min(0.20, beyond_floor * 0.05);
    var all_match = true;
    for (run) |row| {
        if (row.spans.len != peaks.len) { all_match = false; break; }
    }
    if (all_match) conf += 0.10;
    return @min(conf, 0.95);
}

// ---- tests ----

const T = layout.TextSpan;

test "groupIntoRows clusters spans by Y" {
    const a = std.testing.allocator;
    const spans = [_]T{
        .{ .x0 = 10, .y0 = 100, .x1 = 50, .y1 = 110, .text = "a", .font_size = 12 },
        .{ .x0 = 60, .y0 = 100, .x1 = 100, .y1 = 110, .text = "b", .font_size = 12 },
        .{ .x0 = 10, .y0 = 80, .x1 = 50, .y1 = 90, .text = "c", .font_size = 12 },
    };
    const rows = try groupIntoRows(a, &spans);
    defer {
        for (rows) |r| a.free(r.spans);
        a.free(rows);
    }
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqual(@as(usize, 2), rows[0].spans.len); // y=100
    try std.testing.expectEqual(@as(usize, 1), rows[1].spans.len); // y=80
}

test "extractFromSpans detects a 4-row × 2-col stream table" {
    const a = std.testing.allocator;
    const spans = [_]T{
        .{ .x0 = 10, .y0 = 200, .x1 = 80, .y1 = 212, .text = "row1-A", .font_size = 12 },
        .{ .x0 = 200, .y0 = 200, .x1 = 240, .y1 = 212, .text = "10", .font_size = 12 },
        .{ .x0 = 10, .y0 = 180, .x1 = 80, .y1 = 192, .text = "row2-A", .font_size = 12 },
        .{ .x0 = 200, .y0 = 180, .x1 = 240, .y1 = 192, .text = "20", .font_size = 12 },
        .{ .x0 = 10, .y0 = 160, .x1 = 80, .y1 = 172, .text = "row3-A", .font_size = 12 },
        .{ .x0 = 200, .y0 = 160, .x1 = 240, .y1 = 172, .text = "30", .font_size = 12 },
        .{ .x0 = 10, .y0 = 140, .x1 = 80, .y1 = 152, .text = "row4-A", .font_size = 12 },
        .{ .x0 = 200, .y0 = 140, .x1 = 240, .y1 = 152, .text = "40", .font_size = 12 },
    };
    const out = try extractFromSpans(a, &spans, 7);
    defer tables.freeTables(a, out);

    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqual(@as(u32, 4), out[0].n_rows);
    try std.testing.expectEqual(@as(u32, 2), out[0].n_cols);
    try std.testing.expectEqual(@as(u32, 7), out[0].page);
    try std.testing.expectEqual(tables.Engine.stream, out[0].engine);
    try std.testing.expect(out[0].confidence >= 0.7);
}

test "extractFromSpans bails when fewer than MIN_ROWS multi-span rows" {
    const a = std.testing.allocator;
    const spans = [_]T{
        .{ .x0 = 10, .y0 = 200, .x1 = 80, .y1 = 212, .text = "x", .font_size = 12 },
        .{ .x0 = 200, .y0 = 200, .x1 = 240, .y1 = 212, .text = "1", .font_size = 12 },
        .{ .x0 = 10, .y0 = 180, .x1 = 80, .y1 = 192, .text = "y", .font_size = 12 },
        .{ .x0 = 200, .y0 = 180, .x1 = 240, .y1 = 192, .text = "2", .font_size = 12 },
    };
    const out = try extractFromSpans(a, &spans, 1);
    defer tables.freeTables(a, out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "scoreConfidence rises with row count + uniform col-width" {
    const a = std.testing.allocator;
    var rows: [5]Row = undefined;
    var spans_by_row: [5][]T = undefined;
    for (&rows, 0..) |*r, i| {
        const ys: [5]f64 = .{200, 180, 160, 140, 120};
        const arr = try a.alloc(T, 2);
        arr[0] = .{ .x0 = 10, .y0 = ys[i], .x1 = 50, .y1 = ys[i] + 10, .text = "a", .font_size = 12 };
        arr[1] = .{ .x0 = 100, .y0 = ys[i], .x1 = 150, .y1 = ys[i] + 10, .text = "b", .font_size = 12 };
        spans_by_row[i] = arr;
        r.* = .{ .y = ys[i], .spans = arr };
    }
    defer for (spans_by_row) |arr| a.free(arr);
    const peaks = [_]f64{ 12.5, 102.5 };
    const conf = scoreConfidence(&rows, &peaks);
    // 0.6 base + 0.10 (2 rows beyond MIN_ROWS × 0.05) + 0.10 (uniform) = ~0.80
    // (binary float adds drift to 0.7999…). Assert with a tolerance.
    try std.testing.expect(conf > 0.795);
}
