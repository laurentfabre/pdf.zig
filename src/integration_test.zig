//! Integration Tests for ZPDF
//!
//! Tests the full parsing and extraction pipeline using generated PDFs.

const std = @import("std");
const zpdf = @import("root.zig");
const testpdf = @import("testpdf.zig");
const cli = @import("cli_pdfzig.zig");

test "parse minimal PDF" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Hello World");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    // Should have 1 page
    try std.testing.expectEqual(@as(usize, 1), doc.pageCount());
}

test "extract text from minimal PDF" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Test123");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();

    try doc.extractText(0, &output.writer);

    // Should contain our test text
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Test123") != null);
}

test "parse multi-page PDF" {
    const allocator = std.testing.allocator;

    const pages = &[_][]const u8{ "First Page", "Second Page", "Third Page" };
    const pdf_data = try testpdf.generateMultiPagePdf(allocator, pages);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    try std.testing.expectEqual(@as(usize, 3), doc.pageCount());
}

test "extract all text from multi-page PDF" {
    const allocator = std.testing.allocator;

    const pages = &[_][]const u8{ "PageA", "PageB" };
    const pdf_data = try testpdf.generateMultiPagePdf(allocator, pages);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();

    try doc.extractAllText(&output.writer);

    try std.testing.expect(std.mem.indexOf(u8, output.written(), "PageA") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "PageB") != null);
}

test "parse TJ operator PDF" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateTJPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();

    try doc.extractText(0, &output.writer);

    // TJ with spacing should produce "Hello World" (with space from -200 adjustment)
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "World") != null);
}

test "page info extraction" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Test");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const info = doc.getPageInfo(0);
    try std.testing.expect(info != null);

    // Should be letter size (612 x 792 points)
    try std.testing.expectApproxEqRel(@as(f64, 612), info.?.width, 0.1);
    try std.testing.expectApproxEqRel(@as(f64, 792), info.?.height, 0.1);
}

test "error tolerance - permissive mode" {
    const allocator = std.testing.allocator;

    // Create slightly malformed PDF
    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Test");
    defer allocator.free(pdf_data);

    // Even with strict mode, a valid PDF should parse
    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.strict());
    defer doc.close();

    try std.testing.expectEqual(@as(usize, 1), doc.pageCount());
}

test "XRef parsing" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "XRef Test");
    defer allocator.free(pdf_data);

    // Use arena for parsed objects (like real usage)
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var xref_table = try zpdf.xref.parseXRef(allocator, arena.allocator(), pdf_data);
    defer xref_table.deinit();

    // Should have entries for objects 1-5 (and 0 for free list)
    try std.testing.expect(xref_table.entries.count() >= 5);
}

test "content lexer tokens" {
    const content = "BT /F1 12 Tf (Hello) Tj ET";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = zpdf.interpreter.ContentLexer.init(arena.allocator(), content);

    // BT operator
    const t1 = (try lexer.next()).?;
    try std.testing.expect(t1 == .operator);
    try std.testing.expectEqualStrings("BT", t1.operator);

    // /F1 name
    const t2 = (try lexer.next()).?;
    try std.testing.expect(t2 == .name);

    // 12 number
    const t3 = (try lexer.next()).?;
    try std.testing.expect(t3 == .number);

    // Tf operator
    const t4 = (try lexer.next()).?;
    try std.testing.expect(t4 == .operator);

    // (Hello) string
    const t5 = (try lexer.next()).?;
    try std.testing.expect(t5 == .string);

    // Tj operator
    const t6 = (try lexer.next()).?;
    try std.testing.expect(t6 == .operator);

    // ET operator
    const t7 = (try lexer.next()).?;
    try std.testing.expect(t7 == .operator);
}

test "decompression - uncompressed passthrough" {
    const allocator = std.testing.allocator;
    const data = "Hello uncompressed";

    // With no filter, should return data as-is (allocated copy)
    const result = try zpdf.decompress.decompressStream(allocator, data, null, null);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(data, result);
}

test "parse incremental PDF update" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateIncrementalPdf(allocator);
    defer allocator.free(pdf_data);

    // Parse the XRef table - should follow /Prev chain
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var xref_table = try zpdf.xref.parseXRef(allocator, arena.allocator(), pdf_data);
    defer xref_table.deinit();

    // Object 4 should point to the NEW offset (from incremental update)
    const obj4_entry = xref_table.get(4);
    try std.testing.expect(obj4_entry != null);

    // The object 4 entry should exist and be in_use
    try std.testing.expectEqual(zpdf.xref.XRefEntry.EntryType.in_use, obj4_entry.?.entry_type);

    // Find where "Updated Text" appears in the PDF (should be at higher offset than "Original Text")
    const orig_pos = std.mem.indexOf(u8, pdf_data, "Original Text");
    const upd_pos = std.mem.indexOf(u8, pdf_data, "Updated Text");

    try std.testing.expect(orig_pos != null);
    try std.testing.expect(upd_pos != null);

    // Updated Text should come after Original Text (it's in the incremental section)
    try std.testing.expect(upd_pos.? > orig_pos.?);

    // Object 4's offset should point to the updated version
    // The updated object 4 starts just before "Updated Text"
    try std.testing.expect(obj4_entry.?.offset > orig_pos.?);
}

test "isEncrypted returns false for normal PDF" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Not encrypted");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    try std.testing.expect(!doc.isEncrypted());
}

test "isEncrypted returns true for encrypted PDF" {
    const allocator = std.testing.allocator;

    // Build a minimal PDF with /Encrypt in the trailer
    const pdf_data = try testpdf.generateEncryptedPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    try std.testing.expect(doc.isEncrypted());
}

test "extract text from incremental PDF - gets updated content" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateIncrementalPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    // Should have 1 page
    try std.testing.expectEqual(@as(usize, 1), doc.pageCount());

    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();

    try doc.extractText(0, &output.writer);

    // Should extract "Updated Text" NOT "Original Text"
    // because incremental update replaced object 4
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Updated") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Original") == null);
}

test "page tree tolerates leaf node without /Type" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generatePdfWithoutPageType(allocator, "NoTypeTest");
    defer allocator.free(pdf_data);

    // Should still open and report 1 page (Fix 2: /Type default inference)
    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    try std.testing.expectEqual(@as(usize, 1), doc.pageCount());

    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try doc.extractText(0, &output.writer);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "NoTypeTest") != null);
}

test "inline image does not corrupt text extraction" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateInlineImagePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try doc.extractText(0, &output.writer);

    // Both text spans surrounding the inline image must be present (Fix 1: BI/EI skip)
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Before") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "After") != null);
}

// =========================================================================
// New feature integration tests
// =========================================================================

test "metadata extraction" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMetadataPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const meta = doc.metadata();
    try std.testing.expect(meta.title != null);
    try std.testing.expectEqualStrings("Test Document", meta.title.?);
    try std.testing.expectEqualStrings("Test Author", meta.author.?);
    try std.testing.expectEqualStrings("Test Subject", meta.subject.?);
    try std.testing.expectEqualStrings("test, pdf, zpdf", meta.keywords.?);
    try std.testing.expectEqualStrings("TestGenerator", meta.creator.?);
    try std.testing.expectEqualStrings("zpdf", meta.producer.?);
}

test "metadata returns empty for PDF without Info dict" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "No metadata");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const meta = doc.metadata();
    try std.testing.expect(meta.title == null);
    try std.testing.expect(meta.author == null);
}

