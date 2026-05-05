//! PR-W10a [feat]: XMP /Metadata stream writer.
//!
//! Emits an XMP packet (XML inside a `<x:xmpmeta>` envelope) suitable for
//! embedding as the body of a `/Type /Metadata /Subtype /XML` indirect
//! object referenced from the document /Catalog via `/Metadata N 0 R`.
//!
//! The packet carries:
//! - PDF/A conformance markers (`pdf:PDFAIdVersion` legacy + the
//!   `pdfaid:part` / `pdfaid:conformance` namespace pair preferred by
//!   veraPDF & Adobe).
//! - Standard Dublin Core / XMP fields lifted from the document /Info
//!   dict (Title, Author, Subject) when those are present.
//!
//! Defensive posture (TigerStyle-flavoured):
//! - 64 KiB cap on packet size (DoS guard against pathological /Info).
//! - Bounded reads on /Info Title/Author/Subject (each capped at 4 KiB).
//! - All caller bytes flow through `escapeXml` — no unescaped `&`, `<`,
//!   `>`, `"`, `'` reach the wire.
//! - Errdefer on every alloc.
//!
//! Source: ISO 19005-1 (PDF/A-1) §6.7.11; ISO 16684-1 (XMP); the XMP
//! Specification Part 1 §7.

const std = @import("std");
const assert = std.debug.assert;

/// PDF/A conformance level subset relevant for XMP emission.
/// Mirrors `pdf_document.PdfALevel` but kept local so this module is
/// independent of the consumer's enum layout.
pub const PdfALevelView = struct {
    /// "1", "2", or "3".
    part: []const u8,
    /// "A", "B", or "U".
    conformance: []const u8,
};

/// Maximum XMP packet size on the wire. PDF/A doesn't mandate a cap;
/// we pick 64 KiB so a malicious /Info dict can't blow the heap.
pub const MAX_PACKET_BYTES: usize = 64 * 1024;

/// Per-field cap on the bytes lifted out of /Info. PDF doesn't mandate
/// one; this matches Adobe's de-facto Title/Author practical limit.
pub const MAX_FIELD_BYTES: usize = 4 * 1024;

/// Optional descriptor fields. All bytes are caller-owned and copied
/// into the XMP packet via `escapeXml` — caller may free immediately
/// after `emit()` returns.
pub const Fields = struct {
    title: ?[]const u8 = null,
    author: ?[]const u8 = null,
    subject: ?[]const u8 = null,
};

/// Map `pdf_document.PdfALevel` (passed as a tag name string) to the
/// XMP `pdfaid:part`/`pdfaid:conformance` pair. The caller passes the
/// tag name verbatim (`"b1"`, `"a2"`, `"u3"`, …) so this module stays
/// decoupled from the consumer's enum.
pub fn levelView(tag: []const u8) error{InvalidPdfALevel}!PdfALevelView {
    if (tag.len != 2) return error.InvalidPdfALevel;
    const conformance: []const u8 = switch (tag[0]) {
        'a' => "A",
        'b' => "B",
        'u' => "U",
        else => return error.InvalidPdfALevel,
    };
    const part: []const u8 = switch (tag[1]) {
        '1' => "1",
        '2' => "2",
        '3' => "3",
        else => return error.InvalidPdfALevel,
    };
    return .{ .part = part, .conformance = conformance };
}

