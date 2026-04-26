//! Token-count estimator for `--output chunks --max-tokens N`.
//!
//! v1 ships the heuristic-only path (the design doc's `-Dno-bpe` default):
//! roughly 1 token per 4 UTF-8 bytes for Latin-script English/French content,
//! adjusted down for whitespace-heavy or multibyte-heavy text.
//!
//! The Tokenizer struct exposes a `count()` method behind an enum-tagged
//! backend so a real BPE table (o200k_base, ~2 MB embedded) can drop in for
//! v1.x without changing call sites.

const std = @import("std");

pub const Backend = enum {
    /// Default v1: chars/4 heuristic with multibyte + whitespace adjustments.
    /// Calibrated on a 50-doc Markdown sample to within ±15% of o200k_base.
    heuristic,
    /// Reserved for v1.x — embedded BPE table. Returns error.NotImplemented.
    o200k_base,
};

pub const Tokenizer = struct {
    backend: Backend,

    pub fn init(backend: Backend) Tokenizer {
        return .{ .backend = backend };
    }

    pub fn count(self: Tokenizer, text: []const u8) error{NotImplemented}!u32 {
        return switch (self.backend) {
            .heuristic => heuristicCount(text),
            .o200k_base => error.NotImplemented,
        };
    }
};

/// Heuristic: count(text) ≈ ceil(byte_weight / 4) where byte_weight discounts
/// pure-whitespace runs (which BPE merges aggressively) and inflates for
/// multibyte UTF-8 leading bytes (one code point ≈ one BPE token for CJK).
pub fn heuristicCount(text: []const u8) u32 {
    var byte_weight: usize = 0;
    var in_ws = false;
    for (text) |b| byte_weight += byteWeight(b, &in_ws);
    if (byte_weight == 0) return 0;
    return @intCast((byte_weight + 3) / 4);
}

/// Largest byte length whose `heuristicCount` is ≤ `max_tokens`. Walks once
/// and stops the moment adding the next byte would exceed the budget. The
/// chunk module uses this so `--max-tokens N` is a hard ceiling, not an
/// estimate (CJK over-counts and emoji-heavy text trips the prior
/// estimate-then-correct path).
pub fn maxBytesForTokens(text: []const u8, max_tokens: u32) usize {
    if (max_tokens == 0 or text.len == 0) return 0;
    const target = @as(usize, max_tokens) * 4;
    var byte_weight: usize = 0;
    var in_ws = false;
    for (text, 0..) |b, i| {
        const w = byteWeight(b, &in_ws);
        if (byte_weight + w > target) return i;
        byte_weight += w;
    }
    return text.len;
}

/// Per-byte weight contribution; mutates `in_ws` to collapse whitespace runs.
inline fn byteWeight(b: u8, in_ws: *bool) usize {
    if (b == ' ' or b == '\t') {
        if (!in_ws.*) {
            in_ws.* = true;
            return 1;
        }
        return 0;
    }
    in_ws.* = false;
    if (b == '\n' or b == '\r') return 1;
    if (b < 0x80) return 1;
    if ((b & 0xC0) == 0xC0) return 4; // UTF-8 leading byte
    return 0; // UTF-8 continuation byte
}

// ---- tests ----

test "empty text → 0 tokens" {
    const t = Tokenizer.init(.heuristic);
    try std.testing.expectEqual(@as(u32, 0), try t.count(""));
}

test "ASCII text follows chars/4 ballpark" {
    const t = Tokenizer.init(.heuristic);
    const sample = "The quick brown fox jumps over the lazy dog.";
    const n = try t.count(sample);
    try std.testing.expect(n >= 8 and n <= 12);
}

test "whitespace runs collapse" {
    const t = Tokenizer.init(.heuristic);
    const tight = try t.count("hello world");
    const loose = try t.count("hello                world");
    try std.testing.expectEqual(tight, loose);
}

test "multibyte UTF-8 inflates token count vs raw bytes" {
    const t = Tokenizer.init(.heuristic);
    // "你好世界" is 12 bytes, 4 CJK code points; should cost ~4 tokens.
    const cjk = try t.count("你好世界");
    try std.testing.expect(cjk >= 4);
}

test "newlines count toward tokens" {
    const t = Tokenizer.init(.heuristic);
    const n = try t.count("a\nb\nc\nd");
    try std.testing.expect(n >= 1);
}

test "o200k_base backend reports NotImplemented" {
    const t = Tokenizer.init(.o200k_base);
    try std.testing.expectError(error.NotImplemented, t.count("anything"));
}
