//! Token-aware chunking for `pdf.zig extract --output chunks --max-tokens N`.
//!
//! Greedy pack pages into chunks ≤ max_tokens. Within a chunk, prefer
//! cutting at (1) a section heading, (2) a page boundary, (3) a paragraph
//! boundary, (4) a sentence boundary — in that order.
//!
//! v1 keeps the heuristic simple: always start each chunk at a page
//! boundary, then if a single page exceeds `max_tokens`, sub-chunk it on
//! markdown headings → blank lines → sentences. Spec lives in
//! `docs/streaming-layer-design.md`.

const std = @import("std");
const stream = @import("stream.zig");
const tokenizer = @import("tokenizer.zig");

pub const Page = struct {
    /// 0-indexed page number, used in the emitted chunk's `pages` array.
    index: u32,
    markdown: []const u8,
};

pub const Options = struct {
    max_tokens: u32,
    tokenizer: tokenizer.Tokenizer,
};

/// Pack `pages` into chunks ≤ opts.max_tokens, emitting each via `env`.
/// Returns the number of chunks emitted.
pub fn chunkPages(
    allocator: std.mem.Allocator,
    pages: []const Page,
    opts: Options,
    env: *stream.Envelope,
) !u32 {
    if (opts.max_tokens == 0) return error.InvalidMaxTokens;

    var chunk_id: u32 = 0;

    var pending_pages: std.ArrayList(u32) = .empty;
    defer pending_pages.deinit(allocator);
    var pending_md: std.ArrayList(u8) = .empty;
    defer pending_md.deinit(allocator);
    var pending_tokens: u32 = 0;

    for (pages) |page| {
        const page_tokens = try opts.tokenizer.count(page.markdown);

        if (page_tokens > opts.max_tokens) {
            // Flush any pending chunk first so the giant page lands clean.
            if (pending_pages.items.len > 0) {
                try emitPending(env, chunk_id, &pending_pages, &pending_md, pending_tokens, .page_boundary);
                chunk_id += 1;
                pending_tokens = 0;
            }
            chunk_id = try splitGiantPage(page, opts, env, chunk_id);
            continue;
        }

        if (pending_tokens + page_tokens > opts.max_tokens) {
            try emitPending(env, chunk_id, &pending_pages, &pending_md, pending_tokens, .page_boundary);
            chunk_id += 1;
            pending_tokens = 0;
        }

        if (pending_md.items.len > 0) try pending_md.appendSlice(allocator, "\n\n");
        try pending_md.appendSlice(allocator, page.markdown);
        try pending_pages.append(allocator, page.index);
        pending_tokens += page_tokens;
    }

    if (pending_pages.items.len > 0) {
        try emitPending(env, chunk_id, &pending_pages, &pending_md, pending_tokens, .page_boundary);
        chunk_id += 1;
    }

    return chunk_id;
}

fn emitPending(
    env: *stream.Envelope,
    chunk_id: u32,
    pages: *std.ArrayList(u32),
    md: *std.ArrayList(u8),
    tokens: u32,
    breakpoint: stream.ChunkBreak,
) !void {
    try env.emitChunk(chunk_id, pages.items, md.items, tokens, breakpoint);
    pages.clearRetainingCapacity();
    md.clearRetainingCapacity();
}

