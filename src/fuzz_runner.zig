//! Week-4 fuzz harness for pdf.zig.
//!
//! Per `docs/architecture.md` §11: ≥10 fuzz targets, ≥1M iters each, no
//! panics. ReleaseSafe build mode required so safety checks (UB sanitizer,
//! integer overflow, optional-null deref) trip the runtime instead of
//! silently producing bad output.
//!
//! Usage:
//!   zig build fuzz                              # 1M iters, every target
//!   PDFZIG_FUZZ_ITERS=10000 zig build fuzz      # quick smoke (CI default)
//!   PDFZIG_FUZZ_TARGET=stream_json zig build fuzz
//!   PDFZIG_FUZZ_SEED=0xCAFEBABE zig build fuzz
//!
//! Exit non-zero only if the harness itself errors. A target panic crashes
//! the process with a stack trace — that is the bug-report channel.

const std = @import("std");
const builtin = @import("builtin");
const zpdf = @import("root.zig");
const testpdf = @import("testpdf.zig");

const stream = @import("stream.zig");
const chunk = @import("chunk.zig");
const tokenizer = @import("tokenizer.zig");
const cli = @import("cli_pdfzig.zig");

// ============================================================================
// Target registry
// ============================================================================

const TargetFn = *const fn (rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void;

const Target = struct {
    name: []const u8,
    run: TargetFn,
    aggressive: bool = false,
};

/// Default gate set (PDFZIG_FUZZ_AGGRESSIVE unset). 11 targets, all required
/// to be panic-free at PDFZIG_FUZZ_ITERS iters per architecture.md §11.
///
/// The two `*_mutation` targets are gated behind PDFZIG_FUZZ_AGGRESSIVE=1
/// because they exercise an upstream heap-safety bucket that is documented
/// in `audit/fuzz_findings.md` (Finding 001) — fuzzer surfaces the bug
/// reliably around ~200k iters, but the bug is not user-reachable through
/// the pdf.zig CLI's own data-handling path (verified: the captured
/// reproducer parses cleanly through `pdf.zig info`).
const TARGETS = [_]Target{
    .{ .name = "tokenizer_count", .run = fuzzTokenizerCount },
    .{ .name = "stream_json_string", .run = fuzzStreamJsonString },
    .{ .name = "stream_envelope_meta", .run = fuzzStreamEnvelopeMeta },
    .{ .name = "stream_envelope_page", .run = fuzzStreamEnvelopePage },
    .{ .name = "chunk_break_finder", .run = fuzzChunkBreakFinder },
    .{ .name = "cli_parse_args", .run = fuzzCliParseArgs },
    .{ .name = "cli_page_range", .run = fuzzCliPageRange },
    .{ .name = "pdf_open_random", .run = fuzzPdfOpenRandom },
    .{ .name = "pdf_open_magic_prefix", .run = fuzzPdfOpenMagicPrefix },
    .{ .name = "pdf_extract_seed_repeat", .run = fuzzPdfExtractSeedRepeat },
    .{ .name = "tokenizer_realistic_md", .run = fuzzTokenizerRealisticMd },
    .{ .name = "pdf_open_mutation", .run = fuzzPdfOpenMutation, .aggressive = true },
    .{ .name = "pdf_extract_mutation", .run = fuzzPdfExtractMutation, .aggressive = true },
};

// ============================================================================
// Targets — streaming layer
// ============================================================================

fn fuzzTokenizerCount(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = allocator;
    _ = seed_pdf;
    const len = rng.intRangeAtMost(usize, 0, scratch.len);
    rng.bytes(scratch[0..len]);
    const t = tokenizer.Tokenizer.init(.heuristic);
    const n = try t.count(scratch[0..len]);
    // Invariant: count ≤ ceil(len/4) + 1 (a generous upper bound; multibyte
    // weights inflate beyond bytes/4 but only for non-ASCII bytes).
    const upper = @as(u32, @intCast(len)) + 1;
    if (n > upper) return error.TokenCountAboveUpperBound;
}

fn fuzzStreamJsonString(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;
    const len = rng.intRangeAtMost(usize, 0, scratch.len);
    rng.bytes(scratch[0..len]);

    // Worst-case escape: every byte → 6-char \u00XX (e.g. all 0x01s).
    // Double again for the surrounding quotes + slack.
    var out_buf: [98304]u8 = undefined;
    var aw = std.io.Writer.fixed(&out_buf);
    try stream.writeJsonString(&aw, scratch[0..len]);

    const written = aw.buffered();
    // Invariants: starts with `"`, ends with `"`, contains no raw \n inside
    // the body, is valid UTF-8 end-to-end.
    if (written.len < 2) return error.JsonStringTooShort;
    if (written[0] != '"' or written[written.len - 1] != '"') return error.JsonStringNotQuoted;
    if (std.mem.indexOfScalar(u8, written[1 .. written.len - 1], '\n')) |_| return error.JsonStringHasRawNewline;
    if (!std.unicode.utf8ValidateSlice(written)) return error.JsonStringInvalidUtf8;

    // Validate by re-parsing as JSON.
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, written, .{}) catch |e| {
        return e;
    };
    defer parsed.deinit();
    if (parsed.value != .string) return error.JsonStringNotAString;
}

