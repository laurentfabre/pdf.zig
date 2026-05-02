//! PR-W5 [feat]: minimal markdown → PDF renderer for the
//! `pdf.zig new` subcommand.
//!
//! Tier-1 scope:
//!   - Headings (`# `, `## `, `### `) → larger sizes
//!   - Plain text paragraphs with word-wrap at the right margin
//!   - Bullet lists (`- ` / `* ` / `+ `) and numbered lists (`1. `)
//!     with hanging indent
//!   - Page break on a `---` line by itself
//!   - One built-in font (Helvetica family) for the entire document
//!
//! Out of scope (Tier 2+):
//!   - Inline formatting (bold / italic / code via `**` / `_` / `\``)
//!   - Block code fences (```)
//!   - Tables, links, images, footnotes
//!   - Right-to-left, Bidi, CJK
//!   - Any character outside WinAnsi (high-byte bytes are dropped
//!     per `PageBuilder.drawText` semantics).

const std = @import("std");
const pdf_document = @import("pdf_document.zig");

/// Letter, in PDF user-space points.
pub const PAGE_WIDTH: f64 = 612.0;
pub const PAGE_HEIGHT: f64 = 792.0;
pub const MARGIN: f64 = 72.0; // 1 inch

const BODY_SIZE: f64 = 11.0;
const H1_SIZE: f64 = 24.0;
const H2_SIZE: f64 = 18.0;
const H3_SIZE: f64 = 14.0;
const LINE_GAP: f64 = 1.4; // multiplier on font size

/// Render `markdown` into a PDF byte buffer. Caller owns the result;
/// free with `allocator.free(bytes)`.
pub fn render(allocator: std.mem.Allocator, markdown: []const u8) ![]u8 {
    var doc = pdf_document.DocumentBuilder.init(allocator);
    defer doc.deinit();

    var renderer = Renderer{
        .allocator = allocator,
        .doc = &doc,
        .page = null,
        .y = 0,
    };
    try renderer.beginPage();

    var iter = std.mem.splitScalar(u8, markdown, '\n');
    var skip_blank: bool = false;
    while (iter.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, " \t\r");

        // Page break marker: a line containing only `---`.
        if (std.mem.eql(u8, std.mem.trimStart(u8, line, " \t"), "---")) {
            try renderer.beginPage();
            skip_blank = true;
            continue;
        }

        // Blank line collapses paragraphs but doesn't render anything.
        if (line.len == 0) {
            if (!skip_blank) try renderer.advance(BODY_SIZE * 0.6);
            skip_blank = false;
            continue;
        }
        skip_blank = false;

        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "# ") and !std.mem.startsWith(u8, trimmed, "## ")) {
            try renderer.heading(trimmed[2..], H1_SIZE);
        } else if (std.mem.startsWith(u8, trimmed, "## ") and !std.mem.startsWith(u8, trimmed, "### ")) {
            try renderer.heading(trimmed[3..], H2_SIZE);
        } else if (std.mem.startsWith(u8, trimmed, "### ")) {
            try renderer.heading(trimmed[4..], H3_SIZE);
        } else if (bulletPrefix(trimmed)) |skip| {
            // ASCII marker: drawText drops bytes outside 0x20..0x7e,
            // so `•` would render as nothing. `-` is the safe fallback.
            try renderer.listItem(trimmed[skip..], "-");
        } else if (numberedPrefix(trimmed)) |skip_count| {
            // Include the trailing dot; only the space is stripped.
            const num = trimmed[0 .. skip_count - 1];
            try renderer.listItem(trimmed[skip_count..], num);
        } else {
            try renderer.paragraph(trimmed);
        }
    }

    return doc.write();
}

/// Match `- `, `* `, `+ ` (any whitespace before is already trimmed
/// by the caller). Returns the byte count to skip past the bullet
/// + space, or null if not a bullet line.
fn bulletPrefix(line: []const u8) ?usize {
    if (line.len < 2) return null;
    const c = line[0];
    if ((c == '-' or c == '*' or c == '+') and line[1] == ' ') return 2;
    return null;
}

/// Match `1. `, `42. `, etc. Returns bytes to skip past the number
/// + dot + space, or null. The caller can slice [0..skip-2] to get
/// the number text without the trailing `. `.
fn numberedPrefix(line: []const u8) ?usize {
    var p: usize = 0;
    while (p < line.len and std.ascii.isDigit(line[p])) p += 1;
    if (p == 0) return null;
    if (p + 1 >= line.len) return null;
    if (line[p] != '.' or line[p + 1] != ' ') return null;
    return p + 2;
}

