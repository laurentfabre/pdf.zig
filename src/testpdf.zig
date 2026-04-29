//! Test PDF Generator
//!
//! Creates minimal valid PDFs for testing the parser.
//! Hand-crafted bodies migrated to the writer API cluster-by-cluster
//! (PR-W6.1+); fixtures that need /Info, /Outlines, /Annots, AcroForm,
//! /PageLabels stay hand-rolled for now.

const std = @import("std");
const document = @import("pdf_document.zig");

/// PR-W6.1 [refactor]: text-only fixture, now built via DocumentBuilder.
/// Byte-different from the previous hand-rolled output, semantically
/// equivalent for the WinAnsi-printable subset of bytes the existing
/// callers actually pass (same pageCount, font ref, extractable text).
/// Bytes outside `[0x20, 0x7e]` are silently dropped by `drawText`'s
/// WinAnsi filter — the old fixture inlined them verbatim, so seeds
/// like `"fuzz seed — minimal"` (em dash) lose those code points.
/// Existing call sites are robust to the dropped bytes.
pub fn generateMinimalPdf(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var doc = document.DocumentBuilder.init(allocator);
    defer doc.deinit();
    const page = try doc.addPage(.{ 0, 0, 612, 792 });
    try page.drawText(100, 700, .helvetica, 12, text);
    return doc.write();
}

/// PR-W6.1 [refactor]: multi-page text fixture via DocumentBuilder.
/// Each input string lands as a single 12pt Helvetica `Tj` at (100, 700)
/// on its own /Page. The page tree is balanced (PR-W2) — for ≤10
/// pages it stays flat, matching the old hand-rolled shape. Non-ASCII
/// bytes are dropped by `drawText`'s WinAnsi filter (printable-ASCII
/// only), unlike the old verbatim-inlining hand-rolled fixture.
pub fn generateMultiPagePdf(allocator: std.mem.Allocator, pages_text: []const []const u8) ![]u8 {
    var doc = document.DocumentBuilder.init(allocator);
    defer doc.deinit();
    for (pages_text) |text| {
        const page = try doc.addPage(.{ 0, 0, 612, 792 });
        try page.drawText(100, 700, .helvetica, 12, text);
    }
    return doc.write();
}

/// Generate a PDF with TJ operator (array-based text)
/// PR-W6.1 [refactor]: TJ-operator (kerned text-show) fixture via
/// DocumentBuilder. Direct content-stream injection because the writer
/// only models `Tj`. `markFontUsed` returns the resource name (`/F0`
/// for Helvetica) so the `Tf` operator references whatever the
/// auto-resources block actually emits.
pub fn generateTJPdf(allocator: std.mem.Allocator) ![]u8 {
    var doc = document.DocumentBuilder.init(allocator);
    defer doc.deinit();
    const page = try doc.addPage(.{ 0, 0, 612, 792 });
    const f = page.markFontUsed(.helvetica);
    var content_buf: [128]u8 = undefined;
    const content = try std.fmt.bufPrint(
        &content_buf,
        "BT\n{s} 12 Tf\n100 700 Td\n[(Hello) -200 (World)] TJ\nET\n",
        .{f},
    );
    try page.appendContent(content);
    return doc.write();
}

/// Generate a PDF with a CID font (Type0 composite font with ToUnicode)
/// Uses UTF-16BE encoded text and a ToUnicode CMap for mapping
pub fn generateCIDFontPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);

    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    // Object 1: Catalog
    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    // Object 2: Pages
    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    // Object 3: Page
    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    // Object 4: Content stream with UTF-16BE encoded text
    // "Hello" in UTF-16BE: 0048 0065 006C 006C 006F
    // Plus "中" (U+4E2D) in UTF-16BE: 4E2D
    const content = "BT\n/F1 12 Tf\n100 700 Td\n<00480065006C006C006F20004E2D> Tj\nET\n";

    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });

    // Object 5: Type0 Font (Composite font)
    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n");
    try writer.writeAll("<< /Type /Font /Subtype /Type0 /BaseFont /TestCIDFont\n");
    try writer.writeAll("   /Encoding /Identity-H\n");
    try writer.writeAll("   /DescendantFonts [6 0 R]\n");
    try writer.writeAll("   /ToUnicode 7 0 R >>\n");
    try writer.writeAll("endobj\n");

    // Object 6: CIDFont
    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n");
    try writer.writeAll("<< /Type /Font /Subtype /CIDFontType2 /BaseFont /TestCIDFont\n");
    try writer.writeAll("   /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >>\n");
    try writer.writeAll("   /W [0 [500]] >>\n"); // Simple width array
    try writer.writeAll("endobj\n");

    // Object 7: ToUnicode CMap
    const tounicode_cmap =
        \\/CIDInit /ProcSet findresource begin
        \\12 dict begin
        \\begincmap
        \\/CMapType 2 def
        \\/CMapName /TestCMap def
        \\1 begincodespacerange
        \\<0000> <FFFF>
        \\endcodespacerange
        \\7 beginbfchar
        \\<0048> <0048>
        \\<0065> <0065>
        \\<006C> <006C>
        \\<006F> <006F>
        \\<0020> <0020>
        \\<0000> <0000>
        \\<4E2D> <4E2D>
        \\endbfchar
        \\endcmap
        \\CMapName currentdict /CMap defineresource pop
        \\end
        \\end
    ;

    const obj7_offset = pdf.items.len;
    try writer.print("7 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ tounicode_cmap.len, tounicode_cmap });

    // XRef table
    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 8\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj7_offset});

    try writer.writeAll("trailer\n<< /Size 8 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF whose leaf page node omits /Type (valid but often rejected).
/// Tests Fix 2: pagetree /Type default inference.
pub fn generatePdfWithoutPageType(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    // Object 3: Page dict intentionally omits /Type /Page
    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n");
    try writer.writeAll("<< /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\n");
    try writer.writeAll("endobj\n");

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(allocator);
    var cw = content.writer(allocator);
    try cw.writeAll("BT\n/F1 12 Tf\n100 700 Td\n");
    try cw.print("({s}) Tj\n", .{text});
    try cw.writeAll("ET\n");

    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n", .{content.items.len});
    try writer.writeAll(content.items);
    try writer.writeAll("\nendstream\nendobj\n");

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 6\n");
    try writer.print("0000000000 65535 f \n{d:0>10} 00000 n \n{d:0>10} 00000 n \n", .{ obj1_offset, obj2_offset });
    try writer.print("{d:0>10} 00000 n \n{d:0>10} 00000 n \n{d:0>10} 00000 n \n", .{ obj3_offset, obj4_offset, obj5_offset });
    try writer.writeAll("trailer\n<< /Size 6 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with an inline image (BI/EI block) surrounded by text.
/// Tests Fix 1: inline image skipping in the content stream lexer.
pub fn generateInlineImagePdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    // Content stream: text, inline image, text
    // The inline image bytes \xAA\xBB are arbitrary binary - they won't form "EI"
    const content =
        "BT\n/F1 12 Tf\n100 700 Td\n(Before) Tj\nET\n" ++
        "BI\n/W 2 /H 2 /CS /G /BPC 8\nID\n\xAA\xBB\xCC\xDD\nEI\n" ++
        "BT\n/F1 12 Tf\n100 650 Td\n(After) Tj\nET\n";

    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n", .{content.len});
    try writer.writeAll(content);
    try writer.writeAll("\nendstream\nendobj\n");

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 6\n");
    try writer.print("0000000000 65535 f \n{d:0>10} 00000 n \n{d:0>10} 00000 n \n", .{ obj1_offset, obj2_offset });
    try writer.print("{d:0>10} 00000 n \n{d:0>10} 00000 n \n{d:0>10} 00000 n \n", .{ obj3_offset, obj4_offset, obj5_offset });
    try writer.writeAll("trailer\n<< /Size 6 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with superscript text at a slightly elevated Y position.
/// Tests the superscript/subscript newline-suppression fix: a Tm whose Y
/// shift is smaller than 0.7 * max(current_font, last_text_font) should not
/// emit a newline.
/// PR-W6.1 [refactor]: superscript fixture via DocumentBuilder. Uses
/// `Tm` (text matrix) for explicit positioning, which the writer's
/// `drawText` doesn't model — direct content-stream injection.
/// Layout: main text at (100, 700) 12pt, superscript "2" at (110, 707)
/// 7pt, trailing " World" at (120, 700) 12pt. The 7-unit Y shift is
/// below the heuristic threshold (`max(7,12)*0.7 = 8.4`) so the
/// extractor must NOT emit a newline between them.
pub fn generateSuperscriptPdf(allocator: std.mem.Allocator) ![]u8 {
    var doc = document.DocumentBuilder.init(allocator);
    defer doc.deinit();
    const page = try doc.addPage(.{ 0, 0, 612, 792 });
    const f = page.markFontUsed(.helvetica);
    var content_buf: [512]u8 = undefined;
    const content = try std.fmt.bufPrint(
        &content_buf,
        "BT\n" ++
            "{[f]s} 12 Tf\n" ++
            "1 0 0 1 100 700 Tm\n" ++
            "(Hello) Tj\n" ++
            "{[f]s} 7 Tf\n" ++
            "1 0 0 1 110 707 Tm\n" ++
            "(2) Tj\n" ++
            "{[f]s} 12 Tf\n" ++
            "1 0 0 1 120 700 Tm\n" ++
            "( World) Tj\n" ++
            "ET\n",
        .{ .f = f },
    );
    try page.appendContent(content);
    return doc.write();
}

// ============================================================================
// TESTS
// ============================================================================

test "generate minimal PDF" {
    const pdf_data = try generateMinimalPdf(std.testing.allocator, "Hello World");
    defer std.testing.allocator.free(pdf_data);

    // Verify it starts with PDF header
    try std.testing.expect(std.mem.startsWith(u8, pdf_data, "%PDF-1.4"));

    // Verify it ends with %%EOF
    try std.testing.expect(std.mem.endsWith(u8, pdf_data, "%%EOF\n"));

    // Verify it contains our text
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "Hello World") != null);
}

test "generate multi-page PDF" {
    const pages = &[_][]const u8{ "Page One", "Page Two", "Page Three" };
    const pdf_data = try generateMultiPagePdf(std.testing.allocator, pages);
    defer std.testing.allocator.free(pdf_data);

    try std.testing.expect(std.mem.startsWith(u8, pdf_data, "%PDF-1.4"));
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/Count 3") != null);
}

test "generate CID font PDF" {
    const pdf_data = try generateCIDFontPdf(std.testing.allocator);
    defer std.testing.allocator.free(pdf_data);

    try std.testing.expect(std.mem.startsWith(u8, pdf_data, "%PDF-1.4"));
    // Should have Type0 font
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/Subtype /Type0") != null);
    // Should have ToUnicode CMap
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "beginbfchar") != null);
    // Should have Identity-H encoding
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/Identity-H") != null);
}

