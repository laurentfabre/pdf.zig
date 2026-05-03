//! Unicode Bidirectional Algorithm (UAX #9), Level 1 — no explicit
//! embeddings, no isolates, no overrides. Implements the resolution +
//! reordering pipeline needed to produce display-order text from PDF
//! logical-order glyph runs that mix RTL (Arabic, Hebrew) and LTR
//! (Latin, digits) characters.
//!
//! Scope (Stage 1):
//!   - Bidi class lookup for ASCII + key controls + Hebrew/Arabic ranges.
//!     Code points outside the explicitly-tabulated ranges fall back to
//!     `L` (left-to-right) — safe default for Latin-heavy PDFs.
//!   - Paragraph-level resolution per rules P1–P3 (first strong
//!     character).
//!   - Weak-type rules W1–W7 (NSM, EN/ET/AN/CS adjustments).
//!   - Neutral-type rules N0 (paired brackets — not implemented;
//!     deferred), N1, N2.
//!   - Implicit-level rules I1, I2.
//!   - L1 reset of trailing whitespace levels.
//!   - L2 reverse of contiguous-same-level runs (the reorder pass).
//!
//! Out of scope (Stage 2 follow-up):
//!   - X1–X10 explicit embeddings, isolates, overrides (Level 2/3).
//!   - N0 paired-bracket pair resolution (rare in extracted PDF text).
//!   - L3 combining mark display reorder, L4 mirroring.
//!   - BidiTest.txt and BidiCharacterTest.txt full conformance —
//!     requires vendoring the Unicode test suite (license-permissive
//!     but a judgment call on subset size; see PR-16 questions).
//!
//! Reference: <https://www.unicode.org/reports/tr9/tr9-48.html>

const std = @import("std");

/// Bidi character classes per UAX #9 §3.2. Only the classes needed for
/// Level 1 are represented; embeddings/isolates/overrides are absent.
pub const BidiClass = enum(u8) {
    // Strong
    L, // Left-to-Right
    R, // Right-to-Left
    AL, // Arabic Letter

    // Weak
    EN, // European Number
    ES, // European Separator
    ET, // European Terminator
    AN, // Arabic Number
    CS, // Common Separator
    NSM, // Nonspacing Mark
    BN, // Boundary Neutral

    // Neutral
    B, // Paragraph Separator
    S, // Segment Separator
    WS, // Whitespace
    ON, // Other Neutral
};

/// Look up the bidi class for a single Unicode scalar.
///
/// Compact table — covers ASCII, the Hebrew (U+0590–05FF), Arabic
/// (U+0600–06FF, U+0750–077F, U+08A0–08FF), Arabic Presentation Forms-A
/// (U+FB50–FDFF), Arabic Presentation Forms-B (U+FE70–FEFF), and the
/// handful of strong / weak controls and separators that can appear in
/// extracted PDF text (BOM, LRM/RLM, CR/LF, NBSP, common punctuation).
///
/// Code points outside these ranges default to `L`. This is correct for
/// Latin / CJK / symbol scripts (CJK is technically `L` in UAX #9
/// terms — its glyphs render LTR even though writing direction can be
/// vertical, which the algorithm doesn't model).
pub fn classify(cp: u21) BidiClass {
    // ASCII fast path
    if (cp < 0x80) return classifyAscii(@intCast(cp));

    // Latin-1 supplement & common controls
    switch (cp) {
        0x00A0 => return .CS, // NBSP — UAX #9 lists CS, not WS
        0x00AB, 0x00BB => return .ON, // « »
        0x00B0, 0x00B1 => return .ET, // ° ±
        0x00B2, 0x00B3, 0x00B9 => return .EN, // superscript digits
        else => {},
    }

    // Bidi controls (LRM/RLM/ALM only — embeddings deliberately treated
    // as their fallback class for Level 1)
    switch (cp) {
        0x200E => return .L, // LRM
        0x200F => return .R, // RLM
        0x061C => return .AL, // ALM (Arabic Letter Mark — strong AL)
        0x202A...0x202E, 0x2066...0x2069 => return .ON, // embeddings/isolates -> opaque neutral in L1
        0xFEFF => return .BN, // BOM
        else => {},
    }

    // Hebrew block (U+0590–05FF)
    if (cp >= 0x0590 and cp <= 0x05FF) {
        // Marks (cantillation, points)
        if ((cp >= 0x0591 and cp <= 0x05BD) or
            cp == 0x05BF or
            (cp >= 0x05C1 and cp <= 0x05C2) or
            (cp >= 0x05C4 and cp <= 0x05C5) or
            cp == 0x05C7) return .NSM;
        // Letters and punctuation are R
        return .R;
    }

    // Arabic block (U+0600–06FF)
    if (cp >= 0x0600 and cp <= 0x06FF) {
        // European-style digits used inside Arabic context — kept as EN
        // so W2 promotes them to AN appropriately.
        // Arabic-Indic digits U+0660–0669 → AN
        if (cp >= 0x0660 and cp <= 0x0669) return .AN;
        // Extended Arabic-Indic digits U+06F0–06F9 → EN (per UCD)
        if (cp >= 0x06F0 and cp <= 0x06F9) return .EN;
        // Tatweel and connectors
        if (cp == 0x0640) return .AL;
        // Arabic punctuation marks: comma U+060C, semicolon U+061B,
        // question mark U+061F → CS / AL per UCD
        if (cp == 0x060C) return .CS;
        if (cp == 0x061B or cp == 0x061F) return .AL;
        // Combining marks (harakat, etc.)
        if ((cp >= 0x0610 and cp <= 0x061A) or
            (cp >= 0x064B and cp <= 0x065F) or
            cp == 0x0670 or
            (cp >= 0x06D6 and cp <= 0x06DC) or
            (cp >= 0x06DF and cp <= 0x06E4) or
            (cp >= 0x06E7 and cp <= 0x06E8) or
            (cp >= 0x06EA and cp <= 0x06ED)) return .NSM;
        // Currency-like ETs
        if (cp == 0x066A) return .ET; // %
        if (cp >= 0x066B and cp <= 0x066C) return .AN; // Arabic decimal/thousands sep
        // All remaining Arabic-block code points are AL
        return .AL;
    }

    // Syriac / N'Ko / Samaritan / Mandaic / Arabic Extended-A
    // — collapsed to AL/R for Stage 1 (hard fallback; fine for the
    // Hebrew + Arabic acceptance fixtures).
    if (cp >= 0x0700 and cp <= 0x08FF) return .AL;

    // Arabic Presentation Forms-A (U+FB50–FDFF)
    if (cp >= 0xFB50 and cp <= 0xFDFF) return .AL;

    // Hebrew Presentation Forms (U+FB1D–FB4F)
    if (cp >= 0xFB1D and cp <= 0xFB4F) {
        if (cp == 0xFB1E) return .NSM;
        return .R;
    }

    // Arabic Presentation Forms-B (U+FE70–FEFF)
    if (cp >= 0xFE70 and cp <= 0xFEFF) return .AL;

    // Default: L (covers Latin Extended, CJK, etc.)
    return .L;
}