const Renderer = struct {
    allocator: std.mem.Allocator,
    doc: *pdf_document.DocumentBuilder,
    page: ?*pdf_document.PageBuilder,
    /// Current y position (PDF user space, top of the next line).
    y: f64,

    fn beginPage(self: *Renderer) !void {
        self.page = try self.doc.addPage(.{ 0, 0, PAGE_WIDTH, PAGE_HEIGHT });
        self.y = PAGE_HEIGHT - MARGIN;
    }

    fn ensureSpace(self: *Renderer, needed: f64) !void {
        if (self.y - needed < MARGIN) try self.beginPage();
    }

    fn advance(self: *Renderer, dy: f64) !void {
        if (self.y - dy < MARGIN) {
            try self.beginPage();
        } else {
            self.y -= dy;
        }
    }

    fn heading(self: *Renderer, text: []const u8, size: f64) !void {
        // Top spacing for headings, then descend for the line itself.
        try self.ensureSpace(size * LINE_GAP * 1.4);
        try self.advance(size * 0.5);
        try self.drawTextLine(text, .helvetica_bold, size, MARGIN);
        try self.advance(size * LINE_GAP);
    }

    fn paragraph(self: *Renderer, text: []const u8) !void {
        try self.flowText(text, .helvetica, BODY_SIZE, MARGIN);
    }

    fn listItem(self: *Renderer, text: []const u8, marker: []const u8) !void {
        const marker_indent: f64 = MARGIN;
        const text_indent: f64 = MARGIN + 18;
        try self.ensureSpace(BODY_SIZE * LINE_GAP);
        const page = self.page.?;
        try page.drawText(marker_indent, self.y - BODY_SIZE * 0.85, .helvetica, BODY_SIZE, marker);
        try self.flowTextStart(text, .helvetica, BODY_SIZE, text_indent);
    }

    /// Single-line draw at `(left, y - size*0.85)` (so the y-axis
    /// values track the *baseline-top* convention this Renderer uses
    /// internally). Advances y by `size * LINE_GAP`.
    fn drawTextLine(
        self: *Renderer,
        text: []const u8,
        font: pdf_document.BuiltinFont,
        size: f64,
        left: f64,
    ) !void {
        const page = self.page.?;
        try page.drawText(left, self.y - size * 0.85, font, size, text);
        try self.advance(size * LINE_GAP);
    }

    /// Word-wrapping flow at `left`. Wraps at `PAGE_WIDTH - MARGIN`.
    fn flowText(
        self: *Renderer,
        text: []const u8,
        font: pdf_document.BuiltinFont,
        size: f64,
        left: f64,
    ) !void {
        try self.flowTextStart(text, font, size, left);
    }

    fn flowTextStart(
        self: *Renderer,
        text: []const u8,
        font: pdf_document.BuiltinFont,
        size: f64,
        left: f64,
    ) !void {
        const right = PAGE_WIDTH - MARGIN;
        const max_width = right - left;
        // Approximate Helvetica char width ≈ 0.5 * font_size em (rough
        // for proportional fonts; sufficient for Tier-1 layout).
        const avg_char_w = size * 0.5;
        const max_chars: usize = @max(1, @as(usize, @intFromFloat(max_width / avg_char_w)));

        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.allocator);

        var word_iter = std.mem.tokenizeAny(u8, text, " \t");
        while (word_iter.next()) |word| {
            // Hard-wrap a single oversized token (URL, path) so it
            // doesn't blow past the right margin. We slice in
            // `max_chars`-sized chunks; each chunk except the last is
            // emitted on its own line.
            var remaining = word;
            while (remaining.len > max_chars) {
                if (line.items.len > 0) {
                    try self.drawTextLine(line.items, font, size, left);
                    line.clearRetainingCapacity();
                }
                try self.drawTextLine(remaining[0..max_chars], font, size, left);
                remaining = remaining[max_chars..];
            }
            const projected = if (line.items.len == 0) remaining.len else line.items.len + 1 + remaining.len;
            if (projected > max_chars and line.items.len > 0) {
                try self.drawTextLine(line.items, font, size, left);
                line.clearRetainingCapacity();
            }
            if (line.items.len > 0) try line.append(self.allocator, ' ');
            try line.appendSlice(self.allocator, remaining);
        }
        if (line.items.len > 0) {
            try self.drawTextLine(line.items, font, size, left);
        }
    }
};

// ---------- tests ----------

test "render: empty markdown produces a 1-page blank PDF" {
    const allocator = std.testing.allocator;
    const bytes = try render(allocator, "");
    defer allocator.free(bytes);
    const zpdf = @import("root.zig");
    var doc = try zpdf.Document.openFromMemory(allocator, bytes, zpdf.ErrorConfig.permissive());
    defer doc.close();
    try std.testing.expectEqual(@as(usize, 1), doc.pageCount());
}

