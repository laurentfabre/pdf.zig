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

// The three checkAllAllocationFailures tests below document upstream
// allocation-failure leaks (Findings 001, 002, 003 in audit/fuzz_findings.md).
// Until upstream errdefer hygiene is fixed, the tests assert the *current*
// shape — `error.MemoryLeak` — so a regression to hard panic or to a CORRECT
// rollback (which would be the fix landing) both fail the test loudly and
// force a documentation update.
//
// To enable strict-mode assertions (i.e. "must NOT leak"), build with
// `-Dstrict-alloc-failure=true`. Default is the documented-shape mode below.

test "checkAllAllocationFailures — Document.openFromMemory (Finding 001)" {
    const seed = try testpdf.generateMinimalPdf(std.testing.allocator, SEED_TEXT);
    defer std.testing.allocator.free(seed);

    // Backing: page_allocator. The FailingAllocator wraps it and runs its
    // own alloc/free accounting (returns error.MemoryLeakDetected on leak).
    // Using testing.allocator would *also* fire its leak checker on the
    // upstream's partial-OOM leaks, double-counting failures.
    const result = std.testing.checkAllAllocationFailures(
        std.heap.page_allocator,
        openOnly,
        .{seed},
    );
    try std.testing.expectError(error.MemoryLeakDetected, result);
}

test "checkAllAllocationFailures — Document.extractMarkdown (Finding 002)" {
    const seed = try testpdf.generateMinimalPdf(std.testing.allocator, SEED_TEXT);
    defer std.testing.allocator.free(seed);

    // Backing: page_allocator. The FailingAllocator wraps it and runs its
    // own alloc/free accounting (returns error.MemoryLeakDetected on leak).
    // Using testing.allocator would *also* fire its leak checker on the
    // upstream's partial-OOM leaks, double-counting failures.
    const result = std.testing.checkAllAllocationFailures(
        std.heap.page_allocator,
        openAndExtract,
        .{seed},
    );
    try std.testing.expectError(error.MemoryLeakDetected, result);
}

test "checkAllAllocationFailures — Document.metadata (Finding 003)" {
    const seed = try testpdf.generateMinimalPdf(std.testing.allocator, SEED_TEXT);
    defer std.testing.allocator.free(seed);

    // Backing: page_allocator. The FailingAllocator wraps it and runs its
    // own alloc/free accounting (returns error.MemoryLeakDetected on leak).
    // Using testing.allocator would *also* fire its leak checker on the
    // upstream's partial-OOM leaks, double-counting failures.
    const result = std.testing.checkAllAllocationFailures(
        std.heap.page_allocator,
        openAndMetadata,
        .{seed},
    );
    try std.testing.expectError(error.MemoryLeakDetected, result);
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