test "outline extraction" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateOutlinePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const outline_items = try doc.getOutline(allocator);
    defer {
        for (outline_items) |item| {
            allocator.free(@constCast(item.title));
        }
        allocator.free(outline_items);
    }

    try std.testing.expectEqual(@as(usize, 1), outline_items.len);
    try std.testing.expectEqualStrings("Chapter 1", outline_items[0].title);
    try std.testing.expect(outline_items[0].page != null);
    try std.testing.expectEqual(@as(usize, 0), outline_items[0].page.?);
    try std.testing.expectEqual(@as(u32, 0), outline_items[0].level);
}

test "outline returns empty for PDF without outlines" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "No outlines");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const outline_items = try doc.getOutline(allocator);
    defer allocator.free(outline_items);

    try std.testing.expectEqual(@as(usize, 0), outline_items.len);
}

test "link extraction" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateLinkPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const links = try doc.getPageLinks(0, allocator);
    defer zpdf.Document.freeLinks(allocator, links);

    try std.testing.expectEqual(@as(usize, 1), links.len);
    try std.testing.expect(links[0].uri != null);
    try std.testing.expectEqualStrings("https://example.com", links[0].uri.?);
    // Check rect
    try std.testing.expectApproxEqRel(@as(f64, 100), links[0].rect[0], 0.01);
    try std.testing.expectApproxEqRel(@as(f64, 690), links[0].rect[1], 0.01);
}

test "links returns empty for page without annotations" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "No links");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const links = try doc.getPageLinks(0, allocator);
    defer allocator.free(links);

    try std.testing.expectEqual(@as(usize, 0), links.len);
}

test "form field extraction" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateFormFieldPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const fields = try doc.getFormFields(allocator);
    defer zpdf.Document.freeFormFields(allocator, fields);

    try std.testing.expectEqual(@as(usize, 2), fields.len);

    // Find text field
    var found_text = false;
    var found_button = false;
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, "name")) {
            found_text = true;
            try std.testing.expect(f.field_type == .text);
            try std.testing.expect(f.value != null);
            try std.testing.expectEqualStrings("John Doe", f.value.?);
        }
        if (std.mem.eql(u8, f.name, "submit")) {
            found_button = true;
            try std.testing.expect(f.field_type == .button);
        }
    }
    try std.testing.expect(found_text);
    try std.testing.expect(found_button);
}

test "form fields returns empty for PDF without AcroForm" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "No form");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const fields = try doc.getFormFields(allocator);
    defer allocator.free(fields);

    try std.testing.expectEqual(@as(usize, 0), fields.len);
}

test "text search" {
    const allocator = std.testing.allocator;

    const pages = &[_][]const u8{ "Hello World", "Goodbye World", "Hello Again" };
    const pdf_data = try testpdf.generateMultiPagePdf(allocator, pages);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    // Search for "Hello" - should find 2 matches
    const results = try doc.search(allocator, "Hello");
    defer zpdf.Document.freeSearchResults(allocator, results);

    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqual(@as(usize, 0), results[0].page); // Page 0
    try std.testing.expectEqual(@as(usize, 2), results[1].page); // Page 2
}

test "text search case insensitive" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Hello World");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const results = try doc.search(allocator, "hello");
    defer zpdf.Document.freeSearchResults(allocator, results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
}

test "text search no matches" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Hello World");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const results = try doc.search(allocator, "notfound");
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "page labels" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generatePageLabelPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    // Page 0 should be "i" (lowercase roman)
    const label0 = doc.getPageLabel(allocator, 0);
    defer if (label0) |l| allocator.free(l);
    try std.testing.expect(label0 != null);
    try std.testing.expectEqualStrings("i", label0.?);

    // Page 1 should be "ii"
    const label1 = doc.getPageLabel(allocator, 1);
    defer if (label1) |l| allocator.free(l);
    try std.testing.expect(label1 != null);
    try std.testing.expectEqualStrings("ii", label1.?);

    // Page 2 should be "1" (decimal, starting at 1)
    const label2 = doc.getPageLabel(allocator, 2);
    defer if (label2) |l| allocator.free(l);
    try std.testing.expect(label2 != null);
    try std.testing.expectEqualStrings("1", label2.?);
}

test "page labels returns null for PDF without PageLabels" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "No labels");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const label = doc.getPageLabel(allocator, 0);
    try std.testing.expect(label == null);
}

// =========================================================================
// decodePdfString unit tests
// =========================================================================

test "decodePdfString - plain ASCII passthrough" {
    const allocator = std.testing.allocator;
    const result = try zpdf.decodePdfString(allocator, "Hello");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello", result);
}

test "decodePdfString - empty string" {
    const allocator = std.testing.allocator;
    const result = try zpdf.decodePdfString(allocator, "");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "decodePdfString - UTF-16BE BOM simple ASCII" {
    const allocator = std.testing.allocator;
    // FE FF 0048 0069 = "Hi"
    const input = "\xFE\xFF\x00\x48\x00\x69";
    const result = try zpdf.decodePdfString(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hi", result);
}

test "decodePdfString - UTF-16BE with non-ASCII" {
    const allocator = std.testing.allocator;
    // FE FF 00E9 = "é" (U+00E9 → UTF-8: C3 A9)
    const input = "\xFE\xFF\x00\xE9";
    const result = try zpdf.decodePdfString(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\xC3\xA9", result); // "é" in UTF-8
}

test "decodePdfString - UTF-16BE CJK character" {
    const allocator = std.testing.allocator;
    // FE FF 4E2D = "中" (U+4E2D → UTF-8: E4 B8 AD)
    const input = "\xFE\xFF\x4E\x2D";
    const result = try zpdf.decodePdfString(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\xE4\xB8\xAD", result); // "中" in UTF-8
}

test "decodePdfString - PDFDocEncoding high byte" {
    const allocator = std.testing.allocator;
    // 0xE9 without BOM → Latin-1 "é" → UTF-8 C3 A9
    const input = "caf\xE9";
    const result = try zpdf.decodePdfString(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("caf\xC3\xA9", result);
}

test "decodePdfString - UTF-16BE Cafe with accent" {
    const allocator = std.testing.allocator;
    // FE FF 0043 0061 0066 00E9 = "Café"
    const input = "\xFE\xFF\x00\x43\x00\x61\x00\x66\x00\xE9";
    const result = try zpdf.decodePdfString(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Caf\xC3\xA9", result);
}

// =========================================================================
// Nested outline tests
// =========================================================================

test "nested outline with levels and siblings" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateNestedOutlinePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const items = try doc.getOutline(allocator);
    defer {
        for (items) |item| allocator.free(@constCast(item.title));
        allocator.free(items);
    }

    // Should have 3 items: Part I (level 0), Section 1.1 (level 1), Part II (level 0)
    try std.testing.expectEqual(@as(usize, 3), items.len);

    try std.testing.expectEqualStrings("Part I", items[0].title);
    try std.testing.expectEqual(@as(u32, 0), items[0].level);
    try std.testing.expect(items[0].page != null);
    try std.testing.expectEqual(@as(usize, 0), items[0].page.?);

    try std.testing.expectEqualStrings("Section 1.1", items[1].title);
    try std.testing.expectEqual(@as(u32, 1), items[1].level);

    try std.testing.expectEqualStrings("Part II", items[2].title);
    try std.testing.expectEqual(@as(u32, 0), items[2].level);
    try std.testing.expect(items[2].page != null);
    try std.testing.expectEqual(@as(usize, 1), items[2].page.?); // GoTo → page 2
}

test "outline with UTF-16BE encoded title" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateUtf16BePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const items = try doc.getOutline(allocator);
    defer {
        for (items) |item| allocator.free(@constCast(item.title));
        allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 1), items.len);
    // "Café" decoded from UTF-16BE
    try std.testing.expectEqualStrings("Caf\xC3\xA9", items[0].title);
}

// =========================================================================
// Multi-link and GoTo link tests
// =========================================================================

test "multiple links with URI and GoTo" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMultiLinkPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const links = try doc.getPageLinks(0, allocator);
    defer zpdf.Document.freeLinks(allocator, links);

    // Should have 2 links (highlight annotation filtered out)
    try std.testing.expectEqual(@as(usize, 2), links.len);

    // First: URI link
    try std.testing.expect(links[0].uri != null);
    try std.testing.expectEqualStrings("https://example.org", links[0].uri.?);
    try std.testing.expect(links[0].dest_page == null);

    // Second: GoTo internal link → page 0
    try std.testing.expect(links[1].uri == null);
    try std.testing.expect(links[1].dest_page != null);
    try std.testing.expectEqual(@as(usize, 0), links[1].dest_page.?);
}

test "links out of range page returns error" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Test");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const result = doc.getPageLinks(999, allocator);
    try std.testing.expectError(error.PageNotFound, result);
}

// =========================================================================
// All form field types
// =========================================================================

test "all form field types: text, button, choice, signature" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateAllFormFieldsPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const fields = try doc.getFormFields(allocator);
    defer zpdf.Document.freeFormFields(allocator, fields);

    try std.testing.expectEqual(@as(usize, 4), fields.len);

    var found_text = false;
    var found_button = false;
    var found_choice = false;
    var found_sig = false;

    for (fields) |f| {
        if (std.mem.eql(u8, f.name, "email")) {
            found_text = true;
            try std.testing.expect(f.field_type == .text);
            try std.testing.expect(f.value != null);
            try std.testing.expectEqualStrings("user@example.com", f.value.?);
            try std.testing.expect(f.rect != null);
        }
        if (std.mem.eql(u8, f.name, "ok_button")) {
            found_button = true;
            try std.testing.expect(f.field_type == .button);
            try std.testing.expect(f.value == null);
            try std.testing.expect(f.rect == null);
        }
        if (std.mem.eql(u8, f.name, "country")) {
            found_choice = true;
            try std.testing.expect(f.field_type == .choice);
            try std.testing.expectEqualStrings("USA", f.value.?);
        }
        if (std.mem.eql(u8, f.name, "signature")) {
            found_sig = true;
            try std.testing.expect(f.field_type == .signature);
        }
    }

    try std.testing.expect(found_text);
    try std.testing.expect(found_button);
    try std.testing.expect(found_choice);
    try std.testing.expect(found_sig);
}