fn classifyAscii(b: u8) BidiClass {
    return switch (b) {
        '0'...'9' => .EN,
        'A'...'Z', 'a'...'z' => .L,
        '\t' => .S,
        '\n', 0x0B, 0x0C, '\r', 0x1C, 0x1D, 0x1E => .B,
        0x1F => .S,
        ' ' => .WS,
        '+', '-' => .ES,
        '#', '$', '%', '^', '&', '*' => .ET,
        ',', '.', '/', ':' => .CS,
        else => .ON,
    };
}

/// True if any code point in the UTF-8 string carries a strong RTL
/// class (R / AL). Cheap pre-pass — extraction code can skip the full
/// bidi pipeline when this returns false.
pub fn containsRtl(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            continue;
        };
        if (i + seq_len > text.len) break;
        const cp = std.unicode.utf8Decode(text[i .. i + seq_len]) catch {
            i += seq_len;
            continue;
        };
        const cls = classify(cp);
        if (cls == .R or cls == .AL) return true;
        i += seq_len;
    }
    return false;
}

/// Per-character bidi state — one entry per Unicode scalar of the input
/// paragraph. `level` is the resolved embedding level; `class` is the
/// (mutable) bidi class as it is rewritten by W/N/I rules.
const CharState = struct {
    cp: u21,
    /// Original UTF-8 byte offset in the source slice (start of the
    /// scalar). Used to copy bytes back during reorder.
    byte_off: u32,
    byte_len: u8,
    class: BidiClass,
    level: u8,
};

/// Determine the paragraph embedding level per UAX #9 P2/P3.
///
/// Returns 0 for LTR paragraphs, 1 for RTL paragraphs. The override
/// `forced` short-circuits this — useful when the caller already knows
/// the paragraph direction (e.g., from an RTL marker).
fn resolveParagraphLevel(states: []const CharState, forced: ?u8) u8 {
    if (forced) |f| return f;
    for (states) |s| {
        switch (s.class) {
            .L => return 0,
            .R, .AL => return 1,
            else => {},
        }
    }
    return 0;
}

/// Assign per-character embedding levels for Level-1 input (no
/// explicit embeddings → level alternates between paragraph_level and
/// paragraph_level XOR 1 only via implicit rules).
///
/// Pre-W: every character starts at the paragraph level.
fn initLevels(states: []CharState, paragraph_level: u8) void {
    for (states) |*s| s.level = paragraph_level;
}

/// W1: NSM gets the class of the preceding character. NSM at the start
/// of a level run takes the run's "sor" — which in Level-1 reduces to
/// the paragraph direction's strong class (L or R).
fn applyW1(states: []CharState, paragraph_level: u8) void {
    const sor: BidiClass = if (paragraph_level == 0) .L else .R;
    var prev = sor;
    for (states) |*s| {
        if (s.class == .NSM) {
            s.class = prev;
        } else {
            prev = s.class;
        }
    }
}

/// W2: EN preceded by AL (with intervening ETs/ES/CS allowed by the
/// rule's "preceded by" semantics) → AN.
fn applyW2(states: []CharState, paragraph_level: u8) void {
    const sor: BidiClass = if (paragraph_level == 0) .L else .R;
    for (states, 0..) |*s, i| {
        if (s.class != .EN) continue;
        // Walk back to the previous strong type, skipping weak types.
        var prev_strong = sor;
        var j: usize = i;
        while (j > 0) {
            j -= 1;
            switch (states[j].class) {
                .L, .R, .AL => {
                    prev_strong = states[j].class;
                    break;
                },
                else => {},
            }
        }
        if (prev_strong == .AL) s.class = .AN;
    }
}

