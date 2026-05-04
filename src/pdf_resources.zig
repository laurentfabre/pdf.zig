//! PR-W11 [refactor]: document-wide resource registry.
//!
//! Tier-1 (`pdf_document.zig`) inlined a fresh `/Font` dict in every
//! page's `/Resources`. That works for 14 base fonts (cheap, no dedup
//! needed at the writer layer) but breaks at Tier 2: embedded font
//! streams / image XObjects / ICC color spaces MUST exist as a single
//! indirect object referenced from many pages, never duplicated.
//!
//! ## Lifecycle
//!
//! ```zig
//! var reg = ResourceRegistry.init(allocator);
//! defer reg.deinit();
//!
//! const h_helv = try reg.registerBuiltinFont(.helvetica);
//! const name   = reg.fontResourceName(h_helv);   // "/F0"
//! // ... later, at DocumentBuilder.write() ...
//! try reg.assignFontObjectNumbers(&writer);
//! const ref_obj = reg.fontObjectNum(h_helv);     // u32
//! ```
//!
//! ## Inheritance strategy (chosen)
//!
//! Per-page minimal `/Resources` dict referencing the **shared** font
//! indirect objects (`/F0 N 0 R`). Rationale: `/Parent` inheritance for
//! `/Resources` (PDF 1.7 §7.7.3.4) is legal but several real-world
//! readers misbehave when a leaf `/Page` has no `/Resources` of its
//! own. The cost of a per-page dict listing only *referenced* fonts is
//! ~16 B/page for a single-font doc; the savings come from emitting
//! one shared font object instead of inlining the dict body per page.
//!
//! ## Tier-2 placeholders
//!
//! `images` and `color_spaces` are present as empty `ArrayList`s so
//! W7 / W8 / W10 can land their `*Handle` types alongside `FontHandle`
//! without re-shaping this module. They are not yet exercised.

const std = @import("std");
const pdf_writer = @import("pdf_writer.zig");
const pdf_document = @import("pdf_document.zig");
const font_embedder = @import("font_embedder.zig");

pub const BuiltinFont = pdf_document.BuiltinFont;
pub const NUM_BUILTIN_FONTS = pdf_document.NUM_BUILTIN_FONTS;
pub const EmbeddedFontRef = font_embedder.EmbeddedFontRef;

/// Opaque, non-zero font handle. The wrapped u32 is the index into
/// `ResourceRegistry.fonts`; callers MUST treat it as opaque.
pub const FontHandle = enum(u32) { _ };

/// Reserved for PR-W8.
pub const ImageHandle = enum(u32) { _ };

/// Reserved for PR-W10 (PDF/A sRGB ICC) — not yet exercised.
pub const ColorSpaceHandle = enum(u32) { _ };

/// PR-W7 [feat]: now extended with `embedded` variant. The embedded
/// pointer is owned by the registry — `deinit` walks every entry and
/// releases.
pub const FontEntry = union(enum) {
    builtin: BuiltinFont,
    embedded: *EmbeddedFontRef,
};

/// Reserved for PR-W8 — currently no constructors.
pub const ImageEntry = struct {};

/// Reserved for PR-W10 — currently no constructors.
pub const ColorSpaceEntry = struct {};

/// Maximum builtin-font dedup table size. Sized at compile-time so
/// the lookup is a stack array, not a hash map.
const builtin_dedupe_size: usize = NUM_BUILTIN_FONTS;

/// Inline storage for a resource name (`/F<index>`). 12 bytes covers
/// `/F` + any u32 in decimal (max 10 digits); +1 for the length byte.
const NameBuf = struct {
    bytes: [12]u8,
    len: u8,

    fn slice(self: *const NameBuf) []const u8 {
        return self.bytes[0..self.len];
    }

    fn fromIndex(idx: u32) NameBuf {
        var nb: NameBuf = .{ .bytes = undefined, .len = 0 };
        const written = std.fmt.bufPrint(&nb.bytes, "/F{d}", .{idx}) catch unreachable;
        nb.len = @intCast(written.len);
        return nb;
    }
};