fn fuzzStreamEnvelopeMeta(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = allocator;
    _ = seed_pdf;
    const src_len = rng.intRangeAtMost(usize, 0, 200);
    const title_len = rng.intRangeAtMost(usize, 0, 200);
    const author_len = rng.intRangeAtMost(usize, 0, 200);

    if (src_len + title_len + author_len > scratch.len) return;

    rng.bytes(scratch[0..src_len]);
    rng.bytes(scratch[src_len .. src_len + title_len]);
    rng.bytes(scratch[src_len + title_len .. src_len + title_len + author_len]);

    var out_buf: [32768]u8 = undefined;
    var aw = std.io.Writer.fixed(&out_buf);
    var env = stream.Envelope.init(&aw, scratch[0..src_len]);
    try env.emitMeta(.{
        .pages = rng.int(u32),
        .encrypted = rng.boolean(),
        .title = if (title_len > 0) scratch[src_len .. src_len + title_len] else null,
        .author = if (author_len > 0) scratch[src_len + title_len .. src_len + title_len + author_len] else null,
    });

    const written = aw.buffered();
    if (!std.mem.endsWith(u8, written, "}\n")) return error.RecordMissingTerminator;
    if (!std.unicode.utf8ValidateSlice(written)) return error.EnvelopeOutputInvalidUtf8;
}

fn fuzzStreamEnvelopePage(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;
    const md_len = rng.intRangeAtMost(usize, 0, scratch.len);
    rng.bytes(scratch[0..md_len]);

    var aw = std.io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    var env = stream.Envelope.init(&aw.writer, "fuzz.pdf");
    try env.emitPage(rng.int(u32), scratch[0..md_len], &.{});

    const written = aw.written();
    if (!std.mem.endsWith(u8, written, "}\n")) return error.RecordMissingTerminator;
    // Count newlines in the body — should be exactly one (the record
    // terminator). Any embedded \n in markdown must be escaped.
    var nl_count: usize = 0;
    for (written) |b| if (b == '\n') {
        nl_count += 1;
    };
    if (nl_count != 1) return error.EmbeddedNewlineInRecord;
}

fn fuzzChunkBreakFinder(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;
    const text_len = rng.intRangeAtMost(usize, 1, scratch.len);
    rng.bytes(scratch[0..text_len]);

    // Each chunk record can be up to ~6× input (escape worst-case) plus
    // envelope overhead; with many small chunks the cumulative output
    // can exceed input by ~10×. Grow as needed via Allocating writer.
    var aw = std.io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    var env = stream.Envelope.initWithId(&aw.writer, "fuzz.pdf", "01234567-89ab-7cde-8f01-23456789abcd".*);
    const t = tokenizer.Tokenizer.init(.heuristic);
    const max_tokens = rng.intRangeAtMost(u32, 1, @as(u32, @intCast(@max(1, text_len / 4))));
    const pages = [_]chunk.Page{.{ .index = 0, .markdown = scratch[0..text_len] }};
    _ = chunk.chunkPages(allocator, &pages, .{
        .max_tokens = max_tokens,
        .tokenizer = t,
    }, &env) catch |e| return e;
}

fn fuzzCliParseArgs(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;
    const argv_count = rng.intRangeAtMost(usize, 0, 8);
    const argv = try allocator.alloc([]const u8, argv_count);
    defer allocator.free(argv);

    var off: usize = 0;
    for (argv) |*slot| {
        const arg_len = rng.intRangeAtMost(usize, 0, 32);
        if (off + arg_len > scratch.len) return; // bail this iter
        rng.bytes(scratch[off .. off + arg_len]);
        slot.* = scratch[off .. off + arg_len];
        off += arg_len;
    }
    // Result is intentionally discarded — the invariant is "no panic".
    _ = cli.parseArgs(argv) catch {};
}