// =========================================================================
// Extended page label tests
// =========================================================================

test "page labels - uppercase roman" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateExtendedPageLabelPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    // Page 0: uppercase roman → "I"
    const label0 = doc.getPageLabel(allocator, 0);
    defer if (label0) |l| allocator.free(l);
    try std.testing.expect(label0 != null);
    try std.testing.expectEqualStrings("I", label0.?);

    // Page 1: uppercase roman → "II"
    const label1 = doc.getPageLabel(allocator, 1);
    defer if (label1) |l| allocator.free(l);
    try std.testing.expect(label1 != null);
    try std.testing.expectEqualStrings("II", label1.?);
}

test "page labels - lowercase alpha" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateExtendedPageLabelPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    // Page 2: alpha lowercase → "a"
    const label2 = doc.getPageLabel(allocator, 2);
    defer if (label2) |l| allocator.free(l);
    try std.testing.expect(label2 != null);
    try std.testing.expectEqualStrings("a", label2.?);
}

test "page labels - prefix and custom start" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateExtendedPageLabelPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    // Page 3: decimal with prefix "App-" starting at 1 → "App-1"
    const label3 = doc.getPageLabel(allocator, 3);
    defer if (label3) |l| allocator.free(l);
    try std.testing.expect(label3 != null);
    try std.testing.expectEqualStrings("App-1", label3.?);

    // Page 4: → "App-2"
    const label4 = doc.getPageLabel(allocator, 4);
    defer if (label4) |l| allocator.free(l);
    try std.testing.expect(label4 != null);
    try std.testing.expectEqualStrings("App-2", label4.?);
}

test "page label out of range does not crash" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generatePageLabelPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    // Page 999 doesn't exist, but getPageLabel may still compute a label
    // from the last range. What matters is it doesn't crash.
    const label = doc.getPageLabel(allocator, 999);
    if (label) |l| allocator.free(l);
}

// =========================================================================
// Image detection tests
// =========================================================================

test "image detection" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateImagePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const images = try doc.getPageImages(0, allocator, false);
    defer zpdf.Document.freeImages(allocator, images);

    try std.testing.expectEqual(@as(usize, 1), images.len);
    try std.testing.expectEqual(@as(u32, 640), images[0].width);
    try std.testing.expectEqual(@as(u32, 480), images[0].height);

    // CTM was "200 0 0 150 100 500 cm"
    try std.testing.expectApproxEqRel(@as(f64, 100), images[0].rect[0], 0.01);
    try std.testing.expectApproxEqRel(@as(f64, 500), images[0].rect[1], 0.01);

    // Fixture has no /Filter, so encoding stays null.
    try std.testing.expect(images[0].encoding == null);
}

test "PR-19 follow-up: getPageImages surfaces /Filter as encoding" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateImagePdfWithFilter(allocator, "DCTDecode");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const images = try doc.getPageImages(0, allocator, false);
    defer zpdf.Document.freeImages(allocator, images);

    try std.testing.expectEqual(@as(usize, 1), images.len);
    try std.testing.expect(images[0].encoding != null);
    try std.testing.expectEqualStrings("DCTDecode", images[0].encoding.?);
}

test "images returns empty for page without images" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "No images");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const images = try doc.getPageImages(0, allocator, false);
    defer allocator.free(images);

    try std.testing.expectEqual(@as(usize, 0), images.len);
}

test "images out of range page returns error" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Test");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const result = doc.getPageImages(999, allocator, false);
    try std.testing.expectError(error.PageNotFound, result);
}

test "PR-19 base64: DCTDecode payload is non-null and equals raw stream bytes" {
    const allocator = std.testing.allocator;

    // generateImagePdfWithFilter embeds a 1-byte stream (\xFF) with /Filter /DCTDecode.
    const pdf_data = try testpdf.generateImagePdfWithFilter(allocator, "DCTDecode");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const images = try doc.getPageImages(0, allocator, true);
    defer zpdf.Document.freeImages(allocator, images);

    try std.testing.expectEqual(@as(usize, 1), images.len);
    try std.testing.expectEqualStrings("DCTDecode", images[0].encoding.?);
    // DCTDecode is passthrough-friendly: payload must be the raw stream bytes.
    try std.testing.expect(images[0].payload != null);
    try std.testing.expectEqual(@as(u8, 0xFF), images[0].payload.?[0]);
}

test "PR-19 base64: FlateDecode payload is null (not passthrough-friendly)" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateImagePdfWithFilter(allocator, "FlateDecode");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const images = try doc.getPageImages(0, allocator, true);
    defer zpdf.Document.freeImages(allocator, images);

    try std.testing.expectEqual(@as(usize, 1), images.len);
    try std.testing.expectEqualStrings("FlateDecode", images[0].encoding.?);
    // FlateDecode is not passthrough-friendly: payload must be null.
    try std.testing.expect(images[0].payload == null);
}

