//! PR-W7 [feat]: bare-minimum TrueType / OpenType parser to enable
//! font subsetting.
//!
//! ## Scope
//!
//! - **TrueType outlines only.** A `CFF ` table => `error.CffNotSupported`
//!   (follow-up PR territory).
//! - **BMP cmap only (Format 4).** No Format 12 (full-Unicode / emoji).
//! - **Composite-glyph recursion** capped at 16 to defuse cyclic outlines.
//! - **All offsets bounds-checked** before they hit the byte slice. TTFs
//!   are user-supplied — we treat every length as adversarial.
//!
//! ## API surface
//!
//! ```zig
//! var parsed = try truetype.parse(allocator, ttf_bytes);
//! defer parsed.deinit(allocator);
//!
//! const codepoints = [_]u21{ 'H', 'e', 'l', 'l', 'o' };
//! var subset = try truetype.subset(allocator, &parsed, &codepoints);
//! defer subset.deinit(allocator);
//!
//! // subset.bytes is the new font; subset.cid_to_gid maps subset CIDs
//! // back to original GIDs for CIDFontType2 emission.
//! ```
//!
//! ## TrueType reference
//!
//! All section numbers are from "OpenType Specification 1.9.1"
//! (https://learn.microsoft.com/typography/opentype/spec/) which mirrors
//! the original Apple TrueType Reference Manual table layout. Every
//! offset/length validated below cites the spec section it comes from.

const std = @import("std");

pub const Error = error{
    /// Truncated or corrupted bytes — any out-of-bounds offset/length.
    InvalidFont,
    /// CFF outlines (`CFF `) are out of scope for v1.
    CffNotSupported,
    /// Required table missing (`head`, `maxp`, `cmap`, `glyf`, `loca`,
    /// `hhea`, `hmtx`, `name`).
    MissingRequiredTable,
    /// Only Format 4 BMP cmap subtables are supported in v1.
    UnsupportedCmap,
    /// Composite-glyph recursion exceeded `MAX_COMPOSITE_DEPTH`.
    CompositeGlyphCycle,
    /// `head.indexToLocFormat` outside {0, 1}.
    InvalidLocaFormat,
    /// Codepoint set requested a glyph index >= numGlyphs.
    GlyphIndexOutOfRange,
    /// Allocator failure forwarded.
    OutOfMemory,
};

/// Composite-glyph reference cap. TrueType permits arbitrary composite
/// nesting; in practice no real font goes above 4. We cap at 16 so a
/// hostile or buggy font cannot stack-overflow the subsetter.
pub const MAX_COMPOSITE_DEPTH: u8 = 16;

pub const TableTag = struct {
    pub const head: u32 = tagFromStr("head");
    pub const maxp: u32 = tagFromStr("maxp");
    pub const cmap: u32 = tagFromStr("cmap");
    pub const glyf: u32 = tagFromStr("glyf");
    pub const loca: u32 = tagFromStr("loca");
    pub const hhea: u32 = tagFromStr("hhea");
    pub const hmtx: u32 = tagFromStr("hmtx");
    pub const name: u32 = tagFromStr("name");
    pub const cff: u32 = tagFromStr("CFF ");
    pub const post: u32 = tagFromStr("post");
    pub const os2: u32 = tagFromStr("OS/2");
    pub const cvt: u32 = tagFromStr("cvt ");
    pub const prep: u32 = tagFromStr("prep");
    pub const fpgm: u32 = tagFromStr("fpgm");

    fn tagFromStr(comptime s: *const [4]u8) u32 {
        return (@as(u32, s[0]) << 24) |
            (@as(u32, s[1]) << 16) |
            (@as(u32, s[2]) << 8) |
            @as(u32, s[3]);
    }
};

pub const TableRecord = struct {
    tag: u32,
    checksum: u32,
    offset: u32,
    length: u32,
};

pub const HeadTable = struct {
    units_per_em: u16,
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
    /// Spec §head: 0 = short loca offsets (u16/2), 1 = long (u32).
    index_to_loc_format: i16,
    flags: u16,
    mac_style: u16,
    /// Byte offset of `checkSumAdjustment` field within the `head` table.
    /// Used by the subsetter to zero-out the field before recomputing.
    pub const checksum_adjustment_offset: usize = 8;
};

pub const MaxpTable = struct {
    num_glyphs: u16,
};

pub const HheaTable = struct {
    ascender: i16,
    descender: i16,
    line_gap: i16,
    advance_width_max: u16,
    /// Number of advance widths in `hmtx` (the rest reuse the last
    /// advance and only carry their own LSB).
    num_long_h_metrics: u16,
};

pub const HmtxTable = struct {
    /// Borrowed slice into the original font bytes.
    raw: []const u8,
    num_long_h_metrics: u16,
    num_glyphs: u16,

    pub fn advanceWidth(self: HmtxTable, gid: u16) u16 {
        if (gid < self.num_long_h_metrics) {
            const off = @as(usize, gid) * 4;
            return readU16(self.raw, off) catch 0;
        }
        // Beyond `num_long_h_metrics` all glyphs reuse the last advance.
        if (self.num_long_h_metrics == 0) return 0;
        const off = (@as(usize, self.num_long_h_metrics) - 1) * 4;
        return readU16(self.raw, off) catch 0;
    }
};

pub const CmapTable = struct {
    /// Borrowed Format 4 subtable bytes (starts at the format word).
    format4_subtable: []const u8,
    /// Cached Format 4 fields parsed at init.
    seg_count: u16,
    end_codes_offset: usize,
    start_codes_offset: usize,
    id_deltas_offset: usize,
    id_range_offsets_offset: usize,
    glyph_id_array_offset: usize,

    /// Look up `cp`'s GID, returning 0 (.notdef) if not present.
    /// Returns 0 for any cp > 0xFFFF since we are BMP-only.
    pub fn glyphForCodepoint(self: CmapTable, cp: u21) u16 {
        if (cp > 0xFFFF) return 0;
        const code: u16 = @intCast(cp);
        // Linear scan — seg_count is small (typically <100). Binary search
        // would be a micro-optimisation; keep it boring for now.
        var i: usize = 0;
        while (i < self.seg_count) : (i += 1) {
            const end = readU16(self.format4_subtable, self.end_codes_offset + i * 2) catch return 0;
            if (end < code) continue;
            const start = readU16(self.format4_subtable, self.start_codes_offset + i * 2) catch return 0;
            if (start > code) return 0;
            const id_range_offset = readU16(self.format4_subtable, self.id_range_offsets_offset + i * 2) catch return 0;
            const id_delta_raw = readU16(self.format4_subtable, self.id_deltas_offset + i * 2) catch return 0;
            const id_delta: i16 = @bitCast(id_delta_raw);
            if (id_range_offset == 0) {
                // Simple delta path. Per spec §cmap-fmt4: GID = (code + delta) mod 65536.
                const gid_wide: u32 = (@as(u32, code) +% @as(u32, @bitCast(@as(i32, id_delta)))) & 0xFFFF;
                return @intCast(gid_wide);
            }
            // Indirect path through glyphIdArray: spec says the address is
            // &idRangeOffset[i] + idRangeOffset[i] + 2 * (c - startCode).
            const idro_field_addr = self.id_range_offsets_offset + i * 2;
            const target = idro_field_addr + id_range_offset + 2 * (@as(usize, code) - @as(usize, start));
            const gid_raw = readU16(self.format4_subtable, target) catch return 0;
            if (gid_raw == 0) return 0;
            const gid_wide: u32 = (@as(u32, gid_raw) +% @as(u32, @bitCast(@as(i32, id_delta)))) & 0xFFFF;
            return @intCast(gid_wide);
        }
        return 0;
    }
};