/// W3: AL → R (strong-RTL letter is folded into generic R for
/// downstream rules).
fn applyW3(states: []CharState) void {
    for (states) |*s| {
        if (s.class == .AL) s.class = .R;
    }
}

/// W4: A single ES between two ENs → EN. A single CS between two ENs →
/// EN. A single CS between two ANs → AN.
fn applyW4(states: []CharState) void {
    if (states.len < 3) return;
    var i: usize = 1;
    while (i + 1 < states.len) : (i += 1) {
        const c = states[i].class;
        const prev = states[i - 1].class;
        const next = states[i + 1].class;
        if (c == .ES and prev == .EN and next == .EN) {
            states[i].class = .EN;
        } else if (c == .CS) {
            if (prev == .EN and next == .EN) states[i].class = .EN;
            if (prev == .AN and next == .AN) states[i].class = .AN;
        }
    }
}

/// W5: A sequence of ETs adjacent to (touching, possibly via more ETs)
/// an EN → all become EN.
fn applyW5(states: []CharState) void {
    // Forward pass: ET runs followed by EN
    var i: usize = 0;
    while (i < states.len) : (i += 1) {
        if (states[i].class != .ET) continue;
        // find end of ET run
        var j = i;
        while (j < states.len and states[j].class == .ET) : (j += 1) {}
        const after: ?BidiClass = if (j < states.len) states[j].class else null;
        const before: ?BidiClass = if (i > 0) states[i - 1].class else null;
        const adj_en = (after == .EN) or (before == .EN);
        if (adj_en) {
            for (states[i..j]) |*s| s.class = .EN;
        }
        i = j - 1;
    }
}

/// W6: Otherwise, leftover ES, ET, CS → ON.
fn applyW6(states: []CharState) void {
    for (states) |*s| {
        switch (s.class) {
            .ES, .ET, .CS => s.class = .ON,
            else => {},
        }
    }
}

/// W7: EN preceded by L (looking back through weak types) → L.
fn applyW7(states: []CharState, paragraph_level: u8) void {
    const sor: BidiClass = if (paragraph_level == 0) .L else .R;
    for (states, 0..) |*s, i| {
        if (s.class != .EN) continue;
        var prev_strong = sor;
        var j: usize = i;
        while (j > 0) {
            j -= 1;
            switch (states[j].class) {
                .L, .R => {
                    prev_strong = states[j].class;
                    break;
                },
                else => {},
            }
        }
        if (prev_strong == .L) s.class = .L;
    }
}

/// N1 + N2: Resolve neutrals. A run of neutrals takes the direction of
/// surrounding strong types if both sides agree (N1); otherwise it
/// takes the embedding direction (N2).
fn applyN1N2(states: []CharState, paragraph_level: u8) void {
    if (states.len == 0) return;

    const sor: BidiClass = if (paragraph_level == 0) .L else .R;
    const eor: BidiClass = sor;

    var i: usize = 0;
    while (i < states.len) {
        if (!isNeutralForN(states[i].class)) {
            i += 1;
            continue;
        }
        // find run of neutrals
        var j = i;
        while (j < states.len and isNeutralForN(states[j].class)) : (j += 1) {}

        // Determine left-strong (treat EN/AN as R for N1 per UAX #9)
        const left: BidiClass = if (i == 0) sor else strongFor(states[i - 1].class);
        const right: BidiClass = if (j == states.len) eor else strongFor(states[j].class);

        const target: BidiClass = if (left == right) left else (if (paragraph_level == 0) .L else .R);

        for (states[i..j]) |*s| s.class = target;
        i = j;
    }
}

fn isNeutralForN(c: BidiClass) bool {
    return switch (c) {
        .B, .S, .WS, .ON => true,
        else => false,
    };
}

/// "Strong" mapping for N1: EN and AN count as R when bracketing
/// neutral runs.
fn strongFor(c: BidiClass) BidiClass {
    return switch (c) {
        .L => .L,
        .R, .EN, .AN => .R,
        else => .ON,
    };
}

/// I1 + I2: Apply implicit embedding levels.
///   At an even level (LTR base): R += 1, AN/EN += 2.
///   At an odd level (RTL base):  L  += 1, EN/AN += 1.
fn applyI1I2(states: []CharState) void {
    for (states) |*s| {
        const even = (s.level & 1) == 0;
        if (even) {
            switch (s.class) {
                .R => s.level += 1,
                .AN, .EN => s.level += 2,
                else => {},
            }
        } else {
            switch (s.class) {
                .L => s.level += 1,
                .EN, .AN => s.level += 1,
                else => {},
            }
        }
    }
}

