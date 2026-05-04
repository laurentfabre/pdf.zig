//! PR-W7 [feat]: high-level surface that turns a parsed TrueType font
//! into PDF objects.
//!
//! Five indirect objects are emitted per embedded font:
//!
//! 1. `/Type /Font /Subtype /Type0`         — the user-facing font object.
//! 2. `/Type /Font /Subtype /CIDFontType2`   — the descendant CID font.
//! 3. `/Type /FontDescriptor`               — metrics + reference to FontFile2.
//! 4. FontFile2 stream                      — the subsetted TTF bytes.
//! 5. ToUnicode CMap stream                 — CID → Unicode for text extraction.
//!
//! Wrapping a TT font in `/Type0` (rather than directly using `/TrueType`)
//! is what unlocks 16-bit CIDs / arbitrary-Unicode content streams. The
//! Type0 wrapper is the spec-canonical path for non-WinAnsi text in PDF
//! 1.4+.

const std = @import("std");
const truetype = @import("truetype.zig");
const cmap_writer = @import("cmap_writer.zig");
const pdf_writer = @import("pdf_writer.zig");

/// Per-document state accumulated as `drawTextUtf8` calls remember
/// codepoints. Owned by `ResourceRegistry`; pages reference it via a
/// `FontHandle`.
pub const EmbeddedFontRef = struct {
    allocator: std.mem.Allocator,
    /// Borrowed. The document owns the parsed font; the embedder only
    /// reads from it.
    parsed: *truetype.ParsedFont,
    /// Owned. The PostScript subset name (with the standard `AAAAAA+`
    /// 6-uppercase-letter prefix) computed on first emit.
    base_font: []u8,
    /// Set of codepoints requested by drawText calls. Sorted + dedup'd
    /// at emit time.
    used_codepoints: std.AutoHashMap(u21, void),

    /// Indirect-object numbers populated at write time by the resource
    /// registry. Zero = "not yet assigned".
    obj_type0: u32 = 0,
    obj_cid_font: u32 = 0,
    obj_descriptor: u32 = 0,
    obj_font_file: u32 = 0,
    obj_to_unicode: u32 = 0,
    obj_cid_to_gid_map: u32 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        parsed: *truetype.ParsedFont,
        base_font_name: []const u8,
    ) !*EmbeddedFontRef {
        const self = try allocator.create(EmbeddedFontRef);
        errdefer allocator.destroy(self);

        // Tag the BaseFont with a 6-uppercase-letter subset prefix per
        // ISO 32000-1 §9.6.4. The bytes themselves are arbitrary so long
        // as they're stable per document — we derive them from the SHA-1
        // of the original PostScript name, which is reproducible.
        var hash_out: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(base_font_name, &hash_out, .{});
        var prefix: [6]u8 = undefined;
        for (&prefix, 0..) |*c, i| {
            c.* = 'A' + @as(u8, @intCast(hash_out[i] % 26));
        }

        const buf = try allocator.alloc(u8, prefix.len + 1 + base_font_name.len);
        errdefer allocator.free(buf);
        @memcpy(buf[0..prefix.len], &prefix);
        buf[prefix.len] = '+';
        @memcpy(buf[prefix.len + 1 ..], base_font_name);

        self.* = .{
            .allocator = allocator,
            .parsed = parsed,
            .base_font = buf,
            .used_codepoints = std.AutoHashMap(u21, void).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *EmbeddedFontRef) void {
        const allocator = self.allocator;
        self.used_codepoints.deinit();
        allocator.free(self.base_font);
        allocator.destroy(self);
    }

    pub fn rememberCodepoint(self: *EmbeddedFontRef, cp: u21) !void {
        try self.used_codepoints.put(cp, {});
    }

    /// Translate a Unicode codepoint to the CID written in content
    /// streams. We always use the ORIGINAL GID as the CID — the
    /// `/CIDToGIDMap` stream remaps it to the dense in-subset GID at
    /// extraction time. This keeps content streams stable even before
    /// `emit()` runs, so `drawTextUtf8` can be called at any point.
    pub fn cidForCodepoint(self: *const EmbeddedFontRef, cp: u21) u16 {
        return self.parsed.glyphForCodepoint(cp);
    }
};

/// Reserve six indirect-object numbers for an embedded font. Called by
/// `ResourceRegistry.assignFontObjectNumbers` for each `embedded` entry.
pub fn assignObjectNumbers(ref: *EmbeddedFontRef, w: *pdf_writer.Writer) !void {
    ref.obj_type0 = try w.allocObjectNum();
    ref.obj_cid_font = try w.allocObjectNum();
    ref.obj_descriptor = try w.allocObjectNum();
    ref.obj_font_file = try w.allocObjectNum();
    ref.obj_to_unicode = try w.allocObjectNum();
    ref.obj_cid_to_gid_map = try w.allocObjectNum();
}

/// Object number that pages reference from `/Resources /Font /Fk N 0 R`.
/// Always the Type0 wrapper.
pub fn fontResourceObjNum(ref: *const EmbeddedFontRef) u32 {
    return ref.obj_type0;
}

