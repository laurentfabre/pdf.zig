//! PR-W8 [feat]: image XObject writer.
//!
//! Sits beside `pdf_resources.ImageEntry`. The registry holds an
//! `*ImageRef` per registered image; on `emitImageObjects` it walks
//! the list and calls `emitImageObject` for each one — exactly how
//! the font flow works.
//!
//! ## Encoding modes
//!
//! - `dct_passthrough`: `bytes` is a complete JPEG byte stream. We
//!   emit `/Filter /DCTDecode` + the bytes verbatim. The reader's
//!   downstream JPEG codec does the heavy lifting.
//! - `raw_uncompressed`: `bytes` is `width * height * components *
//!   bits/8` raw sample bytes. Emitted with no /Filter; small but
//!   bandwidth-fat — use only for tiny images / debug.
//! - `raw_flate`: `bytes` is raw samples; we run them through
//!   `writer.writeStreamCompressed` (zlib-DEFLATE) and emit
//!   `/Filter /FlateDecode`.
//!
//! ## Defensive posture
//!
//! - JPEG bytes are caller-provided and untrusted. We do NOT re-parse
//!   them here — `pdf_document.addImageJpeg` validated geometry via
//!   `jpeg_meta.parse` before construction. The writer treats them
//!   as opaque.
//! - `obj_num` is asserted non-zero before emission (registry assigns
//!   it lazily; emitting before assignment is a builder bug).
//! - Width / height / bits_per_component are asserted plausible.

const std = @import("std");
const pdf_writer = @import("pdf_writer.zig");

pub const Encoding = enum {
    dct_passthrough,
    raw_uncompressed,
    raw_flate,
};

pub const ColorSpace = enum {
    gray,
    rgb,
    cmyk,

    fn pdfName(self: ColorSpace) []const u8 {
        return switch (self) {
            .gray => "/DeviceGray",
            .rgb => "/DeviceRGB",
            .cmyk => "/DeviceCMYK",
        };
    }
};

/// Owned by the registry. `bytes` is the full encoded payload (JPEG
/// stream for `dct_passthrough`, raw samples otherwise). The registry
/// allocates and frees this slice; callers pass borrowed bytes to
/// `DocumentBuilder.addImage*` and the document copies on register.
pub const ImageRef = struct {
    bytes: []const u8,
    encoding: Encoding,
    width: u32,
    height: u32,
    bits_per_component: u8,
    colorspace: ColorSpace,
    /// Indirect-object number assigned at registry-emit time.
    /// Zero = "not yet assigned" (matches the font flow's sentinel).
    obj_num: u32 = 0,
};

/// Emit one indirect-object body for an image XObject. The writer
/// must be positioned outside any open object — `emitImageObject`
/// calls `beginObject` / `endObject` itself.
pub fn emitImageObject(
    ref: *const ImageRef,
    w: *pdf_writer.Writer,
) !void {
    std.debug.assert(ref.obj_num != 0);
    std.debug.assert(ref.width > 0);
    std.debug.assert(ref.height > 0);
    std.debug.assert(ref.bits_per_component == 1 or
        ref.bits_per_component == 2 or
        ref.bits_per_component == 4 or
        ref.bits_per_component == 8 or
        ref.bits_per_component == 16);

    try w.beginObject(ref.obj_num, 0);

    // Compose the dict prefix shared by all three encodings.
    // /Length is filled in by writeStream / writeStreamCompressed; we
    // pass everything else as `extra_dict`.
    var dict_buf: std.ArrayList(u8) = .empty;
    defer dict_buf.deinit(w.allocator);

    try dict_buf.appendSlice(w.allocator, " /Type /XObject /Subtype /Image");
    try dict_buf.appendSlice(w.allocator, " /Width ");
    try appendInt(&dict_buf, w.allocator, ref.width);
    try dict_buf.appendSlice(w.allocator, " /Height ");
    try appendInt(&dict_buf, w.allocator, ref.height);
    try dict_buf.appendSlice(w.allocator, " /ColorSpace ");
    try dict_buf.appendSlice(w.allocator, ref.colorspace.pdfName());
    try dict_buf.appendSlice(w.allocator, " /BitsPerComponent ");
    try appendInt(&dict_buf, w.allocator, ref.bits_per_component);

    switch (ref.encoding) {
        .dct_passthrough => {
            // PDF 1.7 §8.9.5.1 /Filter /DCTDecode applies to JPEG byte
            // streams emitted verbatim. Length comes from the body
            // length supplied to writeStream.
            try dict_buf.appendSlice(w.allocator, " /Filter /DCTDecode");
            try w.writeStream(ref.bytes, dict_buf.items);
        },
        .raw_uncompressed => {
            // No /Filter; raw samples in row-major / component-interleaved
            // order per PDF §8.9.5.
            try w.writeStream(ref.bytes, dict_buf.items);
        },
        .raw_flate => {
            // writeStreamCompressed prepends `/Filter /FlateDecode` to
            // the extra_dict for us, so we don't add it here.
            try w.writeStreamCompressed(ref.bytes, dict_buf.items);
        },
    }

    try w.endObject();
}

