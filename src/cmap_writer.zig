//! PR-W7 [feat]: ToUnicode CMap stream writer (PDF 32000-1 §9.10.3).
//!
//! A Type 0 / CIDFontType2 font carries glyph IDs in content streams,
//! NOT Unicode codepoints. To make the document text-extractable, we
//! emit a parallel `/ToUnicode` CMap that maps `<CID>` → Unicode.
//!
//! The CMap format is a (highly cursed) PostScript dialect. We emit
//! only the minimum required by §9.10.3 — header + `bfrange`/`bfchar`
//! sections + footer. Writers like Acrobat use additional optional
//! sections; readers (this codebase included) tolerate their absence.
//!
//! ## Range merging contract
//!
//! `[(1,'A'), (2,'B'), (3,'D')]` MUST emit one `bfrange` covering CIDs
//! 1..2 (mapped to 'A'..'B') and one `bfchar` for CID 3 → 'D' — *not*
//! drop CID 3 because it doesn't continue the run, and *not* widen the
//! bfrange to a 3-entry array form. The Codex gate test in
//! `integration_test.zig` enforces both ends of this contract.

const std = @import("std");

pub const Mapping = struct {
    cid: u16,
    unicode: u21,
};

/// Emit a complete ToUnicode CMap *body*. The caller wraps this in a
/// stream object (`<< /Length N >>\nstream\n…\nendstream`).
///
/// `mappings` need not be sorted; we sort by CID internally. Duplicate
/// CIDs are not legal — the caller is expected to dedupe before calling.
pub fn writeToUnicodeCmap(
    writer: *std.Io.Writer,
    mappings: []const Mapping,
) !void {
    // Defensive copy + sort. Caller's slice may be const.
    // Use a stack scratch when small (<256), else fall back to heap.
    if (mappings.len > 65535) return error.TooManyMappings;

    var heap_buf: ?[]Mapping = null;
    defer if (heap_buf) |b| std.heap.page_allocator.free(b);
    var stack_buf: [256]Mapping = undefined;
    const sorted: []Mapping = if (mappings.len <= 256) blk: {
        @memcpy(stack_buf[0..mappings.len], mappings);
        break :blk stack_buf[0..mappings.len];
    } else blk: {
        const buf = try std.heap.page_allocator.alloc(Mapping, mappings.len);
        heap_buf = buf;
        @memcpy(buf, mappings);
        break :blk buf;
    };
    std.mem.sort(Mapping, sorted, {}, struct {
        fn lt(_: void, a: Mapping, b: Mapping) bool {
            return a.cid < b.cid;
        }
    }.lt);

    try writeHeader(writer);

    // Range merging: a "run" extends while consecutive entries have
    // both cid and unicode incrementing by 1, and the run does not
    // cross a 256-CID boundary on the *low byte* of cid (per §9.10.3,
    // the range must satisfy `(start.cid >> 8) == (end.cid >> 8)`).
    var i: usize = 0;
    var ranges: std.ArrayList(Range) = .empty;
    defer ranges.deinit(std.heap.page_allocator);
    var singles: std.ArrayList(Mapping) = .empty;
    defer singles.deinit(std.heap.page_allocator);

    while (i < sorted.len) {
        const start = sorted[i];
        var j = i + 1;
        while (j < sorted.len) : (j += 1) {
            const prev = sorted[j - 1];
            const cur = sorted[j];
            if (cur.cid != prev.cid + 1) break;
            if (cur.unicode != prev.unicode + 1) break;
            // Range start.cid and end.cid must have matching high byte.
            if ((cur.cid >> 8) != (start.cid >> 8)) break;
        }
        const len = j - i;
        if (len >= 2) {
            try ranges.append(std.heap.page_allocator, .{
                .start_cid = start.cid,
                .end_cid = sorted[j - 1].cid,
                .start_unicode = start.unicode,
            });
        } else {
            try singles.append(std.heap.page_allocator, start);
        }
        i = j;
    }

    // Emit singletons first (consistent ordering aids golden-byte tests).
    if (singles.items.len > 0) {
        // PDF spec caps each block at 100 entries. Emit in batches.
        var pos: usize = 0;
        while (pos < singles.items.len) {
            const remain = singles.items.len - pos;
            const batch = if (remain > 100) @as(usize, 100) else remain;
            try writer.print("{d} beginbfchar\n", .{batch});
            for (singles.items[pos .. pos + batch]) |m| {
                try writer.print("<{x:0>4}> ", .{m.cid});
                try writeUnicodeAsHex(writer, m.unicode);
                try writer.writeAll("\n");
            }
            try writer.writeAll("endbfchar\n");
            pos += batch;
        }
    }

    if (ranges.items.len > 0) {
        var pos: usize = 0;
        while (pos < ranges.items.len) {
            const remain = ranges.items.len - pos;
            const batch = if (remain > 100) @as(usize, 100) else remain;
            try writer.print("{d} beginbfrange\n", .{batch});
            for (ranges.items[pos .. pos + batch]) |r| {
                try writer.print("<{x:0>4}> <{x:0>4}> ", .{ r.start_cid, r.end_cid });
                try writeUnicodeAsHex(writer, r.start_unicode);
                try writer.writeAll("\n");
            }
            try writer.writeAll("endbfrange\n");
            pos += batch;
        }
    }

    try writeFooter(writer);
}