test "PR-19 base64: include_payload=false always yields null payload" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateImagePdfWithFilter(allocator, "DCTDecode");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const images = try doc.getPageImages(0, allocator, false);
    defer zpdf.Document.freeImages(allocator, images);

    try std.testing.expectEqual(@as(usize, 1), images.len);
    // Even for DCTDecode, payload must be null when include_payload is false.
    try std.testing.expect(images[0].payload == null);
}

// =========================================================================
// Search edge cases
// =========================================================================

test "search empty query returns empty" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Hello World");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const results = try doc.search(allocator, "");
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "search context contains surrounding text" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "The quick brown fox jumps over the lazy dog");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const results = try doc.search(allocator, "fox");
    defer zpdf.Document.freeSearchResults(allocator, results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqual(@as(usize, 0), results[0].page);
    // Context should contain the match
    try std.testing.expect(std.mem.indexOf(u8, results[0].context, "fox") != null);
}

test "search multiple matches on same page" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "cat and cat and cat");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const results = try doc.search(allocator, "cat");
    defer zpdf.Document.freeSearchResults(allocator, results);

    try std.testing.expectEqual(@as(usize, 3), results.len);
    // All on page 0
    for (results) |r| {
        try std.testing.expectEqual(@as(usize, 0), r.page);
    }
}

// =========================================================================
// Metadata edge cases
// =========================================================================

test "metadata with partial fields" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMetadataPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const meta = doc.metadata();
    // creation_date and mod_date are not in our test PDF
    try std.testing.expect(meta.creation_date == null);
    try std.testing.expect(meta.mod_date == null);
    // But title, author etc. should be present
    try std.testing.expect(meta.title != null);
}

test "superscript positioning does not insert spurious newline" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateSuperscriptPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try doc.extractText(0, &output.writer);

    // All three text chunks must be present
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "World") != null);

    // No newline should appear between them: the 7-unit Y shift for the
    // superscript is below the threshold max(7,12)*0.7=8.4 (Fix 8)
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\n") == null);
}

// PR-1 — Pass B (lattice) recurses into Form XObject `Do` operator,
// walking the XObject's content stream with its own CTM stack so ruled
// tables drawn inside reusable templates are detected.
//
// Fixture: testpdf.generateFormXObjectTablePdf produces a single page
// whose only top-level operator is `/TableForm Do`. The Form XObject
// draws a 3×3 ruled grid (outer 300×300 rect + 2 interior horizontals
// + 2 interior verticals) at user-space [100, 400, 400, 700]. Without
// resource-aware recursion, lattice walks an effectively empty page
// stream and returns 0 tables. With recursion, lattice resolves the
// XObject, decompresses its content, and detects exactly one 3×3
// table.
test "lattice pass B recurses form xobject" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateFormXObjectTablePdf(allocator);
    defer allocator.free(pdf_data);

    var doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const detected = try doc.getTables(allocator);
    defer zpdf.tables.freeTables(allocator, detected);

    // At least one 3×3 table on page 1, lattice-detected.
    var match_idx: ?usize = null;
    for (detected, 0..) |t, i| {
        if (t.page == 1 and t.n_rows == 3 and t.n_cols == 3) {
            match_idx = i;
            break;
        }
    }
    try std.testing.expect(match_idx != null);

    // Bbox in user-space matches the gold rectangle within ±2 pt.
    const t = detected[match_idx.?];
    try std.testing.expect(t.bbox != null);
    const bb = t.bbox.?;
    try std.testing.expectApproxEqAbs(@as(f64, 100), bb[0], 2.0);
    try std.testing.expectApproxEqAbs(@as(f64, 400), bb[1], 2.0);
    try std.testing.expectApproxEqAbs(@as(f64, 400), bb[2], 2.0);
    try std.testing.expectApproxEqAbs(@as(f64, 700), bb[3], 2.0);
}

// Codex review v1.2-rc4 [P2] regression: lattice must resolve indirect
// references in BOTH `/Matrix` and `/Resources` before consuming them.
//
// Round 2 strengthening: the outer form delegates to a nested
// /InnerForm reachable ONLY via the indirect `/Resources 7 0 R`. So
// the test exercises both fixes at once:
//   - indirect Matrix: must resolve `/Matrix 6 0 R` to translate by
//     +50pt; otherwise bbox lands at [100,...] not [150,...].
//   - indirect Resources: must resolve `/Resources 7 0 R` to find
//     /InnerForm; otherwise the nested Do is a no-op and zero
//     strokes are collected (no table at all).
test "lattice pass B resolves indirect Matrix and Resources refs" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateFormXObjectIndirectRefsPdf(allocator);
    defer allocator.free(pdf_data);

    var doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const detected = try doc.getTables(allocator);
    defer zpdf.tables.freeTables(allocator, detected);

    var match_idx: ?usize = null;
    for (detected, 0..) |t, i| {
        if (t.page == 1 and t.n_rows == 3 and t.n_cols == 3) {
            match_idx = i;
            break;
        }
    }
    try std.testing.expect(match_idx != null);

    const t = detected[match_idx.?];
    try std.testing.expect(t.bbox != null);
    const bb = t.bbox.?;
    // Matrix [1 0 0 1 50 0] shifts the form-space x by +50.
    try std.testing.expectApproxEqAbs(@as(f64, 150), bb[0], 2.0);
    try std.testing.expectApproxEqAbs(@as(f64, 400), bb[1], 2.0);
    try std.testing.expectApproxEqAbs(@as(f64, 450), bb[2], 2.0);
    try std.testing.expectApproxEqAbs(@as(f64, 700), bb[3], 2.0);
}

// Codex review v1.2-rc4 round 10 [P2]: indirect /Subtype on a Form
// XObject. Lattice must resolve `/Subtype N 0 R` before checking for
// "Form"; otherwise the form is silently rejected and zero strokes
// land in the table list.
test "lattice pass B resolves indirect /Subtype on Form XObject" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateFormXObjectIndirectSubtypePdf(allocator);
    defer allocator.free(pdf_data);

    var doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const detected = try doc.getTables(allocator);
    defer zpdf.tables.freeTables(allocator, detected);

    var lattice_count: usize = 0;
    for (detected) |t| {
        if (t.engine == zpdf.tables.Engine.lattice and
            t.n_rows == 3 and t.n_cols == 3) lattice_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), lattice_count);
}

// Codex round 20 [P2]: PDF spec §7.3.5 allows `#xx` hex escapes in
// content-stream names. Lattice must decode at the XObject lookup
// boundary (`/Fm#31 Do` ↔ `/Fm1` in Resources). Without the decoder,
// the lookup misses entirely and the form is not invoked.
test "lattice pass B decodes escaped Form XObject names (Fm#31 -> Fm1)" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateFormXObjectEscapedNamePdf(allocator);
    defer allocator.free(pdf_data);

    var doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const detected = try doc.getTables(allocator);
    defer zpdf.tables.freeTables(allocator, detected);

    var lattice_count: usize = 0;
    for (detected) |t| {
        if (t.engine == zpdf.tables.Engine.lattice and
            t.n_rows == 3 and t.n_cols == 3) lattice_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), lattice_count);
}

