// PR-22a [infra]: fixture emitter for the qpdf --check harness.
//
// Materialises every public `generate*Pdf` from `src/testpdf.zig` to a
// temp directory so `audit/qpdf_check.py` can run `qpdf --check` on
// each. This binary is not shipped — it lives only inside the audit
// harness.
//
// Usage:
//     qpdf-emit-fixtures <out_dir>
//
// On success, prints one line per fixture to stdout:
//     <fixture_name>\t<absolute_path>
//
// Failure to emit a single fixture is non-fatal — it logs the error to
// stderr and continues so the harness can still measure the rest. The
// per-fixture failure mode is the `error.*` value Zig threw, which
// `qpdf_check.py` records as a "generation_error" outcome.

const std = @import("std");
const testpdf = @import("testpdf");

// Sample text inputs for the few generators that take a payload. Kept
// minimal — we are testing PDF structural validity, not text content.
const SAMPLE_TEXT = "Hello qpdf check.";
const SAMPLE_BIDI = "abc";
const SAMPLE_PAGES_TEXT = [_][]const u8{ "Page one.", "Page two.", "Page three." };
const SAMPLE_FILTER = "FlateDecode";
const SAMPLE_CJK_UTF8 = "\xe6\x97\xa5\xe6\x9c\xac"; // "日本"

// Each entry: { name, emitter }.  An emitter consumes the (allocator,
// io, out_dir_path) tuple and writes `<out_dir_path>/<name>.pdf`.
// Returning an error is the signalled failure path.
const FixtureCtx = struct {
    a: std.mem.Allocator,
    io: std.Io,
    out_dir_path: []const u8,
};
const FixtureEmitter = struct {
    name: []const u8,
    emit: *const fn (FixtureCtx) anyerror!void,
};

fn writePdf(ctx: FixtureCtx, name: []const u8, bytes: []const u8) !void {
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.pdf", .{ ctx.out_dir_path, name });
    const file = try std.Io.Dir.cwd().createFile(ctx.io, path, .{});
    defer file.close(ctx.io);
    var fw_buf: [4096]u8 = undefined;
    var fw = file.writer(ctx.io, &fw_buf);
    try fw.interface.writeAll(bytes);
    try fw.interface.flush();
}