pub const Error = error{
    OutOfMemory,
    InvalidHandle,
    /// `assignFontObjectNumbers` called twice or `fontObjectNum`
    /// queried before assignment.
    ObjectNumbersNotAssigned,
    ObjectNumbersAlreadyAssigned,
};

/// Document-wide registry of resources referenced by `/Page` objects.
///
/// Owned by `DocumentBuilder`; pages hold opaque handles. The registry
/// hands out resource names (`/F0`, `/F1`, …) at handle-creation time
/// and assigns indirect-object numbers lazily inside `write()`.
pub const ResourceRegistry = struct {
    allocator: std.mem.Allocator,
    fonts: std.ArrayList(FontEntry),
    /// Reserved for PR-W8.
    images: std.ArrayList(ImageEntry),
    /// Reserved for PR-W10.
    color_spaces: std.ArrayList(ColorSpaceEntry),

    /// Indirect-object number per font handle, parallel to `fonts`.
    /// Zero = "not yet assigned" (object 0 is illegal in PDF, so it is
    /// a safe sentinel). Populated by `assignFontObjectNumbers`.
    font_obj_nums: std.ArrayList(u32),

    /// Resource names per font handle, parallel to `fonts`. Pre-formatted
    /// at registration so `fontResourceName` returns a stable, owned
    /// slice valid until `deinit`.
    font_names: std.ArrayList(NameBuf),

    /// Builtin-font dedup. `[idx]` is the `FontHandle` previously
    /// allocated for `BuiltinFont(idx)`, or null if not yet seen.
    /// Stack-allocated; bounded by `NUM_BUILTIN_FONTS` (14).
    builtin_lookup: [builtin_dedupe_size]?FontHandle = @splat(null),

    /// Once true, mutating calls (`registerBuiltinFont` etc.) reject
    /// with `error.ObjectNumbersAlreadyAssigned`. The single-use guard
    /// is mirrored from `DocumentBuilder.written`; on the registry
    /// side we trip on attempts to grow after object numbers are
    /// committed to the writer.
    object_nums_assigned: bool = false,

    pub fn init(allocator: std.mem.Allocator) ResourceRegistry {
        return .{
            .allocator = allocator,
            .fonts = .empty,
            .images = .empty,
            .color_spaces = .empty,
            .font_obj_nums = .empty,
            .font_names = .empty,
        };
    }

    pub fn deinit(self: *ResourceRegistry) void {
        // PR-W7: release every embedded-font ref. Builtin entries hold
        // no heap state, so the union switch is short.
        for (self.fonts.items) |entry| switch (entry) {
            .builtin => {},
            .embedded => |ref| ref.deinit(),
        };
        self.fonts.deinit(self.allocator);
        self.images.deinit(self.allocator);
        self.color_spaces.deinit(self.allocator);
        self.font_obj_nums.deinit(self.allocator);
        self.font_names.deinit(self.allocator);
    }

    /// Register a builtin font. Idempotent: registering the same
    /// `BuiltinFont` twice returns the same `FontHandle`.
    pub fn registerBuiltinFont(self: *ResourceRegistry, font: BuiltinFont) Error!FontHandle {
        if (self.object_nums_assigned) return error.ObjectNumbersAlreadyAssigned;
        const lookup_idx: usize = @intFromEnum(font);
        if (self.builtin_lookup[lookup_idx]) |existing| return existing;

        const new_idx: u32 = @intCast(self.fonts.items.len);
        try self.fonts.append(self.allocator, .{ .builtin = font });
        errdefer _ = self.fonts.pop();
        try self.font_obj_nums.append(self.allocator, 0);
        errdefer _ = self.font_obj_nums.pop();
        try self.font_names.append(self.allocator, NameBuf.fromIndex(new_idx));
        errdefer _ = self.font_names.pop();

        const handle: FontHandle = @enumFromInt(new_idx);
        self.builtin_lookup[lookup_idx] = handle;
        return handle;
    }

    /// PR-W7 [feat]: register an embedded TrueType font. Caller owns
    /// `parsed` (the registry takes ownership of the
    /// `EmbeddedFontRef` allocated for it). On error the
    /// `EmbeddedFontRef` is deinit'd before returning so the caller
    /// never sees a partially-registered ref.
    pub fn registerEmbeddedFont(
        self: *ResourceRegistry,
        ref: *EmbeddedFontRef,
    ) Error!FontHandle {
        if (self.object_nums_assigned) {
            ref.deinit();
            return error.ObjectNumbersAlreadyAssigned;
        }

        const new_idx: u32 = @intCast(self.fonts.items.len);
        self.fonts.append(self.allocator, .{ .embedded = ref }) catch |err| {
            ref.deinit();
            return err;
        };
        // If a later parallel-list append fails, both the popped slot
        // AND the ref it carried must be released — otherwise the ref
        // becomes orphaned (registry no longer references it; deinit
        // walk skips it).
        errdefer {
            _ = self.fonts.pop();
            ref.deinit();
        }
        try self.font_obj_nums.append(self.allocator, 0);
        errdefer _ = self.font_obj_nums.pop();
        try self.font_names.append(self.allocator, NameBuf.fromIndex(new_idx));
        errdefer _ = self.font_names.pop();

        return @enumFromInt(new_idx);
    }

    /// Stable resource name (`/F0`, `/F1`, …) keyed on handle index.
    /// Collision-free across all handles. Returned slice is valid for
    /// the lifetime of the registry (backed by `font_names`).
    pub fn fontResourceName(self: *const ResourceRegistry, handle: FontHandle) []const u8 {
        const idx = @intFromEnum(handle);
        std.debug.assert(idx < self.fonts.items.len);
        return self.font_names.items[idx].slice();
    }

    /// Reserve one indirect-object number per font entry. Must be
    /// called exactly once, before `emitFontObjects`. After this point
    /// the registry is frozen — further `registerBuiltinFont` calls
    /// fail.
    pub fn assignFontObjectNumbers(self: *ResourceRegistry, w: *pdf_writer.Writer) !void {
        if (self.object_nums_assigned) return error.ObjectNumbersAlreadyAssigned;
        for (self.fonts.items, 0..) |entry, i| {
            switch (entry) {
                .builtin => {
                    const num = try w.allocObjectNum();
                    self.font_obj_nums.items[i] = num;
                },
                .embedded => |ref| {
                    // PR-W7: an embedded TT font costs 5 indirect
                    // objects (Type0, CIDFontType2, FontDescriptor,
                    // FontFile2, ToUnicode). The registry's
                    // user-visible obj number is the Type0 wrapper.
                    try font_embedder.assignObjectNumbers(ref, w);
                    self.font_obj_nums.items[i] = font_embedder.fontResourceObjNum(ref);
                },
            }
        }
        self.object_nums_assigned = true;
    }

    /// Indirect-object number for a font handle. Panics if assignment
    /// has not run yet — that is a builder-internal contract violation,
    /// not a caller error.
    pub fn fontObjectNum(self: *const ResourceRegistry, handle: FontHandle) u32 {
        std.debug.assert(self.object_nums_assigned);
        const idx = @intFromEnum(handle);
        std.debug.assert(idx < self.font_obj_nums.items.len);
        const num = self.font_obj_nums.items[idx];
        std.debug.assert(num != 0);
        return num;
    }

    /// Emit one indirect-object body per font entry. Each font becomes
    /// `<< /Type /Font /Subtype /Type1 /BaseFont /<Name> [/Encoding
    /// /WinAnsiEncoding] >>`. W7 will extend this to dispatch on the
    /// `FontEntry` tag.
    pub fn emitFontObjects(self: *const ResourceRegistry, w: *pdf_writer.Writer) !void {
        std.debug.assert(self.object_nums_assigned);
        for (self.fonts.items, 0..) |entry, i| {
            const obj_num = self.font_obj_nums.items[i];
            std.debug.assert(obj_num != 0);
            switch (entry) {
                .builtin => |bf| {
                    try w.beginObject(obj_num, 0);
                    try w.writeRaw("<< /Type /Font /Subtype /Type1 /BaseFont /");
                    try w.writeRaw(bf.baseFontName());
                    if (bf.usesWinAnsi()) {
                        try w.writeRaw(" /Encoding /WinAnsiEncoding");
                    }
                    try w.writeRaw(" >>");
                    try w.endObject();
                },
                .embedded => |ref| {
                    // PR-W7: emit() opens its own beginObject blocks
                    // (one each for the 5 indirect objects), so we do
                    // NOT wrap it here.
                    try font_embedder.emit(ref, w);
                },
            }
        }
    }

    /// Number of registered fonts. Used by `PageBuilder` to size its
    /// per-page used-set bitset.
    pub fn fontCount(self: *const ResourceRegistry) usize {
        return self.fonts.items.len;
    }

    /// Underlying entry for a handle (read-only). Useful for tests.
    pub fn fontEntry(self: *const ResourceRegistry, handle: FontHandle) FontEntry {
        const idx = @intFromEnum(handle);
        std.debug.assert(idx < self.fonts.items.len);
        return self.fonts.items[idx];
    }
};