pub const GlyfLocaTables = struct {
    glyf: []const u8,
    /// Glyph offsets into `glyf`. Length = num_glyphs + 1; final entry
    /// is glyph 0's end (= glyf.len in a well-formed font).
    glyph_offsets: []u32,

    pub fn deinit(self: *GlyfLocaTables, allocator: std.mem.Allocator) void {
        allocator.free(self.glyph_offsets);
    }

    pub fn glyphRange(self: GlyfLocaTables, gid: u16) ?struct { start: u32, end: u32 } {
        if (@as(usize, gid) + 1 >= self.glyph_offsets.len) return null;
        const start = self.glyph_offsets[gid];
        const end = self.glyph_offsets[gid + 1];
        if (start > end) return null;
        if (end > self.glyf.len) return null;
        return .{ .start = start, .end = end };
    }
};

pub const NameTable = struct {
    raw: []const u8,
    /// Best-effort PostScript name extracted at parse time. Owned by
    /// the caller's allocator (see `parse`).
    postscript_name: []const u8,
};

pub const ParsedFont = struct {
    raw: []const u8,
    head: HeadTable,
    maxp: MaxpTable,
    cmap: CmapTable,
    glyf_loca: GlyfLocaTables,
    name: NameTable,
    hhea: HheaTable,
    hmtx: HmtxTable,
    /// Owned. The PostScript name extracted into a stable buffer.
    postscript_name_buf: []u8,

    pub fn deinit(self: *ParsedFont, allocator: std.mem.Allocator) void {
        self.glyf_loca.deinit(allocator);
        allocator.free(self.postscript_name_buf);
    }

    /// GID for a Unicode codepoint, or 0 (.notdef) if unmapped.
    pub fn glyphForCodepoint(self: ParsedFont, cp: u21) u16 {
        return self.cmap.glyphForCodepoint(cp);
    }

    /// Advance width for a GID, in font design units (1/units_per_em ems).
    pub fn advanceWidth(self: ParsedFont, gid: u16) u16 {
        return self.hmtx.advanceWidth(gid);
    }
};

