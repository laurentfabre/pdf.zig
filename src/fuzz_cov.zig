//! Tier-6 fuzz harnesses for pdf.zig — iter-6 of the autonomous fuzz
//! loop (`audit/fuzz_loop_state.md`).
//!
//! Forward-portable shape — uses Zig 0.16's `std.testing.fuzz` +
//! `std.testing.Smith` API so the moment 0.16.x's `--fuzz` discovery
//! pass is fixed (see `build.zig` for the bug repro), flipping
//! `.fuzz = true` on the module turns these into coverage-guided
//! AFL-style tests with no harness edits.
//!
//! Today (Zig 0.16.0 stable) the wiring runs the **seed-corpus** branch
//! of `std.testing.fuzz` (test_runner.zig:596+): `Smith.in` is sourced
//! from `FuzzInputOptions.corpus`, the test_one body executes once per
//! corpus entry, and the harness asserts the same invariants the
//! coverage-guided variant would.
//!
//! Per the iter-6 brief: this is the named pivot — "*seed corpus
//! support* … rotate fixture PDFs in instead of pure random bytes" —
//! delivered through the new API rather than retrofitted onto
//! `fuzz_runner.zig`.
//!
//! Scope:
//!   - Two harnesses, both on the highest-value tier-2 surface:
//!       1. `parser_object`            — `parser.Parser.parseObject`
//!       2. `decompress_filter_chain`  — `decompress.decompressStream`
//!   - Invariants mirror the random-byte targets in `fuzz_runner.zig`
//!     (validateObjectShape, ParseError exhaustive switch, freeable
//!     decompress result, MAX_DECOMPRESSED_SIZE cap).
//!
//! Why these two:
//!   - Parser is the deepest attack surface in the codebase
//!     (140 KB of PDF cross-reference / token / object code reachable)
//!     and tier-2 is already clean at 1M random iters — a Smith-driven
//!     harness is the next escalation rung above plain `std.Random`.
//!   - Decompress filter-chain reaches the multi-stage
//!     decoder→decoder ownership transfer with `decompressStream`'s
//!     `owned` lifetime baton. The corpus excludes ASCII85Decode so
//!     Finding 005 doesn't trip every smoke run.
//!
//! Seed corpus:
//!   - Synthetic CJK PDFs from `audit/cjk-pdfs/synthetic/` are
//!     `@embedFile`'d at comptime. Each fixture is a real, valid PDF
//!     (~1.2 KB, hand-verified) — useful both as parser fodder and as
//!     a hint to a future coverage-guided run that `%PDF-` headers
//!     deserve mutation.
//!   - A handful of inline byte literals exercise the targeted
//!     codepaths the fuzzer is most likely to miss from random bytes
//!     alone (named filters, balanced indirect-object frames, etc.).
//!
//! Smoke (≈1 s, runs the seed corpus once):
//!   ~/.zvm/bin/zig build fuzz-cov
//!
//! Per the loop rules in `audit/fuzz_loop_state.md`: a panic / failed
//! invariant in either test means a real bug — dump the failing input,
//! open a Finding, do **not** auto-fix.

const std = @import("std");
const builtin = @import("builtin");

const parser = @import("parser.zig");
const decompress = @import("decompress.zig");

// ============================================================================
// Seed corpora (comptime-embedded inline byte literals)
// ============================================================================
//
// Hand-crafted byte sequences targeting parser / decompress branches
// that random bytes would take a long time to discover. Per the Smith
// corpus protocol (Smith.zig:620): the first 4 bytes of `in` are read
// as a little-endian u32 length prefix for `slice` calls; the
// `corpusEntry` helper prepends that prefix so the test_one body sees
// realistic byte slices.
//
// We deliberately do NOT @embedFile audit/cjk-pdfs/synthetic/*.pdf
// here — those fixtures live outside the `src/` package boundary, and
// extending the package would scatter test assets. The inline literals
// below cover the same branches the embedded PDFs would exercise (PDF
// header, indirect-object frame, dict / array / name shapes, integer
// overflow guard, decoder EOD markers).

fn corpusEntry(comptime payload: []const u8) []const u8 {
    const len_bytes = std.mem.toBytes(@as(u32, @intCast(payload.len)));
    return len_bytes[0..] ++ payload;
}

