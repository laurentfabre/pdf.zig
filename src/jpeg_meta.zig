//! PR-W8 [feat]: bare-minimum JPEG SOF (Start Of Frame) parser.
//!
//! For the writer's `/DCTDecode` passthrough flow we just need the
//! image's geometry + colorspace to populate the XObject dict before
//! emitting the JPEG bytes verbatim. No huffman tables, no quantization
//! tables, no entropy decoding — the PDF reader's downstream consumer
//! decodes the actual pixels.
//!
//! ## What this parser does
//!
//! - Walks the JPEG marker stream from `SOI` (FF D8) onward.
//! - Skips APPn / DQT / DHT / DRI / COM segments without inspecting
//!   their contents (length-prefixed; safe to bounded-skip).
//! - Stops at the first `SOFx` marker (Start Of Frame), reads the
//!   1 + 2 + 2 + 1 fixed prefix (precision, height, width, components),
//!   and returns.
//!
//! ## Defensive posture
//!
//! Adversarial-input territory. Every read is bounds-checked.
//! Truncated or malformed bytes return `error.TruncatedJpeg` /
//! `error.MalformedJpeg`, never panic.
//!
//! ## What this parser does NOT do
//!
//! - Decode any pixel data.
//! - Validate that SOF + DQT/DHT exist together.
//! - Reorder progressive scans.
//! - Recompute checksums.

const std = @import("std");

pub const ColorSpace = enum { gray, rgb, cmyk };

pub const JpegMeta = struct {
    width: u32,
    height: u32,
    bits_per_component: u8, // typically 8
    colorspace: ColorSpace,
};

pub const Error = error{
    TruncatedJpeg,
    MalformedJpeg,
    UnsupportedSofMarker,
    UnsupportedComponentCount,
    UnsupportedBitDepth,
};

const SOI: u8 = 0xD8;
const EOI: u8 = 0xD9;
const SOS: u8 = 0xDA;

/// Parse a JPEG byte stream and return its image header metadata.
///
/// The stream must start with `FF D8` (SOI). The first SOF marker we
/// encounter wins; everything before it (APPn / DQT / DHT / DRI / COM)
/// is bounded-skipped via the segment-length prefix.
pub fn parse(bytes: []const u8) Error!JpegMeta {
    if (bytes.len < 2) return error.TruncatedJpeg;
    if (bytes[0] != 0xFF or bytes[1] != SOI) return error.MalformedJpeg;

    var i: usize = 2;
    while (i + 1 < bytes.len) {
        // Marker prefix: an `0xFF` byte (possibly repeated as a fill
        // byte, per ITU-T T.81 B.1.1.2) followed by the marker code.
        if (bytes[i] != 0xFF) return error.MalformedJpeg;
        // Skip fill bytes — multiple `0xFF` in a row are legal.
        var marker_pos = i + 1;
        while (marker_pos < bytes.len and bytes[marker_pos] == 0xFF) marker_pos += 1;
        if (marker_pos >= bytes.len) return error.TruncatedJpeg;
        const marker = bytes[marker_pos];
        i = marker_pos + 1;

        // Standalone markers (no length, no payload): SOI / EOI / TEM /
        // RSTm. We've already past SOI; if we see EOI before SOF the
        // file has no frame.
        if (marker == EOI) return error.MalformedJpeg;
        if (marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7)) {
            continue;
        }

        // Start-Of-Scan ends the marker prefix region. If we hit SOS
        // before any SOF we have a malformed file (or one we can't
        // handle without entropy-decoding into the scan body).
        if (marker == SOS) return error.MalformedJpeg;

        // All remaining markers are length-prefixed. The 16-bit length
        // is big-endian and INCLUDES its own 2 bytes.
        if (i + 2 > bytes.len) return error.TruncatedJpeg;
        const seg_len = (@as(u16, bytes[i]) << 8) | @as(u16, bytes[i + 1]);
        if (seg_len < 2) return error.MalformedJpeg;
        const seg_body_len: usize = @as(usize, seg_len) - 2;
        const body_start = i + 2;
        const body_end = body_start + seg_body_len;
        if (body_end > bytes.len) return error.TruncatedJpeg;

        // Is this an SOF marker?
        if (isSofMarker(marker)) {
            try ensureSupportedSof(marker);
            return parseSofPayload(bytes[body_start..body_end]);
        }

        // Not SOF: bounded-skip and continue.
        i = body_end;
    }

    return error.TruncatedJpeg;
}