/// A single page exceeds max_tokens. Cut it on the highest-priority break
/// available: section heading > paragraph (blank line) > sentence (`. ` or
/// `\n`) > hard byte cut as last resort.
fn splitGiantPage(
    page: Page,
    opts: Options,
    env: *stream.Envelope,
    start_chunk_id: u32,
) !u32 {
    var chunk_id = start_chunk_id;
    var rest = page.markdown;

    while (rest.len > 0) {
        const remaining_tokens = try opts.tokenizer.count(rest);
        if (remaining_tokens <= opts.max_tokens) {
            try env.emitChunk(chunk_id, &.{page.index}, rest, remaining_tokens, .page_boundary);
            chunk_id += 1;
            break;
        }

        // `maxBytesForTokens` returns the largest prefix whose heuristic
        // token count is ≤ max_tokens (exact, not estimated). The break
        // finder then trims the cut to the nearest preferred boundary
        // ≤ that budget — never above it.
        const budget_bytes = tokenizer.maxBytesForTokens(rest, opts.max_tokens);
        const cut = findBreakBefore(rest, budget_bytes);
        const slice = rest[0..cut.byte_offset];
        const slice_tokens = try opts.tokenizer.count(slice);
        std.debug.assert(slice_tokens <= opts.max_tokens);

        try env.emitChunk(chunk_id, &.{page.index}, slice, slice_tokens, cut.kind);
        chunk_id += 1;

        rest = std.mem.trimLeft(u8, rest[cut.byte_offset..], " \t\n\r");
    }

    return chunk_id;
}

const BreakPoint = struct {
    byte_offset: usize,
    kind: stream.ChunkBreak,
};

/// Find the highest-priority break ≤ `limit_bytes` in `text`. The returned
/// offset is always > 0 (a break at 0 makes no progress and would loop).
/// Falls back to `limit_bytes` itself if no preferred break is available.
fn findBreakBefore(text: []const u8, limit_bytes: usize) BreakPoint {
    const limit = @min(limit_bytes, text.len);
    if (limit == 0 or limit >= text.len) {
        return .{ .byte_offset = text.len, .kind = .page_boundary };
    }

    if (lastIndexOfHeading(text[0..limit])) |idx| {
        if (idx > 0) return .{ .byte_offset = idx, .kind = .section_heading };
    }
    if (std.mem.lastIndexOf(u8, text[0..limit], "\n\n")) |idx| {
        return .{ .byte_offset = idx + 2, .kind = .paragraph };
    }
    if (std.mem.lastIndexOf(u8, text[0..limit], ". ")) |idx| {
        return .{ .byte_offset = idx + 2, .kind = .sentence };
    }
    if (std.mem.lastIndexOfScalar(u8, text[0..limit], '\n')) |idx| {
        if (idx + 1 > 0) return .{ .byte_offset = idx + 1, .kind = .sentence };
    }
    return .{ .byte_offset = limit, .kind = .sentence };
}

/// Find the last position where a markdown heading line begins (`\n#` or
/// the very start of the buffer if it begins with `#`).
fn lastIndexOfHeading(text: []const u8) ?usize {
    var i: usize = text.len;
    while (i > 0) {
        i -= 1;
        if (text[i] != '#') continue;
        if (i == 0) return 0;
        if (text[i - 1] == '\n') return i;
    }
    return null;
}


// ---- tests ----

const uuid = @import("uuid.zig");
const FIXED_DOC_ID2: uuid.String = "01234567-89ab-7cde-8f01-23456789abcd".*;

test "two small pages pack into one chunk" {
    var buf: [4096]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    var env = stream.Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID2);

    const pages = [_]Page{
        .{ .index = 0, .markdown = "alpha beta gamma" },
        .{ .index = 1, .markdown = "delta epsilon zeta" },
    };
    const opts = Options{
        .max_tokens = 1000,
        .tokenizer = tokenizer.Tokenizer.init(.heuristic),
    };
    const n = try chunkPages(std.testing.allocator, &pages, opts, &env);
    try std.testing.expectEqual(@as(u32, 1), n);
    try std.testing.expect(std.mem.indexOf(u8, aw.buffered(), "\"pages\":[0,1]") != null);
}