fn emitMinimal(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateMinimalPdf(ctx.a, SAMPLE_TEXT);
    defer ctx.a.free(b);
    try writePdf(ctx, "minimal", b);
}
fn emitMultiPage(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateMultiPagePdf(ctx.a, &SAMPLE_PAGES_TEXT);
    defer ctx.a.free(b);
    try writePdf(ctx, "multi_page", b);
}
fn emitTJ(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateTJPdf(ctx.a);
    defer ctx.a.free(b);
    try writePdf(ctx, "tj", b);
}
fn emitCIDFont(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateCIDFontPdf(ctx.a);
    defer ctx.a.free(b);
    try writePdf(ctx, "cid_font", b);
}
fn emitNoPageType(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generatePdfWithoutPageType(ctx.a, SAMPLE_TEXT);
    defer ctx.a.free(b);
    try writePdf(ctx, "no_page_type", b);
}
fn emitInlineImage(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateInlineImagePdf(ctx.a);
    defer ctx.a.free(b);
    try writePdf(ctx, "inline_image", b);
}
fn emitSuperscript(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateSuperscriptPdf(ctx.a);
    defer ctx.a.free(b);
    try writePdf(ctx, "superscript", b);
}
fn emitIncremental(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateIncrementalPdf(ctx.a);
    defer ctx.a.free(b);
    try writePdf(ctx, "incremental", b);
}
fn emitEncrypted(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateEncryptedPdf(ctx.a);
    defer ctx.a.free(b);
    try writePdf(ctx, "encrypted", b);
}
fn emitMetadata(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateMetadataPdf(ctx.a);
    defer ctx.a.free(b);
    try writePdf(ctx, "metadata", b);
}
fn emitOutline(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateOutlinePdf(ctx.a);
    defer ctx.a.free(b);
    try writePdf(ctx, "outline", b);
}
fn emitLink(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateLinkPdf(ctx.a);
    defer ctx.a.free(b);
    try writePdf(ctx, "link", b);
}
fn emitFormField(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateFormFieldPdf(ctx.a);
    defer ctx.a.free(b);
    try writePdf(ctx, "form_field", b);
}
fn emitPageLabel(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generatePageLabelPdf(ctx.a);
    defer ctx.a.free(b);
    try writePdf(ctx, "page_label", b);
}
fn emitNestedOutline(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateNestedOutlinePdf(ctx.a);
    defer ctx.a.free(b);
    try writePdf(ctx, "nested_outline", b);
}
fn emitMultiLink(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateMultiLinkPdf(ctx.a);
    defer ctx.a.free(b);
    try writePdf(ctx, "multi_link", b);
}
fn emitAllFormFields(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateAllFormFieldsPdf(ctx.a);
    defer ctx.a.free(b);
    try writePdf(ctx, "all_form_fields", b);
}
fn emitExtendedPageLabel(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateExtendedPageLabelPdf(ctx.a);
    defer ctx.a.free(b);
    try writePdf(ctx, "extended_page_label", b);
}
fn emitImage(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateImagePdf(ctx.a);
    defer ctx.a.free(b);
    try writePdf(ctx, "image", b);
}
fn emitImageFiltered(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateImagePdfWithFilter(ctx.a, SAMPLE_FILTER);
    defer ctx.a.free(b);
    try writePdf(ctx, "image_flate", b);
}
fn emitFormXObjectTable(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateFormXObjectTablePdf(ctx.a);
    defer ctx.a.free(b);
    try writePdf(ctx, "form_xobject_table", b);
}
fn emitFormXObjectIndirectSubtype(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateFormXObjectIndirectSubtypePdf(ctx.a);
    defer ctx.a.free(b);
    try writePdf(ctx, "form_xobject_indirect_subtype", b);
}
fn emitFormXObjectEscapedName(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateFormXObjectEscapedNamePdf(ctx.a);
    defer ctx.a.free(b);
    try writePdf(ctx, "form_xobject_escaped_name", b);
}
fn emitFormXObjectShadowed(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateFormXObjectShadowedXObjectPdf(ctx.a);
    defer ctx.a.free(b);
    try writePdf(ctx, "form_xobject_shadowed", b);
}
fn emitFormXObjectNullResources(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateFormXObjectNullResourcesPdf(ctx.a);
    defer ctx.a.free(b);
    try writePdf(ctx, "form_xobject_null_resources", b);
}
fn emitFormXObjectMalformedResources(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateFormXObjectMalformedResourcesPdf(ctx.a);
    defer ctx.a.free(b);
    try writePdf(ctx, "form_xobject_malformed_resources", b);
}
fn emitFormXObjectIndirectArrayElements(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateFormXObjectIndirectArrayElementsPdf(ctx.a);
    defer ctx.a.free(b);
    try writePdf(ctx, "form_xobject_indirect_array", b);
}
fn emitFormXObjectBBoxClipped(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateFormXObjectBBoxClippedPdf(ctx.a);
    defer ctx.a.free(b);
    try writePdf(ctx, "form_xobject_bbox_clipped", b);
}
fn emitFormXObjectSelfReferencing(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateFormXObjectSelfReferencingPdf(ctx.a);
    defer ctx.a.free(b);
    try writePdf(ctx, "form_xobject_self_referencing", b);
}
fn emitImageXObjectIgnoredByLattice(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateImageXObjectIgnoredByLatticePdf(ctx.a);
    defer ctx.a.free(b);
    try writePdf(ctx, "image_xobject_ignored_by_lattice", b);
}
fn emitFormXObjectIndirectRefs(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateFormXObjectIndirectRefsPdf(ctx.a);
    defer ctx.a.free(b);
    try writePdf(ctx, "form_xobject_indirect_refs", b);
}
fn emitUtf16Be(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateUtf16BePdf(ctx.a);
    defer ctx.a.free(b);
    try writePdf(ctx, "utf16_be", b);
}
fn emitTaggedTable(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateTaggedTablePdf(ctx.a);
    defer ctx.a.free(b);
    try writePdf(ctx, "tagged_table", b);
}
fn emitTaggedTableNested(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateTaggedTableNestedPdf(ctx.a);
    defer ctx.a.free(b);
    try writePdf(ctx, "tagged_table_nested", b);
}
fn emitTwoUnrelatedTables(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateTwoUnrelatedTablesPdf(ctx.a);
    defer ctx.a.free(b);
    try writePdf(ctx, "two_unrelated_tables", b);
}
fn emitLinkedContinuationTables(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateLinkedContinuationTablesPdf(ctx.a);
    defer ctx.a.free(b);
    try writePdf(ctx, "linked_continuation_tables", b);
}
fn emitLatticeWithText(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateLatticeWithTextPdf(ctx.a);
    defer ctx.a.free(b);
    try writePdf(ctx, "lattice_with_text", b);
}
fn emitBidi(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateBidiPdf(ctx.a, SAMPLE_BIDI);
    defer ctx.a.free(b);
    try writePdf(ctx, "bidi", b);
}
fn emitCjkUtf8H(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateCjkPdfFromUtf8(ctx.a, SAMPLE_CJK_UTF8, 0);
    defer ctx.a.free(b);
    try writePdf(ctx, "cjk_utf8_h", b);
}
fn emitCjkUtf8V(ctx: FixtureCtx) anyerror!void {
    const b = try testpdf.generateCjkPdfFromUtf8(ctx.a, SAMPLE_CJK_UTF8, 1);
    defer ctx.a.free(b);
    try writePdf(ctx, "cjk_utf8_v", b);
}