/// Parse a TrueType font. The returned struct borrows `bytes` for any
/// long-lived data (cmap subtable, glyf/loca, hmtx); the only owned
/// allocations are `glyph_offsets` (for fast loca decode) and
/// `postscript_name_buf`.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) Error!ParsedFont {
    if (bytes.len < 12) return error.InvalidFont;
    const sfnt_version = try readU32(bytes, 0);
    // Accept 0x00010000 (TrueType) and "true" (Mac TrueType). Reject
    // OTTO (CFF) — that's `CFF ` outlines, follow-up PR.
    const true_tag: u32 = (@as(u32, 't') << 24) | (@as(u32, 'r') << 16) | (@as(u32, 'u') << 8) | @as(u32, 'e');
    const otto_tag: u32 = (@as(u32, 'O') << 24) | (@as(u32, 'T') << 16) | (@as(u32, 'T') << 8) | @as(u32, 'O');
    if (sfnt_version == otto_tag) return error.CffNotSupported;
    if (sfnt_version != 0x00010000 and sfnt_version != true_tag) return error.InvalidFont;

    const num_tables = try readU16(bytes, 4);
    if (num_tables == 0 or num_tables > 1024) return error.InvalidFont;

    const records_off: usize = 12;
    const records_len: usize = @as(usize, num_tables) * 16;
    if (records_off + records_len > bytes.len) return error.InvalidFont;

    var head_rec: ?TableRecord = null;
    var maxp_rec: ?TableRecord = null;
    var cmap_rec: ?TableRecord = null;
    var glyf_rec: ?TableRecord = null;
    var loca_rec: ?TableRecord = null;
    var hhea_rec: ?TableRecord = null;
    var hmtx_rec: ?TableRecord = null;
    var name_rec: ?TableRecord = null;
    var has_cff: bool = false;

    var i: usize = 0;
    while (i < num_tables) : (i += 1) {
        const r_off = records_off + i * 16;
        const tag = try readU32(bytes, r_off);
        const checksum = try readU32(bytes, r_off + 4);
        const offset = try readU32(bytes, r_off + 8);
        const length = try readU32(bytes, r_off + 12);
        // Bounds check every table extent up-front.
        if (@as(u64, offset) + @as(u64, length) > bytes.len) return error.InvalidFont;
        const rec: TableRecord = .{ .tag = tag, .checksum = checksum, .offset = offset, .length = length };
        switch (tag) {
            TableTag.head => head_rec = rec,
            TableTag.maxp => maxp_rec = rec,
            TableTag.cmap => cmap_rec = rec,
            TableTag.glyf => glyf_rec = rec,
            TableTag.loca => loca_rec = rec,
            TableTag.hhea => hhea_rec = rec,
            TableTag.hmtx => hmtx_rec = rec,
            TableTag.name => name_rec = rec,
            TableTag.cff => has_cff = true,
            else => {},
        }
    }

    if (has_cff) return error.CffNotSupported;
    const head_r = head_rec orelse return error.MissingRequiredTable;
    const maxp_r = maxp_rec orelse return error.MissingRequiredTable;
    const cmap_r = cmap_rec orelse return error.MissingRequiredTable;
    const glyf_r = glyf_rec orelse return error.MissingRequiredTable;
    const loca_r = loca_rec orelse return error.MissingRequiredTable;
    const hhea_r = hhea_rec orelse return error.MissingRequiredTable;
    const hmtx_r = hmtx_rec orelse return error.MissingRequiredTable;
    const name_r = name_rec orelse return error.MissingRequiredTable;

    // Parse `head` (54 bytes; we read 54 fields' worth conservatively).
    if (head_r.length < 54) return error.InvalidFont;
    const head_off = head_r.offset;
    const head: HeadTable = .{
        .units_per_em = try readU16(bytes, head_off + 18),
        .x_min = @bitCast(try readU16(bytes, head_off + 36)),
        .y_min = @bitCast(try readU16(bytes, head_off + 38)),
        .x_max = @bitCast(try readU16(bytes, head_off + 40)),
        .y_max = @bitCast(try readU16(bytes, head_off + 42)),
        .flags = try readU16(bytes, head_off + 16),
        .mac_style = try readU16(bytes, head_off + 44),
        .index_to_loc_format = @bitCast(try readU16(bytes, head_off + 50)),
    };
    if (head.units_per_em == 0) return error.InvalidFont;
    if (head.index_to_loc_format != 0 and head.index_to_loc_format != 1) return error.InvalidLocaFormat;

    // Parse `maxp`.
    if (maxp_r.length < 6) return error.InvalidFont;
    const maxp: MaxpTable = .{ .num_glyphs = try readU16(bytes, maxp_r.offset + 4) };
    if (maxp.num_glyphs == 0) return error.InvalidFont;

    // Parse `hhea`.
    if (hhea_r.length < 36) return error.InvalidFont;
    const hhea: HheaTable = .{
        .ascender = @bitCast(try readU16(bytes, hhea_r.offset + 4)),
        .descender = @bitCast(try readU16(bytes, hhea_r.offset + 6)),
        .line_gap = @bitCast(try readU16(bytes, hhea_r.offset + 8)),
        .advance_width_max = try readU16(bytes, hhea_r.offset + 10),
        .num_long_h_metrics = try readU16(bytes, hhea_r.offset + 34),
    };
    if (hhea.num_long_h_metrics == 0 or hhea.num_long_h_metrics > maxp.num_glyphs) return error.InvalidFont;
    // hmtx record-length check: numLongHMetrics * 4 + (numGlyphs - numLongHMetrics) * 2.
    const hmtx_min_len: u64 = @as(u64, hhea.num_long_h_metrics) * 4 +
        (@as(u64, maxp.num_glyphs) - @as(u64, hhea.num_long_h_metrics)) * 2;
    if (hmtx_r.length < hmtx_min_len) return error.InvalidFont;

    const hmtx: HmtxTable = .{
        .raw = bytes[hmtx_r.offset .. hmtx_r.offset + hmtx_r.length],
        .num_long_h_metrics = hhea.num_long_h_metrics,
        .num_glyphs = maxp.num_glyphs,
    };

    // Parse `loca` → glyph_offsets array.
    const glyph_offsets = try allocator.alloc(u32, @as(usize, maxp.num_glyphs) + 1);
    errdefer allocator.free(glyph_offsets);
    if (head.index_to_loc_format == 0) {
        // Short format — u16, multiplied by 2.
        const need: u64 = (@as(u64, maxp.num_glyphs) + 1) * 2;
        if (loca_r.length < need) return error.InvalidFont;
        for (0..glyph_offsets.len) |idx| {
            const v = try readU16(bytes, loca_r.offset + idx * 2);
            glyph_offsets[idx] = @as(u32, v) * 2;
        }
    } else {
        const need: u64 = (@as(u64, maxp.num_glyphs) + 1) * 4;
        if (loca_r.length < need) return error.InvalidFont;
        for (0..glyph_offsets.len) |idx| {
            glyph_offsets[idx] = try readU32(bytes, loca_r.offset + idx * 4);
        }
    }
    // Final entry must be ≤ glyf.length; intermediate entries non-decreasing
    // is recommended but not required. We enforce only the bound.
    if (glyph_offsets[glyph_offsets.len - 1] > glyf_r.length) return error.InvalidFont;

    const glyf_loca: GlyfLocaTables = .{
        .glyf = bytes[glyf_r.offset .. glyf_r.offset + glyf_r.length],
        .glyph_offsets = glyph_offsets,
    };

    // Parse `cmap`: walk encoding-record table for a Format-4 subtable
    // with platform Unicode (0) or Microsoft Unicode (3,1).
    const cmap_off = cmap_r.offset;
    if (cmap_r.length < 4) {
        return error.InvalidFont;
    }
    const num_subtables = try readU16(bytes, cmap_off + 2);
    if (cmap_r.length < 4 + @as(usize, num_subtables) * 8) return error.InvalidFont;

    var format4_subtable_off: ?usize = null;
    var sub_i: usize = 0;
    while (sub_i < num_subtables) : (sub_i += 1) {
        const rec_off = cmap_off + 4 + sub_i * 8;
        const platform_id = try readU16(bytes, rec_off);
        const encoding_id = try readU16(bytes, rec_off + 2);
        const sub_off = try readU32(bytes, rec_off + 4);
        const abs_off = @as(u64, cmap_off) + @as(u64, sub_off);
        if (abs_off + 4 > bytes.len) continue;
        const fmt = try readU16(bytes, @intCast(abs_off));
        if (fmt != 4) continue;
        // Acceptable platform/encoding combos for BMP Unicode.
        const ok =
            (platform_id == 0) or
            (platform_id == 3 and encoding_id == 1) or
            (platform_id == 3 and encoding_id == 0);
        if (!ok) continue;
        format4_subtable_off = @intCast(abs_off);
        break;
    }
    const f4_off = format4_subtable_off orelse return error.UnsupportedCmap;
    if (f4_off + 14 > bytes.len) return error.InvalidFont;
    const f4_length = try readU16(bytes, f4_off + 2);
    if (@as(u64, f4_off) + @as(u64, f4_length) > bytes.len) return error.InvalidFont;
    const seg_count_x2 = try readU16(bytes, f4_off + 6);
    if (seg_count_x2 == 0 or (seg_count_x2 & 1) != 0) return error.InvalidFont;
    const seg_count = seg_count_x2 / 2;
    // Format 4 layout: header(14) + endCount[seg]+pad(2) + startCount[seg] +
    // idDelta[seg] + idRangeOffset[seg] + glyphIdArray[].
    const end_codes_off = 14;
    const start_codes_off = end_codes_off + @as(usize, seg_count) * 2 + 2; // +2 for reservedPad
    const id_deltas_off = start_codes_off + @as(usize, seg_count) * 2;
    const id_range_offsets_off = id_deltas_off + @as(usize, seg_count) * 2;
    const glyph_id_array_off = id_range_offsets_off + @as(usize, seg_count) * 2;
    if (glyph_id_array_off > f4_length) return error.InvalidFont;

    const cmap: CmapTable = .{
        .format4_subtable = bytes[f4_off .. f4_off + f4_length],
        .seg_count = seg_count,
        .end_codes_offset = end_codes_off,
        .start_codes_offset = start_codes_off,
        .id_deltas_offset = id_deltas_off,
        .id_range_offsets_offset = id_range_offsets_off,
        .glyph_id_array_offset = glyph_id_array_off,
    };

    // Parse `name` for a PostScript name (nameID 6). Best-effort —
    // empty string if not found.
    if (name_r.length < 6) return error.InvalidFont;
    const name_count = try readU16(bytes, name_r.offset + 2);
    const string_off_in_name = try readU16(bytes, name_r.offset + 4);
    if (@as(u64, name_r.offset) + 6 + @as(u64, name_count) * 12 > @as(u64, name_r.offset) + name_r.length) {
        return error.InvalidFont;
    }
    var ps_name: []const u8 = "";
    var ps_is_unicode = false;
    var n_i: usize = 0;
    while (n_i < name_count) : (n_i += 1) {
        const r_off = name_r.offset + 6 + n_i * 12;
        const platform_id = try readU16(bytes, r_off);
        const encoding_id = try readU16(bytes, r_off + 2);
        const name_id = try readU16(bytes, r_off + 6);
        const length = try readU16(bytes, r_off + 8);
        const string_offset = try readU16(bytes, r_off + 10);
        if (name_id != 6) continue;
        const abs_str = @as(u64, name_r.offset) + @as(u64, string_off_in_name) + @as(u64, string_offset);
        if (abs_str + length > @as(u64, name_r.offset) + name_r.length) continue;
        const start: usize = @intCast(abs_str);
        const slice = bytes[start .. start + length];
        // Mac Roman = 1/0; Microsoft Unicode = 3/1 (UTF-16BE).
        if (platform_id == 1 and encoding_id == 0) {
            ps_name = slice;
            ps_is_unicode = false;
            // Mac Roman PS name is preferred (ASCII subset), keep it.
            break;
        }
        if (platform_id == 3 and encoding_id == 1 and ps_name.len == 0) {
            ps_name = slice;
            ps_is_unicode = true;
            // Don't break — prefer the Mac Roman record if we find one later.
        }
    }
    // Convert / copy into an owned buffer. UTF-16BE PS names are decoded
    // by stripping high bytes (PS names are ASCII per spec).
    const ps_buf: []u8 = blk: {
        if (ps_name.len == 0) break :blk try allocator.dupe(u8, "Unnamed");
        if (!ps_is_unicode) break :blk try allocator.dupe(u8, ps_name);
        // UTF-16BE → ASCII by taking the low byte of every code unit
        // when it's < 128. Drop non-ASCII; PS names should be ASCII.
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var idx: usize = 0;
        while (idx + 1 < ps_name.len) : (idx += 2) {
            const hi = ps_name[idx];
            const lo = ps_name[idx + 1];
            if (hi == 0 and lo < 128) try out.append(allocator, lo);
        }
        break :blk try out.toOwnedSlice(allocator);
    };
    errdefer allocator.free(ps_buf);

    return .{
        .raw = bytes,
        .head = head,
        .maxp = maxp,
        .cmap = cmap,
        .glyf_loca = glyf_loca,
        .name = .{ .raw = bytes[name_r.offset .. name_r.offset + name_r.length], .postscript_name = ps_buf },
        .hhea = hhea,
        .hmtx = hmtx,
        .postscript_name_buf = ps_buf,
    };
}