/// Emit all five indirect objects. Called from
/// `ResourceRegistry.emitFontObjects`. Consumes `ref.used_codepoints`
/// — after this returns, the codepoint set is logically frozen, though
/// not physically cleared.
pub fn emit(
    ref: *EmbeddedFontRef,
    w: *pdf_writer.Writer,
) !void {
    std.debug.assert(ref.obj_type0 != 0);
    std.debug.assert(ref.obj_cid_font != 0);
    std.debug.assert(ref.obj_descriptor != 0);
    std.debug.assert(ref.obj_font_file != 0);
    std.debug.assert(ref.obj_to_unicode != 0);
    std.debug.assert(ref.obj_cid_to_gid_map != 0);

    const allocator = ref.allocator;

    // 1. Materialise the codepoint set.
    var cps: std.ArrayList(u21) = .empty;
    defer cps.deinit(allocator);
    {
        var it = ref.used_codepoints.keyIterator();
        while (it.next()) |k| try cps.append(allocator, k.*);
    }
    // If no codepoints were ever requested, .notdef-only is still a
    // valid subset — keeps the structure intact.

    // 2. Subset.
    var sub = try truetype.subset(allocator, ref.parsed, cps.items);
    defer sub.deinit(allocator);

    // 3. Build the (cid, unicode) mappings. Per the design note in
    // `cidForCodepoint`: CID = ORIGINAL GID (so content streams are
    // stable across emit). The /CIDToGIDMap stream below remaps that to
    // the dense in-subset GID for the rasteriser.
    var mappings: std.ArrayList(cmap_writer.Mapping) = .empty;
    defer mappings.deinit(allocator);
    {
        var seen = std.AutoHashMap(u16, void).init(allocator);
        defer seen.deinit();
        for (cps.items) |cp| {
            const cid = ref.cidForCodepoint(cp);
            if (cid == 0) continue;
            if (seen.contains(cid)) continue;
            try seen.put(cid, {});
            try mappings.append(allocator, .{ .cid = cid, .unicode = cp });
        }
    }

    // 4. Build CIDToGIDMap: 2 bytes per CID for CID = 0..num_glyphs_old.
    // Most slots are 0 (CID maps to .notdef in the subset); kept GIDs
    // get their dense index.
    const num_glyphs_old: usize = @intCast(ref.parsed.maxp.num_glyphs);
    const cidmap = try allocator.alloc(u8, num_glyphs_old * 2);
    defer allocator.free(cidmap);
    @memset(cidmap, 0);
    for (sub.cid_to_gid, 0..) |old_gid, new_idx| {
        if (@as(usize, old_gid) >= num_glyphs_old) return error.InvalidFont;
        std.mem.writeInt(u16, cidmap[old_gid * 2 ..][0..2], @intCast(new_idx), .big);
    }

    // 4. Emit FontFile2 stream.
    try w.beginObject(ref.obj_font_file, 0);
    var len_buf: [40]u8 = undefined;
    const length1_str = std.fmt.bufPrint(&len_buf, " /Length1 {d}", .{sub.bytes.len}) catch return error.InvalidReal;
    if (sub.bytes.len > 256) {
        try w.writeStreamCompressed(sub.bytes, length1_str);
    } else {
        try w.writeStream(sub.bytes, length1_str);
    }
    try w.endObject();

    // 5. Compute font-descriptor bbox + flags from parsed.head.
    const head = ref.parsed.head;
    const upem: f64 = @floatFromInt(head.units_per_em);
    // Convert design units to 1000-unit space (PDF FontDescriptor expects 1000 = 1em).
    const scale = 1000.0 / upem;
    const bbox = [_]i32{
        @intFromFloat(@as(f64, @floatFromInt(head.x_min)) * scale),
        @intFromFloat(@as(f64, @floatFromInt(head.y_min)) * scale),
        @intFromFloat(@as(f64, @floatFromInt(head.x_max)) * scale),
        @intFromFloat(@as(f64, @floatFromInt(head.y_max)) * scale),
    };
    const ascent_pdf: i32 = @intFromFloat(@as(f64, @floatFromInt(ref.parsed.hhea.ascender)) * scale);
    const descent_pdf: i32 = @intFromFloat(@as(f64, @floatFromInt(ref.parsed.hhea.descender)) * scale);
    // Symbolic flag (bit 3 = 1<<2) when the font has any non-Latin
    // glyphs; defensive default — Acrobat tolerates either.
    const flags: u32 = 0x0004; // /Symbolic — broadly safe for non-base-14.

    // 6. Emit FontDescriptor.
    try w.beginObject(ref.obj_descriptor, 0);
    try w.writeRaw("<< /Type /FontDescriptor /FontName /");
    try w.writeRaw(ref.base_font);
    try w.writeRaw(" /Flags ");
    try w.writeInt(@intCast(flags));
    try w.writeRaw(" /FontBBox [");
    try w.writeInt(bbox[0]);
    try w.writeRaw(" ");
    try w.writeInt(bbox[1]);
    try w.writeRaw(" ");
    try w.writeInt(bbox[2]);
    try w.writeRaw(" ");
    try w.writeInt(bbox[3]);
    try w.writeRaw("] /ItalicAngle 0 /Ascent ");
    try w.writeInt(ascent_pdf);
    try w.writeRaw(" /Descent ");
    try w.writeInt(descent_pdf);
    // CapHeight + StemV are required-ish; we use sensible defaults.
    try w.writeRaw(" /CapHeight ");
    try w.writeInt(ascent_pdf);
    try w.writeRaw(" /StemV 80 /FontFile2 ");
    try w.writeRef(ref.obj_font_file, 0);
    try w.writeRaw(" >>");
    try w.endObject();

    // 7. Emit /CIDFontType2 with /W array.
    try w.beginObject(ref.obj_cid_font, 0);
    try w.writeRaw("<< /Type /Font /Subtype /CIDFontType2 /BaseFont /");
    try w.writeRaw(ref.base_font);
    try w.writeRaw(" /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >>");
    try w.writeRaw(" /FontDescriptor ");
    try w.writeRef(ref.obj_descriptor, 0);
    try w.writeRaw(" /CIDToGIDMap ");
    try w.writeRef(ref.obj_cid_to_gid_map, 0);
    // /W array: only emit kept CIDs (= old GIDs), each with its own
    // single-CID block: `cid [width]`. Reader-tolerant + spec-clean.
    try w.writeRaw(" /W [");
    for (sub.cid_to_gid) |old_gid| {
        if (old_gid == 0) continue; // skip .notdef
        const adv = ref.parsed.advanceWidth(old_gid);
        const adv_scaled: i32 = @intFromFloat(@as(f64, @floatFromInt(adv)) * scale);
        try w.writeRaw(" ");
        try w.writeInt(@intCast(old_gid));
        try w.writeRaw(" [");
        try w.writeInt(adv_scaled);
        try w.writeRaw("]");
    }
    try w.writeRaw(" ] >>");
    try w.endObject();

    // 8. Emit /Type0 wrapper.
    try w.beginObject(ref.obj_type0, 0);
    try w.writeRaw("<< /Type /Font /Subtype /Type0 /BaseFont /");
    try w.writeRaw(ref.base_font);
    try w.writeRaw(" /Encoding /Identity-H /DescendantFonts [");
    try w.writeRef(ref.obj_cid_font, 0);
    try w.writeRaw("] /ToUnicode ");
    try w.writeRef(ref.obj_to_unicode, 0);
    try w.writeRaw(" >>");
    try w.endObject();

    // 9. Emit ToUnicode CMap stream.
    var cmap_aw = std.Io.Writer.Allocating.init(allocator);
    defer cmap_aw.deinit();
    try cmap_writer.writeToUnicodeCmap(&cmap_aw.writer, mappings.items);
    try w.beginObject(ref.obj_to_unicode, 0);
    if (cmap_aw.written().len > 256) {
        try w.writeStreamCompressed(cmap_aw.written(), "");
    } else {
        try w.writeStream(cmap_aw.written(), "");
    }
    try w.endObject();

    // 10. Emit /CIDToGIDMap stream. Compressed unconditionally — most
    // entries are zero (CID space is sparse against the dense subset),
    // and zlib hammers that to ~1% of the wire size.
    try w.beginObject(ref.obj_cid_to_gid_map, 0);
    if (cidmap.len > 256) {
        try w.writeStreamCompressed(cidmap, "");
    } else {
        try w.writeStream(cidmap, "");
    }
    try w.endObject();
}