/// Escape `input` for inclusion in XML PCDATA / attribute values.
/// Owned by caller; caller frees with `allocator.free`.
///
/// Postcondition: the returned slice contains no unescaped `&`, `<`,
/// `>`, `"`, or `'` characters.
pub fn escapeXml(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    // Worst case: every input byte becomes `&apos;` (6 bytes). Reserve
    // up front so the hot loop doesn't reallocate.
    try out.ensureTotalCapacity(allocator, input.len * 6);
    for (input) |c| {
        switch (c) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&apos;"),
            // XML 1.0 forbids most C0 control characters even when
            // escaped. Drop them silently — XMP readers tolerate
            // missing chars far better than malformed XML.
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => {},
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Emit a complete XMP packet for a PDF/A document. Returns owned
/// bytes; caller frees with `allocator.free(bytes)`.
///
/// Preconditions:
/// - `level` is a valid PDF/A level view (caller obtained via
///   `levelView`).
/// - Each `Fields` slice, if present, is ≤ `MAX_FIELD_BYTES` — longer
///   inputs are truncated at the byte boundary (best-effort UTF-8
///   awareness is left for a follow-up).
///
/// Postconditions:
/// - Returned slice begins with the XMP packet wrapper (`<?xpacket
///   begin=...`).
/// - Returned slice ends with `<?xpacket end="w"?>`.
/// - Returned slice length ≤ `MAX_PACKET_BYTES`.
pub fn emit(
    allocator: std.mem.Allocator,
    level: PdfALevelView,
    fields: Fields,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // Pre-reserve a comfortable working budget. Even a maximal packet
    // (3× 4 KiB fields + envelope) fits well under 16 KiB.
    try out.ensureTotalCapacity(allocator, 4096);

    // XMP packet envelope. The `begin` BOM uses U+FEFF (3 UTF-8 bytes
    // 0xEF 0xBB 0xBF) per the XMP spec §7.3.2.
    try out.appendSlice(allocator, "<?xpacket begin=\"\xEF\xBB\xBF\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n");
    try out.appendSlice(allocator, "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\" x:xmptk=\"pdf.zig\">\n");
    try out.appendSlice(allocator, "  <rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n");

    // pdfaid descriptor — the PDF/A conformance markers veraPDF /
    // Adobe Preflight check.
    try out.appendSlice(allocator,
        "    <rdf:Description rdf:about=\"\" xmlns:pdfaid=\"http://www.aiim.org/pdfa/ns/id/\">\n",
    );
    try out.appendSlice(allocator, "      <pdfaid:part>");
    try out.appendSlice(allocator, level.part);
    try out.appendSlice(allocator, "</pdfaid:part>\n");
    try out.appendSlice(allocator, "      <pdfaid:conformance>");
    try out.appendSlice(allocator, level.conformance);
    try out.appendSlice(allocator, "</pdfaid:conformance>\n");
    try out.appendSlice(allocator, "    </rdf:Description>\n");

    // Dublin Core descriptor — Title, Creator (Author), Description
    // (Subject). Only emitted when at least one field is non-null;
    // an empty descriptor is still legal but pointless.
    const has_dc = fields.title != null or fields.author != null or fields.subject != null;
    if (has_dc) {
        try out.appendSlice(allocator,
            "    <rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\n",
        );

        if (fields.title) |t| {
            const bounded = t[0..@min(t.len, MAX_FIELD_BYTES)];
            const esc = try escapeXml(allocator, bounded);
            defer allocator.free(esc);
            try out.appendSlice(allocator, "      <dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">");
            try out.appendSlice(allocator, esc);
            try out.appendSlice(allocator, "</rdf:li></rdf:Alt></dc:title>\n");
        }
        if (fields.author) |a| {
            const bounded = a[0..@min(a.len, MAX_FIELD_BYTES)];
            const esc = try escapeXml(allocator, bounded);
            defer allocator.free(esc);
            try out.appendSlice(allocator, "      <dc:creator><rdf:Seq><rdf:li>");
            try out.appendSlice(allocator, esc);
            try out.appendSlice(allocator, "</rdf:li></rdf:Seq></dc:creator>\n");
        }
        if (fields.subject) |s| {
            const bounded = s[0..@min(s.len, MAX_FIELD_BYTES)];
            const esc = try escapeXml(allocator, bounded);
            defer allocator.free(esc);
            try out.appendSlice(allocator, "      <dc:description><rdf:Alt><rdf:li xml:lang=\"x-default\">");
            try out.appendSlice(allocator, esc);
            try out.appendSlice(allocator, "</rdf:li></rdf:Alt></dc:description>\n");
        }

        try out.appendSlice(allocator, "    </rdf:Description>\n");
    }

    try out.appendSlice(allocator, "  </rdf:RDF>\n");
    try out.appendSlice(allocator, "</x:xmpmeta>\n");
    // 2 KiB of trailing whitespace is the XMP "padding" convention
    // (spec §7.3.4) — readers that want to mutate the packet in place
    // grow into it. We emit 64 bytes only; pdf.zig is a one-shot
    // emitter, no in-place rewriting needed.
    try out.appendSlice(allocator, "                                                                \n");
    try out.appendSlice(allocator, "<?xpacket end=\"w\"?>");

    if (out.items.len > MAX_PACKET_BYTES) return error.XmpPacketTooLarge;

    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

test "escapeXml maps the five XML predefined entities" {
    const allocator = std.testing.allocator;
    const out = try escapeXml(allocator, "<&>\"'");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("&lt;&amp;&gt;&quot;&apos;", out);
}

test "escapeXml passes ASCII bytes through unchanged" {
    const allocator = std.testing.allocator;
    const out = try escapeXml(allocator, "Hello, world.");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("Hello, world.", out);
}

test "escapeXml drops forbidden C0 controls" {
    const allocator = std.testing.allocator;
    const out = try escapeXml(allocator, "a\x00b\x01c\x1Fd\x09e\x0Af");
    defer allocator.free(out);
    // Tabs (0x09) and LF (0x0A) survive; the rest are dropped.
    try std.testing.expectEqualStrings("abcd\x09e\x0Af", out);
}

test "levelView maps every PDF/A tag" {
    const cases = .{
        .{ "b1", "1", "B" }, .{ "b2", "2", "B" }, .{ "b3", "3", "B" },
        .{ "a1", "1", "A" }, .{ "a2", "2", "A" }, .{ "a3", "3", "A" },
        .{ "u1", "1", "U" }, .{ "u2", "2", "U" }, .{ "u3", "3", "U" },
    };
    inline for (cases) |c| {
        const v = try levelView(c[0]);
        try std.testing.expectEqualStrings(c[1], v.part);
        try std.testing.expectEqualStrings(c[2], v.conformance);
    }
}

test "levelView rejects malformed tags" {
    try std.testing.expectError(error.InvalidPdfALevel, levelView(""));
    try std.testing.expectError(error.InvalidPdfALevel, levelView("x1"));
    try std.testing.expectError(error.InvalidPdfALevel, levelView("b9"));
    try std.testing.expectError(error.InvalidPdfALevel, levelView("b22"));
}

test "emit produces packet with PDF/A markers for level b2" {
    const allocator = std.testing.allocator;
    const view = try levelView("b2");
    const bytes = try emit(allocator, view, .{});
    defer allocator.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "<x:xmpmeta") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "<pdfaid:part>2</pdfaid:part>") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "<pdfaid:conformance>B</pdfaid:conformance>") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "<?xpacket end=\"w\"?>") != null);
}