const Range = struct {
    start_cid: u16,
    end_cid: u16,
    start_unicode: u21,
};

fn writeHeader(w: *std.Io.Writer) !void {
    // Boilerplate per §9.10.3: identifies this as a ToUnicode CMap with
    // no horizontal/vertical orientation overrides.
    try w.writeAll(
        \\/CIDInit /ProcSet findresource begin
        \\12 dict begin
        \\begincmap
        \\/CIDSystemInfo
        \\<< /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
        \\/CMapName /Adobe-Identity-UCS def
        \\/CMapType 2 def
        \\1 begincodespacerange
        \\<0000> <FFFF>
        \\endcodespacerange
        \\
    );
}

fn writeFooter(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\endcmap
        \\CMapName currentdict /CMap defineresource pop
        \\end
        \\end
        \\
    );
}

/// Encode a single Unicode codepoint as `<HHHH>` (BMP) or `<HHHHHHHH>`
/// (UTF-16 surrogate pair for supplementary planes).
fn writeUnicodeAsHex(w: *std.Io.Writer, cp: u21) !void {
    if (cp <= 0xFFFF) {
        try w.print("<{x:0>4}>", .{cp});
    } else {
        // UTF-16 surrogate encoding per RFC 2781.
        const v = cp - 0x10000;
        const high: u16 = @intCast(0xD800 | (v >> 10));
        const low: u16 = @intCast(0xDC00 | (v & 0x3FF));
        try w.print("<{x:0>4}{x:0>4}>", .{ high, low });
    }
}

// ============================================================================
// TESTS
// ============================================================================

test "single mapping → bfchar only" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    const m = [_]Mapping{.{ .cid = 1, .unicode = 'A' }};
    try writeToUnicodeCmap(&aw.writer, &m);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "1 beginbfchar") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<0001> <0041>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "beginbfrange") == null);
}

test "consecutive run → bfrange only" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    const m = [_]Mapping{
        .{ .cid = 1, .unicode = 'A' },
        .{ .cid = 2, .unicode = 'B' },
        .{ .cid = 3, .unicode = 'C' },
    };
    try writeToUnicodeCmap(&aw.writer, &m);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "1 beginbfrange") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<0001> <0003> <0041>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "beginbfchar") == null);
}

test "Codex gate: [(1,'A'),(2,'B'),(3,'D')] yields one bfrange + one bfchar" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    const m = [_]Mapping{
        .{ .cid = 1, .unicode = 'A' },
        .{ .cid = 2, .unicode = 'B' },
        .{ .cid = 3, .unicode = 'D' },
    };
    try writeToUnicodeCmap(&aw.writer, &m);
    const out = aw.written();
    // Both sections present.
    try std.testing.expect(std.mem.indexOf(u8, out, "1 beginbfrange") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<0001> <0002> <0041>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "1 beginbfchar") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<0003> <0044>") != null);
    // 'D' (0x0044) must appear exactly once — i.e. the run did NOT
    // silently absorb it as a 3-entry range mapping to A/B/D.
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOf(u8, out[idx..], "<0044>")) |found| {
        count += 1;
        idx += found + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "supplementary plane codepoint emits surrogate pair" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    // U+1F1EB (regional indicator letter F, part of the French flag emoji).
    const m = [_]Mapping{.{ .cid = 7, .unicode = 0x1F1EB }};
    try writeToUnicodeCmap(&aw.writer, &m);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "<d83cddeb>") != null);
}

test "mappings sort: input out of order is normalised" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    const m = [_]Mapping{
        .{ .cid = 5, .unicode = 'E' },
        .{ .cid = 1, .unicode = 'A' },
        .{ .cid = 2, .unicode = 'B' },
    };
    try writeToUnicodeCmap(&aw.writer, &m);
    const out = aw.written();
    // (1,A)..(2,B) becomes a bfrange; (5,E) lands as a bfchar.
    try std.testing.expect(std.mem.indexOf(u8, out, "<0001> <0002> <0041>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<0005> <0045>") != null);
}

test "256-boundary forces a split between ranges" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    // Two pairs: (0xFE,0xFE→a), (0xFF,0xFF→b), (0x100,0x100→c) — the
    // 0xFF→0x100 transition crosses the high-byte boundary so the range
    // must split there per spec.
    const m = [_]Mapping{
        .{ .cid = 0x00FE, .unicode = 0x0061 },
        .{ .cid = 0x00FF, .unicode = 0x0062 },
        .{ .cid = 0x0100, .unicode = 0x0063 },
    };
    try writeToUnicodeCmap(&aw.writer, &m);
    const out = aw.written();
    // Expect a bfrange (0xFE-0xFF) and a bfchar (0x0100). NOT a single
    // 3-entry range that would violate the "matching high byte" rule.
    try std.testing.expect(std.mem.indexOf(u8, out, "<00fe> <00ff>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<0100> <0063>") != null);
}