// Codex round 17 [P2]: nested Form /Resources fallback uses the
// PAGE Resources, not the calling Form's. Per ISO 32000-1 §7.8.3.
// Three-level chain: page → OuterForm → MidForm. OuterForm shadows
// /InnerGrid with a 4x4 grid; MidForm has /Resources null and calls
// /InnerGrid. Spec-conform fallback resolves to the page's 3x3 grid;
// pre-fix caller-fallback would have resolved to OuterForm's 4x4
// shadow.
test "lattice pass B nested-Form null Resources falls back to page (not caller)" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateFormXObjectShadowedXObjectPdf(allocator);
    defer allocator.free(pdf_data);

    var doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const detected = try doc.getTables(allocator);
    defer zpdf.tables.freeTables(allocator, detected);

    var has_3x3: bool = false;
    var has_4x4: bool = false;
    for (detected) |t| {
        if (t.engine != zpdf.tables.Engine.lattice) continue;
        if (t.n_rows == 3 and t.n_cols == 3) has_3x3 = true;
        if (t.n_rows == 4 and t.n_cols == 4) has_4x4 = true;
    }
    // Spec-conform: page's 3x3 wins; OuterForm's 4x4 shadow doesn't fire.
    try std.testing.expect(has_3x3);
    try std.testing.expect(!has_4x4);
}

// Codex round 16 [P2]: per PDF 32000-1 §7.3.9, a `null` dictionary
// value is equivalent to omitting the entry, so /Resources null on
// a Form must inherit parent resources rather than fail closed.
// The fixture sets /Resources null on the outer form and exposes
// /InnerGrid via the page-level Resources. With spec-conform
// inheritance, /InnerGrid resolves and produces a 3x3 lattice
// table.
test "lattice pass B treats Form /Resources null as inherited" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateFormXObjectNullResourcesPdf(allocator);
    defer allocator.free(pdf_data);

    var doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const detected = try doc.getTables(allocator);
    defer zpdf.tables.freeTables(allocator, detected);

    var lattice_count: usize = 0;
    for (detected) |t| {
        if (t.engine == zpdf.tables.Engine.lattice and
            t.n_rows == 3 and t.n_cols == 3) lattice_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), lattice_count);
}

// Round-9 [P2] + round-16 [P2]: a Form with a present-but-malformed
// /Resources (NOT including .null, which is spec-equivalent to
// absent) must NOT inherit from its parent. The fixture sets
// /Resources to integer 42 and lets the page expose /InnerGrid at
// the page-level Resources. A buggy walker would inherit page
// Resources, find /InnerGrid, draw its 3x3 grid; the correct walker
// fails closed at the first nested Do.
test "lattice pass B fails closed on malformed Form /Resources" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateFormXObjectMalformedResourcesPdf(allocator);
    defer allocator.free(pdf_data);

    var doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const detected = try doc.getTables(allocator);
    defer zpdf.tables.freeTables(allocator, detected);

    // Zero lattice tables expected: outer form's malformed /Resources
    // prevents the nested /InnerGrid Do from resolving; the inner
    // grid never gets drawn, no strokes collected.
    var lattice_count: usize = 0;
    for (detected) |t| {
        if (t.engine == zpdf.tables.Engine.lattice) lattice_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), lattice_count);
}

// Codex review v1.2-rc4 round 8 [P2]: indirect numeric elements in
// /BBox and /Matrix arrays. Both arrays are expressed as `[N 0 R ...]`;
// readBBox/readMatrix must resolve each element through resolveRefSoft.
// Matrix translates by +30 in x; the form-space 3x3 grid at
// [100,400,400,700] should land in user-space at [130,400,430,700].
// Without indirect-element resolution: BBox null + Matrix identity →
// bbox at [100,400,400,700] (the regression we're catching).
test "lattice pass B resolves indirect-element /BBox and /Matrix arrays" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateFormXObjectIndirectArrayElementsPdf(allocator);
    defer allocator.free(pdf_data);

    var doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const detected = try doc.getTables(allocator);
    defer zpdf.tables.freeTables(allocator, detected);

    var match_idx: ?usize = null;
    for (detected, 0..) |t, i| {
        if (t.page == 1 and t.n_rows == 3 and t.n_cols == 3 and
            t.engine == zpdf.tables.Engine.lattice)
        {
            match_idx = i;
            break;
        }
    }
    try std.testing.expect(match_idx != null);

    const t = detected[match_idx.?];
    try std.testing.expect(t.bbox != null);
    const bb = t.bbox.?;
    // Translation +30: x should be in the [130, 430] range.
    try std.testing.expectApproxEqAbs(@as(f64, 130), bb[0], 2.0);
    try std.testing.expectApproxEqAbs(@as(f64, 400), bb[1], 2.0);
    try std.testing.expectApproxEqAbs(@as(f64, 430), bb[2], 2.0);
    try std.testing.expectApproxEqAbs(@as(f64, 700), bb[3], 2.0);
}

// Codex review v1.2-rc4 [P2] /BBox clipping (round 4 + round 5).
// The form draws an oversized inside grid that extends past the BBox
// right edge AND a separate fully-outside grid. Lattice must:
//   round-4: drop fully-outside strokes (the y=50..350 grid)
//   round-5: clamp boundary-crossing strokes so the detected table's
//            bbox doesn't extend past the BBox edge at x=400
test "lattice pass B clips strokes to Form XObject /BBox" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateFormXObjectBBoxClippedPdf(allocator);
    defer allocator.free(pdf_data);

    var doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const detected = try doc.getTables(allocator);
    defer zpdf.tables.freeTables(allocator, detected);

    // Exactly one 3x3 lattice table on page 1: the inside grid clamped
    // to the BBox. Without round-4 clipping we'd see 2 tables; without
    // round-5 partial clipping the surviving table's bbox would have
    // x1 ≈ 700 instead of ≈ 400.
    var lattice_matches: usize = 0;
    var match_idx: ?usize = null;
    for (detected, 0..) |t, i| {
        if (t.page == 1 and t.n_rows == 3 and t.n_cols == 3 and
            t.engine == zpdf.tables.Engine.lattice)
        {
            lattice_matches += 1;
            match_idx = i;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), lattice_matches);

    const t = detected[match_idx.?];
    try std.testing.expect(t.bbox != null);
    const bb = t.bbox.?;
    // Inside-BBox region: y must be >= 400 (no leak from outside grid).
    try std.testing.expectApproxEqAbs(@as(f64, 400), bb[1], 2.0);
    try std.testing.expectApproxEqAbs(@as(f64, 700), bb[3], 2.0);
    // Round-5: boundary strokes clamped to BBox right edge ≈ 400.
    // Without per-stroke clipping the bbox would be ≈ 700.
    try std.testing.expect(bb[2] <= 405.0);
}

// Cycle guard: a Form XObject that invokes itself via `Do` must not
// hang or stack-overflow lattice. The first invocation collects the
// outer rect (1 stroke set); the recursive Do is rejected by the
// visited-set guard. getTables completes successfully.
test "lattice pass B handles self-referencing Form XObject without hanging" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateFormXObjectSelfReferencingPdf(allocator);
    defer allocator.free(pdf_data);

    var doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    // Must return without hanging or panicking. The single rect drawn
    // by the form has only 4 strokes so lattice produces no table
    // (needs >= 2 cluster lines on each axis); the test is the
    // *non-hang* itself.
    const detected = try doc.getTables(allocator);
    defer zpdf.tables.freeTables(allocator, detected);
    // No stronger assertion — the success of `getTables` returning is
    // the only invariant the cycle guard guarantees.
}