test "three pages split into multiple chunks at page boundaries" {
    var buf: [8192]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    var env = stream.Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID2);

    // Each page ~16 bytes / 4 bytes/token ≈ 4 tokens; max_tokens = 5 forces
    // one page per chunk.
    const pages = [_]Page{
        .{ .index = 0, .markdown = "aaaa bbbb cccc d" },
        .{ .index = 1, .markdown = "eeee ffff gggg h" },
        .{ .index = 2, .markdown = "iiii jjjj kkkk l" },
    };
    const opts = Options{
        .max_tokens = 5,
        .tokenizer = tokenizer.Tokenizer.init(.heuristic),
    };
    const n = try chunkPages(std.testing.allocator, &pages, opts, &env);
    try std.testing.expectEqual(@as(u32, 3), n);
}

test "giant page is split on heading preference" {
    var buf: [8192]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    var env = stream.Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID2);

    const md =
        "intro paragraph one. sentence two. sentence three.\n" ++
        "\n# Section A\n\n" ++
        "lorem ipsum dolor sit amet, consectetur adipiscing elit. " ++
        "sed do eiusmod tempor incididunt ut labore et dolore magna.\n" ++
        "\n# Section B\n\n" ++
        "ut enim ad minim veniam, quis nostrud exercitation ullamco.";
    const pages = [_]Page{.{ .index = 7, .markdown = md }};
    const opts = Options{
        .max_tokens = 30,
        .tokenizer = tokenizer.Tokenizer.init(.heuristic),
    };
    const n = try chunkPages(std.testing.allocator, &pages, opts, &env);
    try std.testing.expect(n >= 2);
    // At least one chunk must report a section_heading break.
    try std.testing.expect(std.mem.indexOf(u8, aw.buffered(), "\"break\":\"section_heading\"") != null);
}

test "chunk respects max_tokens contract on CJK-heavy pages" {
    // 200 CJK chars (600 bytes UTF-8) — heuristicCount ≈ 200 tokens.
    var rep: [600]u8 = undefined;
    var i: usize = 0;
    while (i + 3 <= rep.len) : (i += 3) {
        rep[i] = 0xe4; rep[i + 1] = 0xbd; rep[i + 2] = 0xa0; // 你
    }
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    var env = stream.Envelope.initWithId(&aw.writer, "fuzz.pdf", FIXED_DOC_ID2);
    const t = tokenizer.Tokenizer.init(.heuristic);
    const pages = [_]Page{.{ .index = 1, .markdown = &rep }};
    const max: u32 = 50;
    const n = try chunkPages(std.testing.allocator, &pages, .{
        .max_tokens = max,
        .tokenizer = t,
    }, &env);
    try std.testing.expect(n >= 4); // 200 tokens / 50 budget => ≥4 chunks
    // Every emitted chunk's tokens_est must be ≤ max_tokens.
    var pos: usize = 0;
    var seen: usize = 0;
    while (std.mem.indexOfPos(u8, aw.written(), pos, "\"tokens_est\":")) |idx| {
        const tail = aw.written()[idx + "\"tokens_est\":".len ..];
        const end = std.mem.indexOfAnyPos(u8, tail, 0, ",}").?;
        const v = try std.fmt.parseInt(u32, tail[0..end], 10);
        try std.testing.expect(v <= max);
        seen += 1;
        pos = idx + 1;
    }
    try std.testing.expect(seen >= 4);
}

test "max_tokens = 0 is rejected" {
    var buf: [256]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    var env = stream.Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID2);
    const pages = [_]Page{.{ .index = 0, .markdown = "anything" }};
    try std.testing.expectError(error.InvalidMaxTokens, chunkPages(
        std.testing.allocator,
        &pages,
        .{ .max_tokens = 0, .tokenizer = tokenizer.Tokenizer.init(.heuristic) },
        &env,
    ));
}

test "empty page list emits zero chunks" {
    var buf: [256]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    var env = stream.Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID2);
    const n = try chunkPages(std.testing.allocator, &.{}, .{
        .max_tokens = 100,
        .tokenizer = tokenizer.Tokenizer.init(.heuristic),
    }, &env);
    try std.testing.expectEqual(@as(u32, 0), n);
    try std.testing.expectEqual(@as(usize, 0), aw.buffered().len);
}