/// L1: Trailing whitespace and segment/paragraph separators reset to
/// the paragraph level.
fn applyL1(states: []CharState, paragraph_level: u8) void {
    // Reset trailing whitespace at end of paragraph.
    var i: usize = states.len;
    while (i > 0) {
        i -= 1;
        switch (states[i].class) {
            .B, .S => {
                states[i].level = paragraph_level;
            },
            .WS => states[i].level = paragraph_level,
            else => break,
        }
    }
    // Also reset whitespace immediately preceding a B/S.
    i = 0;
    while (i < states.len) : (i += 1) {
        const c = states[i].class;
        if (c == .B or c == .S) {
            states[i].level = paragraph_level;
            var j: usize = i;
            while (j > 0) {
                j -= 1;
                if (states[j].class != .WS) break;
                states[j].level = paragraph_level;
            }
        }
    }
}

/// L2: Reverse contiguous level runs from the highest level down to
/// `lowest_odd_level`. The result is the visual order.
///
/// Output: a permutation `out_order[i]` = source index that should
/// appear at visual position `i`.
fn applyL2(states: []const CharState, allocator: std.mem.Allocator) ![]usize {
    var order = try allocator.alloc(usize, states.len);
    for (order, 0..) |*o, idx| o.* = idx;

    if (states.len == 0) return order;

    // Find max level and lowest odd level.
    var max_level: u8 = 0;
    var lowest_odd_level: u8 = 0xFF;
    for (states) |s| {
        if (s.level > max_level) max_level = s.level;
        if ((s.level & 1) == 1 and s.level < lowest_odd_level) lowest_odd_level = s.level;
    }
    if (lowest_odd_level == 0xFF) return order; // no RTL runs at all

    // From highest level down to lowest_odd_level, reverse contiguous
    // runs at or above the current threshold.
    var level: u8 = max_level;
    while (level >= lowest_odd_level) : (level -= 1) {
        var i: usize = 0;
        while (i < states.len) {
            if (states[order[i]].level < level) {
                i += 1;
                continue;
            }
            var j = i;
            while (j < states.len and states[order[j]].level >= level) : (j += 1) {}
            std.mem.reverse(usize, order[i..j]);
            i = j;
        }
        if (level == 0) break;
    }

    return order;
}

/// Take a UTF-8 buffer that may contain multiple `\n`-separated
/// paragraphs, run each line through `process()` in turn, and return
/// the concatenated result. Lines without any strong-RTL character are
/// passed through byte-for-byte (cheap `containsRtl` pre-pass).
///
/// `\n` separators are preserved in the output. The final byte is also
/// preserved exactly: input ending in `\n` produces output ending in
/// `\n`; input not so ending does not.
///
/// Allocator-owned result.
pub fn processLines(
    allocator: std.mem.Allocator,
    text: []const u8,
) ![]u8 {
    if (!containsRtl(text)) {
        return allocator.dupe(u8, text);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, text.len);

    var start: usize = 0;
    while (start < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        const line = text[start..nl];
        if (containsRtl(line)) {
            const reordered = try process(allocator, line, null);
            defer allocator.free(reordered);
            try out.appendSlice(allocator, reordered);
        } else {
            try out.appendSlice(allocator, line);
        }
        if (nl < text.len) {
            try out.append(allocator, '\n');
            start = nl + 1;
        } else {
            start = text.len;
        }
    }

    return out.toOwnedSlice(allocator);
}

/// Public entry point: take a UTF-8 logical-order paragraph and return
/// an allocated UTF-8 visual-order paragraph.
///
/// Arguments:
///   - `allocator`: result and temporaries are allocated here.
///   - `text`: input UTF-8 (logical order). Must be a single paragraph
///     (no embedded U+2029); the algorithm does not split paragraphs.
///   - `forced_paragraph_level`: optional override for P3 — pass `null`
///     to auto-detect via P2 (first strong character).
///
/// Returns: caller-owned UTF-8 slice in display order. If `text` has
/// no RTL characters the output is a byte-for-byte copy (still
/// allocator-owned for caller-side uniform free()).
pub fn process(
    allocator: std.mem.Allocator,
    text: []const u8,
    forced_paragraph_level: ?u8,
) ![]u8 {
    // Build the per-character state array.
    var states: std.ArrayList(CharState) = .empty;
    defer states.deinit(allocator);
    try states.ensureTotalCapacity(allocator, text.len);

    var i: usize = 0;
    while (i < text.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            // Invalid UTF-8 leading byte — emit as opaque ON
            try states.append(allocator, .{
                .cp = text[i],
                .byte_off = @intCast(i),
                .byte_len = 1,
                .class = .ON,
                .level = 0,
            });
            i += 1;
            continue;
        };
        if (i + seq_len > text.len) break;
        const cp = std.unicode.utf8Decode(text[i .. i + seq_len]) catch {
            try states.append(allocator, .{
                .cp = text[i],
                .byte_off = @intCast(i),
                .byte_len = 1,
                .class = .ON,
                .level = 0,
            });
            i += 1;
            continue;
        };
        try states.append(allocator, .{
            .cp = cp,
            .byte_off = @intCast(i),
            .byte_len = @intCast(seq_len),
            .class = classify(cp),
            .level = 0,
        });
        i += seq_len;
    }

    const slice = states.items;
    const paragraph_level = resolveParagraphLevel(slice, forced_paragraph_level);
    initLevels(slice, paragraph_level);

    // Weak rules
    applyW1(slice, paragraph_level);
    applyW2(slice, paragraph_level);
    applyW3(slice);
    applyW4(slice);
    applyW5(slice);
    applyW6(slice);
    applyW7(slice, paragraph_level);

    // Neutral rules
    applyN1N2(slice, paragraph_level);

    // Implicit levels
    applyI1I2(slice);

    // L1 reset
    applyL1(slice, paragraph_level);

    // L2 reorder — produces a permutation
    const order = try applyL2(slice, allocator);
    defer allocator.free(order);

    // Reassemble the output in visual order. NSM characters that follow
    // an RTL letter would need L3 to render correctly with combining-
    // -mark order preserved; that is deferred to Stage 2.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, text.len);

    for (order) |src_idx| {
        const s = slice[src_idx];
        try out.appendSlice(allocator, text[s.byte_off .. s.byte_off + s.byte_len]);
    }

    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "classify ASCII basics" {
    try std.testing.expectEqual(BidiClass.L, classify('A'));
    try std.testing.expectEqual(BidiClass.L, classify('z'));
    try std.testing.expectEqual(BidiClass.EN, classify('5'));
    try std.testing.expectEqual(BidiClass.WS, classify(' '));
    try std.testing.expectEqual(BidiClass.B, classify('\n'));
    try std.testing.expectEqual(BidiClass.CS, classify(','));
    try std.testing.expectEqual(BidiClass.CS, classify(':'));
    try std.testing.expectEqual(BidiClass.ES, classify('+'));
}