const ALL_FIXTURES = [_]FixtureEmitter{
    .{ .name = "minimal", .emit = emitMinimal },
    .{ .name = "multi_page", .emit = emitMultiPage },
    .{ .name = "tj", .emit = emitTJ },
    .{ .name = "cid_font", .emit = emitCIDFont },
    .{ .name = "no_page_type", .emit = emitNoPageType },
    .{ .name = "inline_image", .emit = emitInlineImage },
    .{ .name = "superscript", .emit = emitSuperscript },
    .{ .name = "incremental", .emit = emitIncremental },
    .{ .name = "encrypted", .emit = emitEncrypted },
    .{ .name = "metadata", .emit = emitMetadata },
    .{ .name = "outline", .emit = emitOutline },
    .{ .name = "link", .emit = emitLink },
    .{ .name = "form_field", .emit = emitFormField },
    .{ .name = "page_label", .emit = emitPageLabel },
    .{ .name = "nested_outline", .emit = emitNestedOutline },
    .{ .name = "multi_link", .emit = emitMultiLink },
    .{ .name = "all_form_fields", .emit = emitAllFormFields },
    .{ .name = "extended_page_label", .emit = emitExtendedPageLabel },
    .{ .name = "image", .emit = emitImage },
    .{ .name = "image_flate", .emit = emitImageFiltered },
    .{ .name = "form_xobject_table", .emit = emitFormXObjectTable },
    .{ .name = "form_xobject_indirect_subtype", .emit = emitFormXObjectIndirectSubtype },
    .{ .name = "form_xobject_escaped_name", .emit = emitFormXObjectEscapedName },
    .{ .name = "form_xobject_shadowed", .emit = emitFormXObjectShadowed },
    .{ .name = "form_xobject_null_resources", .emit = emitFormXObjectNullResources },
    .{ .name = "form_xobject_malformed_resources", .emit = emitFormXObjectMalformedResources },
    .{ .name = "form_xobject_indirect_array", .emit = emitFormXObjectIndirectArrayElements },
    .{ .name = "form_xobject_bbox_clipped", .emit = emitFormXObjectBBoxClipped },
    .{ .name = "form_xobject_self_referencing", .emit = emitFormXObjectSelfReferencing },
    .{ .name = "image_xobject_ignored_by_lattice", .emit = emitImageXObjectIgnoredByLattice },
    .{ .name = "form_xobject_indirect_refs", .emit = emitFormXObjectIndirectRefs },
    .{ .name = "utf16_be", .emit = emitUtf16Be },
    .{ .name = "tagged_table", .emit = emitTaggedTable },
    .{ .name = "tagged_table_nested", .emit = emitTaggedTableNested },
    .{ .name = "two_unrelated_tables", .emit = emitTwoUnrelatedTables },
    .{ .name = "linked_continuation_tables", .emit = emitLinkedContinuationTables },
    .{ .name = "lattice_with_text", .emit = emitLatticeWithText },
    .{ .name = "bidi", .emit = emitBidi },
    .{ .name = "cjk_utf8_h", .emit = emitCjkUtf8H },
    .{ .name = "cjk_utf8_v", .emit = emitCjkUtf8V },
};

pub fn main(init: std.process.Init) !u8 {
    const a = init.gpa;
    const io = init.io;

    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len < 2) {
        std.debug.print("usage: qpdf-emit-fixtures <out_dir>\n", .{});
        return 1;
    }
    const out_dir_path: []const u8 = argv[1];

    // Ensure the directory exists; harmless if already present.
    std.Io.Dir.cwd().createDirPath(io, out_dir_path) catch {};

    const ctx = FixtureCtx{ .a = a, .io = io, .out_dir_path = out_dir_path };

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_w.interface;
    defer stdout.flush() catch {};
    var stderr_buf: [4096]u8 = undefined;
    var stderr_w = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_w.interface;
    defer stderr.flush() catch {};

    var ok: usize = 0;
    var fail: usize = 0;
    inline for (ALL_FIXTURES) |fx| {
        if (fx.emit(ctx)) |_| {
            try stdout.print("OK\t{s}\n", .{fx.name});
            ok += 1;
        } else |e| {
            try stderr.print("EMIT_FAIL\t{s}\t{s}\n", .{ fx.name, @errorName(e) });
            fail += 1;
        }
    }
    if (fail > 0 and ok == 0) return 1;
    return 0;
}