// ============================================================================
// SUBSET
// ============================================================================

pub const Subset = struct {
    bytes: []u8,
    cid_to_gid: []u16,
    glyph_count: u16,

    pub fn deinit(self: *Subset, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.cid_to_gid);
    }
};

/// Subset `font` to keep `.notdef` (GID 0) plus every GID reachable from
/// the requested codepoints (and any composite-glyph dependencies).
/// CID order is GID-ascending: the resulting font's CID N maps to the
/// caller's old GID `cid_to_gid[N]`, and CID 0 always maps to old GID 0.
pub fn subset(
    allocator: std.mem.Allocator,
    font: *const ParsedFont,
    codepoints: []const u21,
) Error!Subset {
    const num_glyphs_old = font.maxp.num_glyphs;

    // 1. Walk codepoints → GIDs, then close under composite references.
    var keep_set = try std.DynamicBitSet.initEmpty(allocator, num_glyphs_old);
    defer keep_set.deinit();
    keep_set.set(0); // .notdef must survive.

    for (codepoints) |cp| {
        const gid = font.glyphForCodepoint(cp);
        if (gid >= num_glyphs_old) return error.GlyphIndexOutOfRange;
        keep_set.set(gid);
    }

    // Close under composite references with a bounded stack.
    var work: std.ArrayList(u16) = .empty;
    defer work.deinit(allocator);
    var iter = keep_set.iterator(.{});
    while (iter.next()) |bit| try work.append(allocator, @intCast(bit));

    while (work.pop()) |gid| {
        try expandComposite(font, gid, &keep_set, &work, allocator, 0);
    }

    // 2. Build the GID-ascending CID→GID map.
    var cid_list: std.ArrayList(u16) = .empty;
    errdefer cid_list.deinit(allocator);
    var gid: u16 = 0;
    while (gid < num_glyphs_old) : (gid += 1) {
        if (keep_set.isSet(gid)) try cid_list.append(allocator, gid);
    }
    if (cid_list.items.len == 0 or cid_list.items[0] != 0) {
        // .notdef must always be CID 0.
        return error.InvalidFont;
    }
    const cid_to_gid_arr = try cid_list.toOwnedSlice(allocator);
    errdefer allocator.free(cid_to_gid_arr);
    const new_num_glyphs: u16 = @intCast(cid_to_gid_arr.len);

    // 3. Build a reverse map old_gid → new_gid (or 0xFFFF for "drop").
    var old_to_new = try allocator.alloc(u16, num_glyphs_old);
    defer allocator.free(old_to_new);
    @memset(old_to_new, 0xFFFF);
    for (cid_to_gid_arr, 0..) |old_gid, new_idx| {
        old_to_new[old_gid] = @intCast(new_idx);
    }

    // 4. Build new glyf bytes by concatenating the kept glyphs (rewriting
    // composite references through `old_to_new`), and a fresh loca table.
    var new_glyf: std.ArrayList(u8) = .empty;
    errdefer new_glyf.deinit(allocator);
    const new_loca = try allocator.alloc(u32, @as(usize, new_num_glyphs) + 1);
    errdefer allocator.free(new_loca);

    for (cid_to_gid_arr, 0..) |old_gid, new_idx| {
        new_loca[new_idx] = @intCast(new_glyf.items.len);
        if (font.glyf_loca.glyphRange(old_gid)) |range| {
            const gbytes = font.glyf_loca.glyf[range.start..range.end];
            if (gbytes.len == 0) continue;
            // Composite glyph? If number_of_contours < 0.
            if (gbytes.len >= 2) {
                const noc_raw = readU16(gbytes, 0) catch return error.InvalidFont;
                const noc: i16 = @bitCast(noc_raw);
                if (noc < 0) {
                    // Composite — rewrite GLYF_INDEX fields.
                    const rewritten = try allocator.alloc(u8, gbytes.len);
                    errdefer allocator.free(rewritten);
                    @memcpy(rewritten, gbytes);
                    rewriteCompositeGlyphIndices(rewritten, old_to_new) catch |err| {
                        allocator.free(rewritten);
                        return err;
                    };
                    try new_glyf.appendSlice(allocator, rewritten);
                    allocator.free(rewritten);
                    continue;
                }
            }
            try new_glyf.appendSlice(allocator, gbytes);
        }
    }
    new_loca[new_num_glyphs] = @intCast(new_glyf.items.len);

    // 5. Re-pad glyf to 4-byte alignment (TT requirement for table data).
    while (new_glyf.items.len % 4 != 0) try new_glyf.append(allocator, 0);

    // 6. Build new hmtx (one record per kept glyph).
    var new_hmtx: std.ArrayList(u8) = .empty;
    errdefer new_hmtx.deinit(allocator);
    // Compute new num_long_h_metrics. Simplest correct choice: emit a
    // long metric for every kept glyph (no compression). The reader then
    // sees num_long_h_metrics == new_num_glyphs.
    for (cid_to_gid_arr) |old_gid| {
        const adv = font.hmtx.advanceWidth(old_gid);
        // LSB: read directly from old hmtx, falling back to 0.
        const lsb: i16 = blk: {
            if (old_gid < font.hmtx.num_long_h_metrics) {
                const off = @as(usize, old_gid) * 4 + 2;
                const v = readU16(font.hmtx.raw, off) catch break :blk 0;
                break :blk @bitCast(v);
            }
            // Beyond num_long_h_metrics: lsb-only array.
            const base = @as(usize, font.hmtx.num_long_h_metrics) * 4;
            const off = base + (@as(usize, old_gid) - @as(usize, font.hmtx.num_long_h_metrics)) * 2;
            const v = readU16(font.hmtx.raw, off) catch break :blk 0;
            break :blk @bitCast(v);
        };
        try writeU16(&new_hmtx, allocator, adv);
        try writeI16(&new_hmtx, allocator, lsb);
    }

    // 7. Build new head / maxp / hhea bytes (mostly copied-then-patched).
    const head_bytes = try sliceTable(font, TableTag.head, allocator);
    errdefer allocator.free(head_bytes);
    // Zero checkSumAdjustment as required during file-checksum recompute.
    if (head_bytes.len < 12) return error.InvalidFont;
    std.mem.writeInt(u32, head_bytes[8..12], 0, .big);
    // Patch indexToLocFormat to long (1) since we always emit u32 loca.
    if (head_bytes.len < 52) return error.InvalidFont;
    std.mem.writeInt(i16, head_bytes[50..52], 1, .big);

    const maxp_bytes = try sliceTable(font, TableTag.maxp, allocator);
    errdefer allocator.free(maxp_bytes);
    if (maxp_bytes.len < 6) return error.InvalidFont;
    std.mem.writeInt(u16, maxp_bytes[4..6], new_num_glyphs, .big);

    const hhea_bytes = try sliceTable(font, TableTag.hhea, allocator);
    errdefer allocator.free(hhea_bytes);
    if (hhea_bytes.len < 36) return error.InvalidFont;
    std.mem.writeInt(u16, hhea_bytes[34..36], new_num_glyphs, .big);

    // 8. Build long-format loca bytes.
    var new_loca_bytes = try allocator.alloc(u8, new_loca.len * 4);
    errdefer allocator.free(new_loca_bytes);
    for (new_loca, 0..) |off, idx| {
        std.mem.writeInt(u32, new_loca_bytes[idx * 4 ..][0..4], off, .big);
    }
    allocator.free(new_loca);

    // 9. Build a minimal cmap (Format 4) covering the requested codepoints
    // using the new GID space. This is what the reader uses to re-extract
    // text — Type 0 / CID fonts don't strictly *need* this but it keeps
    // the font usable as a standalone TrueType file.
    const new_cmap = try buildSubsetCmap(allocator, font, codepoints, old_to_new);
    errdefer allocator.free(new_cmap);

    // 10. Copy `name` and (if present) `post` verbatim — required tables
    // for valid TT fonts. `post` we synthesise as a minimal "Format 3.0"
    // table (no glyph names) per spec §post.
    const name_bytes = try sliceTable(font, TableTag.name, allocator);
    errdefer allocator.free(name_bytes);
    const post_bytes = try buildMinimalPost(allocator);
    errdefer allocator.free(post_bytes);

    // 11. Assemble final font with new offsets.
    const tables_to_emit = [_]TableEntry{
        .{ .tag = TableTag.cmap, .body = new_cmap },
        .{ .tag = TableTag.glyf, .body = new_glyf.items },
        .{ .tag = TableTag.head, .body = head_bytes },
        .{ .tag = TableTag.hhea, .body = hhea_bytes },
        .{ .tag = TableTag.hmtx, .body = new_hmtx.items },
        .{ .tag = TableTag.loca, .body = new_loca_bytes },
        .{ .tag = TableTag.maxp, .body = maxp_bytes },
        .{ .tag = TableTag.name, .body = name_bytes },
        .{ .tag = TableTag.post, .body = post_bytes },
    };
    const out_bytes = try assembleFont(allocator, &tables_to_emit);
    errdefer allocator.free(out_bytes);

    // 12. Now patch head.checkSumAdjustment in the assembled file.
    try patchChecksumAdjustment(out_bytes);

    // Free intermediate buffers (everything ended up copied into out_bytes).
    new_glyf.deinit(allocator);
    new_hmtx.deinit(allocator);
    allocator.free(new_cmap);
    allocator.free(new_loca_bytes);
    allocator.free(head_bytes);
    allocator.free(maxp_bytes);
    allocator.free(hhea_bytes);
    allocator.free(name_bytes);
    allocator.free(post_bytes);

    return .{
        .bytes = out_bytes,
        .cid_to_gid = cid_to_gid_arr,
        .glyph_count = new_num_glyphs,
    };
}

