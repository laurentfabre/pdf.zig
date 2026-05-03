//! PR-15 [feat]: synthetic CJK corpus generator.
//!
//! Standalone executable that materialises the 15 synthetic CJK
//! fixtures from `testpdf.zig` to disk. Run via:
//!
//!     zig build gen-cjk-corpus
//!
//! Output: `audit/cjk-pdfs/synthetic/<id>.pdf` (one per fixture in
//! `testpdf.cjk_fixtures`) plus a manifest at
//! `audit/cjk-pdfs/synthetic/manifest.json` with the expected text +
//! wmode for each PDF.  The Python harness (`v1_4_cjk_run.py`) reads
//! the manifest as ground truth.
//!
//! Designed to be idempotent — re-running overwrites identical bytes.
//! No third-party deps; uses only stdlib + `testpdf.zig`.

const std = @import("std");
const testpdf = @import("testpdf.zig");

const OUT_DIR = "audit/cjk-pdfs/synthetic";

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.Io.Dir.cwd().createDirPath(io, OUT_DIR) catch {};

    // Manifest writer.
    var manifest_buf = std.Io.Writer.Allocating.init(allocator);
    defer manifest_buf.deinit();
    const mw = &manifest_buf.writer;
    try mw.writeAll("{\n  \"version\": 1,\n  \"fixtures\": [\n");

    var stderr_buf: [1024]u8 = undefined;
    var stderr_w = std.Io.File.stderr().writer(io, &stderr_buf);
    const sw = &stderr_w.interface;
    defer sw.flush() catch {};

    var first: bool = true;
    for (testpdf.cjk_fixtures) |fixture| {
        const pdf_data = try testpdf.generateCjkPdfFromUtf8(allocator, fixture.utf8, fixture.wmode);
        defer allocator.free(pdf_data);

        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.pdf", .{ OUT_DIR, fixture.id });

        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        var fw_buf: [4096]u8 = undefined;
        var fw = file.writer(io, &fw_buf);
        try fw.interface.writeAll(pdf_data);
        try fw.interface.flush();

        try sw.print("wrote {s} ({d} bytes, lang={s}, wmode={d})\n", .{
            path, pdf_data.len, fixture.lang, fixture.wmode,
        });

        if (!first) try mw.writeAll(",\n");
        first = false;
        try mw.writeAll("    {");
        try mw.print("\"id\":\"{s}\",", .{fixture.id});
        try mw.print("\"lang\":\"{s}\",", .{fixture.lang});
        try mw.print("\"wmode\":{d},", .{fixture.wmode});
        try mw.print("\"path\":\"{s}.pdf\",", .{fixture.id});
        try mw.writeAll("\"expected_utf8\":\"");
        // JSON-escape the UTF-8 string. Only `"` and `\` and control
        // bytes need escaping; CJK bytes pass through unchanged.
        for (fixture.utf8) |b| {
            switch (b) {
                '"' => try mw.writeAll("\\\""),
                '\\' => try mw.writeAll("\\\\"),
                '\n' => try mw.writeAll("\\n"),
                '\r' => try mw.writeAll("\\r"),
                '\t' => try mw.writeAll("\\t"),
                else => {
                    if (b < 0x20) {
                        try mw.print("\\u{x:0>4}", .{b});
                    } else {
                        try mw.writeByte(b);
                    }
                },
            }
        }
        try mw.writeAll("\"}");
    }
    try mw.writeAll("\n  ]\n}\n");

    var manifest_path_buf: [256]u8 = undefined;
    const manifest_path = try std.fmt.bufPrint(&manifest_path_buf, "{s}/manifest.json", .{OUT_DIR});
    const mf = try std.Io.Dir.cwd().createFile(io, manifest_path, .{});
    defer mf.close(io);
    var mfw_buf: [4096]u8 = undefined;
    var mfw = mf.writer(io, &mfw_buf);
    try mfw.interface.writeAll(manifest_buf.written());
    try mfw.interface.flush();

    try sw.print("manifest at {s} ({d} bytes)\n", .{ manifest_path, manifest_buf.written().len });
}