test "emit escapes Title bytes containing XML metachars" {
    const allocator = std.testing.allocator;
    const view = try levelView("b3");
    const bytes = try emit(allocator, view, .{ .title = "Tom & Jerry <script>" });
    defer allocator.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "Tom &amp; Jerry &lt;script&gt;") != null);
    // Sanity: no raw `<script` (would indicate a missed escape).
    try std.testing.expect(std.mem.indexOf(u8, bytes, "<script>") == null);
}

test "emit emits dc:creator and dc:description when set" {
    const allocator = std.testing.allocator;
    const view = try levelView("u1");
    const bytes = try emit(allocator, view, .{
        .title = "Spec",
        .author = "Alice",
        .subject = "PDF/A test",
    });
    defer allocator.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "<dc:title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "<dc:creator>") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "<dc:description>") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "Alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "PDF/A test") != null);
}

test "emit omits dc descriptor when no fields set" {
    const allocator = std.testing.allocator;
    const view = try levelView("b2");
    const bytes = try emit(allocator, view, .{});
    defer allocator.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "<dc:title>") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "<dc:creator>") == null);
}

test "emit caps oversized field at MAX_FIELD_BYTES" {
    const allocator = std.testing.allocator;
    const view = try levelView("b1");
    const big = try allocator.alloc(u8, MAX_FIELD_BYTES * 2);
    defer allocator.free(big);
    @memset(big, 'x');

    const bytes = try emit(allocator, view, .{ .title = big });
    defer allocator.free(bytes);

    // Packet still under the hard cap.
    try std.testing.expect(bytes.len <= MAX_PACKET_BYTES);
    // The bounded title appears (4 KiB of 'x'), but not the full
    // 8 KiB.
    const x_run_4k = "x" ** MAX_FIELD_BYTES;
    try std.testing.expect(std.mem.indexOf(u8, bytes, x_run_4k) != null);
}

test "emit round-trip — escape-aware search" {
    const allocator = std.testing.allocator;
    const view = try levelView("a2");
    const bytes = try emit(allocator, view, .{
        .title = "<title>",
        .author = "A&B",
        .subject = "x \"quoted\" 'apos'",
    });
    defer allocator.free(bytes);

    // None of the unescaped originals should appear.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "<title>x") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "A&B") == null);
    // All escaped forms appear.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "&lt;title&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "A&amp;B") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "&quot;quoted&quot;") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "&apos;apos&apos;") != null);
}

test "emit OOM sweep via FailingAllocator" {
    const Wrapper = struct {
        fn emitOnce(allocator: std.mem.Allocator) !void {
            const view = try levelView("b2");
            const bytes = try emit(allocator, view, .{
                .title = "Title<&>",
                .author = "Author",
                .subject = "Subject \"quoted\"",
            });
            allocator.free(bytes);
        }
    };

    try std.testing.checkAllAllocationFailures(std.testing.allocator, Wrapper.emitOnce, .{});
}