test "classify Hebrew letters as R" {
    // Aleph U+05D0
    try std.testing.expectEqual(BidiClass.R, classify(0x05D0));
    // Tav U+05EA
    try std.testing.expectEqual(BidiClass.R, classify(0x05EA));
    // Hebrew point patah U+05B7 → NSM
    try std.testing.expectEqual(BidiClass.NSM, classify(0x05B7));
}

test "classify Arabic letters as AL" {
    // Alef U+0627
    try std.testing.expectEqual(BidiClass.AL, classify(0x0627));
    // Yeh U+064A
    try std.testing.expectEqual(BidiClass.AL, classify(0x064A));
    // Fatha U+064E → NSM
    try std.testing.expectEqual(BidiClass.NSM, classify(0x064E));
    // Arabic-Indic 0 → AN
    try std.testing.expectEqual(BidiClass.AN, classify(0x0660));
    // Arabic-Indic 9 → AN
    try std.testing.expectEqual(BidiClass.AN, classify(0x0669));
    // Extended Arabic-Indic 0 → EN
    try std.testing.expectEqual(BidiClass.EN, classify(0x06F0));
}

test "containsRtl: pure ASCII → false" {
    try std.testing.expect(!containsRtl("Hello, world!"));
    try std.testing.expect(!containsRtl(""));
    try std.testing.expect(!containsRtl("12345"));
}

test "containsRtl: Hebrew → true" {
    // "שלום" (shalom) U+05E9 U+05DC U+05D5 U+05DD
    try std.testing.expect(containsRtl("\u{05E9}\u{05DC}\u{05D5}\u{05DD}"));
}

test "containsRtl: Arabic → true" {
    // "سلام" (salam) U+0633 U+0644 U+0627 U+0645
    try std.testing.expect(containsRtl("\u{0633}\u{0644}\u{0627}\u{0645}"));
}

test "process: pure LTR is byte-identical" {
    const allocator = std.testing.allocator;
    const out = try process(allocator, "Hello, world!", null);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("Hello, world!", out);
}