// ---------- tests ----------

test "registerBuiltinFont dedupes identical builtins" {
    var reg = ResourceRegistry.init(std.testing.allocator);
    defer reg.deinit();
    const a = try reg.registerBuiltinFont(.helvetica);
    const b = try reg.registerBuiltinFont(.helvetica);
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(@as(usize, 1), reg.fontCount());
}

test "registerBuiltinFont distinguishes different builtins" {
    var reg = ResourceRegistry.init(std.testing.allocator);
    defer reg.deinit();
    const a = try reg.registerBuiltinFont(.helvetica);
    const b = try reg.registerBuiltinFont(.times_roman);
    try std.testing.expect(a != b);
    try std.testing.expectEqual(@as(usize, 2), reg.fontCount());
}

test "fontResourceName returns /F<index> stable across calls" {
    var reg = ResourceRegistry.init(std.testing.allocator);
    defer reg.deinit();
    const h0 = try reg.registerBuiltinFont(.helvetica);
    const h1 = try reg.registerBuiltinFont(.times_roman);
    const n0 = reg.fontResourceName(h0);
    const n1 = reg.fontResourceName(h1);
    try std.testing.expectEqualStrings("/F0", n0);
    try std.testing.expectEqualStrings("/F1", n1);
    // Handle 0's slice must remain valid after handle 1's call —
    // earlier scratch-buffer impl would have clobbered it.
    try std.testing.expectEqualStrings("/F0", reg.fontResourceName(h0));
}