fn appendInt(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, n: u32) !void {
    var tmp: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch unreachable;
    try buf.appendSlice(allocator, s);
}

// ---------- tests ----------

test "emitImageObject: dct_passthrough emits /DCTDecode + verbatim bytes" {
    const allocator = std.testing.allocator;
    var w = pdf_writer.Writer.init(allocator);
    defer w.deinit();

    const fake_jpeg = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 'J', 'F', 'I', 'F', 0, 1, 1, 0, 0, 0, 0, 0, 0xFF, 0xD9 };
    var ref: ImageRef = .{
        .bytes = &fake_jpeg,
        .encoding = .dct_passthrough,
        .width = 320,
        .height = 240,
        .bits_per_component = 8,
        .colorspace = .rgb,
    };
    ref.obj_num = try w.allocObjectNum();

    try emitImageObject(&ref, &w);

    const out = w.buf.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "/Subtype /Image") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/Width 320") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/Height 240") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/ColorSpace /DeviceRGB") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/BitsPerComponent 8") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/Filter /DCTDecode") != null);
    // Verbatim JPEG bytes survive into the stream.
    try std.testing.expect(std.mem.indexOf(u8, out, &fake_jpeg) != null);
}

test "emitImageObject: cmyk colorspace emits /DeviceCMYK" {
    const allocator = std.testing.allocator;
    var w = pdf_writer.Writer.init(allocator);
    defer w.deinit();

    const fake_bytes = [_]u8{0xAA} ** 16;
    var ref: ImageRef = .{
        .bytes = &fake_bytes,
        .encoding = .dct_passthrough,
        .width = 2,
        .height = 2,
        .bits_per_component = 8,
        .colorspace = .cmyk,
    };
    ref.obj_num = try w.allocObjectNum();

    try emitImageObject(&ref, &w);
    const out = w.buf.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "/ColorSpace /DeviceCMYK") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/ColorSpace /DeviceRGB") == null);
}

test "emitImageObject: gray colorspace emits /DeviceGray" {
    const allocator = std.testing.allocator;
    var w = pdf_writer.Writer.init(allocator);
    defer w.deinit();

    const fake_bytes = [_]u8{0xAA} ** 4;
    var ref: ImageRef = .{
        .bytes = &fake_bytes,
        .encoding = .raw_uncompressed,
        .width = 2,
        .height = 2,
        .bits_per_component = 8,
        .colorspace = .gray,
    };
    ref.obj_num = try w.allocObjectNum();

    try emitImageObject(&ref, &w);
    const out = w.buf.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "/ColorSpace /DeviceGray") != null);
    // raw_uncompressed must NOT emit /Filter
    try std.testing.expect(std.mem.indexOf(u8, out, "/Filter") == null);
}

test "emitImageObject: raw_flate emits /FlateDecode" {
    const allocator = std.testing.allocator;
    var w = pdf_writer.Writer.init(allocator);
    defer w.deinit();

    // Highly redundant body so DEFLATE actually has something to compress.
    const body = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" ** 16;
    var ref: ImageRef = .{
        .bytes = body,
        .encoding = .raw_flate,
        .width = 8,
        .height = 8,
        .bits_per_component = 8,
        .colorspace = .gray,
    };
    ref.obj_num = try w.allocObjectNum();

    try emitImageObject(&ref, &w);
    const out = w.buf.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "/Filter /FlateDecode") != null);
}

test "FailingAllocator: emitImageObject dct path leaks nothing" {
    var fail_index: usize = 0;
    while (fail_index < 32) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        const allocator = failing.allocator();
        var w = pdf_writer.Writer.init(allocator);
        defer w.deinit();

        const fake_jpeg = [_]u8{ 0xFF, 0xD8, 0xFF, 0xD9 };
        const obj = w.allocObjectNum() catch continue;
        var ref: ImageRef = .{
            .bytes = &fake_jpeg,
            .encoding = .dct_passthrough,
            .width = 4,
            .height = 4,
            .bits_per_component = 8,
            .colorspace = .rgb,
        };
        ref.obj_num = obj;
        _ = emitImageObject(&ref, &w) catch {};
    }
}