/// Generate a PDF with incremental updates
/// Creates a base PDF, then appends an incremental update that modifies the content
pub fn generateIncrementalPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);

    var writer = pdf.writer(allocator);

    // ===== ORIGINAL PDF =====
    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    // Object 1: Catalog
    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    // Object 2: Pages
    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    // Object 3: Page
    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    // Object 4: Content (original text: "Original Text")
    const content1 = "BT\n/F1 12 Tf\n100 700 Td\n(Original Text) Tj\nET\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content1.len, content1 });

    // Object 5: Font
    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n");

    // Original XRef table
    const xref1_offset = pdf.items.len;
    try writer.writeAll("xref\n0 6\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});

    try writer.writeAll("trailer\n<< /Size 6 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref1_offset});

    // ===== INCREMENTAL UPDATE =====
    // Replace object 4 with new content

    // New Object 4: Updated content (now says "Updated Text")
    const content2 = "BT\n/F1 12 Tf\n100 700 Td\n(Updated Text) Tj\nET\n";
    const new_obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content2.len, content2 });

    // Incremental XRef table (only updated objects)
    const xref2_offset = pdf.items.len;
    try writer.writeAll("xref\n4 1\n"); // Only object 4 is updated
    try writer.print("{d:0>10} 00000 n \n", .{new_obj4_offset});

    try writer.writeAll("trailer\n");
    try writer.print("<< /Size 6 /Root 1 0 R /Prev {} >>\n", .{xref1_offset});
    try writer.print("startxref\n{}\n%%EOF\n", .{xref2_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a minimal PDF with an /Encrypt entry in the trailer.
/// This doesn't implement real encryption - it just has the /Encrypt key
/// so the parser detects it as encrypted.
pub fn generateEncryptedPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);

    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    // Object 1: Catalog
    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    // Object 2: Pages
    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    // Object 3: Page
    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    // Object 4: Content stream
    const content = "BT\n/F1 12 Tf\n100 700 Td\n(Encrypted) Tj\nET\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });

    // Object 5: Font
    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n");

    // Object 6: Encrypt dictionary (dummy - just enough to be detected)
    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n<< /Filter /Standard /V 1 /R 2 /O (dummy) /U (dummy) /P -4 >>\nendobj\n");

    // XRef table
    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 7\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});

    // Trailer with /Encrypt reference
    try writer.writeAll("trailer\n");
    try writer.writeAll("<< /Size 7 /Root 1 0 R /Encrypt 6 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

test "generate encrypted PDF" {
    const pdf_data = try generateEncryptedPdf(std.testing.allocator);
    defer std.testing.allocator.free(pdf_data);

    try std.testing.expect(std.mem.startsWith(u8, pdf_data, "%PDF-1.4"));
    // Should have /Encrypt in trailer
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/Encrypt 6 0 R") != null);
}

test "generate incremental PDF" {
    const pdf_data = try generateIncrementalPdf(std.testing.allocator);
    defer std.testing.allocator.free(pdf_data);

    try std.testing.expect(std.mem.startsWith(u8, pdf_data, "%PDF-1.4"));
    // Should have two %%EOF markers (original + incremental update)
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, pdf_data, pos, "%%EOF")) |idx| {
        count += 1;
        pos = idx + 5;
    }
    try std.testing.expectEqual(@as(usize, 2), count);

    // Should have /Prev reference
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/Prev") != null);

    // Should contain both texts (though only "Updated Text" should be extracted)
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "Original Text") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "Updated Text") != null);
}

/// PR-W6.2 [refactor]: metadata fixture via DocumentBuilder.
/// Exercises `setInfoDict` (W6 escape-hatch surface). Trailer
/// `/Info N 0 R` is wired automatically by the writer.
pub fn generateMetadataPdf(allocator: std.mem.Allocator) ![]u8 {
    var doc = document.DocumentBuilder.init(allocator);
    defer doc.deinit();
    _ = try doc.setInfoDict(
        "<< /Title (Test Document) /Author (Test Author) " ++
            "/Subject (Test Subject) /Keywords (test, pdf, zpdf) " ++
            "/Creator (TestGenerator) /Producer (zpdf) >>",
    );
    const page = try doc.addPage(.{ 0, 0, 612, 792 });
    try page.drawText(100, 700, .helvetica, 12, "Metadata Test");
    return doc.write();
}

/// PR-W6.2 [refactor]: outline (bookmark / TOC) fixture via
/// DocumentBuilder. Exercises `setInfoDict`, `reserveAuxiliaryObject`
/// for the cyclic /Outlines ↔ item graph, and `setCatalogExtras` for
/// the /Outlines ref in /Catalog.
pub fn generateOutlinePdf(allocator: std.mem.Allocator) ![]u8 {
    var doc = document.DocumentBuilder.init(allocator);
    defer doc.deinit();

    _ = try doc.setInfoDict("<< /Title (Outline Test) >>");

    const page1 = try doc.addPage(.{ 0, 0, 612, 792 });
    try page1.drawText(100, 700, .helvetica, 12, "Chapter 1 Content");

    const page2 = try doc.addPage(.{ 0, 0, 612, 792 });
    try page2.drawText(100, 700, .helvetica, 12, "Chapter 2 Content");

    // Cyclic refs: outlines /First → item, item /Parent → outlines.
    const outlines = try doc.reserveAuxiliaryObject();
    const item = try doc.reserveAuxiliaryObject();

    var outlines_buf: [128]u8 = undefined;
    try doc.setAuxiliaryPayload(outlines, try std.fmt.bufPrint(
        &outlines_buf,
        "<< /Type /Outlines /First {d} 0 R /Last {d} 0 R /Count 1 >>",
        .{ item, item },
    ));

    var item_buf: [128]u8 = undefined;
    try doc.setAuxiliaryPayload(item, try std.fmt.bufPrint(
        &item_buf,
        "<< /Title (Chapter 1) /Parent {d} 0 R /Dest [{d} 0 R /Fit] >>",
        .{ outlines, page1.objNum() },
    ));

    var extras_buf: [64]u8 = undefined;
    try doc.setCatalogExtras(try std.fmt.bufPrint(&extras_buf, "/Outlines {d} 0 R", .{outlines}));

    return doc.write();
}