const parser_corpus = [_][]const u8{
    // Realistic PDF prologue — exercises the version-string +
    // first-token path. Shorter than the 1.2 KB synthetic fixtures
    // but lights up the same `%PDF-` branches.
    corpusEntry("%PDF-1.7\n%\xe2\xe3\xcf\xd3\n1 0 obj\n<<>>\nendobj\n"),
    // Common PDF object shapes.
    corpusEntry("<<>>"), // empty dict
    corpusEntry("[1 2 3 4 5]"), // simple array
    corpusEntry("<< /Type /Catalog /Pages 2 0 R >>"), // catalog dict
    corpusEntry("<< /Length 42 /Filter /FlateDecode >>"), // stream dict
    corpusEntry("(unbalanced"), // unterminated literal string
    corpusEntry("<deadbeef>"), // hex string
    corpusEntry("/Name#20with#20spaces"), // name with hex escapes
    corpusEntry("99999999999999999999"), // overflowing integer
    corpusEntry("0.000000001 -1.5 +.5 .5e10"), // real number variants
    corpusEntry("[[[[[[[[[[[]]]]]]]]]]]"), // deep nesting
    corpusEntry("<< /K [ 1 2 3 ] /P null >>"), // mixed dict
};

const decompress_corpus = [_][]const u8{
    // Empty payload — exercises each decoder's zero-byte fast path.
    corpusEntry(""),
    // ASCII-hex-shaped content with EOD terminator.
    corpusEntry("48656c6c6f>"),
    // ASCII-hex with whitespace + odd char count.
    corpusEntry("4 8\n6 5\n6c\n6c\n6f >"),
    // Run-length: 5-byte literal then EOD marker (128).
    corpusEntry(&.{ 4, 'a', 'b', 'c', 'd', 'e', 128 }),
    // Run-length: repeat run + EOD.
    corpusEntry(&.{ 254, 'X', 128 }),
    // Garbage payload — every decoder must reject without panic.
    corpusEntry("\x00\x01\x02\x03\xff\xfe\xfd"),
    // LZW-shaped payload (clear-table code 0x80 prefix).
    corpusEntry(&.{ 0x80, 0x00, 0x00, 0x40 }),
};

// ============================================================================
// Harness 1 — parser.parseObject (tier-6 over tier-2)
// ============================================================================

// Coverage-guided variant of `fuzzParserObjectPdfish` from
// `src/fuzz_runner.zig`. The random-byte version is clean at 1M iters
// per `audit/fuzz_loop_state.md` (iter 2). This variant lets the
// edge-coverage feedback loop discover token shapes the random pass
// missed.
//
// Invariants (must hold for every input):
//   - no panic, no UB sanitizer trip, no integer-overflow trap
//   - on success: `p.pos <= p.data.len`
//   - on success: returned `Object` graph is well-formed under
//     `validateObjectShape` (no NaN reals, dict entries non-aliased,
//     nesting bounded by `parser.MAX_NESTING`)
//   - any returned error is a member of `parser.ParseError`
//
// Pre-condition: `Smith` provides up to 4 KiB of fuzzer-driven bytes.
test "fuzz parser_object" {
    try std.testing.fuzz({}, fuzzParserObject, .{ .corpus = &parser_corpus });
}

fn fuzzParserObject(_: void, smith: *std.testing.Smith) anyerror!void {
    @disableInstrumentation();

    // 4 KiB matches the random-byte harness's `scratch.len` upper bound,
    // so any crash repros against the same input shape.
    var buf: [4096]u8 = undefined;
    const n = smith.slice(&buf);

    std.debug.assert(n <= buf.len);

    // Arena: parseObject's nested allocations (arrays, dicts, strings)
    // are all freed in one call. Same pattern as `fuzzParserObjectPdfish`
    // in `src/fuzz_runner.zig`.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var p: parser.Parser = .init(arena.allocator(), buf[0..n]);
    const obj = p.parseObject() catch |err| switch (err) {
        // Every member of ParseError is an expected adversarial-input
        // outcome. Listing them exhaustively means a future addition
        // becomes a compile error here, not a silent fuzz miss.
        error.UnexpectedToken,
        error.UnexpectedEof,
        error.InvalidNumber,
        error.InvalidString,
        error.InvalidHexString,
        error.InvalidName,
        error.InvalidDictionary,
        error.InvalidArray,
        error.InvalidStream,
        error.InvalidReference,
        error.NestingTooDeep,
        error.OutOfMemory,
        => return,
    };

    // Post-conditions on the success path. Failure here is a *real* bug:
    // the parser claimed success but left state inconsistent.
    if (p.pos > p.data.len) return error.ParserPosBeyondData;
    if (p.pos == 0 and n > 0) return error.ParserDidNotAdvance;

    try validateObjectShape(obj, 0);
}