test "process: empty string" {
    const allocator = std.testing.allocator;
    const out = try process(allocator, "", null);
    defer allocator.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "process: Hebrew word reversed" {
    const allocator = std.testing.allocator;
    // Logical: ש ל ו ם   →   Visual: ם ו ל ש
    const logical = "\u{05E9}\u{05DC}\u{05D5}\u{05DD}";
    const expected_visual = "\u{05DD}\u{05D5}\u{05DC}\u{05E9}";
    const out = try process(allocator, logical, null);
    defer allocator.free(out);
    try std.testing.expectEqualStrings(expected_visual, out);
}

test "process: Arabic word reversed" {
    const allocator = std.testing.allocator;
    // Logical: س ل ا م   →   Visual: م ا ل س
    const logical = "\u{0633}\u{0644}\u{0627}\u{0645}";
    const expected_visual = "\u{0645}\u{0627}\u{0644}\u{0633}";
    const out = try process(allocator, logical, null);
    defer allocator.free(out);
    try std.testing.expectEqualStrings(expected_visual, out);
}

test "process: LTR sentence with embedded Hebrew word" {
    const allocator = std.testing.allocator;
    // Logical (UAX #9 sample): "he said "<HE><BR><EW>" to me."
    // Using two-letter Hebrew word: <אב> = U+05D0 U+05D1
    // Logical bytes: "x " <05D0> <05D1> " y"
    // Paragraph is LTR (first strong is 'x'). The Hebrew run reverses
    // in place: visual is "x " <05D1> <05D0> " y".
    const logical = "x \u{05D0}\u{05D1} y";
    const expected = "x \u{05D1}\u{05D0} y";
    const out = try process(allocator, logical, null);
    defer allocator.free(out);
    try std.testing.expectEqualStrings(expected, out);
}

test "process: RTL paragraph with embedded LTR word" {
    const allocator = std.testing.allocator;
    // Logical: <05D0><05D1> ABC <05D2><05D3>  (Hebrew word, Latin
    // word, Hebrew word — paragraph base RTL, first strong is Hebrew).
    // Visual order should be: <05D3><05D2> ABC <05D1><05D0>
    // (Latin "ABC" stays LTR, but the surrounding RTL runs reverse,
    // and the whole paragraph displays right-to-left so the Latin
    // word sits in the middle with its letters preserved.)
    const logical = "\u{05D0}\u{05D1} ABC \u{05D2}\u{05D3}";
    const expected = "\u{05D3}\u{05D2} ABC \u{05D1}\u{05D0}";
    const out = try process(allocator, logical, null);
    defer allocator.free(out);
    try std.testing.expectEqualStrings(expected, out);
}

test "process: Arabic with European digits stays LTR within RTL run" {
    const allocator = std.testing.allocator;
    // Logical: <0623><0628>123<062C> (Arabic letter, letter, "123",
    // letter). Per W2, EN preceded by AL → AN. Per I1 at even level,
    // AN += 2; AL → R += 1. So Arabic letters at level 1 (RTL),
    // digits at level 2 — which under L2 get reversed once by the
    // outer run and once by the inner run, ending up still in their
    // original logical order.
    //
    // Paragraph base detected from first strong (AL → R), so base
    // level = 1.
    const logical = "\u{0623}\u{0628}123\u{062C}";
    // Visual: <062C>123<0628><0623>  (digits keep their order,
    // surrounding letters reverse).
    const expected = "\u{062C}123\u{0628}\u{0623}";
    const out = try process(allocator, logical, null);
    defer allocator.free(out);
    try std.testing.expectEqualStrings(expected, out);
}

test "resolveParagraphLevel: first strong wins" {
    const states_ltr = [_]CharState{
        .{ .cp = ' ', .byte_off = 0, .byte_len = 1, .class = .WS, .level = 0 },
        .{ .cp = 'A', .byte_off = 1, .byte_len = 1, .class = .L, .level = 0 },
        .{ .cp = 0x05D0, .byte_off = 2, .byte_len = 2, .class = .R, .level = 0 },
    };
    try std.testing.expectEqual(@as(u8, 0), resolveParagraphLevel(&states_ltr, null));

    const states_rtl = [_]CharState{
        .{ .cp = ' ', .byte_off = 0, .byte_len = 1, .class = .WS, .level = 0 },
        .{ .cp = 0x05D0, .byte_off = 1, .byte_len = 2, .class = .R, .level = 0 },
        .{ .cp = 'A', .byte_off = 3, .byte_len = 1, .class = .L, .level = 0 },
    };
    try std.testing.expectEqual(@as(u8, 1), resolveParagraphLevel(&states_rtl, null));

    // No strong → default 0
    const states_none = [_]CharState{
        .{ .cp = ' ', .byte_off = 0, .byte_len = 1, .class = .WS, .level = 0 },
        .{ .cp = '5', .byte_off = 1, .byte_len = 1, .class = .EN, .level = 0 },
    };
    try std.testing.expectEqual(@as(u8, 0), resolveParagraphLevel(&states_none, null));

    // Forced level wins
    try std.testing.expectEqual(@as(u8, 1), resolveParagraphLevel(&states_ltr, 1));
}

test "process: invalid UTF-8 byte does not crash" {
    const allocator = std.testing.allocator;
    // 0xFF is invalid UTF-8 — should be treated as opaque ON.
    const input = [_]u8{ 'A', 0xFF, 'B' };
    const out = try process(allocator, &input, null);
    defer allocator.free(out);
    // Length preserved (algorithm is byte-conserving for ON neutrals).
    try std.testing.expectEqual(input.len, out.len);
}

test "process: digits adjacent to Hebrew preserved as LTR run" {
    const allocator = std.testing.allocator;
    // Logical: <05D0><05D1>42 (Hebrew word + European digits).
    // Paragraph base: RTL (first strong is Hebrew). Digits get level
    // 2 (W2 doesn't apply because previous strong is R, not AL; W7
    // doesn't apply for R). At level 2, "42" reverses once relative to
    // the surrounding level-1 RTL run, so visually digits keep their
    // logical order at the leftmost position: "42<05D1><05D0>".
    const logical = "\u{05D0}\u{05D1}42";
    const expected = "42\u{05D1}\u{05D0}";
    const out = try process(allocator, logical, null);
    defer allocator.free(out);
    try std.testing.expectEqualStrings(expected, out);
}

// ---------------------------------------------------------------------------
// Hand-curated UAX #9 spec coverage (W1–W7, N1–N2, I1–I2, L1–L2).
//
// The PR body documents the rationale: full BidiTest.txt conformance
// is out of scope; these cases are picked to exercise each rule's
// effect on representative input.
// ---------------------------------------------------------------------------

test "spec W1: NSM after Hebrew letter inherits R" {
    const allocator = std.testing.allocator;
    // <05D0> (R) + <05B7> (NSM, Hebrew patah). NSM should resolve to R
    // and reverse with the letter under L2.
    const logical = "\u{05D0}\u{05B7}";
    const expected = "\u{05B7}\u{05D0}";
    const out = try process(allocator, logical, null);
    defer allocator.free(out);
    try std.testing.expectEqualStrings(expected, out);
}

test "spec W1: NSM at sor takes paragraph direction" {
    const allocator = std.testing.allocator;
    // NSM as the first character of a paragraph — sor is L (default
    // base direction), so the NSM resolves to L and the output stays
    // logical-order.
    const logical = "\u{05B7}A";
    const out = try process(allocator, logical, null);
    defer allocator.free(out);
    try std.testing.expectEqualStrings(logical, out);
}

test "spec W2: EN preceded by AL → AN" {
    // Direct unit on the resolution table — feeding through process
    // would also implicitly verify W2, but locking the class transition
    // here keeps regressions on the rule itself loud.
    var states = [_]CharState{
        .{ .cp = 0x0623, .byte_off = 0, .byte_len = 2, .class = .AL, .level = 0 },
        .{ .cp = '5', .byte_off = 2, .byte_len = 1, .class = .EN, .level = 0 },
    };
    applyW2(&states, 1);
    try std.testing.expectEqual(BidiClass.AN, states[1].class);
}

test "spec W3: AL → R after weak resolution" {
    var states = [_]CharState{
        .{ .cp = 0x0627, .byte_off = 0, .byte_len = 2, .class = .AL, .level = 1 },
    };
    applyW3(&states);
    try std.testing.expectEqual(BidiClass.R, states[0].class);
}

test "spec W4: single CS between two ENs → EN" {
    // "1,2" → CS becomes EN.
    var states = [_]CharState{
        .{ .cp = '1', .byte_off = 0, .byte_len = 1, .class = .EN, .level = 0 },
        .{ .cp = ',', .byte_off = 1, .byte_len = 1, .class = .CS, .level = 0 },
        .{ .cp = '2', .byte_off = 2, .byte_len = 1, .class = .EN, .level = 0 },
    };
    applyW4(&states);
    try std.testing.expectEqual(BidiClass.EN, states[1].class);
}

test "spec W5: ETs adjacent to EN absorbed" {
    // "$ 9" — ET ($) preceding EN should become EN; whitespace stays.
    var states = [_]CharState{
        .{ .cp = '$', .byte_off = 0, .byte_len = 1, .class = .ET, .level = 0 },
        .{ .cp = '9', .byte_off = 1, .byte_len = 1, .class = .EN, .level = 0 },
    };
    applyW5(&states);
    try std.testing.expectEqual(BidiClass.EN, states[0].class);
}

test "spec W6: leftover ES/ET/CS → ON" {
    // ET not adjacent to EN should fall through to ON via W6.
    var states = [_]CharState{
        .{ .cp = '$', .byte_off = 0, .byte_len = 1, .class = .ET, .level = 0 },
        .{ .cp = 'A', .byte_off = 1, .byte_len = 1, .class = .L, .level = 0 },
    };
    applyW5(&states);
    applyW6(&states);
    try std.testing.expectEqual(BidiClass.ON, states[0].class);
}

test "spec W7: EN preceded by L → L" {
    // "A 5" — EN preceded by L (with WS in between) becomes L.
    var states = [_]CharState{
        .{ .cp = 'A', .byte_off = 0, .byte_len = 1, .class = .L, .level = 0 },
        .{ .cp = ' ', .byte_off = 1, .byte_len = 1, .class = .WS, .level = 0 },
        .{ .cp = '5', .byte_off = 2, .byte_len = 1, .class = .EN, .level = 0 },
    };
    applyW7(&states, 0);
    try std.testing.expectEqual(BidiClass.L, states[2].class);
}

test "spec N1: neutrals between two Rs adopt R" {
    // <05D0> ' ' <05D1> — WS between two Hebrew letters takes R per N1.
    var states = [_]CharState{
        .{ .cp = 0x05D0, .byte_off = 0, .byte_len = 2, .class = .R, .level = 1 },
        .{ .cp = ' ', .byte_off = 2, .byte_len = 1, .class = .WS, .level = 1 },
        .{ .cp = 0x05D1, .byte_off = 3, .byte_len = 2, .class = .R, .level = 1 },
    };
    applyN1N2(&states, 1);
    try std.testing.expectEqual(BidiClass.R, states[1].class);
}

test "spec N2: bracketing-mismatch neutrals take embedding direction" {
    // L ' ' R — strong types differ, paragraph_level=0 (LTR), so the
    // WS resolves to L per N2.
    var states = [_]CharState{
        .{ .cp = 'A', .byte_off = 0, .byte_len = 1, .class = .L, .level = 0 },
        .{ .cp = ' ', .byte_off = 1, .byte_len = 1, .class = .WS, .level = 0 },
        .{ .cp = 0x05D0, .byte_off = 2, .byte_len = 2, .class = .R, .level = 0 },
    };
    applyN1N2(&states, 0);
    try std.testing.expectEqual(BidiClass.L, states[1].class);
}

test "spec I1: at even level, R += 1, AN/EN += 2" {
    var states = [_]CharState{
        .{ .cp = 0x05D0, .byte_off = 0, .byte_len = 2, .class = .R, .level = 0 },
        .{ .cp = '5', .byte_off = 2, .byte_len = 1, .class = .EN, .level = 0 },
        .{ .cp = '5', .byte_off = 3, .byte_len = 1, .class = .AN, .level = 0 },
    };
    applyI1I2(&states);
    try std.testing.expectEqual(@as(u8, 1), states[0].level);
    try std.testing.expectEqual(@as(u8, 2), states[1].level);
    try std.testing.expectEqual(@as(u8, 2), states[2].level);
}

test "spec I2: at odd level, L/EN/AN += 1" {
    var states = [_]CharState{
        .{ .cp = 'A', .byte_off = 0, .byte_len = 1, .class = .L, .level = 1 },
        .{ .cp = '5', .byte_off = 1, .byte_len = 1, .class = .EN, .level = 1 },
        .{ .cp = '5', .byte_off = 2, .byte_len = 1, .class = .AN, .level = 1 },
    };
    applyI1I2(&states);
    try std.testing.expectEqual(@as(u8, 2), states[0].level);
    try std.testing.expectEqual(@as(u8, 2), states[1].level);
    try std.testing.expectEqual(@as(u8, 2), states[2].level);
}

test "spec L1: trailing whitespace resets to paragraph level" {
    const allocator = std.testing.allocator;
    // RTL paragraph with trailing space — the space should sit at the
    // visual right edge after L1+L2 (it's level-0 inside an otherwise
    // level-1 paragraph), but since the paragraph base is RTL the
    // visual order still places it at the visual *left* of the content
    // because L2 reverses level-≥1 runs. The logical order
    // "<05D0><05D1> " becomes visual " <05D1><05D0>".
    const logical = "\u{05D0}\u{05D1} ";
    const expected = " \u{05D1}\u{05D0}";
    const out = try process(allocator, logical, null);
    defer allocator.free(out);
    try std.testing.expectEqualStrings(expected, out);
}

test "spec L2: nested-level reversal of mixed RTL+LTR run" {
    const allocator = std.testing.allocator;
    // LTR base ("Hello "<05D0><05D1>"!") — the Hebrew run is the only
    // level-1 segment and reverses; "Hello " and "!" stay LTR.
    const logical = "Hello \u{05D0}\u{05D1}!";
    const expected = "Hello \u{05D1}\u{05D0}!";
    const out = try process(allocator, logical, null);
    defer allocator.free(out);
    try std.testing.expectEqualStrings(expected, out);
}

test "spec L1: paragraph separator resets" {
    // B characters are at paragraph level after L1 regardless of the
    // weak class evolution.
    const allocator = std.testing.allocator;
    const logical = "\u{05D0}\u{05D1}\n";
    const out = try process(allocator, logical, null);
    defer allocator.free(out);
    // Trailing '\n' is preserved in place at paragraph level (0 from
    // perspective of the L2 reversal — but here the paragraph_level is
    // 1 because first strong is Hebrew). The Hebrew letters reverse;
    // the '\n' (B) sits at level 1 (post-L1 reset to paragraph_level=1)
    // so it goes through the level-1 reversal too. End result: the '\n'
    // ends up at the visual left edge.
    try std.testing.expectEqualStrings("\n\u{05D1}\u{05D0}", out);
}

test "processLines: multi-line input preserves separators" {
    const allocator = std.testing.allocator;
    const input = "Hello\n\u{05D0}\u{05D1}\nWorld";
    const out = try processLines(allocator, input);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("Hello\n\u{05D1}\u{05D0}\nWorld", out);
}

test "processLines: pure-LTR is byte-identical" {
    const allocator = std.testing.allocator;
    const input = "Line1\nLine2\nLine3";
    const out = try processLines(allocator, input);
    defer allocator.free(out);
    try std.testing.expectEqualStrings(input, out);
}

test "processLines: trailing newline preserved" {
    const allocator = std.testing.allocator;
    const out = try processLines(allocator, "\u{05D0}\u{05D1}\n");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("\u{05D1}\u{05D0}\n", out);
}

test "spec W7: digits before Hebrew word in LTR paragraph stay LTR" {
    const allocator = std.testing.allocator;
    // Paragraph base: LTR (first strong is 'A'). "A 5 <05D0><05D1>" —
    // the digit 5 is preceded (looking back through weak types) by L,
    // so W7 fires and EN→L. The Hebrew word reverses in its own run.
    const logical = "A 5 \u{05D0}\u{05D1}";
    const expected = "A 5 \u{05D1}\u{05D0}";
    const out = try process(allocator, logical, null);
    defer allocator.free(out);
    try std.testing.expectEqualStrings(expected, out);
}

test "spec mixed: Arabic + European digits + ASCII brackets" {
    const allocator = std.testing.allocator;
    // Paragraph base: RTL (first strong is Arabic).
    // <0623><0628> "(" "12" ")" — digits get level 2 (preceded by AL,
    // promoted to AN by W2; AN at even level 0 would += 2 but this
    // paragraph is level-1, so AN += 1 → level 2). The brackets are
    // neutrals between AN runs; per N1 they take strong R (since AN
    // counts as R for N1). At level 1 they reverse.
    const logical = "\u{0623}\u{0628}(12)";
    const out = try process(allocator, logical, null);
    defer allocator.free(out);
    // Visual: ")" "12" "(" then the Arabic letters reversed.
    // Brackets resolve to R via N1 → level 1; digits at level 2
    // (preserve internal order under L2's pairwise reversal).
    try std.testing.expectEqualStrings(")12(\u{0628}\u{0623}", out);
}