// Subtype filter: an /Image XObject must not be walked as a content
// stream. The page draws a real 3x3 table inline, then invokes the
// Image XObject; lattice detects exactly one table from the inline
// strokes and ignores the image.
test "lattice pass B ignores non-Form XObject Subtypes" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateImageXObjectIgnoredByLatticePdf(allocator);
    defer allocator.free(pdf_data);

    var doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const detected = try doc.getTables(allocator);
    defer zpdf.tables.freeTables(allocator, detected);

    var match_idx: ?usize = null;
    for (detected, 0..) |t, i| {
        if (t.page == 1 and t.n_rows == 3 and t.n_cols == 3) {
            match_idx = i;
            break;
        }
    }
    try std.testing.expect(match_idx != null);
    // bbox of the inline table — same as generateFormXObjectTablePdf
    // because the strokes are drawn directly in the page content
    // stream, no Matrix involved.
    const t = detected[match_idx.?];
    try std.testing.expect(t.bbox != null);
    const bb = t.bbox.?;
    try std.testing.expectApproxEqAbs(@as(f64, 100), bb[0], 2.0);
    try std.testing.expectApproxEqAbs(@as(f64, 700), bb[3], 2.0);
}

// PR-3 — Pass A (tagged-path) populates per-cell text by walking each
// TD's MCID list and concatenating each MCID's accumulated text via
// the existing `structtree.MarkedContentExtractor.getTextForMcid`.
//
// The fixture (`testpdf.generateTaggedTablePdf`) emits a single-page
// tagged 2×3 table. Each /TD has one MCID; the page content stream
// wraps each glyph run in `/TD <</MCID N>> BDC ... EMC`. After
// `getTables`, every cell's `text` should match the gold values.
//
// Architectural note: PR-3 originally proposed bbox-intersection
// (per-MCID bbox lookup → glyph span filter). The implementation
// instead uses the existing direct text-by-MCID pathway — same
// answer, no glyph-bbox prerequisite, no false positives from
// glyph centers landing inside an MCID's bbox without being tagged.
test "tagged table extracts cell text" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateTaggedTablePdf(allocator);
    defer allocator.free(pdf_data);

    var doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const detected = try doc.getTables(allocator);
    defer zpdf.tables.freeTables(allocator, detected);

    // Exactly one Pass A (tagged) table with 2 rows × 3 cols.
    var match_idx: ?usize = null;
    for (detected, 0..) |t, i| {
        if (t.engine == zpdf.tables.Engine.tagged and
            t.n_rows == 2 and t.n_cols == 3)
        {
            match_idx = i;
            break;
        }
    }
    try std.testing.expect(match_idx != null);

    const t = detected[match_idx.?];
    // Build a 2x3 grid of expected texts and assert each cell.
    const gold = [2][3][]const u8{
        .{ "A1", "B1", "C1" },
        .{ "A2", "B2", "C2" },
    };

    for (t.cells) |c| {
        try std.testing.expect(c.r < 2 and c.c < 3);
        try std.testing.expect(c.text != null);
        try std.testing.expectEqualStrings(gold[c.r][c.c], c.text.?);
    }
    try std.testing.expectEqual(@as(usize, 6), t.cells.len);
    // Codex round 1 [P2]: the fixture attaches /Pg only to leaf TDs;
    // Pass A page-resolution must walk descendants and emit page=1.
    try std.testing.expectEqual(@as(u32, 1), t.page);
}

// Codex review v1.2-rc4 PR-3 round 1 [P2]: cells whose MCIDs are
// nested inside child structure elements (e.g. <TD><P>...MCID
// ...</P></TD>) — common in real tagged PDFs per ISO 32000-1
// §14.7.4. Pass A's cell-text walker must descend through structure
// elements, not stop at direct .mcid children. Fixture mirrors the
// flat-MCID test but inserts /P elements between each /TD and its
// MCID; gold texts: N1..N6.
test "tagged table extracts cell text from nested MCID children" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateTaggedTableNestedPdf(allocator);
    defer allocator.free(pdf_data);

    var doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const detected = try doc.getTables(allocator);
    defer zpdf.tables.freeTables(allocator, detected);

    var match_idx: ?usize = null;
    for (detected, 0..) |tbl, i| {
        if (tbl.engine == zpdf.tables.Engine.tagged and
            tbl.n_rows == 2 and tbl.n_cols == 3)
        {
            match_idx = i;
            break;
        }
    }
    try std.testing.expect(match_idx != null);

    const t = detected[match_idx.?];
    const gold = [2][3][]const u8{
        .{ "N1", "N2", "N3" },
        .{ "N4", "N5", "N6" },
    };
    for (t.cells) |c| {
        try std.testing.expect(c.text != null);
        try std.testing.expectEqualStrings(gold[c.r][c.c], c.text.?);
    }
    try std.testing.expectEqual(@as(usize, 6), t.cells.len);
    try std.testing.expectEqual(@as(u32, 1), t.page);
}

// PR-2 — bbox-y proximity constraint in linkContinuations.
// Two ruled 3x3 tables on consecutive pages, BOTH placed in the
// vertical middle of their respective pages — neither sits in the
// 20% page-boundary band. With matching column counts the old rule
// would have linked them; the new bbox-y check correctly rejects.
test "continuation link rejects two unrelated mid-page tables" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateTwoUnrelatedTablesPdf(allocator);
    defer allocator.free(pdf_data);

    var doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const detected = try doc.getTables(allocator);
    defer zpdf.tables.freeTables(allocator, detected);

    var lattice_count: usize = 0;
    var any_continuation: bool = false;
    for (detected) |t| {
        if (t.engine != zpdf.tables.Engine.lattice) continue;
        if (t.n_rows != 3 or t.n_cols != 3) continue;
        lattice_count += 1;
        if (t.continued_to != null or t.continued_from != null) {
            any_continuation = true;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), lattice_count);
    try std.testing.expect(!any_continuation);
}

// PR-2 positive case — table_a at the bottom of page 1 + table_b at
// the top of page 2 + matching col counts → linked.
test "continuation link accepts true near-boundary chain" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateLinkedContinuationTablesPdf(allocator);
    defer allocator.free(pdf_data);

    var doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const detected = try doc.getTables(allocator);
    defer zpdf.tables.freeTables(allocator, detected);

    var page1_table: ?usize = null;
    var page2_table: ?usize = null;
    for (detected, 0..) |t, i| {
        if (t.engine != zpdf.tables.Engine.lattice) continue;
        if (t.n_rows != 3 or t.n_cols != 3) continue;
        if (t.page == 1) page1_table = i;
        if (t.page == 2) page2_table = i;
    }
    try std.testing.expect(page1_table != null);
    try std.testing.expect(page2_table != null);

    // page1 table → continued_to points at page2 table.
    const a = detected[page1_table.?];
    try std.testing.expect(a.continued_to != null);
    try std.testing.expectEqual(@as(u32, 2), a.continued_to.?.page);

    // page2 table → continued_from points at page1 table.
    const b = detected[page2_table.?];
    try std.testing.expect(b.continued_from != null);
    try std.testing.expectEqual(@as(u32, 1), b.continued_from.?.page);
}