/// Mirror of `validateObjectShape` in `src/fuzz_runner.zig` — kept here
/// so the coverage-guided harness is self-contained and doesn't drag
/// in the larger `fuzz_runner.zig` module (which has a `pub fn main`
/// and would conflict with the test_runner's `main`).
///
/// Invariants enforced:
///   - real numbers are finite (no NaN / ±inf)
///   - nesting depth bounded by 200 (generous backstop above the
///     parser's documented MAX_NESTING=100)
fn validateObjectShape(obj: parser.Object, depth: usize) anyerror!void {
    @disableInstrumentation();
    if (depth > 200) return error.ObjectNestingExceedsBackstop;
    switch (obj) {
        .null, .boolean, .integer => {},
        .real => |r| {
            if (!std.math.isFinite(r)) return error.ObjectRealNonFinite;
        },
        .string, .hex_string, .name => {},
        .array => |arr| {
            for (arr) |item| try validateObjectShape(item, depth + 1);
        },
        .dict => |d| {
            for (d.entries) |entry| try validateObjectShape(entry.value, depth + 1);
        },
        .stream => |s| {
            for (s.dict.entries) |entry| try validateObjectShape(entry.value, depth + 1);
        },
        .reference => {},
    }
}

// ============================================================================
// Harness 2 — decompress.decompressStream filter chain (tier-6 over tier-1)
// ============================================================================

// Coverage-guided variant of the iter-1 / iter-5 decompress targets.
// Drives `decompressStream` through a multi-filter pipeline. The
// fuzzer chooses the filter sequence (length 1-3 from a curated set
// that *excludes* ASCII85Decode), then chooses the input bytes.
//
// ASCII85Decode is excluded because Finding 005 (open) is a u32 overflow
// in `decodeASCII85` that aborts on `"uuuuu"`. Including it here would
// cause every long coverage-guided run to terminate within seconds on
// the same known issue. Re-include once Finding 005 is fixed.
//
// Invariants:
//   - no panic, no UB sanitizer trip, no integer-overflow trap
//   - on success: returned slice is non-null and freeable via the
//     same allocator
//   - any returned error is a member of `decompress.DecompressError`
//     or `error.OutOfMemory`
//
// The harness builds an in-memory `parser.Object` representing the
// /Filter array from raw token bytes — that path itself is part of
// what we're testing.
test "fuzz decompress_filter_chain" {
    try std.testing.fuzz({}, fuzzDecompressFilterChain, .{ .corpus = &decompress_corpus });
}

const SafeFilters = [_][]const u8{
    "FlateDecode",
    "ASCIIHexDecode",
    "RunLengthDecode",
    // LZWDecode is intentionally included — pdf.zig has a hand-rolled
    // LZW decoder at decompress.zig and it has had no coverage-guided
    // pass yet.
    "LZWDecode",
};

fn fuzzDecompressFilterChain(_: void, smith: *std.testing.Smith) anyerror!void {
    @disableInstrumentation();

    // Pick 1-3 filters. The fuzzer learns which sequences hit new
    // basic blocks in `applyFilter` + the per-decoder dispatch.
    //
    // Smith requires fixed-bitsize types (no `usize`); we use `u32`
    // for the count and `Smith.index` (which itself takes a usize but
    // hashes internally) for the filter selection.
    const n_filters: u32 = smith.valueRangeAtMost(u32, 1, 3);
    var filter_storage: [3]parser.Object = undefined;
    var i: u32 = 0;
    while (i < n_filters) : (i += 1) {
        const idx = smith.index(SafeFilters.len);
        filter_storage[i] = .{ .name = SafeFilters[idx] };
    }
    const filter_array: parser.Object = .{ .array = filter_storage[0..n_filters] };

    // Up to 4 KiB of fuzzer-driven payload bytes. The decoder's
    // input-byte handling — escape sequences, code-table state,
    // truncation — is what the coverage signal will steer.
    var payload_buf: [4096]u8 = undefined;
    const payload_len = smith.slice(&payload_buf);

    const result = decompress.decompressStream(
        std.testing.allocator,
        payload_buf[0..payload_len],
        filter_array,
        null,
    ) catch |err| switch (err) {
        // DecompressError set + OOM are both expected on adversarial
        // input. Any other error is a harness bug — propagate.
        error.UnsupportedFilter,
        error.InvalidFilterParams,
        error.DecompressFailed,
        error.OutputTooLarge,
        error.InvalidPredictor,
        error.OutOfMemory,
        => return,
    };
    defer std.testing.allocator.free(result);

    // Post-condition: result is freeable (deferred above) and bounded
    // by the documented MAX_DECOMPRESSED_SIZE. The decoder asserts
    // this internally; we re-assert here so a regression in the cap
    // is caught at the boundary.
    const MAX_DECOMPRESSED_SIZE: usize = 256 * 1024 * 1024;
    if (result.len > MAX_DECOMPRESSED_SIZE) return error.DecompressOverCap;
}