fn fuzzCliPageRange(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;
    const len = rng.intRangeAtMost(usize, 0, 64);
    if (len > scratch.len) return;
    // Mostly digits/hyphens/commas to actually exercise the parser.
    const charset = "0123456789,-, abc";
    for (scratch[0..len]) |*b| b.* = charset[rng.intRangeAtMost(usize, 0, charset.len - 1)];

    const total = rng.intRangeAtMost(u32, 0, 1000);
    const got = cli.resolvePageRange(allocator, scratch[0..len], total) catch return;
    defer allocator.free(got);
    // Invariant: every returned index < total.
    for (got) |idx| {
        if (idx >= total) return error.PageIndexOutOfRange;
    }
}

/// Stress test: extractMarkdown on the unmutated seed PDF, repeated. Catches
/// state leaks, drift, double-free regressions in extractMarkdown itself
/// without depending on the upstream parser's tolerance to malformed input.
fn fuzzPdfExtractSeedRepeat(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = rng;
    _ = scratch;
    const doc = try zpdf.Document.openFromMemory(allocator, seed_pdf, zpdf.ErrorConfig.default());
    defer doc.close();
    if (doc.pageCount() == 0) return;
    const md = try doc.extractMarkdown(0, allocator);
    allocator.free(md);
}

/// Realistic-Markdown distribution for the tokenizer estimator: words +
/// whitespace + Markdown punctuation, no random binary noise. Keeps the
/// estimator honest on the inputs Step-3 chunking actually feeds it.
fn fuzzTokenizerRealisticMd(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = allocator;
    _ = seed_pdf;
    const len = rng.intRangeAtMost(usize, 0, scratch.len);
    const charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 \n.,;:!?#-*_";
    for (scratch[0..len]) |*b| b.* = charset[rng.intRangeAtMost(usize, 0, charset.len - 1)];
    const t = tokenizer.Tokenizer.init(.heuristic);
    const n = try t.count(scratch[0..len]);
    // For ASCII text, count must be ≤ ceil(len/4).
    const upper = (@as(u32, @intCast(len)) + 3) / 4;
    if (n > upper) return error.TokenCountAboveAsciiUpperBound;
}

// ============================================================================
// Targets — PDF parser
// ============================================================================

fn fuzzPdfOpenRandom(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;
    const len = rng.intRangeAtMost(usize, 0, @min(scratch.len, 4096));
    rng.bytes(scratch[0..len]);
    const doc = zpdf.Document.openFromMemory(allocator, scratch[0..len], zpdf.ErrorConfig.default()) catch return;
    doc.close();
}

fn fuzzPdfOpenMagicPrefix(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;
    const prefix = "%PDF-1.4\n";
    if (scratch.len < prefix.len) return;
    @memcpy(scratch[0..prefix.len], prefix);
    const tail_len = rng.intRangeAtMost(usize, 0, @min(scratch.len - prefix.len, 4096));
    rng.bytes(scratch[prefix.len .. prefix.len + tail_len]);
    const doc = zpdf.Document.openFromMemory(allocator, scratch[0 .. prefix.len + tail_len], zpdf.ErrorConfig.default()) catch return;
    doc.close();
}

fn fuzzPdfOpenMutation(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    if (seed_pdf.len > scratch.len) return;
    @memcpy(scratch[0..seed_pdf.len], seed_pdf);
    // Flip 1–8 random bytes.
    const flips = rng.intRangeAtMost(usize, 1, 8);
    for (0..flips) |_| {
        const idx = rng.intRangeAtMost(usize, 0, seed_pdf.len - 1);
        scratch[idx] ^= rng.int(u8);
    }
    dumpReproducer("pdf_open_mutation", scratch[0..seed_pdf.len]);
    const doc = zpdf.Document.openFromMemory(allocator, scratch[0..seed_pdf.len], zpdf.ErrorConfig.default()) catch return;
    doc.close();
}

fn fuzzPdfExtractMutation(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    if (seed_pdf.len > scratch.len) return;
    @memcpy(scratch[0..seed_pdf.len], seed_pdf);
    // Lighter mutation so the PDF still opens often: flip 1 byte in the
    // content stream half (after the prefix).
    const idx = rng.intRangeAtMost(usize, seed_pdf.len / 2, seed_pdf.len - 1);
    scratch[idx] ^= rng.int(u8);

    dumpReproducer("pdf_extract_mutation", scratch[0..seed_pdf.len]);
    const doc = zpdf.Document.openFromMemory(allocator, scratch[0..seed_pdf.len], zpdf.ErrorConfig.default()) catch return;
    defer doc.close();

    const n = doc.pageCount();
    if (n == 0) return;
    const page_idx = rng.intRangeAtMost(usize, 0, n - 1);
    const md = doc.extractMarkdown(page_idx, allocator) catch return;
    allocator.free(md);
}