/// True for any of the 16 SOFx codes (0xC0 .. 0xCF) excluding the
/// non-frame markers in that range: DHT (0xC4), JPG (0xC8), DAC (0xCC).
/// The supported/unsupported split happens later in `ensureSupportedSof`.
fn isSofMarker(m: u8) bool {
    if (m < 0xC0 or m > 0xCF) return false;
    return m != 0xC4 and m != 0xC8 and m != 0xCC;
}

/// Reject arithmetic-coded SOFs (SOF9–11, SOF13–15). PDF 1.7 §8.9.5.1.5
/// /DCTDecode is defined for huffman-coded baseline / extended /
/// progressive / lossless only — arithmetic coding is permitted by the
/// JPEG standard but rare and unevenly supported by readers.
fn ensureSupportedSof(marker: u8) Error!void {
    switch (marker) {
        // SOF0..SOF3: huffman-coded — accept.
        0xC0, 0xC1, 0xC2, 0xC3 => return,
        // SOF5/6/7: differential huffman — rare but legal /DCTDecode.
        // Treat as unsupported for now; PDF readers in the wild rarely
        // accept these and the writer has no use case.
        0xC5, 0xC6, 0xC7 => return error.UnsupportedSofMarker,
        // SOF9/10/11/13/14/15: arithmetic-coded — reject.
        0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF => return error.UnsupportedSofMarker,
        else => return error.UnsupportedSofMarker,
    }
}

/// SOF body layout (ITU-T T.81 B.2.2):
///   - Lf  (segment length)        — already stripped by caller
///   - P   (sample precision)      u8
///   - Y   (number of lines)       u16 BE
///   - X   (samples per line)      u16 BE
///   - Nf  (components)            u8
///   - per-component descriptor    3 bytes × Nf (id, sampling, Tq)
fn parseSofPayload(body: []const u8) Error!JpegMeta {
    // 6 fixed bytes (P + Y + X + Nf) + at least 1 component (3 bytes).
    if (body.len < 6) return error.TruncatedJpeg;

    const precision = body[0];
    const height: u32 = (@as(u32, body[1]) << 8) | @as(u32, body[2]);
    const width: u32 = (@as(u32, body[3]) << 8) | @as(u32, body[4]);
    const num_components = body[5];

    // PDF /BitsPerComponent legal values are 1, 2, 4, 8, 16. JPEG only
    // emits 8 (baseline) or 12/16 (extended/lossless). Restrict to what
    // a PDF reader will accept downstream.
    if (precision != 8 and precision != 12 and precision != 16) {
        return error.UnsupportedBitDepth;
    }

    // Frame must declare at least one component.
    if (num_components == 0) return error.UnsupportedComponentCount;

    // Component descriptor bytes must fit. Each is 3 bytes.
    const expected_descriptor_bytes: usize = 3 * @as(usize, num_components);
    if (body.len < 6 + expected_descriptor_bytes) return error.TruncatedJpeg;

    // Defensive: assert descriptor area is consistent. TigerStyle pair
    // assertion — we read num_components from the body and we expect
    // exactly num_components × 3 trailing bytes. The check above is the
    // public-facing version; the assert is the internal mirror.
    std.debug.assert(body.len >= 6 + expected_descriptor_bytes);

    const colorspace: ColorSpace = switch (num_components) {
        1 => .gray,
        3 => .rgb,
        4 => .cmyk,
        else => return error.UnsupportedComponentCount,
    };

    if (width == 0 or height == 0) return error.MalformedJpeg;

    return .{
        .width = width,
        .height = height,
        .bits_per_component = precision,
        .colorspace = colorspace,
    };
}

// ---------- tests ----------