fn sliceTable(font: *const ParsedFont, tag: u32, allocator: std.mem.Allocator) Error![]u8 {
    // Walk the table directory once more — cheap and avoids storing all
    // record offsets in ParsedFont.
    const num_tables = readU16(font.raw, 4) catch return error.InvalidFont;
    var i: usize = 0;
    while (i < num_tables) : (i += 1) {
        const r_off = 12 + i * 16;
        const t = readU32(font.raw, r_off) catch return error.InvalidFont;
        if (t != tag) continue;
        const offset = readU32(font.raw, r_off + 8) catch return error.InvalidFont;
        const length = readU32(font.raw, r_off + 12) catch return error.InvalidFont;
        if (@as(u64, offset) + length > font.raw.len) return error.InvalidFont;
        const out = try allocator.alloc(u8, length);
        @memcpy(out, font.raw[offset .. offset + length]);
        return out;
    }
    return error.MissingRequiredTable;
}

fn expandComposite(
    font: *const ParsedFont,
    gid: u16,
    keep_set: *std.DynamicBitSet,
    work: *std.ArrayList(u16),
    allocator: std.mem.Allocator,
    depth: u8,
) Error!void {
    if (depth >= MAX_COMPOSITE_DEPTH) return error.CompositeGlyphCycle;
    const range = font.glyf_loca.glyphRange(gid) orelse return;
    if (range.end - range.start < 2) return;
    const gbytes = font.glyf_loca.glyf[range.start..range.end];
    const noc_raw = readU16(gbytes, 0) catch return error.InvalidFont;
    const noc: i16 = @bitCast(noc_raw);
    if (noc >= 0) return; // simple glyph, no children
    if (gbytes.len < 10) return error.InvalidFont;

    // Composite glyph header: noc(2) + bbox(8) = 10 bytes; then
    // repeated component records.
    var off: usize = 10;
    const ARG_1_AND_2_ARE_WORDS: u16 = 0x0001;
    const WE_HAVE_A_SCALE: u16 = 0x0008;
    const MORE_COMPONENTS: u16 = 0x0020;
    const WE_HAVE_AN_X_AND_Y_SCALE: u16 = 0x0040;
    const WE_HAVE_A_TWO_BY_TWO: u16 = 0x0080;

    while (true) {
        if (off + 4 > gbytes.len) return error.InvalidFont;
        const flags = readU16(gbytes, off) catch return error.InvalidFont;
        const child_gid = readU16(gbytes, off + 2) catch return error.InvalidFont;
        off += 4;
        if (child_gid >= font.maxp.num_glyphs) return error.GlyphIndexOutOfRange;
        if (!keep_set.isSet(child_gid)) {
            keep_set.set(child_gid);
            try work.append(allocator, child_gid);
            try expandComposite(font, child_gid, keep_set, work, allocator, depth + 1);
        }
        // Skip args and transform per flags.
        if ((flags & ARG_1_AND_2_ARE_WORDS) != 0) {
            off += 4;
        } else {
            off += 2;
        }
        if ((flags & WE_HAVE_A_SCALE) != 0) {
            off += 2;
        } else if ((flags & WE_HAVE_AN_X_AND_Y_SCALE) != 0) {
            off += 4;
        } else if ((flags & WE_HAVE_A_TWO_BY_TWO) != 0) {
            off += 8;
        }
        if ((flags & MORE_COMPONENTS) == 0) break;
    }
}