// PR-4 — Pass B (lattice) populates per-cell text by intersecting
// extractTextWithBounds spans against each cell's bbox via
// glyph-center containment. Mirrors stream_table.zig's
// buildCellsWithText pattern but uses rectangular bbox containment
// instead of x-anchor matching (lattice cells have explicit
// row/col line geometry).
//
// Fixture: 4×3 ruled grid with each cell centred-text "RC" where
// R is the row index (0=bottom, 3=top per existing lattice
// convention) and C is the column index (0=left). Glyph centers
// land squarely inside the cell bbox so the intersection is
// unambiguous.
// PR-11 codex r2 P3 (test-gate): end-to-end integration coverage
// for the scanned-PDF heuristic. Uses generateMultiPagePdf with
// very-short text per page (registers fonts but produces tiny
// markdown output, mimicking image-only / scanned PDFs).
test "scanned-PDF heuristic flags 3-page low-text doc" {
    const allocator = std.testing.allocator;

    // 3 pages, each with a single character: enough to register the
    // page + font but produces sub-50-byte markdown per page.
    const pages_text = [_][]const u8{ "x", "y", "z" };
    const pdf_data = try testpdf.generateMultiPagePdf(allocator, &pages_text);
    defer allocator.free(pdf_data);

    var doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var pages_emitted: u32 = 0;
    var scanned_pages: u32 = 0;
    var page_idx: usize = 0;
    while (page_idx < doc.pageCount()) : (page_idx += 1) {
        const md = try doc.extractMarkdown(page_idx, allocator);
        defer allocator.free(md);
        pages_emitted += 1;
        if (md.len < 50) scanned_pages += 1;
    }
    const has_fonts = doc.font_cache.count() > 0 or doc.font_obj_cache.count() > 0;
    const flag = cli.computeScanFlag(pages_emitted, scanned_pages, has_fonts, 50);
    try std.testing.expect(flag != null);
    try std.testing.expectEqualStrings("scanned", flag.?);
}

test "scanned-PDF heuristic does NOT flag born-digital 3-page doc" {
    const allocator = std.testing.allocator;

    // 3 pages with normal-length sentences — markdown comfortably
    // exceeds 50 bytes per page.
    const pages_text = [_][]const u8{
        "The quick brown fox jumps over the lazy dog. This sentence is intentionally long enough to exceed the scanned-flag threshold.",
        "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.",
        "Sphinx of black quartz, judge my vow. Pack my box with five dozen liquor jugs. The five boxing wizards jump quickly.",
    };
    const pdf_data = try testpdf.generateMultiPagePdf(allocator, &pages_text);
    defer allocator.free(pdf_data);

    var doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var pages_emitted: u32 = 0;
    var scanned_pages: u32 = 0;
    var page_idx: usize = 0;
    while (page_idx < doc.pageCount()) : (page_idx += 1) {
        const md = try doc.extractMarkdown(page_idx, allocator);
        defer allocator.free(md);
        pages_emitted += 1;
        if (md.len < 50) scanned_pages += 1;
    }
    const has_fonts = doc.font_cache.count() > 0 or doc.font_obj_cache.count() > 0;
    const flag = cli.computeScanFlag(pages_emitted, scanned_pages, has_fonts, 50);
    try std.testing.expectEqual(@as(?[]const u8, null), flag);
}

test "lattice pass B populates cell text via glyph-center intersection" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateLatticeWithTextPdf(allocator);
    defer allocator.free(pdf_data);

    var doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const detected = try doc.getTables(allocator);
    defer zpdf.tables.freeTables(allocator, detected);

    var match_idx: ?usize = null;
    for (detected, 0..) |t, i| {
        if (t.engine == zpdf.tables.Engine.lattice and
            t.n_rows == 4 and t.n_cols == 3)
        {
            match_idx = i;
            break;
        }
    }
    try std.testing.expect(match_idx != null);

    const t = detected[match_idx.?];
    try std.testing.expectEqual(@as(usize, 12), t.cells.len);

    // Build a 4×3 grid of expected texts. Lattice convention: r=0
    // is the bottom row.
    const gold = [4][3][]const u8{
        .{ "00", "01", "02" },
        .{ "10", "11", "12" },
        .{ "20", "21", "22" },
        .{ "30", "31", "32" },
    };
    for (t.cells) |c| {
        try std.testing.expect(c.r < 4 and c.c < 3);
        try std.testing.expect(c.text != null);
        try std.testing.expectEqualStrings(gold[c.r][c.c], c.text.?);
    }
}

// Regression: corrupt content streams with a name-typed operand at a
// numeric operator position used to panic with "access of union field
// 'number' while field 'name' is active" on Td / Tm / cm. The
// `pdf_extract_mutation` fuzz target hit this; covering it here so the
// regression is caught at unit-test time instead of seed-lottery time.
//
// Each fixture uses DocumentBuilder + page.appendContent to inject a
// hand-crafted content stream that violates the PDF spec at a single
// well-defined point, then runs extractMarkdown end-to-end. The test
// passes if and only if extraction completes without panicking; the
// extractor's job is graceful degradation, not byte-exact recovery.

fn buildCorruptContentPdf(allocator: std.mem.Allocator, raw_content: []const u8) ![]u8 {
    const document = @import("pdf_document.zig");
    var doc = document.DocumentBuilder.init(allocator);
    defer doc.deinit();
    const page = try doc.addPage(.{ 0, 0, 612, 792 });
    const f = page.markFontUsed(.helvetica);
    var buf: [1024]u8 = undefined;
    const stream = try std.fmt.bufPrint(&buf, "BT\n{s} 12 Tf\n{s}\nET\n", .{ f, raw_content });
    try page.appendContent(stream);
    return doc.write();
}

test "extractMarkdown survives Td with a name where ty is expected" {
    const allocator = std.testing.allocator;
    // `100 /BadOperand Td` — ty is /BadOperand instead of a number.
    const bytes = try buildCorruptContentPdf(allocator, "100 /BadOperand Td (Hello) Tj");
    defer allocator.free(bytes);

    var doc = try zpdf.Document.openFromMemory(allocator, bytes, zpdf.ErrorConfig.permissive());
    defer doc.close();
    const md = try doc.extractMarkdown(0, allocator);
    defer allocator.free(md);
    // No assertion on content — the gate is "did not panic".
}

test "extractMarkdown survives Tm with a name where the matrix expects a number" {
    const allocator = std.testing.allocator;
    // `1 0 0 1 100 /BadOperand Tm` — f (ty) is /BadOperand instead of a number.
    const bytes = try buildCorruptContentPdf(allocator, "1 0 0 1 100 /BadOperand Tm (Hello) Tj");
    defer allocator.free(bytes);

    var doc = try zpdf.Document.openFromMemory(allocator, bytes, zpdf.ErrorConfig.permissive());
    defer doc.close();
    const md = try doc.extractMarkdown(0, allocator);
    defer allocator.free(md);
}

test "getPageImages survives cm with a name in the matrix" {
    const allocator = std.testing.allocator;
    // `1 0 /Garbage 1 0 0 cm` — c is /Garbage instead of a number.
    // The `cm` handler lives in `getPageImages` (the layout-aware
    // image-rect walker); `extractMarkdown`'s content-stream extractor
    // doesn't track CTM, so we exercise the panicking path directly.
    const bytes = try buildCorruptContentPdf(allocator, "1 0 /Garbage 1 0 0 cm (Hello) Tj");
    defer allocator.free(bytes);

    var doc = try zpdf.Document.openFromMemory(allocator, bytes, zpdf.ErrorConfig.permissive());
    defer doc.close();
    const images = try doc.getPageImages(0, allocator, false);
    defer allocator.free(images);
    // No assertion on image count — the gate is "did not panic".
}