/// Build the smallest plausible JPEG byte stream that exposes a SOFx
/// marker and a 1-byte component descriptor (n components × 3 bytes).
/// No DQT / DHT / SOS / EOI — the parser stops at SOFx and never reads
/// beyond.
fn buildSyntheticSof(
    sof_marker: u8,
    width: u16,
    height: u16,
    precision: u8,
    components: u8,
    out: []u8,
) usize {
    var i: usize = 0;
    out[i] = 0xFF;
    out[i + 1] = SOI;
    i += 2;
    out[i] = 0xFF;
    out[i + 1] = sof_marker;
    i += 2;
    // Length = 2 (length itself) + 6 (fixed) + 3*components.
    const seg_len: u16 = 2 + 6 + 3 * @as(u16, components);
    out[i] = @intCast(seg_len >> 8);
    out[i + 1] = @intCast(seg_len & 0xFF);
    i += 2;
    out[i] = precision;
    i += 1;
    out[i] = @intCast(height >> 8);
    out[i + 1] = @intCast(height & 0xFF);
    i += 2;
    out[i] = @intCast(width >> 8);
    out[i + 1] = @intCast(width & 0xFF);
    i += 2;
    out[i] = components;
    i += 1;
    var c: u8 = 0;
    while (c < components) : (c += 1) {
        out[i] = c + 1; // id
        out[i + 1] = 0x11; // sampling 1×1
        out[i + 2] = 0; // Tq
        i += 3;
    }
    return i;
}

test "parse rejects empty input" {
    try std.testing.expectError(error.TruncatedJpeg, parse(&.{}));
}

test "parse rejects missing SOI" {
    try std.testing.expectError(error.MalformedJpeg, parse(&[_]u8{ 0x00, 0x00 }));
}

test "parse SOF0 baseline JPEG returns rgb 8-bit" {
    var buf: [64]u8 = undefined;
    const len = buildSyntheticSof(0xC0, 320, 240, 8, 3, &buf);
    const meta = try parse(buf[0..len]);
    try std.testing.expectEqual(@as(u32, 320), meta.width);
    try std.testing.expectEqual(@as(u32, 240), meta.height);
    try std.testing.expectEqual(@as(u8, 8), meta.bits_per_component);
    try std.testing.expectEqual(ColorSpace.rgb, meta.colorspace);
}

test "parse SOF2 progressive JPEG accepted" {
    var buf: [64]u8 = undefined;
    const len = buildSyntheticSof(0xC2, 100, 50, 8, 3, &buf);
    const meta = try parse(buf[0..len]);
    try std.testing.expectEqual(@as(u32, 100), meta.width);
    try std.testing.expectEqual(ColorSpace.rgb, meta.colorspace);
}

test "parse SOF9 arithmetic JPEG rejected" {
    var buf: [64]u8 = undefined;
    const len = buildSyntheticSof(0xC9, 100, 50, 8, 3, &buf);
    try std.testing.expectError(error.UnsupportedSofMarker, parse(buf[0..len]));
}

test "parse 1-component SOF returns gray" {
    var buf: [64]u8 = undefined;
    const len = buildSyntheticSof(0xC0, 8, 8, 8, 1, &buf);
    const meta = try parse(buf[0..len]);
    try std.testing.expectEqual(ColorSpace.gray, meta.colorspace);
}

test "parse 4-component SOF returns cmyk" {
    var buf: [64]u8 = undefined;
    const len = buildSyntheticSof(0xC0, 16, 16, 8, 4, &buf);
    const meta = try parse(buf[0..len]);
    try std.testing.expectEqual(ColorSpace.cmyk, meta.colorspace);
}

test "parse 2-component SOF rejected" {
    var buf: [64]u8 = undefined;
    const len = buildSyntheticSof(0xC0, 16, 16, 8, 2, &buf);
    try std.testing.expectError(error.UnsupportedComponentCount, parse(buf[0..len]));
}

test "parse rejects unsupported bit depth" {
    var buf: [64]u8 = undefined;
    const len = buildSyntheticSof(0xC0, 8, 8, 10, 3, &buf);
    try std.testing.expectError(error.UnsupportedBitDepth, parse(buf[0..len]));
}