fn rewriteCompositeGlyphIndices(gbytes: []u8, old_to_new: []const u16) Error!void {
    if (gbytes.len < 10) return error.InvalidFont;
    var off: usize = 10;
    const ARG_1_AND_2_ARE_WORDS: u16 = 0x0001;
    const WE_HAVE_A_SCALE: u16 = 0x0008;
    const MORE_COMPONENTS: u16 = 0x0020;
    const WE_HAVE_AN_X_AND_Y_SCALE: u16 = 0x0040;
    const WE_HAVE_A_TWO_BY_TWO: u16 = 0x0080;

    while (true) {
        if (off + 4 > gbytes.len) return error.InvalidFont;
        const flags = std.mem.readInt(u16, gbytes[off..][0..2], .big);
        const old_child = std.mem.readInt(u16, gbytes[off + 2 ..][0..2], .big);
        if (old_child >= old_to_new.len) return error.GlyphIndexOutOfRange;
        const new_child = old_to_new[old_child];
        if (new_child == 0xFFFF) return error.InvalidFont;
        std.mem.writeInt(u16, gbytes[off + 2 ..][0..2], new_child, .big);
        off += 4;
        if ((flags & ARG_1_AND_2_ARE_WORDS) != 0) {
            off += 4;
        } else {
            off += 2;
        }
        if ((flags & WE_HAVE_A_SCALE) != 0) {
            off += 2;
        } else if ((flags & WE_HAVE_AN_X_AND_Y_SCALE) != 0) {
            off += 4;
        } else if ((flags & WE_HAVE_A_TWO_BY_TWO) != 0) {
            off += 8;
        }
        if ((flags & MORE_COMPONENTS) == 0) break;
    }
}

fn buildSubsetCmap(
    allocator: std.mem.Allocator,
    font: *const ParsedFont,
    codepoints: []const u21,
    old_to_new: []const u16,
) Error![]u8 {
    // Collect (codepoint, new_gid) pairs sorted by codepoint, dropping
    // duplicates and any non-BMP / missing GIDs. We emit a single Format-4
    // subtable with one segment per pair (no run merging — keeps the code
    // boring; subset cmaps are tiny).
    var pairs: std.ArrayList(struct { cp: u16, gid: u16 }) = .empty;
    defer pairs.deinit(allocator);
    var seen = try std.DynamicBitSet.initEmpty(allocator, 0x10000);
    defer seen.deinit();
    for (codepoints) |cp| {
        if (cp > 0xFFFF) continue;
        const cp16: u16 = @intCast(cp);
        if (seen.isSet(cp16)) continue;
        const old_gid = font.glyphForCodepoint(cp);
        if (old_gid == 0) continue;
        const new_gid = old_to_new[old_gid];
        if (new_gid == 0xFFFF) continue;
        seen.set(cp16);
        try pairs.append(allocator, .{ .cp = cp16, .gid = new_gid });
    }
    std.mem.sort(@TypeOf(pairs.items[0]), pairs.items, {}, struct {
        fn lt(_: void, a: @TypeOf(pairs.items[0]), b: @TypeOf(pairs.items[0])) bool {
            return a.cp < b.cp;
        }
    }.lt);

    // Emit cmap. Layout:
    //   Header: version(0) numTables(1) [4]                            = 4
    //   Encoding record: platformID(0) encodingID(3) offset(12)        = 8
    //   Format 4 subtable: see below
    //
    // Format 4 segments: one per pair + one terminator (0xFFFF).
    // We use idRangeOffset = 0 (delta path) for simplicity.
    const seg_count: u16 = @intCast(pairs.items.len + 1);
    const seg_count_x2 = seg_count * 2;
    const search_range = blk: {
        var sr: u16 = 2;
        while (sr * 2 <= seg_count_x2) sr *= 2;
        break :blk sr;
    };
    const entry_selector: u16 = blk: {
        var es: u16 = 0;
        var v: u16 = search_range;
        while (v > 1) : (v >>= 1) es += 1;
        break :blk es;
    };
    const range_shift: u16 = seg_count_x2 -% search_range;

    // Format 4 subtable on-disk layout (cmap §subtable):
    //   format(2) length(2) language(2) segCountX2(2) searchRange(2)
    //   entrySelector(2) rangeShift(2)                        = 14 bytes
    //   endCount[seg](2*seg) reservedPad(2)                   = 2*seg + 2
    //   startCount[seg](2*seg)                                = 2*seg
    //   idDelta[seg](2*seg)                                   = 2*seg
    //   idRangeOffset[seg](2*seg)                             = 2*seg
    const subtable_len: usize = 14 +
        @as(usize, seg_count) * 2 + 2 +
        @as(usize, seg_count) * 2 +
        @as(usize, seg_count) * 2 +
        @as(usize, seg_count) * 2;
    const total_len = 4 + 8 + subtable_len;
    var out = try allocator.alloc(u8, total_len);
    errdefer allocator.free(out);
    @memset(out, 0);

    // cmap header
    std.mem.writeInt(u16, out[0..2], 0, .big);
    std.mem.writeInt(u16, out[2..4], 1, .big);
    // encoding record: platform 0 (Unicode), encoding 3 (BMP).
    std.mem.writeInt(u16, out[4..6], 0, .big);
    std.mem.writeInt(u16, out[6..8], 3, .big);
    std.mem.writeInt(u32, out[8..12], 12, .big);

    // subtable header: format(4) length subtable_len language(0)
    var p: usize = 12;
    std.mem.writeInt(u16, out[p..][0..2], 4, .big);
    p += 2;
    std.mem.writeInt(u16, out[p..][0..2], @intCast(subtable_len), .big);
    p += 2;
    std.mem.writeInt(u16, out[p..][0..2], 0, .big);
    p += 2;
    std.mem.writeInt(u16, out[p..][0..2], seg_count_x2, .big);
    p += 2;
    std.mem.writeInt(u16, out[p..][0..2], search_range, .big);
    p += 2;
    std.mem.writeInt(u16, out[p..][0..2], entry_selector, .big);
    p += 2;
    std.mem.writeInt(u16, out[p..][0..2], range_shift, .big);
    p += 2;

    // endCount[seg_count]
    for (pairs.items) |pair| {
        std.mem.writeInt(u16, out[p..][0..2], pair.cp, .big);
        p += 2;
    }
    std.mem.writeInt(u16, out[p..][0..2], 0xFFFF, .big);
    p += 2;
    // reservedPad
    std.mem.writeInt(u16, out[p..][0..2], 0, .big);
    p += 2;
    // startCount[seg_count]
    for (pairs.items) |pair| {
        std.mem.writeInt(u16, out[p..][0..2], pair.cp, .big);
        p += 2;
    }
    std.mem.writeInt(u16, out[p..][0..2], 0xFFFF, .big);
    p += 2;
    // idDelta[seg_count] — delta = (gid - cp) mod 65536.
    for (pairs.items) |pair| {
        const delta_wide: u32 = (@as(u32, pair.gid) -% @as(u32, pair.cp)) & 0xFFFF;
        const delta: u16 = @intCast(delta_wide);
        std.mem.writeInt(u16, out[p..][0..2], delta, .big);
        p += 2;
    }
    // Terminator delta: must give GID 0 for cp 0xFFFF (per spec).
    std.mem.writeInt(u16, out[p..][0..2], 1, .big); // delta 1: 0xFFFF + 1 = 0x10000 → 0
    p += 2;
    // idRangeOffset[seg_count] — all zero (delta path).
    p += @as(usize, seg_count) * 2;

    std.debug.assert(p == total_len);
    return out;
}