test "registerBuiltinFont rejects after assignFontObjectNumbers" {
    var reg = ResourceRegistry.init(std.testing.allocator);
    defer reg.deinit();
    var w = pdf_writer.Writer.init(std.testing.allocator);
    defer w.deinit();
    _ = try reg.registerBuiltinFont(.helvetica);
    try reg.assignFontObjectNumbers(&w);
    try std.testing.expectError(
        error.ObjectNumbersAlreadyAssigned,
        reg.registerBuiltinFont(.times_roman),
    );
}

test "FailingAllocator: registerBuiltinFont leaks nothing on OOM" {
    // Drive each alloc index up to ~50 and assert no leaks.
    var fail_index: usize = 0;
    while (fail_index < 50) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        var reg = ResourceRegistry.init(failing.allocator());
        defer reg.deinit();
        // Try to register up to 14 distinct builtins. Some will succeed
        // and some will fail; what matters is no leak in either path.
        const fonts = [_]BuiltinFont{
            .helvetica,        .helvetica_bold,        .helvetica_oblique,        .helvetica_bold_oblique,
            .times_roman,      .times_bold,            .times_italic,             .times_bold_italic,
            .courier,          .courier_bold,          .courier_oblique,          .courier_bold_oblique,
            .symbol,           .zapf_dingbats,
        };
        for (fonts) |f| {
            _ = reg.registerBuiltinFont(f) catch |err| switch (err) {
                error.OutOfMemory => break,
                else => return err,
            };
        }
        // testing.allocator inside FailingAllocator catches leaks at
        // deinit; the assertion is implicit.
    }
}