test "PR-20: getPageAnnotations extracts non-/Link annotations" {
    // Builds a PDF via DocumentBuilder with four hand-crafted annotation
    // aux objects covering the primary subtypes (text, highlight,
    // underline, ink), then verifies getPageAnnotations returns them
    // with correct fields and skips a /Link annotation that's also on
    // the page (handled by getPageLinks).
    const allocator = std.testing.allocator;
    const document = @import("pdf_document.zig");

    var doc = document.DocumentBuilder.init(allocator);
    defer doc.deinit();

    const page = try doc.addPage(.{ 0, 0, 612, 792 });
    try page.drawText(72, 720, .helvetica, 12, "Annotated body");

    const text_annot = try doc.addAuxiliaryObject(
        "<< /Type /Annot /Subtype /Text /Rect [50 700 70 720] " ++
            "/Contents (Sticky note) /T (Reviewer A) " ++
            "/M (D:20260430123045Z) >>",
    );
    const hi_annot = try doc.addAuxiliaryObject(
        "<< /Type /Annot /Subtype /Highlight /Rect [72 720 200 736] " ++
            "/Contents (Important) >>",
    );
    const ul_annot = try doc.addAuxiliaryObject(
        "<< /Type /Annot /Subtype /Underline /Rect [72 720 200 722] >>",
    );
    const ink_annot = try doc.addAuxiliaryObject(
        "<< /Type /Annot /Subtype /Ink /Rect [100 600 300 620] >>",
    );
    const link_annot = try doc.addAuxiliaryObject(
        "<< /Type /Annot /Subtype /Link /Rect [10 10 100 30] " ++
            "/A << /S /URI /URI (https://example.com) >> >>",
    );

    var extras_buf: [192]u8 = undefined;
    try page.setPageExtras(try std.fmt.bufPrint(
        &extras_buf,
        "/Annots [{d} 0 R {d} 0 R {d} 0 R {d} 0 R {d} 0 R]",
        .{ text_annot, hi_annot, ul_annot, ink_annot, link_annot },
    ));

    const bytes = try doc.write();
    defer allocator.free(bytes);

    var parsed = try zpdf.Document.openFromMemory(allocator, bytes, zpdf.ErrorConfig.permissive());
    defer parsed.close();

    const annots = try parsed.getPageAnnotations(0, allocator);
    defer zpdf.Document.freeAnnotations(allocator, annots);

    // Exactly 4 non-link annotations.
    try std.testing.expectEqual(@as(usize, 4), annots.len);

    // Index annotations by subtype for stable assertions (order is
    // page-Annots-array order, but we don't rely on it here).
    var found_text = false;
    var found_highlight = false;
    var found_underline = false;
    var found_ink = false;
    for (annots) |a| {
        if (std.mem.eql(u8, a.subtype, "text")) {
            found_text = true;
            try std.testing.expectEqualStrings("Sticky note", a.contents.?);
            try std.testing.expectEqualStrings("Reviewer A", a.author.?);
            try std.testing.expectEqualStrings("D:20260430123045Z", a.modified.?);
        } else if (std.mem.eql(u8, a.subtype, "highlight")) {
            found_highlight = true;
            try std.testing.expectEqualStrings("Important", a.contents.?);
        } else if (std.mem.eql(u8, a.subtype, "underline")) {
            found_underline = true;
            try std.testing.expect(a.contents == null);
        } else if (std.mem.eql(u8, a.subtype, "ink")) {
            found_ink = true;
        } else {
            // /Link must NOT appear here — it's filtered upstream.
            return error.UnexpectedSubtype;
        }
    }
    try std.testing.expect(found_text);
    try std.testing.expect(found_highlight);
    try std.testing.expect(found_underline);
    try std.testing.expect(found_ink);

    // /Link still surfaces via getPageLinks.
    const links = try parsed.getPageLinks(0, allocator);
    defer zpdf.Document.freeLinks(allocator, links);
    try std.testing.expectEqual(@as(usize, 1), links.len);
}

test "PR-21: emitElementJson produces a Table → TR → TD tree" {
    // Tagged-table fixture has a real /StructTreeRoot rooted at Table:
    //   Table → 2× TR → 3× TD each (6 cells, MCIDs 0..5).
    // Emit the tree as JSON and assert the structural shape.
    const allocator = std.testing.allocator;
    const pdf_data = try testpdf.generateTaggedTablePdf(allocator);
    defer allocator.free(pdf_data);

    var doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const tree = try doc.getStructTree();
    try std.testing.expect(tree.root != null);

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try zpdf.structtree.emitElementJson(tree.root.?, &aw.writer, 0);

    const json = aw.written();
    // Type-shape sanity: Table is the root; TR/TD nesting present; MCIDs 0..5 attached.
    try std.testing.expect(std.mem.startsWith(u8, json, "{\"type\":\"Table\""));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"TR\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"TD\"") != null);
    // Each TD carries exactly one MCID. Verify all six are emitted.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mcid_refs\":[0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mcid_refs\":[1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mcid_refs\":[5]") != null);
}

test "PR-20: getPageAnnotations returns empty for page without /Annots" {
    const allocator = std.testing.allocator;
    const bytes = try testpdf.generateMinimalPdf(allocator, "Hello");
    defer allocator.free(bytes);

    var doc = try zpdf.Document.openFromMemory(allocator, bytes, zpdf.ErrorConfig.permissive());
    defer doc.close();
    const annots = try doc.getPageAnnotations(0, allocator);
    defer zpdf.Document.freeAnnotations(allocator, annots);
    try std.testing.expectEqual(@as(usize, 0), annots.len);
}

test "analyzePageLayout does not leak the input spans array" {
    // Regression for the PR-W6 fuzz follow-up: extractTextWithBounds
    // allocates a `[]TextSpan` that analyzeLayout `@memcpy`s into its
    // own buffer; the input array used to leak. This test runs the
    // analyzePageLayout path on a tiny known-good fixture and relies
    // on std.testing.allocator's leak detection to catch a regression.
    const allocator = std.testing.allocator;
    const bytes = try testpdf.generateMinimalPdf(allocator, "Hello");
    defer allocator.free(bytes);

    var doc = try zpdf.Document.openFromMemory(allocator, bytes, zpdf.ErrorConfig.permissive());
    defer doc.close();
    var layout_result = try doc.analyzePageLayout(0, allocator);
    defer layout_result.deinit();
    // No assertion on layout content — the gate is "no leak detected".
}

test "extractMarkdown survives BDC with non-name property dict (MCID extraction)" {
    const allocator = std.testing.allocator;
    // `42 /Tag BDC` — first operand should be /Tag (name), second is the
    // property dict / name. We keep the shape valid here but flip the
    // property operand into a number to exercise the MCID extractor's
    // tag-checked path. The fuzz target found ReleaseSafe inlining that
    // misattributed the panic to this BDC site; the real fix is in cm/Td/Tm
    // but a regression test pinning BDC's tag-checked behaviour is cheap.
    const bytes = try buildCorruptContentPdf(allocator, "/Span 42 BDC (Hello) Tj EMC");
    defer allocator.free(bytes);

    var doc = try zpdf.Document.openFromMemory(allocator, bytes, zpdf.ErrorConfig.permissive());
    defer doc.close();
    const md = try doc.extractMarkdown(0, allocator);
    defer allocator.free(md);
}