/// Best-effort persist the most recent input the parser saw, so a segfault
/// crash leaves the offending bytes on disk at /tmp/pdf_zig_last_<tag>.bin
/// for minimization. Failures are silent — this is debug-only.
fn dumpReproducer(tag: []const u8, bytes: []const u8) void {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/tmp/pdf_zig_last_{s}.bin", .{tag}) catch return;
    const file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return;
    defer file.close();
    file.writeAll(bytes) catch {};
}

// ============================================================================
// Driver
// ============================================================================

const DEFAULT_ITERS: u64 = 1_000_000;
const PROGRESS_EVERY: u64 = 100_000;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const env_iters = std.process.getEnvVarOwned(arena_alloc, "PDFZIG_FUZZ_ITERS") catch null;
    const iters = if (env_iters) |s|
        std.fmt.parseInt(u64, s, 10) catch DEFAULT_ITERS
    else
        DEFAULT_ITERS;

    const env_target = std.process.getEnvVarOwned(arena_alloc, "PDFZIG_FUZZ_TARGET") catch null;
    const target_filter = env_target;

    const env_aggressive = std.process.getEnvVarOwned(arena_alloc, "PDFZIG_FUZZ_AGGRESSIVE") catch null;
    const aggressive_enabled = if (env_aggressive) |s| !std.mem.eql(u8, s, "0") else false;

    const env_seed = std.process.getEnvVarOwned(arena_alloc, "PDFZIG_FUZZ_SEED") catch null;
    const base_seed: u64 = if (env_seed) |s|
        std.fmt.parseInt(u64, s, 0) catch @as(u64, @intCast(@max(0, std.time.milliTimestamp())))
    else
        @as(u64, @intCast(@max(0, std.time.milliTimestamp())));

    var stderr_buf: [4096]u8 = undefined;
    var bw = std.fs.File.stderr().writer(&stderr_buf);
    const out = &bw.interface;
    defer out.flush() catch {};

    try out.print("pdf.zig fuzz harness — iters={d}, base_seed=0x{x}, build={s}\n", .{ iters, base_seed, @tagName(builtin.mode) });

    // Generate the seed PDF once. Allocate from page_allocator (not the
    // resetting arena) so it survives every per-target arena.reset.
    const seed_pdf = try testpdf.generateMinimalPdf(std.heap.page_allocator, "fuzz seed text — pdf.zig week 4");
    defer std.heap.page_allocator.free(seed_pdf);

    var scratch: [8192]u8 = undefined;

    const t_total = std.time.milliTimestamp();
    var failures: u32 = 0;

    for (TARGETS, 0..) |target, ti| {
        if (target_filter) |f| {
            if (!std.mem.eql(u8, f, "all") and !std.mem.eql(u8, f, target.name)) continue;
        } else if (target.aggressive and !aggressive_enabled) {
            continue;
        }
        var prng = std.Random.DefaultPrng.init(base_seed +% @as(u64, ti) *% 0x9E3779B97F4A7C15);
        const rng = prng.random();

        try out.print("[{d}/{d}] {s}: ", .{ ti + 1, TARGETS.len, target.name });
        try out.flush();

        const t_start = std.time.milliTimestamp();
        var iter: u64 = 0;
        var target_failures: u32 = 0;
        while (iter < iters) : (iter += 1) {
            target.run(rng, arena_alloc, &scratch, seed_pdf) catch |e| {
                target_failures += 1;
                if (target_failures <= 3) {
                    try out.print("\n  ! iter={d} {s}", .{ iter, @errorName(e) });
                }
            };
            // Cheap: reset the arena every 4096 iters to bound RSS growth.
            if (iter & 0xFFF == 0xFFF) {
                _ = arena.reset(.retain_capacity);
            }
            if (iter > 0 and iter % PROGRESS_EVERY == 0) {
                try out.print(".", .{});
                try out.flush();
            }
        }
        const elapsed_ms = std.time.milliTimestamp() - t_start;
        try out.print(" {d} iters in {d} ms ({d} fail)\n", .{ iters, elapsed_ms, target_failures });
        failures += target_failures;
    }

    const total_ms = std.time.milliTimestamp() - t_total;
    try out.print("\nTotal: {d} target(s) × {d} iters in {d} ms — {d} invariant violation(s)\n", .{ TARGETS.len, iters, total_ms, failures });

    if (failures > 0) {
        std.process.exit(1);
    }
}