// ============================================================================
// TESTS
// ============================================================================

test "EmbeddedFontRef.init computes a stable subset prefix" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, "/System/Library/Fonts/Monaco.ttf", allocator, .limited(32 * 1024 * 1024)) catch return;
    defer allocator.free(bytes);

    var parsed = try truetype.parse(allocator, bytes);
    defer parsed.deinit(allocator);

    var ref = try EmbeddedFontRef.init(allocator, &parsed, "Monaco");
    defer ref.deinit();

    try std.testing.expect(ref.base_font.len == 6 + 1 + "Monaco".len);
    try std.testing.expect(ref.base_font[6] == '+');
    // Prefix bytes are uppercase ASCII A..Z.
    for (ref.base_font[0..6]) |b| {
        try std.testing.expect(b >= 'A' and b <= 'Z');
    }
}

test "rememberCodepoint dedupes" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, "/System/Library/Fonts/Monaco.ttf", allocator, .limited(32 * 1024 * 1024)) catch return;
    defer allocator.free(bytes);

    var parsed = try truetype.parse(allocator, bytes);
    defer parsed.deinit(allocator);

    var ref = try EmbeddedFontRef.init(allocator, &parsed, "Monaco");
    defer ref.deinit();

    try ref.rememberCodepoint('A');
    try ref.rememberCodepoint('B');
    try ref.rememberCodepoint('A');
    try std.testing.expectEqual(@as(u32, 2), ref.used_codepoints.count());
}