test "parse skips APP0 (JFIF) segment before SOF" {
    // SOI + APP0(JFIF length=16) + SOF0(rgb 320x240). The parser must
    // bounded-skip APP0 without inspecting its contents.
    var buf: [128]u8 = undefined;
    var i: usize = 0;
    buf[i] = 0xFF;
    buf[i + 1] = SOI;
    i += 2;
    // APP0 marker
    buf[i] = 0xFF;
    buf[i + 1] = 0xE0;
    i += 2;
    // Length = 16 (2 length + 14 body)
    buf[i] = 0x00;
    buf[i + 1] = 0x10;
    i += 2;
    // 14 bytes of garbage that look like a JFIF body
    const jfif_body = [_]u8{ 'J', 'F', 'I', 'F', 0, 1, 1, 0, 0x48, 0, 0x48, 0, 0, 0 };
    @memcpy(buf[i .. i + 14], &jfif_body);
    i += 14;
    // Now an SOF0 with rgb 320x240
    const sof_len = buildSyntheticSof(0xC0, 320, 240, 8, 3, buf[i..]);
    // buildSyntheticSof emits its own SOI; strip those 2 bytes since we
    // already wrote one. The marker layout immediately after our APP0
    // should be FF C0 (SOF0), not another FF D8 (SOI).
    // Easier: just construct SOF0 manually inline.
    // Reset and rebuild without nested SOI:
    i = 0;
    buf[i] = 0xFF;
    buf[i + 1] = SOI;
    i += 2;
    buf[i] = 0xFF;
    buf[i + 1] = 0xE0;
    i += 2;
    buf[i] = 0x00;
    buf[i + 1] = 0x10;
    i += 2;
    @memcpy(buf[i .. i + 14], &jfif_body);
    i += 14;
    // SOF0
    buf[i] = 0xFF;
    buf[i + 1] = 0xC0;
    i += 2;
    // Length = 2 + 6 + 9 = 17
    buf[i] = 0x00;
    buf[i + 1] = 17;
    i += 2;
    buf[i] = 8; // precision
    i += 1;
    buf[i] = 0x00;
    buf[i + 1] = 0xF0; // height = 240
    i += 2;
    buf[i] = 0x01;
    buf[i + 1] = 0x40; // width = 320
    i += 2;
    buf[i] = 3; // components
    i += 1;
    var c: u8 = 0;
    while (c < 3) : (c += 1) {
        buf[i] = c + 1;
        buf[i + 1] = 0x11;
        buf[i + 2] = 0;
        i += 3;
    }
    _ = sof_len;
    const meta = try parse(buf[0..i]);
    try std.testing.expectEqual(@as(u32, 320), meta.width);
    try std.testing.expectEqual(@as(u32, 240), meta.height);
}

test "parse rejects truncated segment-length prefix" {
    // SOI, FF E0 (APP0), then nothing.
    const bytes = [_]u8{ 0xFF, SOI, 0xFF, 0xE0 };
    try std.testing.expectError(error.TruncatedJpeg, parse(&bytes));
}

test "parse rejects truncated payload" {
    // SOI, FF E0, length=16 but only 4 body bytes follow.
    const bytes = [_]u8{ 0xFF, SOI, 0xFF, 0xE0, 0x00, 0x10, 0x01, 0x02, 0x03, 0x04 };
    try std.testing.expectError(error.TruncatedJpeg, parse(&bytes));
}

test "parse rejects zero-length segment" {
    const bytes = [_]u8{ 0xFF, SOI, 0xFF, 0xE0, 0x00, 0x00 };
    try std.testing.expectError(error.MalformedJpeg, parse(&bytes));
}

test "parse rejects EOI before SOF" {
    const bytes = [_]u8{ 0xFF, SOI, 0xFF, EOI };
    try std.testing.expectError(error.MalformedJpeg, parse(&bytes));
}

test "parse handles fill bytes between marker prefix and code" {
    // FF FF FF C0 ... (extra FFs are legal fill).
    var buf: [64]u8 = undefined;
    var i: usize = 0;
    buf[i] = 0xFF;
    buf[i + 1] = SOI;
    i += 2;
    buf[i] = 0xFF;
    buf[i + 1] = 0xFF; // fill
    buf[i + 2] = 0xFF; // fill
    buf[i + 3] = 0xC0;
    i += 4;
    buf[i] = 0x00;
    buf[i + 1] = 17;
    i += 2;
    buf[i] = 8;
    i += 1;
    buf[i] = 0x00;
    buf[i + 1] = 0x10;
    i += 2;
    buf[i] = 0x00;
    buf[i + 1] = 0x10;
    i += 2;
    buf[i] = 3;
    i += 1;
    var c: u8 = 0;
    while (c < 3) : (c += 1) {
        buf[i] = c + 1;
        buf[i + 1] = 0x11;
        buf[i + 2] = 0;
        i += 3;
    }
    const meta = try parse(buf[0..i]);
    try std.testing.expectEqual(@as(u32, 16), meta.width);
}