/// Generate a PDF with link annotations
pub fn generateLinkPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    // Page with /Annots array
    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> ");
    try writer.writeAll("/Annots [6 0 R] >>\nendobj\n");

    const content = "BT\n/F1 12 Tf\n100 700 Td\n(Click here) Tj\nET\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    // Object 6: Link annotation with URI
    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n<< /Type /Annot /Subtype /Link /Rect [100 690 200 710] ");
    try writer.writeAll("/A << /S /URI /URI (https://example.com) >> >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 7\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});

    try writer.writeAll("trailer\n<< /Size 7 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with form fields (/AcroForm)
pub fn generateFormFieldPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    // Catalog with AcroForm
    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R ");
    try writer.writeAll("/AcroForm << /Fields [6 0 R 7 0 R] >> >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    const content = "BT\n/F1 12 Tf\n100 700 Td\n(Form Test) Tj\nET\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    // Object 6: Text field
    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n<< /FT /Tx /T (name) /V (John Doe) ");
    try writer.writeAll("/Rect [100 600 300 620] >>\nendobj\n");

    // Object 7: Button field
    const obj7_offset = pdf.items.len;
    try writer.writeAll("7 0 obj\n<< /FT /Btn /T (submit) ");
    try writer.writeAll("/Rect [100 550 200 570] >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 8\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj7_offset});

    try writer.writeAll("trailer\n<< /Size 8 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with page labels
pub fn generatePageLabelPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    // Catalog with PageLabels: pages 0-1 roman lowercase, pages 2+ decimal
    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R ");
    try writer.writeAll("/PageLabels << /Nums [0 << /S /r >> 2 << /S /D >>] >> >>\nendobj\n");

    // 3 pages
    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R 6 0 R 8 0 R] /Count 3 >>\nendobj\n");

    // Page 1
    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    const c1 = "BT\n/F1 12 Tf\n100 700 Td\n(Page i) Tj\nET\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ c1.len, c1 });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    // Page 2
    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 7 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    const c2 = "BT\n/F1 12 Tf\n100 700 Td\n(Page ii) Tj\nET\n";
    const obj7_offset = pdf.items.len;
    try writer.print("7 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ c2.len, c2 });

    // Page 3
    const obj8_offset = pdf.items.len;
    try writer.writeAll("8 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 9 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    const c3 = "BT\n/F1 12 Tf\n100 700 Td\n(Page 1) Tj\nET\n";
    const obj9_offset = pdf.items.len;
    try writer.print("9 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ c3.len, c3 });

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 10\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj7_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj8_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj9_offset});

    try writer.writeAll("trailer\n<< /Size 10 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

test "generate metadata PDF" {
    const pdf_data = try generateMetadataPdf(std.testing.allocator);
    defer std.testing.allocator.free(pdf_data);
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/Title (Test Document)") != null);
    // Object numbers are writer-assigned; check the trailer signal instead.
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/Info ") != null);
}

test "generate outline PDF" {
    const pdf_data = try generateOutlinePdf(std.testing.allocator);
    defer std.testing.allocator.free(pdf_data);
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/Outlines ") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/Title (Chapter 1)") != null);
}

test "generate link PDF" {
    const pdf_data = try generateLinkPdf(std.testing.allocator);
    defer std.testing.allocator.free(pdf_data);
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/Subtype /Link") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "https://example.com") != null);
}

test "generate form field PDF" {
    const pdf_data = try generateFormFieldPdf(std.testing.allocator);
    defer std.testing.allocator.free(pdf_data);
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/AcroForm") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/FT /Tx") != null);
}

test "generate page label PDF" {
    const pdf_data = try generatePageLabelPdf(std.testing.allocator);
    defer std.testing.allocator.free(pdf_data);
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/PageLabels") != null);
}

/// PR-W6.2 [refactor]: nested outline (multi-level, sibling, GoTo
/// action) fixture via DocumentBuilder.
/// Hierarchy: /Outlines → Part I (with child Section 1.1) and Part II
/// (sibling, via /A GoTo). Mirrors the old hand-rolled object layout
/// modulo numbering.
pub fn generateNestedOutlinePdf(allocator: std.mem.Allocator) ![]u8 {
    var doc = document.DocumentBuilder.init(allocator);
    defer doc.deinit();

    const page1 = try doc.addPage(.{ 0, 0, 612, 792 });
    try page1.drawText(100, 700, .helvetica, 12, "Page One");

    const page2 = try doc.addPage(.{ 0, 0, 612, 792 });
    try page2.drawText(100, 700, .helvetica, 12, "Page Two");

    const outlines = try doc.reserveAuxiliaryObject();
    const part1 = try doc.reserveAuxiliaryObject();
    const part2 = try doc.reserveAuxiliaryObject();
    const section11 = try doc.reserveAuxiliaryObject();

    var buf: [256]u8 = undefined;
    try doc.setAuxiliaryPayload(outlines, try std.fmt.bufPrint(
        &buf,
        "<< /Type /Outlines /First {d} 0 R /Last {d} 0 R /Count 2 >>",
        .{ part1, part2 },
    ));
    try doc.setAuxiliaryPayload(part1, try std.fmt.bufPrint(
        &buf,
        "<< /Title (Part I) /Parent {d} 0 R /Next {d} 0 R " ++
            "/First {d} 0 R /Last {d} 0 R /Count 1 /Dest [{d} 0 R /Fit] >>",
        .{ outlines, part2, section11, section11, page1.objNum() },
    ));
    try doc.setAuxiliaryPayload(part2, try std.fmt.bufPrint(
        &buf,
        "<< /Title (Part II) /Parent {d} 0 R " ++
            "/A << /S /GoTo /D [{d} 0 R /Fit] >> >>",
        .{ outlines, page2.objNum() },
    ));
    try doc.setAuxiliaryPayload(section11, try std.fmt.bufPrint(
        &buf,
        "<< /Title (Section 1.1) /Parent {d} 0 R /Dest [{d} 0 R /Fit] >>",
        .{ part1, page1.objNum() },
    ));

    var extras_buf: [64]u8 = undefined;
    try doc.setCatalogExtras(try std.fmt.bufPrint(&extras_buf, "/Outlines {d} 0 R", .{outlines}));

    return doc.write();
}

/// Generate a PDF with multiple link annotations: URI, GoTo internal, and a non-link annotation
pub fn generateMultiLinkPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    // Page with 3 annotations: 2 links + 1 highlight (should be ignored)
    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> ");
    try writer.writeAll("/Annots [6 0 R 7 0 R 8 0 R] >>\nendobj\n");

    const content = "BT\n/F1 12 Tf\n100 700 Td\n(Links page) Tj\nET\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    // Object 6: URI link
    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n<< /Type /Annot /Subtype /Link /Rect [10 10 100 30] ");
    try writer.writeAll("/A << /S /URI /URI (https://example.org) >> >>\nendobj\n");

    // Object 7: GoTo internal link to page 1 (obj 3)
    const obj7_offset = pdf.items.len;
    try writer.writeAll("7 0 obj\n<< /Type /Annot /Subtype /Link /Rect [10 40 100 60] ");
    try writer.writeAll("/A << /S /GoTo /D [3 0 R /Fit] >> >>\nendobj\n");

    // Object 8: Highlight annotation (NOT a link, should be skipped)
    const obj8_offset = pdf.items.len;
    try writer.writeAll("8 0 obj\n<< /Type /Annot /Subtype /Highlight /Rect [10 70 100 90] >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 9\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj7_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj8_offset});

    try writer.writeAll("trailer\n<< /Size 9 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with all form field types: text, button, choice, signature
pub fn generateAllFormFieldsPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R ");
    try writer.writeAll("/AcroForm << /Fields [6 0 R 7 0 R 8 0 R 9 0 R] >> >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    const content = "BT\n/F1 12 Tf\n100 700 Td\n(All Fields) Tj\nET\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    // Text field with value
    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n<< /FT /Tx /T (email) /V (user@example.com) ");
    try writer.writeAll("/Rect [100 600 300 620] >>\nendobj\n");

    // Button field (no value)
    const obj7_offset = pdf.items.len;
    try writer.writeAll("7 0 obj\n<< /FT /Btn /T (ok_button) >>\nendobj\n");

    // Choice field with value
    const obj8_offset = pdf.items.len;
    try writer.writeAll("8 0 obj\n<< /FT /Ch /T (country) /V (USA) ");
    try writer.writeAll("/Rect [100 500 300 520] >>\nendobj\n");

    // Signature field (no value)
    const obj9_offset = pdf.items.len;
    try writer.writeAll("9 0 obj\n<< /FT /Sig /T (signature) >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 10\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj7_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj8_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj9_offset});

    try writer.writeAll("trailer\n<< /Size 10 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with page labels: uppercase roman, alpha, prefix, custom start
pub fn generateExtendedPageLabelPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    // Pages 0-1: uppercase roman (I, II)
    // Page 2: alpha lowercase starting at 1 (a)
    // Pages 3+: decimal with prefix "App-" starting at 1 (App-1)
    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R ");
    try writer.writeAll("/PageLabels << /Nums [0 << /S /R >> 2 << /S /a >> 3 << /S /D /P (App-) /St 1 >>] >> >>\nendobj\n");

    // 5 pages
    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R 6 0 R 8 0 R 10 0 R 12 0 R] /Count 5 >>\nendobj\n");

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    // Generate 5 pages (objects 3,4, 6,7, 8,9, 10,11, 12,13)
    const page_texts = [_][]const u8{ "Page I", "Page II", "Page a", "App Page 1", "App Page 2" };
    var page_offsets: [10]u64 = undefined; // pairs of (page_obj, content_obj)
    for (0..5) |pg| {
        const page_obj_num = 3 + pg * 2;
        const content_obj_num = page_obj_num + 1;
        if (page_obj_num == 5) {
            // Skip obj 5 (font) — already written. Adjust numbering.
            // Actually our numbering is 3,4, 6,7, 8,9, 10,11, 12,13 — no collision with 5.
        }

        page_offsets[pg * 2] = pdf.items.len;
        try writer.print("{} 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ", .{page_obj_num});
        try writer.print("/Contents {} 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n", .{content_obj_num});

        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(allocator);
        var cw = content.writer(allocator);
        try cw.writeAll("BT\n/F1 12 Tf\n100 700 Td\n");
        try cw.print("({s}) Tj\n", .{page_texts[pg]});
        try cw.writeAll("ET\n");

        page_offsets[pg * 2 + 1] = pdf.items.len;
        try writer.print("{} 0 obj\n<< /Length {} >>\nstream\n", .{ content_obj_num, content.items.len });
        try writer.writeAll(content.items);
        try writer.writeAll("\nendstream\nendobj\n");
    }

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 14\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{page_offsets[0]}); // obj 3
    try writer.print("{d:0>10} 00000 n \n", .{page_offsets[1]}); // obj 4
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset}); // obj 5
    try writer.print("{d:0>10} 00000 n \n", .{page_offsets[2]}); // obj 6
    try writer.print("{d:0>10} 00000 n \n", .{page_offsets[3]}); // obj 7
    try writer.print("{d:0>10} 00000 n \n", .{page_offsets[4]}); // obj 8
    try writer.print("{d:0>10} 00000 n \n", .{page_offsets[5]}); // obj 9
    try writer.print("{d:0>10} 00000 n \n", .{page_offsets[6]}); // obj 10
    try writer.print("{d:0>10} 00000 n \n", .{page_offsets[7]}); // obj 11
    try writer.print("{d:0>10} 00000 n \n", .{page_offsets[8]}); // obj 12
    try writer.print("{d:0>10} 00000 n \n", .{page_offsets[9]}); // obj 13

    try writer.writeAll("trailer\n<< /Size 14 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with an XObject image on the page
pub fn generateImagePdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    // Page with XObject resource
    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> /XObject << /Im1 7 0 R >> >> >>\nendobj\n");

    // Content stream: text + cm (scale) + Do image
    const content = "BT\n/F1 12 Tf\n100 700 Td\n(Image below) Tj\nET\n200 0 0 150 100 500 cm\n/Im1 Do\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    // Object 6: (unused)

    // Object 7: Image XObject (1x1 grayscale pixel)
    const obj7_offset = pdf.items.len;
    try writer.writeAll("7 0 obj\n<< /Type /XObject /Subtype /Image /Width 640 /Height 480 ");
    try writer.writeAll("/ColorSpace /DeviceGray /BitsPerComponent 8 /Length 1 >>\n");
    try writer.writeAll("stream\n\xFF\nendstream\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 8\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    // obj 6 unused — write dummy
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset}); // placeholder
    try writer.print("{d:0>10} 00000 n \n", .{obj7_offset});

    try writer.writeAll("trailer\n<< /Size 8 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a single-page PDF whose only page-level content stream
/// emits `/TableForm Do`, where `TableForm` is a Form XObject that
/// draws a 3×3 ruled table using stroke ops on absolute coordinates.
///
/// Used by the lattice Pass-B Form-XObject-recursion test. The
/// expected detection is one table with `n_rows = 3`, `n_cols = 3`
/// and `bbox ≈ [100, 400, 400, 700]` in user-space.
pub fn generateFormXObjectTablePdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    // Object 1 — Catalog
    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    // Object 2 — Pages
    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    // Object 3 — Page (references the Form XObject in /Resources)
    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n");
    try writer.writeAll("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R ");
    try writer.writeAll("/Resources << /XObject << /TableForm 5 0 R >> >> >>\n");
    try writer.writeAll("endobj\n");

    // Object 4 — page content stream: just invoke the Form XObject.
    const page_content = "/TableForm Do\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n", .{page_content.len});
    try writer.writeAll(page_content);
    try writer.writeAll("\nendstream\nendobj\n");

    // Object 5 — Form XObject. Identity matrix, BBox covers the table.
    // Content draws a 3x3 grid: outer 300x300 rect at (100,400) plus
    // 2 interior horizontals at y=500/600 and 2 interior verticals at
    // x=200/300. Each path is stroked with `S` so lattice picks up
    // every segment.
    const form_content =
        \\100 400 300 300 re S
        \\100 500 m 400 500 l S
        \\100 600 m 400 600 l S
        \\200 400 m 200 700 l S
        \\300 400 m 300 700 l S
        \\
    ;
    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n");
    try writer.print(
        "<< /Type /XObject /Subtype /Form /FormType 1 " ++
            "/BBox [100 400 400 700] /Matrix [1 0 0 1 0 0] /Length {} >>\n",
        .{form_content.len},
    );
    try writer.writeAll("stream\n");
    try writer.writeAll(form_content);
    try writer.writeAll("endstream\nendobj\n");

    // XRef
    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 6\n");
    try writer.print("{d:0>10} 65535 f \n", .{@as(u64, 0)});
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});

    try writer.writeAll("trailer\n<< /Size 6 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF whose Form XObject stores `/Subtype` as an indirect
/// reference (`/Subtype 7 0 R` → 7 0 obj /Form endobj). Codex review
/// v1.2-rc4 round 10 [P2]: lattice must resolve `/Subtype` through
/// `resolveRefSoft` before checking for "Form"; otherwise the form is
/// rejected and its 3x3 grid never surfaces as a detected table.
pub fn generateFormXObjectIndirectSubtypePdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n");
    try writer.writeAll("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R ");
    try writer.writeAll("/Resources << /XObject << /TableForm 5 0 R >> >> >>\n");
    try writer.writeAll("endobj\n");

    const page_content = "/TableForm Do\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n", .{page_content.len});
    try writer.writeAll(page_content);
    try writer.writeAll("\nendstream\nendobj\n");

    const form_content =
        \\100 400 300 300 re S
        \\100 500 m 400 500 l S
        \\100 600 m 400 600 l S
        \\200 400 m 200 700 l S
        \\300 400 m 300 700 l S
        \\
    ;
    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n");
    try writer.print(
        "<< /Type /XObject /Subtype 6 0 R /FormType 1 " ++
            "/BBox [100 400 400 700] /Matrix [1 0 0 1 0 0] /Length {} >>\n",
        .{form_content.len},
    );
    try writer.writeAll("stream\n");
    try writer.writeAll(form_content);
    try writer.writeAll("endstream\nendobj\n");

    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n/Form\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 7\n");
    try writer.print("{d:0>10} 65535 f \n", .{@as(u64, 0)});
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});

    try writer.writeAll("trailer\n<< /Size 7 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF whose content invokes a Form XObject by an escaped
/// name (`/Fm#31 Do` for `/Fm1`). Per ISO 32000-1 §7.3.5, names in
/// content streams may use `#` + 2 hex digits to escape characters.
/// The dictionary parser decodes name keys but the content-stream
/// lexer does not, so lattice must decode at the lookup boundary
/// (Codex review v1.2-rc4 round 20 [P2]).
pub fn generateFormXObjectEscapedNamePdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    // Page Resources expose `/Fm1` (decoded form). Page content
    // invokes `/Fm#31 Do` (escaped).
    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n");
    try writer.writeAll("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R ");
    try writer.writeAll("/Resources << /XObject << /Fm1 5 0 R >> >> >>\n");
    try writer.writeAll("endobj\n");

    const page_content = "/Fm#31 Do\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n", .{page_content.len});
    try writer.writeAll(page_content);
    try writer.writeAll("\nendstream\nendobj\n");

    const form_content =
        \\100 400 300 300 re S
        \\100 500 m 400 500 l S
        \\100 600 m 400 600 l S
        \\200 400 m 200 700 l S
        \\300 400 m 300 700 l S
        \\
    ;
    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n");
    try writer.print(
        "<< /Type /XObject /Subtype /Form /FormType 1 " ++
            "/BBox [100 400 400 700] /Matrix [1 0 0 1 0 0] /Length {} >>\n",
        .{form_content.len},
    );
    try writer.writeAll("stream\n");
    try writer.writeAll(form_content);
    try writer.writeAll("endstream\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 6\n");
    try writer.print("{d:0>10} 65535 f \n", .{@as(u64, 0)});
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});

    try writer.writeAll("trailer\n<< /Size 6 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Three-level Form XObject nesting that exercises ISO 32000-1
/// §7.8.3 page-resource fallback (Codex review v1.2-rc4 round 17 [P2]).
///
/// Layout:
///   - Page /Resources/XObject: { OuterForm 5, InnerGrid 6 }
///       (page-level /InnerGrid is a 3x3 grid)
///   - OuterForm /Resources/XObject: { MidForm 7, InnerGrid 8 }
///       (OuterForm shadows /InnerGrid with a 4x4 grid in obj 8)
///   - OuterForm content: `/MidForm Do`
///   - MidForm /Resources: null   ← absent per §7.3.9
///   - MidForm content: `/InnerGrid Do`
///
/// When MidForm executes `/InnerGrid Do`, the spec requires falling
/// back to the PAGE Resources (not OuterForm's shadowed map), so
/// /InnerGrid resolves to obj 6 — the 3x3 grid. With the OLD
/// caller-fallback behavior the resolution would chase OuterForm's
/// shadow (obj 8) and produce a 4x4 grid instead.
///
/// PDFBox and MuPDF both implement page-fallback; pdf.js historically
/// did not. This fixture proves pdf.zig matches the spec.
///
/// Object map:
///   1. Catalog
///   2. Pages
///   3. Page (XObject /OuterForm 5 + /InnerGrid 6)
///   4. Page content stream (`/OuterForm Do`)
///   5. OuterForm — Resources/XObject /MidForm 7 + /InnerGrid 8
///   6. Page-level /InnerGrid — 3x3 grid (the SPEC-CORRECT detection)
///   7. MidForm — /Resources null, content `/InnerGrid Do`
///   8. OuterForm-shadow /InnerGrid — 4x4 grid (the WRONG detection)
pub fn generateFormXObjectShadowedXObjectPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n");
    try writer.writeAll("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R ");
    try writer.writeAll("/Resources << /XObject << /OuterForm 5 0 R /InnerGrid 6 0 R >> >> >>\n");
    try writer.writeAll("endobj\n");

    const page_content = "/OuterForm Do\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n", .{page_content.len});
    try writer.writeAll(page_content);
    try writer.writeAll("\nendstream\nendobj\n");

    // OuterForm has its OWN /Resources that shadows /InnerGrid with
    // obj 8 (a 4x4 grid). It also exposes /MidForm = obj 7. Body
    // calls MidForm.
    const outer_content = "/MidForm Do\n";
    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n");
    try writer.print(
        "<< /Type /XObject /Subtype /Form /FormType 1 " ++
            "/BBox [0 0 612 792] /Matrix [1 0 0 1 0 0] " ++
            "/Resources << /XObject << /MidForm 7 0 R /InnerGrid 8 0 R >> >> " ++
            "/Length {} >>\n",
        .{outer_content.len},
    );
    try writer.writeAll("stream\n");
    try writer.writeAll(outer_content);
    try writer.writeAll("endstream\nendobj\n");

    // Page-level /InnerGrid: a 3x3 grid — what the SPEC says we
    // should detect (page-fallback).
    const page_inner =
        \\100 400 300 300 re S
        \\100 500 m 400 500 l S
        \\100 600 m 400 600 l S
        \\200 400 m 200 700 l S
        \\300 400 m 300 700 l S
        \\
    ;
    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n");
    try writer.print(
        "<< /Type /XObject /Subtype /Form /FormType 1 " ++
            "/BBox [100 400 400 700] /Matrix [1 0 0 1 0 0] /Length {} >>\n",
        .{page_inner.len},
    );
    try writer.writeAll("stream\n");
    try writer.writeAll(page_inner);
    try writer.writeAll("endstream\nendobj\n");

    // MidForm: /Resources null (so resolution must fall back somewhere).
    // Body invokes /InnerGrid. With round-17 page-fallback this
    // resolves to obj 6 (page); with the old caller-fallback it would
    // resolve to obj 8 (OuterForm shadow).
    const mid_content = "/InnerGrid Do\n";
    const obj7_offset = pdf.items.len;
    try writer.writeAll("7 0 obj\n");
    try writer.print(
        "<< /Type /XObject /Subtype /Form /FormType 1 " ++
            "/BBox [0 0 612 792] /Matrix [1 0 0 1 0 0] /Resources null " ++
            "/Length {} >>\n",
        .{mid_content.len},
    );
    try writer.writeAll("stream\n");
    try writer.writeAll(mid_content);
    try writer.writeAll("endstream\nendobj\n");

    // OuterForm-shadow /InnerGrid: a 4x4 grid — the WRONG detection
    // (would only fire if MidForm's null /Resources fell back to
    // OuterForm's resources instead of the page's).
    const shadow_inner =
        \\100 400 300 300 re S
        \\100 475 m 400 475 l S
        \\100 550 m 400 550 l S
        \\100 625 m 400 625 l S
        \\175 400 m 175 700 l S
        \\250 400 m 250 700 l S
        \\325 400 m 325 700 l S
        \\
    ;
    const obj8_offset = pdf.items.len;
    try writer.writeAll("8 0 obj\n");
    try writer.print(
        "<< /Type /XObject /Subtype /Form /FormType 1 " ++
            "/BBox [100 400 400 700] /Matrix [1 0 0 1 0 0] /Length {} >>\n",
        .{shadow_inner.len},
    );
    try writer.writeAll("stream\n");
    try writer.writeAll(shadow_inner);
    try writer.writeAll("endstream\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 9\n");
    try writer.print("{d:0>10} 65535 f \n", .{@as(u64, 0)});
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj7_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj8_offset});

    try writer.writeAll("trailer\n<< /Size 9 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF where the outer Form XObject sets `/Resources null`.
/// Per PDF 32000-1 §7.3.9, a `null` dictionary value is equivalent to
/// the entry being absent, so the form INHERITS its parent's
/// resources (the page-level /XObject map). The nested /InnerGrid
/// Do should resolve and produce a 3x3 lattice table.
///
/// Codex review v1.2-rc4 round 16 [P2]: spec-conform behavior for
/// `null`-valued /Resources.
pub fn generateFormXObjectNullResourcesPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n");
    try writer.writeAll("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R ");
    try writer.writeAll("/Resources << /XObject << /OuterForm 5 0 R /InnerGrid 6 0 R >> >> >>\n");
    try writer.writeAll("endobj\n");

    const page_content = "/OuterForm Do\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n", .{page_content.len});
    try writer.writeAll(page_content);
    try writer.writeAll("\nendstream\nendobj\n");

    const outer_content = "/InnerGrid Do\n";
    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n");
    try writer.print(
        "<< /Type /XObject /Subtype /Form /FormType 1 " ++
            "/BBox [0 0 612 792] /Matrix [1 0 0 1 0 0] /Resources null " ++
            "/Length {} >>\n",
        .{outer_content.len},
    );
    try writer.writeAll("stream\n");
    try writer.writeAll(outer_content);
    try writer.writeAll("endstream\nendobj\n");

    const inner_content =
        \\100 400 300 300 re S
        \\100 500 m 400 500 l S
        \\100 600 m 400 600 l S
        \\200 400 m 200 700 l S
        \\300 400 m 300 700 l S
        \\
    ;
    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n");
    try writer.print(
        "<< /Type /XObject /Subtype /Form /FormType 1 " ++
            "/BBox [100 400 400 700] /Matrix [1 0 0 1 0 0] /Length {} >>\n",
        .{inner_content.len},
    );
    try writer.writeAll("stream\n");
    try writer.writeAll(inner_content);
    try writer.writeAll("endstream\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 7\n");
    try writer.print("{d:0>10} 65535 f \n", .{@as(u64, 0)});
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});

    try writer.writeAll("trailer\n<< /Size 7 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF where the outer Form XObject sets `/Resources 42`
/// (a non-null, non-dict, non-reference malformed value). Per PDF
/// 32000-1 §7.3.9, `null` is equivalent to "entry omitted" so it
/// would correctly inherit; this fixture instead uses an integer to
/// exercise the genuine fail-closed leg. Round 9 [P2] introduced
/// fail-closed for any non-dict; round 16 [P2] narrowed it to
/// non-null-non-dict per spec.
///
/// Layout:
///   1. Catalog
///   2. Pages
///   3. Page (XObject map exposes /OuterForm 5 0 R AND /InnerGrid 6 0 R)
///   4. Page content (`/OuterForm Do`)
///   5. OuterForm — /Resources 42 (integer, non-dict, non-null).
///      Content invokes `/InnerGrid Do`.
///      A buggy walker would inherit page Resources and find
///      /InnerGrid 6 0 R there, drawing its 3x3 grid. The correct
///      walker fails closed at the first nested Do.
///   6. InnerGrid — draws a 3x3 grid in user-space [100, 400, 400, 700].
///
/// Expected: zero detected tables on page 1.
pub fn generateFormXObjectMalformedResourcesPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n");
    try writer.writeAll("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R ");
    try writer.writeAll("/Resources << /XObject << /OuterForm 5 0 R /InnerGrid 6 0 R >> >> >>\n");
    try writer.writeAll("endobj\n");

    const page_content = "/OuterForm Do\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n", .{page_content.len});
    try writer.writeAll(page_content);
    try writer.writeAll("\nendstream\nendobj\n");

    // OuterForm with non-null malformed /Resources (integer 42). A
    // correct walker must NOT inherit page-level /XObject ->
    // /InnerGrid here. Note: a `null` value would be spec-equivalent
    // to omitting /Resources, which DOES inherit; that's a separate
    // test case ("treats /Resources null as inherited").
    const outer_content = "/InnerGrid Do\n";
    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n");
    try writer.print(
        "<< /Type /XObject /Subtype /Form /FormType 1 " ++
            "/BBox [0 0 612 792] /Matrix [1 0 0 1 0 0] /Resources 42 " ++
            "/Length {} >>\n",
        .{outer_content.len},
    );
    try writer.writeAll("stream\n");
    try writer.writeAll(outer_content);
    try writer.writeAll("endstream\nendobj\n");

    // InnerGrid draws a 3x3 grid. Reachable from page Resources but
    // NOT from a malformed-Resources form.
    const inner_content =
        \\100 400 300 300 re S
        \\100 500 m 400 500 l S
        \\100 600 m 400 600 l S
        \\200 400 m 200 700 l S
        \\300 400 m 300 700 l S
        \\
    ;
    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n");
    try writer.print(
        "<< /Type /XObject /Subtype /Form /FormType 1 " ++
            "/BBox [100 400 400 700] /Matrix [1 0 0 1 0 0] /Length {} >>\n",
        .{inner_content.len},
    );
    try writer.writeAll("stream\n");
    try writer.writeAll(inner_content);
    try writer.writeAll("endstream\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 7\n");
    try writer.print("{d:0>10} 65535 f \n", .{@as(u64, 0)});
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});

    try writer.writeAll("trailer\n<< /Size 7 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF where the Form XObject's `/BBox` and `/Matrix` arrays
/// contain INDIRECT element references — e.g. `/BBox [11 0 R 12 0 R
/// 13 0 R 14 0 R]`. Per PDF spec §7.3.10, indirect references are legal
/// inside numeric arrays. Lattice's readBBox / readMatrix must resolve
/// each element through `resolveRefSoft` before consuming.
///
/// Object layout:
///   1. Catalog
///   2. Pages
///   3. Page (XObject /TableForm 5 0 R)
///   4. Page content stream (`/TableForm Do`)
///   5. Form — /BBox built from refs 6/7/8/9; /Matrix from refs 10–15
///      Content draws 3x3 grid at form-space [100, 400, 400, 700].
///   6. integer 100 (BBox x_min)
///   7. integer 400 (BBox y_min)
///   8. integer 400 (BBox x_max)
///   9. integer 700 (BBox y_max)
///   10. real 1.0  (Matrix a)
///   11. real 0.0  (Matrix b)
///   12. real 0.0  (Matrix c)
///   13. real 1.0  (Matrix d)
///   14. integer 30 (Matrix e — translates +30 in x)
///   15. integer 0  (Matrix f)
///
/// Detected bbox (post-translation): [130, 400, 430, 700].
/// Without indirect-element resolution: BBox returns null (no clip)
/// AND Matrix returns identity, so bbox lands at [100, 400, 400, 700]
/// — that's the regression we're catching.
pub fn generateFormXObjectIndirectArrayElementsPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n");
    try writer.writeAll("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R ");
    try writer.writeAll("/Resources << /XObject << /TableForm 5 0 R >> >> >>\n");
    try writer.writeAll("endobj\n");

    const page_content = "/TableForm Do\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n", .{page_content.len});
    try writer.writeAll(page_content);
    try writer.writeAll("\nendstream\nendobj\n");

    const form_content =
        \\100 400 300 300 re S
        \\100 500 m 400 500 l S
        \\100 600 m 400 600 l S
        \\200 400 m 200 700 l S
        \\300 400 m 300 700 l S
        \\
    ;
    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n");
    try writer.print(
        "<< /Type /XObject /Subtype /Form /FormType 1 " ++
            "/BBox [6 0 R 7 0 R 8 0 R 9 0 R] " ++
            "/Matrix [10 0 R 11 0 R 12 0 R 13 0 R 14 0 R 15 0 R] " ++
            "/Length {} >>\n",
        .{form_content.len},
    );
    try writer.writeAll("stream\n");
    try writer.writeAll(form_content);
    try writer.writeAll("endstream\nendobj\n");

    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n100\nendobj\n");
    const obj7_offset = pdf.items.len;
    try writer.writeAll("7 0 obj\n400\nendobj\n");
    const obj8_offset = pdf.items.len;
    try writer.writeAll("8 0 obj\n400\nendobj\n");
    const obj9_offset = pdf.items.len;
    try writer.writeAll("9 0 obj\n700\nendobj\n");
    const obj10_offset = pdf.items.len;
    try writer.writeAll("10 0 obj\n1.0\nendobj\n");
    const obj11_offset = pdf.items.len;
    try writer.writeAll("11 0 obj\n0.0\nendobj\n");
    const obj12_offset = pdf.items.len;
    try writer.writeAll("12 0 obj\n0.0\nendobj\n");
    const obj13_offset = pdf.items.len;
    try writer.writeAll("13 0 obj\n1.0\nendobj\n");
    const obj14_offset = pdf.items.len;
    try writer.writeAll("14 0 obj\n30\nendobj\n");
    const obj15_offset = pdf.items.len;
    try writer.writeAll("15 0 obj\n0\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 16\n");
    try writer.print("{d:0>10} 65535 f \n", .{@as(u64, 0)});
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj7_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj8_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj9_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj10_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj11_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj12_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj13_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj14_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj15_offset});

    try writer.writeAll("trailer\n<< /Size 16 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF whose Form XObject draws a 3x3 ruled grid that
/// extends WAY past its declared `/BBox`, plus a separate fully-out-of-
/// BBox grid. Tests two clipping behaviours:
///
/// 1. The fully-outside grid (y=50..350) must be DROPPED entirely.
/// 2. The boundary-crossing strokes of the inside grid must be CLAMPED
///    to the BBox so the detected table's bbox doesn't extend past the
///    visible region.
///
/// Inside grid: outer rect at [100, 400, 700, 700] — 600pt wide, but
/// the BBox is only [100, 400, 400, 700]. Without per-stroke clipping
/// the detected bbox would have x1 ≈ 700; with proper clipping it
/// must be ≤ ~402 (BBox right edge + tolerance).
///
/// Outside grid: a separate 3x3 at y=50..350 — must produce 0 tables.
pub fn generateFormXObjectBBoxClippedPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n");
    try writer.writeAll("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R ");
    try writer.writeAll("/Resources << /XObject << /TableForm 5 0 R >> >> >>\n");
    try writer.writeAll("endobj\n");

    const page_content = "/TableForm Do\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n", .{page_content.len});
    try writer.writeAll(page_content);
    try writer.writeAll("\nendstream\nendobj\n");

    // Inside grid: clean 300x300 outer rect at the BBox extent
    // [100,400,400,700]. The two interior horizontal separators are
    // drawn OVERSIZED — from x=100 to x=700, way past the BBox right
    // edge. Round-5 clipping must clamp them to x=400 so the table's
    // detected bbox doesn't extend past the visible region.
    //
    // Two interior verticals at x=200, x=300. The result post-clip is
    // a 3x3 grid bounded at [100, 400, 400, 700].
    //
    // Outside grid: separate 3x3 at y=50..350, entirely below the
    // BBox bottom. Round-4 clipping must drop it whole.
    const form_content =
        \\100 400 300 300 re S
        \\100 500 m 700 500 l S
        \\100 600 m 700 600 l S
        \\200 400 m 200 700 l S
        \\300 400 m 300 700 l S
        \\100 50 300 300 re S
        \\100 150 m 400 150 l S
        \\100 250 m 400 250 l S
        \\200 50 m 200 350 l S
        \\300 50 m 300 350 l S
        \\
    ;
    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n");
    try writer.print(
        "<< /Type /XObject /Subtype /Form /FormType 1 " ++
            "/BBox [100 400 400 700] /Matrix [1 0 0 1 0 0] /Length {} >>\n",
        .{form_content.len},
    );
    try writer.writeAll("stream\n");
    try writer.writeAll(form_content);
    try writer.writeAll("endstream\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 6\n");
    try writer.print("{d:0>10} 65535 f \n", .{@as(u64, 0)});
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});

    try writer.writeAll("trailer\n<< /Size 6 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF where Form XObject A's content stream invokes itself
/// via `/SelfForm Do`. The cycle guard in lattice.collectStrokesIn must
/// catch this and bail before stack overflow / hang.
///
/// The Form draws a single rect so we can also verify that the FIRST
/// invocation (depth 0) successfully collects strokes before the cycle
/// is detected on the recursive Do.
pub fn generateFormXObjectSelfReferencingPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n");
    try writer.writeAll("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R ");
    try writer.writeAll("/Resources << /XObject << /SelfForm 5 0 R >> >> >>\n");
    try writer.writeAll("endobj\n");

    const page_content = "/SelfForm Do\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n", .{page_content.len});
    try writer.writeAll(page_content);
    try writer.writeAll("\nendstream\nendobj\n");

    // SelfForm — content stream draws ONE rect, then invokes itself.
    // The Form's own Resources expose itself as /SelfForm so the
    // recursive `Do` resolves back to the same XObject (object 5).
    const form_content =
        \\100 400 300 300 re S
        \\/SelfForm Do
        \\
    ;
    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n");
    try writer.print(
        "<< /Type /XObject /Subtype /Form /FormType 1 " ++
            "/BBox [100 400 400 700] /Matrix [1 0 0 1 0 0] " ++
            "/Resources << /XObject << /SelfForm 5 0 R >> >> " ++
            "/Length {} >>\n",
        .{form_content.len},
    );
    try writer.writeAll("stream\n");
    try writer.writeAll(form_content);
    try writer.writeAll("endstream\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 6\n");
    try writer.print("{d:0>10} 65535 f \n", .{@as(u64, 0)});
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});

    try writer.writeAll("trailer\n<< /Size 6 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF where the page references an XObject whose Subtype
/// is `/Image` (NOT `/Form`). Lattice must NOT recurse into image
/// XObjects; non-Form subtypes are silently ignored.
pub fn generateImageXObjectIgnoredByLatticePdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n");
    try writer.writeAll("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R ");
    try writer.writeAll("/Resources << /XObject << /Im1 5 0 R >> >> >>\n");
    try writer.writeAll("endobj\n");

    // Page draws a real ruled table inline AND invokes the Image XObject.
    const page_content =
        \\100 400 300 300 re S
        \\100 500 m 400 500 l S
        \\100 600 m 400 600 l S
        \\200 400 m 200 700 l S
        \\300 400 m 300 700 l S
        \\/Im1 Do
        \\
    ;
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n", .{page_content.len});
    try writer.writeAll(page_content);
    try writer.writeAll("\nendstream\nendobj\n");

    // /Im1 is an Image XObject. If lattice mistakenly recursed into the
    // body it would parse the random image bytes as a content stream;
    // we keep the body short and harmless.
    const image_data = "fake-image-bytes";
    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n");
    try writer.print(
        "<< /Type /XObject /Subtype /Image /Width 1 /Height 1 " ++
            "/ColorSpace /DeviceGray /BitsPerComponent 8 /Length {} >>\n",
        .{image_data.len},
    );
    try writer.writeAll("stream\n");
    try writer.writeAll(image_data);
    try writer.writeAll("\nendstream\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 6\n");
    try writer.print("{d:0>10} 65535 f \n", .{@as(u64, 0)});
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});

    try writer.writeAll("trailer\n<< /Size 6 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Like `generateFormXObjectTablePdf`, but the outer Form XObject stores
/// both `/Matrix` and `/Resources` as indirect references rather than
/// inline objects. The outer form delegates the actual table drawing to
/// a NESTED Form XObject (`/InnerForm`), reachable ONLY via the indirect
/// `/Resources` lookup. This makes the indirect-ref Resources path
/// load-bearing: if lattice fails to resolve `/Resources 7 0 R`, the
/// nested `/InnerForm Do` cannot be resolved and zero strokes are
/// collected, which the integration test catches.
///
/// Object layout:
///   1. Catalog
///   2. Pages
///   3. Page (Resources/XObject -> 5 0 R inline)
///   4. Page content stream (`/TableForm Do`)
///   5. Outer Form — /Matrix 6 0 R, /Resources 7 0 R, content invokes
///      `/InnerForm Do`. NO strokes drawn directly.
///   6. The Matrix array — [1 0 0 1 50 0] translates by +50pt in x.
///   7. The Resources dict — { /XObject << /InnerForm 8 0 R >> }
///   8. Inner Form — identity Matrix, content draws the 3x3 grid.
///
/// End-to-end: page invokes outer; outer must resolve indirect Matrix
/// to translate by +50pt; outer must resolve indirect Resources to find
/// /InnerForm; inner draws the grid. Detected bbox: [150, 400, 450, 700].
pub fn generateFormXObjectIndirectRefsPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n");
    try writer.writeAll("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R ");
    try writer.writeAll("/Resources << /XObject << /TableForm 5 0 R >> >> >>\n");
    try writer.writeAll("endobj\n");

    const page_content = "/TableForm Do\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n", .{page_content.len});
    try writer.writeAll(page_content);
    try writer.writeAll("\nendstream\nendobj\n");

    // Outer form delegates to the nested form via `/InnerForm Do`. The
    // /InnerForm name resolves ONLY through the indirect /Resources 7 0 R,
    // so reverting the indirect-Resources fix would make this test fail.
    const outer_form_content = "/InnerForm Do\n";
    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n");
    try writer.print(
        "<< /Type /XObject /Subtype /Form /FormType 1 " ++
            "/BBox [100 400 400 700] /Matrix 6 0 R /Resources 7 0 R " ++
            "/Length {} >>\n",
        .{outer_form_content.len},
    );
    try writer.writeAll("stream\n");
    try writer.writeAll(outer_form_content);
    try writer.writeAll("endstream\nendobj\n");

    // Matrix object — [1 0 0 1 50 0] translates the form by +50pt in x.
    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n[1 0 0 1 50 0]\nendobj\n");

    // Resources object — exposes /InnerForm so the nested Do resolves.
    const obj7_offset = pdf.items.len;
    try writer.writeAll("7 0 obj\n<< /XObject << /InnerForm 8 0 R >> >>\nendobj\n");

    // Inner form — draws the 3x3 ruled grid in form-space.
    const inner_form_content =
        \\100 400 300 300 re S
        \\100 500 m 400 500 l S
        \\100 600 m 400 600 l S
        \\200 400 m 200 700 l S
        \\300 400 m 300 700 l S
        \\
    ;
    const obj8_offset = pdf.items.len;
    try writer.writeAll("8 0 obj\n");
    try writer.print(
        "<< /Type /XObject /Subtype /Form /FormType 1 " ++
            "/BBox [100 400 400 700] /Matrix [1 0 0 1 0 0] /Length {} >>\n",
        .{inner_form_content.len},
    );
    try writer.writeAll("stream\n");
    try writer.writeAll(inner_form_content);
    try writer.writeAll("endstream\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 9\n");
    try writer.print("{d:0>10} 65535 f \n", .{@as(u64, 0)});
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj7_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj8_offset});

    try writer.writeAll("trailer\n<< /Size 9 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// PR-W6.2 [refactor]: UTF-16BE-titled outline fixture via
/// DocumentBuilder. The single outline item carries a hex-string
/// /Title `<FEFF00430061006600E9>` ("Café" in UTF-16BE with BOM) —
/// straight bytes through `setAuxiliaryPayload`, no escaping needed.
pub fn generateUtf16BePdf(allocator: std.mem.Allocator) ![]u8 {
    var doc = document.DocumentBuilder.init(allocator);
    defer doc.deinit();

    const page = try doc.addPage(.{ 0, 0, 612, 792 });
    try page.drawText(100, 700, .helvetica, 12, "UTF16 test");

    const outlines = try doc.reserveAuxiliaryObject();
    const item = try doc.reserveAuxiliaryObject();

    var buf: [192]u8 = undefined;
    try doc.setAuxiliaryPayload(outlines, try std.fmt.bufPrint(
        &buf,
        "<< /Type /Outlines /First {d} 0 R /Last {d} 0 R /Count 1 >>",
        .{ item, item },
    ));
    try doc.setAuxiliaryPayload(item, try std.fmt.bufPrint(
        &buf,
        "<< /Title <FEFF00430061006600E9> /Parent {d} 0 R /Dest [{d} 0 R /Fit] >>",
        .{ outlines, page.objNum() },
    ));

    var extras_buf: [64]u8 = undefined;
    try doc.setCatalogExtras(try std.fmt.bufPrint(&extras_buf, "/Outlines {d} 0 R", .{outlines}));

    return doc.write();
}

/// PR-3: a single-page tagged PDF with a 2-row × 3-column table.
/// Each /TD element points at one MCID (0..5); the page content
/// stream wraps each glyph run in `/TD <</MCID N>> BDC ... EMC` so
/// the lattice/Pass-A path can resolve cell text by MCID lookup.
///
/// Cell texts (gold):
///   r0:  "A1"  "B1"  "C1"
///   r1:  "A2"  "B2"  "C2"
///
/// Object layout:
///   1. Catalog (/StructTreeRoot 6 0 R)
///   2. Pages
///   3. Page (/StructParents 0)
///   4. Page content stream — six BDC/EMC cells with Tm-positioned text
///   5. Font /F1 (Helvetica)
///   6. StructTreeRoot (/K [7 0 R])
///   7. Table element (/S /Table /K [8 0 R 9 0 R])
///   8. TR row 0 (/S /TR /K [10 0 R 11 0 R 12 0 R])
///   9. TR row 1 (/S /TR /K [13 0 R 14 0 R 15 0 R])
///   10..15. TD cells, each with /K [N] (MCID 0..5) and /Pg 3 0 R
pub fn generateTaggedTablePdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 6 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n");
    try writer.writeAll("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> ");
    try writer.writeAll("/StructParents 0 >>\n");
    try writer.writeAll("endobj\n");

    // Six cells: BDC per MCID, Tm absolute position, Tj single string,
    // EMC. The text matrix is reset between cells via Tm so they don't
    // drift relative to one another.
    const content =
        \\BT
        \\/F1 12 Tf
        \\/TD <</MCID 0>> BDC
        \\1 0 0 1 100 700 Tm
        \\(A1) Tj
        \\EMC
        \\/TD <</MCID 1>> BDC
        \\1 0 0 1 200 700 Tm
        \\(B1) Tj
        \\EMC
        \\/TD <</MCID 2>> BDC
        \\1 0 0 1 300 700 Tm
        \\(C1) Tj
        \\EMC
        \\/TD <</MCID 3>> BDC
        \\1 0 0 1 100 680 Tm
        \\(A2) Tj
        \\EMC
        \\/TD <</MCID 4>> BDC
        \\1 0 0 1 200 680 Tm
        \\(B2) Tj
        \\EMC
        \\/TD <</MCID 5>> BDC
        \\1 0 0 1 300 680 Tm
        \\(C2) Tj
        \\EMC
        \\ET
        \\
    ;
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n", .{content.len});
    try writer.writeAll(content);
    try writer.writeAll("\nendstream\nendobj\n");

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n");
    try writer.writeAll("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    const obj6_offset = pdf.items.len;
    // /K is a single reference (not an array). pdf.zig's
    // parseStructElement accepts dict/ref at the root but not array;
    // PDF spec §14.7.4 allows both forms — this fixture uses the
    // single-ref form to match the parser's current shape.
    try writer.writeAll("6 0 obj\n<< /Type /StructTreeRoot /K 7 0 R >>\nendobj\n");

    const obj7_offset = pdf.items.len;
    try writer.writeAll("7 0 obj\n<< /S /Table /P 6 0 R /K [8 0 R 9 0 R] >>\nendobj\n");

    const obj8_offset = pdf.items.len;
    try writer.writeAll("8 0 obj\n<< /S /TR /P 7 0 R /K [10 0 R 11 0 R 12 0 R] >>\nendobj\n");

    const obj9_offset = pdf.items.len;
    try writer.writeAll("9 0 obj\n<< /S /TR /P 7 0 R /K [13 0 R 14 0 R 15 0 R] >>\nendobj\n");

    var td_offsets: [6]u64 = undefined;
    inline for (0..6) |i| {
        td_offsets[i] = pdf.items.len;
        try writer.print(
            "{} 0 obj\n<< /S /TD /P {} 0 R /Pg 3 0 R /K [{}] >>\nendobj\n",
            .{ 10 + i, if (i < 3) @as(u32, 8) else @as(u32, 9), i },
        );
    }

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 16\n");
    try writer.print("{d:0>10} 65535 f \n", .{@as(u64, 0)});
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj7_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj8_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj9_offset});
    inline for (0..6) |i| {
        try writer.print("{d:0>10} 00000 n \n", .{td_offsets[i]});
    }

    try writer.writeAll("trailer\n<< /Size 16 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// PR-3 [P2 round 1]: tagged 2x3 table whose TD cells nest their
/// content under /P (Paragraph) elements rather than placing MCIDs
/// directly on the TD. Per ISO 32000-1 §14.7.4 this is legal and
/// common; Pass A's cell-text walker must descend into structure
/// elements, not just leaf .mcid children.
///
/// Layout matches generateTaggedTablePdf except each TD has /K [P 0 R]
/// (a single child element ref) and the P element has /K [N] for the
/// MCID. Object range: 1..21 (six TDs + six Ps).
pub fn generateTaggedTableNestedPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 6 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n");
    try writer.writeAll("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> ");
    try writer.writeAll("/StructParents 0 >>\n");
    try writer.writeAll("endobj\n");

    const content =
        \\BT
        \\/F1 12 Tf
        \\/P <</MCID 0>> BDC
        \\1 0 0 1 100 700 Tm
        \\(N1) Tj
        \\EMC
        \\/P <</MCID 1>> BDC
        \\1 0 0 1 200 700 Tm
        \\(N2) Tj
        \\EMC
        \\/P <</MCID 2>> BDC
        \\1 0 0 1 300 700 Tm
        \\(N3) Tj
        \\EMC
        \\/P <</MCID 3>> BDC
        \\1 0 0 1 100 680 Tm
        \\(N4) Tj
        \\EMC
        \\/P <</MCID 4>> BDC
        \\1 0 0 1 200 680 Tm
        \\(N5) Tj
        \\EMC
        \\/P <</MCID 5>> BDC
        \\1 0 0 1 300 680 Tm
        \\(N6) Tj
        \\EMC
        \\ET
        \\
    ;
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n", .{content.len});
    try writer.writeAll(content);
    try writer.writeAll("\nendstream\nendobj\n");

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>\nendobj\n");

    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n<< /Type /StructTreeRoot /K 7 0 R >>\nendobj\n");

    const obj7_offset = pdf.items.len;
    try writer.writeAll("7 0 obj\n<< /S /Table /P 6 0 R /K [8 0 R 9 0 R] >>\nendobj\n");

    const obj8_offset = pdf.items.len;
    try writer.writeAll("8 0 obj\n<< /S /TR /P 7 0 R /K [10 0 R 11 0 R 12 0 R] >>\nendobj\n");

    const obj9_offset = pdf.items.len;
    try writer.writeAll("9 0 obj\n<< /S /TR /P 7 0 R /K [13 0 R 14 0 R 15 0 R] >>\nendobj\n");

    // TDs 10..15 each point at one P (16..21). TDs carry no MCID
    // directly; the P holds it. /Pg is on the TD level so descendant
    // page-ref fallback can find page=1.
    var td_offsets: [6]u64 = undefined;
    inline for (0..6) |i| {
        td_offsets[i] = pdf.items.len;
        try writer.print(
            "{} 0 obj\n<< /S /TD /P {} 0 R /Pg 3 0 R /K [{} 0 R] >>\nendobj\n",
            .{ 10 + i, if (i < 3) @as(u32, 8) else @as(u32, 9), 16 + i },
        );
    }

    // Ps 16..21 each hold the actual MCID for their cell.
    var p_offsets: [6]u64 = undefined;
    inline for (0..6) |i| {
        p_offsets[i] = pdf.items.len;
        try writer.print(
            "{} 0 obj\n<< /S /P /P {} 0 R /K [{}] >>\nendobj\n",
            .{ 16 + i, 10 + i, i },
        );
    }

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 22\n");
    try writer.print("{d:0>10} 65535 f \n", .{@as(u64, 0)});
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj7_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj8_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj9_offset});
    inline for (0..6) |i| {
        try writer.print("{d:0>10} 00000 n \n", .{td_offsets[i]});
    }
    inline for (0..6) |i| {
        try writer.print("{d:0>10} 00000 n \n", .{p_offsets[i]});
    }

    try writer.writeAll("trailer\n<< /Size 22 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// PR-2: a 2-page PDF with one ruled 3x3 table per page, BOTH placed
/// in the vertical middle of their respective pages — neither sits
/// near the page-boundary band that linkContinuations now requires.
/// Without the bbox-y constraint these would be linked (col counts
/// match, table_b is first on its page); with the constraint they
/// stay independent.
///
/// Page dimensions: 612 x 792 (US Letter).
/// Both tables: 300 x 100 with outer rect at y=350 (≈ middle).
///   - For page 1: a.bbox.y0=350, gap to media_box.y_min=0 is 350.
///     20% of 792 = 158.4. Gap > band → not near bottom → no link.
///   - For page 2: b.bbox.y1=450, gap to media_box.y_max=792 is 342.
///     Same reason — not near top.
pub fn generateTwoUnrelatedTablesPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>\nendobj\n");

    // Both tables: 3x3 ruled grid, 300 wide × 100 tall, at y0=350.
    const table_content =
        \\100 350 300 100 re S
        \\100 383 m 400 383 l S
        \\100 416 m 400 416 l S
        \\200 350 m 200 450 l S
        \\300 350 m 300 450 l S
        \\
    ;
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n", .{table_content.len});
    try writer.writeAll(table_content);
    try writer.writeAll("\nendstream\nendobj\n");

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R >>\nendobj\n");

    const obj6_offset = pdf.items.len;
    try writer.print("6 0 obj\n<< /Length {} >>\nstream\n", .{table_content.len});
    try writer.writeAll(table_content);
    try writer.writeAll("\nendstream\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 7\n");
    try writer.print("{d:0>10} 65535 f \n", .{@as(u64, 0)});
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});

    try writer.writeAll("trailer\n<< /Size 7 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// PR-2 positive case: a 2-page PDF with one ruled 3x3 table per page,
/// BOTH placed in their respective near-boundary band — table_a is
/// at the bottom of page 1, table_b is at the top of page 2. With
/// matching column counts and the new bbox-y constraint satisfied,
/// linkContinuations chains them.
///
/// Page dimensions: 612 x 792 (US Letter); 20% band = 158.4.
///   - table_a: outer rect at y=20, height 100 → y0=20 (gap 20 from
///     page bottom 0). Gap < 158.4 → near bottom → ok.
///   - table_b: outer rect at y=672, height 100 → y1=772 (gap 20
///     from page top 792). Gap < 158.4 → near top → ok.
pub fn generateLinkedContinuationTablesPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>\nendobj\n");

    // table_a — bottom of page 1: y0=20, y1=120.
    const table_a =
        \\100 20 300 100 re S
        \\100 53 m 400 53 l S
        \\100 86 m 400 86 l S
        \\200 20 m 200 120 l S
        \\300 20 m 300 120 l S
        \\
    ;
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n", .{table_a.len});
    try writer.writeAll(table_a);
    try writer.writeAll("\nendstream\nendobj\n");

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R >>\nendobj\n");

    // table_b — top of page 2: y0=672, y1=772.
    const table_b =
        \\100 672 300 100 re S
        \\100 705 m 400 705 l S
        \\100 738 m 400 738 l S
        \\200 672 m 200 772 l S
        \\300 672 m 300 772 l S
        \\
    ;
    const obj6_offset = pdf.items.len;
    try writer.print("6 0 obj\n<< /Length {} >>\nstream\n", .{table_b.len});
    try writer.writeAll(table_b);
    try writer.writeAll("\nendstream\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 7\n");
    try writer.print("{d:0>10} 65535 f \n", .{@as(u64, 0)});
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});

    try writer.writeAll("trailer\n<< /Size 7 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// PR-4: a single-page PDF with a 4-row × 3-column ruled table and
/// positioned text per cell. The lattice/Pass-B path detects the
/// grid via stroke clustering and populates each cell's `.text`
/// by intersecting glyph centers against the cell bbox.
///
/// Grid geometry (PDF user-space, y increases upward):
///   - Outer rect: x = 100..400, y = 100..400 (300x300)
///   - row_lines (after clusterByCoord, sorted asc): 100, 175, 250, 325, 400
///   - col_lines: 100, 200, 300, 400
///   - 4 rows × 3 cols = 12 cells, each 100 wide × 75 tall
///
/// Cell text — per the existing lattice convention (r=0 = bottom
/// row, c=0 = left col):
///   r=0 (y=100..175): "00" "01" "02"
///   r=1 (y=175..250): "10" "11" "12"
///   r=2 (y=250..325): "20" "21" "22"
///   r=3 (y=325..400): "30" "31" "32"
///
/// Each glyph is positioned at the cell center via `Tm`. The
/// extractTextWithBounds path emits a TextSpan whose bbox covers
/// the glyph; the center lands inside the cell bbox so glyph-center
/// intersection assigns the span correctly.
pub fn generateLatticeWithTextPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n");
    try writer.writeAll("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\n");
    try writer.writeAll("endobj\n");

    // Build content stream: outer rect + 3 interior horizontals (at
    // y=175, 250, 325) + 2 interior verticals (at x=200, 300) + 12
    // text chunks at cell centers.
    var cs: std.ArrayList(u8) = .empty;
    defer cs.deinit(allocator);
    var csw = cs.writer(allocator);

    try csw.writeAll("100 100 300 300 re S\n"); // outer rect
    try csw.writeAll("100 175 m 400 175 l S\n");
    try csw.writeAll("100 250 m 400 250 l S\n");
    try csw.writeAll("100 325 m 400 325 l S\n");
    try csw.writeAll("200 100 m 200 400 l S\n");
    try csw.writeAll("300 100 m 300 400 l S\n");

    // Cell text. Cell (r, c) center: x = 150 + c*100, y = 137.5 + r*75.
    // Tm at center − (textWidth/2, font_size/2) so the glyph sits
    // visually centered. With 10pt Helvetica, "00" is ~12pt wide;
    // shift by -6 in x and -5 in y from cell center.
    try csw.writeAll("BT /F1 10 Tf\n");
    inline for (0..4) |r| {
        inline for (0..3) |c| {
            const cx: f64 = 150.0 + @as(f64, @floatFromInt(c)) * 100.0;
            const cy: f64 = 137.5 + @as(f64, @floatFromInt(r)) * 75.0;
            try csw.print("1 0 0 1 {d:.1} {d:.1} Tm ({d}{d}) Tj\n", .{ cx - 6, cy - 5, r, c });
        }
    }
    try csw.writeAll("ET\n");

    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n", .{cs.items.len});
    try writer.writeAll(cs.items);
    try writer.writeAll("\nendstream\nendobj\n");

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n");
    try writer.writeAll("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 6\n");
    try writer.print("{d:0>10} 65535 f \n", .{@as(u64, 0)});
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});

    try writer.writeAll("trailer\n<< /Size 6 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}