fn buildMinimalPost(allocator: std.mem.Allocator) Error![]u8 {
    // Format 3.0 post: 32 bytes, no glyph-name array.
    var out = try allocator.alloc(u8, 32);
    errdefer allocator.free(out);
    @memset(out, 0);
    std.mem.writeInt(u32, out[0..4], 0x00030000, .big); // format 3.0
    return out;
}

const TableEntry = struct { tag: u32, body: []const u8 };

fn assembleFont(
    allocator: std.mem.Allocator,
    tables: []const TableEntry,
) Error![]u8 {
    const num_tables: u16 = @intCast(tables.len);
    const seg = blk: {
        var s: u16 = 1;
        while (s * 2 <= num_tables) s *= 2;
        break :blk s;
    };
    const search_range_w: u16 = seg * 16;
    const entry_selector_w: u16 = blk: {
        var es: u16 = 0;
        var v: u16 = seg;
        while (v > 1) : (v >>= 1) es += 1;
        break :blk es;
    };
    const range_shift_w: u16 = num_tables * 16 -% search_range_w;

    // Compute padded sizes & offsets.
    const header_len: usize = 12 + @as(usize, num_tables) * 16;
    var total_len: usize = header_len;
    var padded_lens = try allocator.alloc(usize, tables.len);
    defer allocator.free(padded_lens);
    for (tables, 0..) |t, idx| {
        const padded = (t.body.len + 3) & ~@as(usize, 3);
        padded_lens[idx] = padded;
        total_len += padded;
    }

    var out = try allocator.alloc(u8, total_len);
    errdefer allocator.free(out);
    @memset(out, 0);

    // Offset Table.
    std.mem.writeInt(u32, out[0..4], 0x00010000, .big);
    std.mem.writeInt(u16, out[4..6], num_tables, .big);
    std.mem.writeInt(u16, out[6..8], search_range_w, .big);
    std.mem.writeInt(u16, out[8..10], entry_selector_w, .big);
    std.mem.writeInt(u16, out[10..12], range_shift_w, .big);

    // Lay out tables in tag order (spec recommends ascending).
    var dir_offsets = try allocator.alloc(u32, tables.len);
    defer allocator.free(dir_offsets);
    var cursor: usize = header_len;
    // tables[] is already in tag-ascending order in the caller.
    for (tables, 0..) |t, idx| {
        dir_offsets[idx] = @intCast(cursor);
        @memcpy(out[cursor .. cursor + t.body.len], t.body);
        cursor += padded_lens[idx];
    }

    // Write directory records — same order as `tables`, with checksums.
    for (tables, 0..) |t, idx| {
        const r_off = 12 + idx * 16;
        std.mem.writeInt(u32, out[r_off..][0..4], t.tag, .big);
        const cs = tableChecksum(out[dir_offsets[idx] .. dir_offsets[idx] + padded_lens[idx]]);
        std.mem.writeInt(u32, out[r_off + 4 ..][0..4], cs, .big);
        std.mem.writeInt(u32, out[r_off + 8 ..][0..4], dir_offsets[idx], .big);
        std.mem.writeInt(u32, out[r_off + 12 ..][0..4], @intCast(t.body.len), .big);
    }
    return out;
}

fn tableChecksum(body: []const u8) u32 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 4 <= body.len) : (i += 4) {
        const w = std.mem.readInt(u32, body[i..][0..4], .big);
        sum +%= w;
    }
    if (i < body.len) {
        var tail: [4]u8 = .{ 0, 0, 0, 0 };
        const rem = body.len - i;
        @memcpy(tail[0..rem], body[i..]);
        sum +%= std.mem.readInt(u32, &tail, .big);
    }
    return sum;
}

fn patchChecksumAdjustment(out: []u8) Error!void {
    // Find `head` table, zero its checksumAdjustment, recompute file
    // checksum, write 0xB1B0AFBA - file_sum into the `head` slot.
    if (out.len < 12) return error.InvalidFont;
    const num_tables = std.mem.readInt(u16, out[4..6], .big);
    if (12 + @as(usize, num_tables) * 16 > out.len) return error.InvalidFont;
    var head_off: ?u32 = null;
    var i: usize = 0;
    while (i < num_tables) : (i += 1) {
        const r_off = 12 + i * 16;
        const tag = std.mem.readInt(u32, out[r_off..][0..4], .big);
        if (tag == TableTag.head) {
            head_off = std.mem.readInt(u32, out[r_off + 8 ..][0..4], .big);
            break;
        }
    }
    const ho = head_off orelse return error.MissingRequiredTable;
    if (ho + 12 > out.len) return error.InvalidFont;
    // Zero checkSumAdjustment.
    std.mem.writeInt(u32, out[ho + 8 ..][0..4], 0, .big);
    const file_sum = tableChecksum(out);
    const adjustment: u32 = 0xB1B0AFBA -% file_sum;
    std.mem.writeInt(u32, out[ho + 8 ..][0..4], adjustment, .big);
}

// ============================================================================
// Helpers
// ============================================================================

fn readU16(b: []const u8, off: usize) Error!u16 {
    if (off + 2 > b.len) return error.InvalidFont;
    return std.mem.readInt(u16, b[off..][0..2], .big);
}

fn readU32(b: []const u8, off: usize) Error!u32 {
    if (off + 4 > b.len) return error.InvalidFont;
    return std.mem.readInt(u32, b[off..][0..4], .big);
}

fn writeU16(list: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u16) Error!void {
    var tmp: [2]u8 = undefined;
    std.mem.writeInt(u16, &tmp, v, .big);
    try list.appendSlice(allocator, &tmp);
}

fn writeI16(list: *std.ArrayList(u8), allocator: std.mem.Allocator, v: i16) Error!void {
    var tmp: [2]u8 = undefined;
    std.mem.writeInt(i16, &tmp, v, .big);
    try list.appendSlice(allocator, &tmp);
}

// ============================================================================
// TESTS
// ============================================================================

test "tagFromStr packs ASCII tags big-endian" {
    try std.testing.expectEqual(@as(u32, 0x68656164), TableTag.head);
    try std.testing.expectEqual(@as(u32, 0x676C7966), TableTag.glyf);
}

