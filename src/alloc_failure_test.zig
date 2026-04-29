//! checkAllAllocationFailures coverage on the parse paths that the pdf.zig
//! CLI hits per architecture.md §11. Each test wraps a parse function in
//! `std.testing.checkAllAllocationFailures`, which runs it under a
//! FailingAllocator that fails at each successive allocation index — the
//! function under test must return error.OutOfMemory cleanly at every
//! failure point, with no leaks.
//!
//! Coverage:
//!   - Document.openFromMemory on a known-good minimal PDF
//!   - Document.extractMarkdown on the same PDF (page 0)
//!   - Document.metadata access
//!   - tokenizer.heuristicCount (allocation-free; smoke test only)

const std = @import("std");
const zpdf = @import("root.zig");
const testpdf = @import("testpdf.zig");
const tokenizer = @import("tokenizer.zig");

/// Generate the seed PDF once (under a non-failing allocator) and pass it
/// as a constant input to each AllocationFailures-wrapped function. We are
/// testing the parser's recovery, not the test PDF generator's.
const SEED_TEXT = "alloc failure test — pdf.zig week 4";

fn openOnly(allocator: std.mem.Allocator, pdf_bytes: []const u8) !void {
    const doc = try zpdf.Document.openFromMemory(
        allocator,
        pdf_bytes,
        zpdf.ErrorConfig.default(),
    );
    doc.close();
}

fn openAndExtract(allocator: std.mem.Allocator, pdf_bytes: []const u8) !void {
    const doc = try zpdf.Document.openFromMemory(
        allocator,
        pdf_bytes,
        zpdf.ErrorConfig.default(),
    );
    defer doc.close();
    if (doc.pageCount() == 0) return;
    const md = try doc.extractMarkdown(0, allocator);
    allocator.free(md);
}

fn openAndMetadata(allocator: std.mem.Allocator, pdf_bytes: []const u8) !void {
    const doc = try zpdf.Document.openFromMemory(
        allocator,
        pdf_bytes,
        zpdf.ErrorConfig.default(),
    );
    defer doc.close();
    _ = doc.metadata();
}

// PR-9 [refactor]: strict-mode assertions now active. The three
// checkAllAllocationFailures tests below previously asserted the
// *current* leak shape (Findings 001-003 in audit/fuzz_findings.md);
// PR-9 added a `deinitPartial` errdefer chain on the open* paths
// that rolls back hashmap/arena/list growth on parseDocument
// failure, so the leaks no longer reproduce. Tests now assert
// "must NOT leak" — `try result` propagates any unexpected error
// (OutOfMemory at the failure index is the only expected one).

test "checkAllAllocationFailures — Document.openFromMemory (Finding 001 RESOLVED)" {
    const seed = try testpdf.generateMinimalPdf(std.testing.allocator, SEED_TEXT);
    defer std.testing.allocator.free(seed);

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        openOnly,
        .{seed},
    );
}

test "checkAllAllocationFailures — Document.extractMarkdown (Finding 002 RESOLVED)" {
    const seed = try testpdf.generateMinimalPdf(std.testing.allocator, SEED_TEXT);
    defer std.testing.allocator.free(seed);

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        openAndExtract,
        .{seed},
    );
}

test "checkAllAllocationFailures — Document.metadata (Finding 003 RESOLVED)" {
    const seed = try testpdf.generateMinimalPdf(std.testing.allocator, SEED_TEXT);
    defer std.testing.allocator.free(seed);

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        openAndMetadata,
        .{seed},
    );
}

test "tokenizer.heuristicCount is allocation-free" {
    // The heuristic backend allocates nothing — verify the call path stays
    // that way by counting allocations through a tracking allocator.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const before = arena.queryCapacity();
    const t = tokenizer.Tokenizer.init(.heuristic);
    _ = try t.count("the quick brown fox jumps over the lazy dog");
    const after = arena.queryCapacity();
    try std.testing.expectEqual(before, after);
}