test "render: H1 + paragraph round-trips" {
    const allocator = std.testing.allocator;
    const md =
        \\# Hello PR-W5
        \\
        \\This is a small body paragraph.
    ;
    const bytes = try render(allocator, md);
    defer allocator.free(bytes);

    const zpdf = @import("root.zig");
    var doc = try zpdf.Document.openFromMemory(allocator, bytes, zpdf.ErrorConfig.permissive());
    defer doc.close();
    const text = try doc.extractMarkdown(0, allocator);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Hello PR-W5") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "small body paragraph") != null);
}

test "render: --- triggers a page break" {
    const allocator = std.testing.allocator;
    const md =
        \\Page one body.
        \\
        \\---
        \\
        \\Page two body.
    ;
    const bytes = try render(allocator, md);
    defer allocator.free(bytes);

    const zpdf = @import("root.zig");
    var doc = try zpdf.Document.openFromMemory(allocator, bytes, zpdf.ErrorConfig.permissive());
    defer doc.close();
    try std.testing.expectEqual(@as(usize, 2), doc.pageCount());

    const md0 = try doc.extractMarkdown(0, allocator);
    defer allocator.free(md0);
    try std.testing.expect(std.mem.indexOf(u8, md0, "Page one body") != null);

    const md1 = try doc.extractMarkdown(1, allocator);
    defer allocator.free(md1);
    try std.testing.expect(std.mem.indexOf(u8, md1, "Page two body") != null);
}

test "render: bullet list" {
    const allocator = std.testing.allocator;
    const md =
        \\- alpha
        \\- beta
        \\- gamma
    ;
    const bytes = try render(allocator, md);
    defer allocator.free(bytes);

    const zpdf = @import("root.zig");
    var doc = try zpdf.Document.openFromMemory(allocator, bytes, zpdf.ErrorConfig.permissive());
    defer doc.close();
    const text = try doc.extractMarkdown(0, allocator);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "gamma") != null);
}

test "render: long paragraph wraps to next line within page" {
    const allocator = std.testing.allocator;
    const md = "The quick brown fox jumps over the lazy dog. " ** 10;
    const bytes = try render(allocator, md);
    defer allocator.free(bytes);

    const zpdf = @import("root.zig");
    var doc = try zpdf.Document.openFromMemory(allocator, bytes, zpdf.ErrorConfig.permissive());
    defer doc.close();
    try std.testing.expect(doc.pageCount() >= 1);
    const text = try doc.extractMarkdown(0, allocator);
    defer allocator.free(text);
    // Round-trip: the words survive even after word-wrap.
    try std.testing.expect(std.mem.indexOf(u8, text, "quick brown fox") != null);
}

test "render: numbered list" {
    const allocator = std.testing.allocator;
    const md =
        \\1. first
        \\2. second
        \\3. third
    ;
    const bytes = try render(allocator, md);
    defer allocator.free(bytes);

    const zpdf = @import("root.zig");
    var doc = try zpdf.Document.openFromMemory(allocator, bytes, zpdf.ErrorConfig.permissive());
    defer doc.close();
    const text = try doc.extractMarkdown(0, allocator);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "first") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "second") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "third") != null);
}

test "render: bullet markers emit ASCII `-` in the content stream" {
    const allocator = std.testing.allocator;
    const md =
        \\- alpha
        \\- beta
    ;
    const bytes = try render(allocator, md);
    defer allocator.free(bytes);
    // The marker is drawn as a literal string `(-)` followed by `Tj`.
    // Markdown extraction auto-renumbers/normalises markers, so we
    // inspect the raw content bytes instead.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "(-) Tj") != null);
}

test "render: numbered markers emit `1.`/`2.` literals in the content stream" {
    const allocator = std.testing.allocator;
    const md =
        \\1. first
        \\2. second
    ;
    const bytes = try render(allocator, md);
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "(1.) Tj") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "(2.) Tj") != null);
}

test "render: long unbroken token hard-wraps in the content stream" {
    const allocator = std.testing.allocator;
    // 200-char token, longer than ~85 chars/line at body size. The
    // hard-wrap loop chunks it into max_chars pieces and emits each
    // chunk as its own Tj. We assert that the token is split into
    // at least 2 distinct Tj operators.
    const md = "https://example.com/" ++ ("a" ** 180);
    const bytes = try render(allocator, md);
    defer allocator.free(bytes);

    var tj_count: usize = 0;
    var search = bytes;
    while (std.mem.indexOf(u8, search, ") Tj")) |idx| : (search = search[idx + 4 ..]) {
        tj_count += 1;
    }
    try std.testing.expect(tj_count >= 2);
    // The first chunk starts with the URL prefix (the prefix is
    // shorter than max_chars, so it fits intact in chunk #1).
    try std.testing.expect(std.mem.indexOf(u8, bytes, "(https://example.com") != null);
}