test "readU16 / readU32 reject out-of-bounds" {
    const b = [_]u8{ 1, 2, 3 };
    try std.testing.expectError(error.InvalidFont, readU16(&b, 2));
    try std.testing.expectError(error.InvalidFont, readU32(&b, 0));
}

test "parse rejects truncated buffer" {
    const tiny = [_]u8{ 0, 1, 0, 0 };
    try std.testing.expectError(error.InvalidFont, parse(std.testing.allocator, &tiny));
}

test "parse rejects OTTO (CFF) fonts" {
    // Just the version word — that's enough for the CFF check.
    const otto = [_]u8{ 'O', 'T', 'T', 'O', 0, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectError(error.CffNotSupported, parse(std.testing.allocator, &otto));
}

/// Helper for tests: load a system font, returning null on any I/O
/// error. Tests using this MUST gracefully skip when the font is
/// unavailable (CI runners may lack /System/Library/Fonts).
fn loadSystemFont(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(32 * 1024 * 1024)) catch null;
}

test "parse round-trips a real system TTF (Monaco.ttf)" {
    const bytes = loadSystemFont(std.testing.allocator, "/System/Library/Fonts/Monaco.ttf") orelse return;
    defer std.testing.allocator.free(bytes);
    var parsed = try parse(std.testing.allocator, bytes);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expect(parsed.maxp.num_glyphs > 0);
    try std.testing.expect(parsed.head.units_per_em > 0);
    // 'A' must map to a real glyph in any Latin font.
    try std.testing.expect(parsed.glyphForCodepoint('A') != 0);
}

test "subset 'Hello' is < 30% of source font (Monaco)" {
    const bytes = loadSystemFont(std.testing.allocator, "/System/Library/Fonts/Monaco.ttf") orelse return;
    defer std.testing.allocator.free(bytes);
    var parsed = try parse(std.testing.allocator, bytes);
    defer parsed.deinit(std.testing.allocator);

    const codepoints = [_]u21{ 'H', 'e', 'l', 'o' };
    var sub = try subset(std.testing.allocator, &parsed, &codepoints);
    defer sub.deinit(std.testing.allocator);

    const ratio = @as(f64, @floatFromInt(sub.bytes.len)) / @as(f64, @floatFromInt(bytes.len));
    try std.testing.expect(ratio < 0.30);
    // Re-parse the subset to prove it's a structurally valid TT font.
    var reparsed = try parse(std.testing.allocator, sub.bytes);
    defer reparsed.deinit(std.testing.allocator);
}

test "subset preserves head.checkSumAdjustment correctness" {
    const bytes = loadSystemFont(std.testing.allocator, "/System/Library/Fonts/Monaco.ttf") orelse return;
    defer std.testing.allocator.free(bytes);
    var parsed = try parse(std.testing.allocator, bytes);
    defer parsed.deinit(std.testing.allocator);

    const codepoints = [_]u21{ 'A', 'B', 'C' };
    var sub = try subset(std.testing.allocator, &parsed, &codepoints);
    defer sub.deinit(std.testing.allocator);

    // Validate: zero out checkSumAdjustment, recompute file checksum,
    // verify file_sum + checksumAdjustment == 0xB1B0AFBA.
    const num_tables = std.mem.readInt(u16, sub.bytes[4..6], .big);
    var head_off: u32 = 0;
    var i: usize = 0;
    while (i < num_tables) : (i += 1) {
        const r_off = 12 + i * 16;
        const tag = std.mem.readInt(u32, sub.bytes[r_off..][0..4], .big);
        if (tag == TableTag.head) {
            head_off = std.mem.readInt(u32, sub.bytes[r_off + 8 ..][0..4], .big);
            break;
        }
    }
    try std.testing.expect(head_off != 0);
    const adjustment = std.mem.readInt(u32, sub.bytes[head_off + 8 ..][0..4], .big);
    // Recompute with adjustment field temporarily zeroed.
    const tmp = try std.testing.allocator.dupe(u8, sub.bytes);
    defer std.testing.allocator.free(tmp);
    std.mem.writeInt(u32, tmp[head_off + 8 ..][0..4], 0, .big);
    const file_sum = tableChecksum(tmp);
    const expected: u32 = 0xB1B0AFBA -% file_sum;
    try std.testing.expectEqual(expected, adjustment);
}

test "composite recursion exceeds MAX_COMPOSITE_DEPTH → error.CompositeGlyphCycle" {
    // Build a chain of 18 composite glyphs: 0 → 1 → 2 → ... → 17. Since
    // every link points to a fresh GID, the keep-set memoization can't
    // short-circuit; the depth cap (16) must trip on the way down.
    const N: u16 = 18;
    const GLYPH_LEN: u32 = 16;
    const glyph_offsets = try std.testing.allocator.alloc(u32, N + 1);
    defer std.testing.allocator.free(glyph_offsets);
    for (0..(N + 1)) |i| glyph_offsets[i] = @intCast(i * GLYPH_LEN);

    const glyf = try std.testing.allocator.alloc(u8, N * GLYPH_LEN);
    defer std.testing.allocator.free(glyf);
    @memset(glyf, 0);
    for (0..N) |i| {
        const base = i * GLYPH_LEN;
        // noc = -1 (composite)
        glyf[base + 0] = 0xFF;
        glyf[base + 1] = 0xFF;
        // bbox = 0..7 (already zeroed)
        // flags @ base+10 = 0 (no MORE_COMPONENTS, single-byte args)
        // child @ base+12 = next glyph (or self-loop on last to keep within bounds)
        const child: u16 = if (i + 1 < N) @intCast(i + 1) else @intCast(i);
        std.mem.writeInt(u16, glyf[base + 12 ..][0..2], child, .big);
        // args @ base+14..16 = 0
    }

    const fake_font: ParsedFont = .{
        .raw = &.{},
        .head = .{
            .units_per_em = 1000,
            .x_min = 0,
            .y_min = 0,
            .x_max = 0,
            .y_max = 0,
            .index_to_loc_format = 0,
            .flags = 0,
            .mac_style = 0,
        },
        .maxp = .{ .num_glyphs = N },
        .cmap = .{
            .format4_subtable = &.{},
            .seg_count = 0,
            .end_codes_offset = 0,
            .start_codes_offset = 0,
            .id_deltas_offset = 0,
            .id_range_offsets_offset = 0,
            .glyph_id_array_offset = 0,
        },
        .glyf_loca = .{ .glyf = glyf, .glyph_offsets = glyph_offsets },
        .name = .{ .raw = &.{}, .postscript_name = "" },
        .hhea = .{
            .ascender = 0,
            .descender = 0,
            .line_gap = 0,
            .advance_width_max = 0,
            .num_long_h_metrics = N,
        },
        .hmtx = .{ .raw = &.{}, .num_long_h_metrics = N, .num_glyphs = N },
        .postscript_name_buf = "",
    };
    var keep_set = try std.DynamicBitSet.initEmpty(std.testing.allocator, N);
    defer keep_set.deinit();
    var work: std.ArrayList(u16) = .empty;
    defer work.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.CompositeGlyphCycle,
        expandComposite(&fake_font, 0, &keep_set, &work, std.testing.allocator, 0),
    );
}
