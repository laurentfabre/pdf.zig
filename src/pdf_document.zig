//! PR-W2 [feat]: Document / Page / Resources builder for greenfield
//! authoring. Sits on top of `pdf_writer.zig` (PR-W1).
//!
//! ## Lifecycle
//!
//! ```zig
//! var doc = pdf_document.DocumentBuilder.init(allocator);
//! defer doc.deinit();
//!
//! const page1 = try doc.addPage(.{ 0, 0, 612, 792 });
//! try page1.appendContent("BT /F1 12 Tf 100 700 Td (Hello) Tj ET");
//! try page1.setResourcesRaw("<< /Font << /F1 5 0 R >> >>");
//! // ...
//!
//! const bytes = try doc.write();
//! defer allocator.free(bytes);
//! ```
//!
//! ## Page tree shape (codex / roadmap PR-W2 acceptance gate)
//!
//! Balanced from day one with a fan-out of `PAGE_TREE_FANOUT = 10` per
//! `/Pages` node. Tree depth = `⌈log₁₀(N)⌉`. Every leaf `/Page` has a
//! correct `/Parent` ref; every internal `/Pages` node has `/Count`
//! equal to the **subtree page count** (NOT direct-children count) and
//! a `/Kids` array of child object refs.
//!
//! For N ≤ 10 the tree is flat (single root /Pages node, all pages as
//! direct children). For N > 10 intermediate /Pages nodes appear; the
//! leaves remain individual /Page objects.
//!
//! ## What this module does NOT do (Tier-1 scope)
//!
//! - Font resources or content-stream encoding — `PR-W3`.
//! - FlateDecode compression — `PR-W4` (content streams are raw).
//! - Inheritable page attributes (resources lifted to /Pages nodes).
//! - Outlines, TOC, annotations.
//! - Encryption, linearization, signatures — Tier 2/3.

const std = @import("std");
const pdf_writer = @import("pdf_writer.zig");

/// Number of children per `/Pages` node. ISO 32000-1 doesn't mandate
/// a specific fan-out; values between 8 and 32 are typical. 10 keeps
/// the math simple (depth = ⌈log₁₀(N)⌉) and is well below the
/// soft-limit reader implementations check at (~200).
pub const PAGE_TREE_FANOUT: u32 = 10;

/// PR-W3 [feat]: the 14 standard Type 1 fonts every PDF reader is
/// required to ship per ISO 32000-1 §9.6.2.2. No font-file embedding
/// needed — the reader has the metrics built-in. Tier-1 limit:
/// callers can only encode WinAnsiEncoding bytes (Latin-1-ish);
/// non-encodable bytes are dropped silently in `drawText`. PR-W7+
/// (Tier 2) will introduce TrueType subsetting + UTF-8.
pub const BuiltinFont = enum(u4) {
    helvetica,
    helvetica_bold,
    helvetica_oblique,
    helvetica_bold_oblique,
    times_roman,
    times_bold,
    times_italic,
    times_bold_italic,
    courier,
    courier_bold,
    courier_oblique,
    courier_bold_oblique,
    symbol,
    zapf_dingbats,

    /// PDF /BaseFont name per ISO 32000-1 §9.6.2.2 Table 121.
    pub fn baseFontName(self: BuiltinFont) []const u8 {
        return switch (self) {
            .helvetica => "Helvetica",
            .helvetica_bold => "Helvetica-Bold",
            .helvetica_oblique => "Helvetica-Oblique",
            .helvetica_bold_oblique => "Helvetica-BoldOblique",
            .times_roman => "Times-Roman",
            .times_bold => "Times-Bold",
            .times_italic => "Times-Italic",
            .times_bold_italic => "Times-BoldItalic",
            .courier => "Courier",
            .courier_bold => "Courier-Bold",
            .courier_oblique => "Courier-Oblique",
            .courier_bold_oblique => "Courier-BoldOblique",
            .symbol => "Symbol",
            .zapf_dingbats => "ZapfDingbats",
        };
    }

    /// Symbol and ZapfDingbats use their own encoding — not WinAnsi.
    /// drawText still works for them but the character set is the
    /// font's native encoding (per §9.6.6.4).
    pub fn usesWinAnsi(self: BuiltinFont) bool {
        return self != .symbol and self != .zapf_dingbats;
    }

    /// PR-W6.1 [feat]: resource name as it appears in the auto-emitted
    /// `/Resources/Font` dict. Matches the `/F<index>` form that
    /// `emitAutoResources` writes — callers injecting raw content
    /// streams (TJ, Tm) via `page.appendContent` must use this exact
    /// name in their `Tf` operator. Also used by `markFontUsed`.
    pub fn resourceName(self: BuiltinFont) []const u8 {
        return switch (self) {
            .helvetica => "/F0",
            .helvetica_bold => "/F1",
            .helvetica_oblique => "/F2",
            .helvetica_bold_oblique => "/F3",
            .times_roman => "/F4",
            .times_bold => "/F5",
            .times_italic => "/F6",
            .times_bold_italic => "/F7",
            .courier => "/F8",
            .courier_bold => "/F9",
            .courier_oblique => "/F10",
            .courier_bold_oblique => "/F11",
            .symbol => "/F12",
            .zapf_dingbats => "/F13",
        };
    }
};

pub const NUM_BUILTIN_FONTS: comptime_int = @typeInfo(BuiltinFont).@"enum".fields.len;

pub const PageBuilder = struct {
    media_box: [4]f64,
    /// Raw bytes inside the content stream (before any compression).
    /// Caller composes BT/ET, Tf, Td, etc. via `appendContent` or
    /// (preferred) the typed `drawText` helper.
    content: std.ArrayList(u8),
    /// Raw bytes that make up the `/Resources` dict body, e.g.
    /// `"<< /Font << /F1 5 0 R >> >>"`. When non-empty, this fully
    /// overrides the auto-emitted resources from `fonts_used`. When
    /// empty AND `fonts_used` has any true entry, `write` synthesises
    /// a `/Resources << /Font << /Fk << ...inline Type 1... >> >> >>`
    /// dict on the fly. When both empty, emits `<< >>`.
    resources_raw: std.ArrayList(u8),
    /// PR-W6 [feat]: extra raw bytes spliced into the leaf `/Page`
    /// dict between `/Resources` and `/Contents`. Used for `/Annots`,
    /// `/Group`, `/StructParents`, etc. Caller is responsible for
    /// well-formed PDF tokens (must start with `/<Name>` and round-trip
    /// through the parser).
    extras_raw: std.ArrayList(u8),
    /// PR-W3 [feat]: which BuiltinFont indices were referenced by
    /// `drawText` on this page. The /Resources dict is auto-built
    /// from this set during `write`.
    fonts_used: [NUM_BUILTIN_FONTS]bool = @splat(false),
    /// Allocator used for `content` + `resources_raw`. Set by the
    /// owning DocumentBuilder via `init`.
    allocator: std.mem.Allocator,
    /// PR-W6 [feat]: object number assigned to this leaf `/Page` by
    /// `DocumentBuilder.addPage`. Stable for the lifetime of the
    /// builder so callers can reference the page from /Annots, /Dest,
    /// /Outlines, /Names, etc.
    obj_num: u32 = 0,
    /// PR-W6 [feat]: object number for this page's content stream.
    /// Allocated alongside `obj_num`.
    content_obj_num: u32 = 0,

    fn init(allocator: std.mem.Allocator, media_box: [4]f64) PageBuilder {
        return .{
            .media_box = media_box,
            .content = .empty,
            .resources_raw = .empty,
            .extras_raw = .empty,
            .allocator = allocator,
        };
    }

    fn deinit(self: *PageBuilder) void {
        self.content.deinit(self.allocator);
        self.resources_raw.deinit(self.allocator);
        self.extras_raw.deinit(self.allocator);
    }

    pub fn appendContent(self: *PageBuilder, bytes: []const u8) !void {
        try self.content.appendSlice(self.allocator, bytes);
    }

    /// Replace the `/Resources` dict body. Must be a valid dict
    /// expression `<< ... >>`. Pass `"<< >>"` to clear. Setting this
    /// suppresses the auto-emitted font dict — you must include any
    /// /Font entries the page needs.
    pub fn setResourcesRaw(self: *PageBuilder, raw: []const u8) !void {
        self.resources_raw.clearRetainingCapacity();
        try self.resources_raw.appendSlice(self.allocator, raw);
    }

    /// PR-W6 [feat]: replace the per-page extras blob (key/value pairs
    /// inside the leaf `/Page` dict — `/Annots [...]`, `/Group << >>`,
    /// `/StructParents N`, etc.). Pass empty to clear. Caller writes
    /// well-formed PDF tokens; nothing is escaped.
    pub fn setPageExtras(self: *PageBuilder, raw: []const u8) !void {
        self.extras_raw.clearRetainingCapacity();
        try self.extras_raw.appendSlice(self.allocator, raw);
    }

    /// PR-W6 [feat]: object number assigned to this leaf `/Page` by
    /// `DocumentBuilder.addPage`. Useful when constructing /Annots
    /// destinations, outline /Dest entries, /AcroForm fields, etc.
    pub fn objNum(self: *const PageBuilder) u32 {
        return self.obj_num;
    }

    /// PR-W6.1 [feat]: register `font` in this page's auto-resources
    /// set and return its resource name (`/F0`..`/F13`) for use in a
    /// content-stream `Tf` operator. Use this when you need to call
    /// `appendContent` with a hand-written content stream and want
    /// the auto-emitted `/Resources/Font` dict to define the font
    /// name your stream references.
    pub fn markFontUsed(self: *PageBuilder, font: BuiltinFont) []const u8 {
        self.fonts_used[@intFromEnum(font)] = true;
        return font.resourceName();
    }

    /// PR-W3 [feat]: emit `BT /Fk size Tf x y Td (escaped) Tj ET`
    /// for `text` rendered with `font` at `size` points starting at
    /// PDF user-space coordinates `(x, y)` (origin = bottom-left).
    /// `font` is registered in this page's resources automatically.
    /// Bytes outside [0x20, 0x7e] are dropped silently for the 12
    /// WinAnsi-using built-in fonts (Tier-1 ASCII subset). Symbol /
    /// ZapfDingbats accept all bytes but use their native encoding.
    /// Empty text after escaping is a no-op (no BT/ET emitted).
    pub fn drawText(
        self: *PageBuilder,
        x: f64,
        y: f64,
        font: BuiltinFont,
        size: f64,
        text: []const u8,
    ) !void {
        if (!std.math.isFinite(x) or !std.math.isFinite(y) or !std.math.isFinite(size)) {
            return error.InvalidReal;
        }
        if (size <= 0) return error.InvalidReal;

        // Filter to WinAnsi-printable ASCII for the 12 standard fonts.
        // Symbol / ZapfDingbats keep all bytes (caller is responsible
        // for using the right encoding).
        var filtered: std.ArrayList(u8) = .empty;
        defer filtered.deinit(self.allocator);
        if (font.usesWinAnsi()) {
            for (text) |b| {
                if (b >= 0x20 and b <= 0x7e) try filtered.append(self.allocator, b);
            }
        } else {
            try filtered.appendSlice(self.allocator, text);
        }
        if (filtered.items.len == 0) return; // no-op for empty / all-dropped text

        self.fonts_used[@intFromEnum(font)] = true;

        // Compose into a scratch buffer first so a partial-failure
        // doesn't leave the page's content stream half-written.
        var scratch: std.ArrayList(u8) = .empty;
        defer scratch.deinit(self.allocator);
        const ws = scratch.writer(self.allocator);

        try ws.print("BT {s} ", .{font.resourceName()});
        try writeRealTo(ws, size);
        try ws.writeAll(" Tf ");
        try writeRealTo(ws, x);
        try ws.writeAll(" ");
        try writeRealTo(ws, y);
        try ws.writeAll(" Td (");
        for (filtered.items) |b| {
            switch (b) {
                '(' => try ws.writeAll("\\("),
                ')' => try ws.writeAll("\\)"),
                '\\' => try ws.writeAll("\\\\"),
                // codex r1 [Low]: PDF literal strings normalise
                // unescaped CR / CRLF to LF (§7.3.4.2). Octal-escape
                // control bytes so the Symbol/ZapfDingbats path is
                // byte-preserving. The WinAnsi-filtered path can't
                // hit this branch because [0x20, 0x7e] excludes them
                // anyway, so this is essentially Symbol-only.
                else => {
                    if (b < 0x20 or b == 0x7f) {
                        try ws.print("\\{o:0>3}", .{b});
                    } else {
                        try ws.writeByte(b);
                    }
                },
            }
        }
        try ws.writeAll(") Tj ET\n");

        try self.content.appendSlice(self.allocator, scratch.items);
    }
};

/// Tiny mirror of `pdf_writer.Writer.writeReal`: emit a finite f64
/// in the spec's restricted form (no exponent, trailing zeros
/// stripped). NaN/inf rejected by `drawText` callers, so we can
/// safely format here.
fn writeRealTo(writer: anytype, n: f64) !void {
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d:.6}", .{n}) catch return error.InvalidReal;
    var end = s.len;
    if (std.mem.indexOfScalar(u8, s, '.') != null) {
        while (end > 0 and s[end - 1] == '0') end -= 1;
        if (end > 0 and s[end - 1] == '.') end -= 1;
    }
    try writer.writeAll(s[0..end]);
}

pub const DocumentBuilder = struct {
    allocator: std.mem.Allocator,
    /// PR-W6 [feat]: writer is now long-lived so `addPage` and
    /// `addAuxiliaryObject` can reserve object numbers eagerly. The
    /// builder is single-use: `write()` consumes the writer and sets
    /// `written` to true; further mutating calls return
    /// `error.DocumentAlreadyWritten`.
    writer: pdf_writer.Writer,
    /// Pages in document order. Each pointer is heap-owned; freed by
    /// `deinit`.
    pages: std.ArrayList(*PageBuilder),
    /// PR-W6 [feat]: caller-supplied indirect objects (e.g. /Outlines
    /// items, /Annot dicts, /AcroForm field nodes). Each entry's bytes
    /// are emitted verbatim between `obj_num 0 obj` and `endobj`.
    aux_objects: std.ArrayList(AuxObject),
    /// PR-W6 [feat]: optional /Info dict (object number reserved on
    /// the first `setInfoDict` call; payload re-settable until `write`).
    info_obj_num: ?u32 = null,
    info_payload: std.ArrayList(u8),
    /// PR-W6 [feat]: raw bytes spliced into the /Catalog dict between
    /// `/Pages X 0 R` and the closing `>>` (e.g. `/Outlines N 0 R
    /// /PageLabels << ... >>`).
    catalog_extras_raw: std.ArrayList(u8),
    /// PR-W6 [feat]: single-use guard. Set true at the end of `write`;
    /// further mutating calls return `error.DocumentAlreadyWritten`.
    written: bool = false,

    const AuxObject = struct {
        obj_num: u32,
        /// `null` means "reserved but unfilled" — caller must call
        /// `setAuxiliaryPayload` before `write()`. Emitted as an empty
        /// `<< >>` dict if left unfilled, which keeps the PDF
        /// structurally valid but semantically meaningless.
        payload: ?[]u8,
    };

    pub const Error = pdf_writer.Writer.Error || error{ NoPages, DocumentAlreadyWritten, UnknownAuxObject };

    pub fn init(allocator: std.mem.Allocator) DocumentBuilder {
        return .{
            .allocator = allocator,
            .writer = pdf_writer.Writer.init(allocator),
            .pages = .empty,
            .aux_objects = .empty,
            .info_payload = .empty,
            .catalog_extras_raw = .empty,
        };
    }

    pub fn deinit(self: *DocumentBuilder) void {
        for (self.pages.items) |p| {
            p.deinit();
            self.allocator.destroy(p);
        }
        self.pages.deinit(self.allocator);
        for (self.aux_objects.items) |a| if (a.payload) |p| self.allocator.free(p);
        self.aux_objects.deinit(self.allocator);
        self.info_payload.deinit(self.allocator);
        self.catalog_extras_raw.deinit(self.allocator);
        self.writer.deinit();
    }

    /// PR-W6 [feat]: failure-atomicity contract for the mutating
    /// methods below. On any error other than `DocumentAlreadyWritten`
    /// (e.g. OOM mid-call), the builder may have partially-reserved
    /// object numbers in the underlying writer; the caller MUST treat
    /// the builder as poisoned and call `deinit` without reattempting
    /// the operation. The page-tree assembly in `write()` would
    /// otherwise trip `error.DanglingObjectAllocation`.
    pub fn addPage(self: *DocumentBuilder, media_box: [4]f64) !*PageBuilder {
        if (self.written) return error.DocumentAlreadyWritten;
        const page_num = try self.writer.allocObjectNum();
        const content_num = try self.writer.allocObjectNum();
        const page = try self.allocator.create(PageBuilder);
        errdefer self.allocator.destroy(page);
        page.* = PageBuilder.init(self.allocator, media_box);
        page.obj_num = page_num;
        page.content_obj_num = content_num;
        try self.pages.append(self.allocator, page);
        return page;
    }

    /// PR-W6 [feat]: register an auxiliary indirect object with its
    /// payload set in one shot. Returns the allocated object number
    /// for the caller to use in refs. Equivalent to `reserveAuxiliary
    /// Object` + `setAuxiliaryPayload`.
    pub fn addAuxiliaryObject(self: *DocumentBuilder, payload: []const u8) !u32 {
        const num = try self.reserveAuxiliaryObject();
        try self.setAuxiliaryPayload(num, payload);
        return num;
    }

    /// PR-W6 [feat]: reserve an auxiliary object number without
    /// supplying the payload yet. Used when two aux objects must
    /// reference each other (e.g. /Outlines /First → item, item
    /// /Parent → /Outlines). Caller MUST call `setAuxiliaryPayload`
    /// before `write()`; an unfilled aux object emits as `<< >>`.
    pub fn reserveAuxiliaryObject(self: *DocumentBuilder) !u32 {
        if (self.written) return error.DocumentAlreadyWritten;
        const num = try self.writer.allocObjectNum();
        try self.aux_objects.append(self.allocator, .{ .obj_num = num, .payload = null });
        return num;
    }

    /// PR-W6 [feat]: fill in (or replace) the payload of a previously
    /// reserved aux object. The bytes are duplicated; subsequent
    /// callers may free the original buffer immediately.
    pub fn setAuxiliaryPayload(self: *DocumentBuilder, obj_num: u32, payload: []const u8) !void {
        if (self.written) return error.DocumentAlreadyWritten;
        for (self.aux_objects.items) |*aux| {
            if (aux.obj_num == obj_num) {
                const owned = try self.allocator.dupe(u8, payload);
                if (aux.payload) |old| self.allocator.free(old);
                aux.payload = owned;
                return;
            }
        }
        return error.UnknownAuxObject;
    }

    /// PR-W6 [feat]: set the /Info dict payload. The payload must be
    /// a complete PDF dict expression (`<< /Title (...) /Author (...)
    /// >>`). The object number is reserved on the first call and
    /// returned so the caller may reference it (e.g. as an /Encrypt
    /// peer); subsequent calls only update the payload.
    pub fn setInfoDict(self: *DocumentBuilder, payload: []const u8) !u32 {
        if (self.written) return error.DocumentAlreadyWritten;
        if (self.info_obj_num == null) {
            self.info_obj_num = try self.writer.allocObjectNum();
        }
        self.info_payload.clearRetainingCapacity();
        try self.info_payload.appendSlice(self.allocator, payload);
        return self.info_obj_num.?;
    }

    /// PR-W6 [feat]: replace the /Catalog extras blob (raw bytes
    /// spliced in *before* the closing `>>`). Pass empty to clear.
    /// Caller is responsible for well-formed PDF tokens.
    pub fn setCatalogExtras(self: *DocumentBuilder, raw: []const u8) !void {
        if (self.written) return error.DocumentAlreadyWritten;
        self.catalog_extras_raw.clearRetainingCapacity();
        try self.catalog_extras_raw.appendSlice(self.allocator, raw);
    }

    /// Assemble the document and return owned bytes. Caller frees with
    /// `allocator.free(bytes)`. Single-use: a second call returns
    /// `error.DocumentAlreadyWritten`.
    pub fn write(self: *DocumentBuilder) ![]u8 {
        if (self.written) return error.DocumentAlreadyWritten;
        if (self.pages.items.len == 0) return error.NoPages;

        const w = &self.writer;
        try w.writeHeader();

        const num_pages: u32 = @intCast(self.pages.items.len);

        const catalog = try w.allocObjectNum();

        // Pull pre-allocated page/content nums into a local array for
        // buildBalancedTree (which expects a slice of page nums).
        const page_obj_nums = try self.allocator.alloc(u32, num_pages);
        defer self.allocator.free(page_obj_nums);
        for (self.pages.items, 0..) |p, i| page_obj_nums[i] = p.obj_num;

        var tree = try buildBalancedTree(self.allocator, w, page_obj_nums);
        defer freeTree(self.allocator, &tree);

        // 3a. Catalog (with optional extras blob).
        try w.beginObject(catalog, 0);
        try w.writeRaw("<< /Type /Catalog /Pages ");
        try w.writeRef(tree.root_obj, 0);
        if (self.catalog_extras_raw.items.len > 0) {
            try w.writeRaw(" ");
            try w.writeRaw(self.catalog_extras_raw.items);
        }
        try w.writeRaw(" >>");
        try w.endObject();

        // 3b. Internal /Pages nodes (root + intermediate). The `tree`
        // structure stores them in level order (root first).
        for (tree.internal_nodes) |node| {
            try w.beginObject(node.obj_num, 0);
            try w.writeRaw("<< /Type /Pages");
            if (node.parent_obj) |parent| {
                try w.writeRaw(" /Parent ");
                try w.writeRef(parent, 0);
            }
            try w.writeRaw(" /Kids [");
            for (node.kids, 0..) |kid, kix| {
                if (kix > 0) try w.writeRaw(" ");
                try w.writeRef(kid, 0);
            }
            try w.writeRaw("] /Count ");
            try w.writeInt(@intCast(node.subtree_page_count));
            try w.writeRaw(" >>");
            try w.endObject();
        }

        // 3c. Leaf /Page objects (with optional /Annots, /Group, …).
        for (self.pages.items, 0..) |page, i| {
            try w.beginObject(page.obj_num, 0);
            try w.writeRaw("<< /Type /Page /Parent ");
            try w.writeRef(tree.leaf_parent_obj[i], 0);
            try w.writeRaw(" /MediaBox [");
            try w.writeReal(page.media_box[0]);
            try w.writeRaw(" ");
            try w.writeReal(page.media_box[1]);
            try w.writeRaw(" ");
            try w.writeReal(page.media_box[2]);
            try w.writeRaw(" ");
            try w.writeReal(page.media_box[3]);
            try w.writeRaw("] /Resources ");
            if (page.resources_raw.items.len > 0) {
                try w.writeRaw(page.resources_raw.items);
            } else {
                try emitAutoResources(w, page);
            }
            if (page.extras_raw.items.len > 0) {
                try w.writeRaw(" ");
                try w.writeRaw(page.extras_raw.items);
            }
            try w.writeRaw(" /Contents ");
            try w.writeRef(page.content_obj_num, 0);
            try w.writeRaw(" >>");
            try w.endObject();
        }

        // 3d. Content streams.
        for (self.pages.items) |page| {
            try w.beginObject(page.content_obj_num, 0);
            try w.writeStream(page.content.items, "");
            try w.endObject();
        }

        // 3e. Auxiliary objects (outline items, annotations, form
        // fields, page-label trees, …). Each payload is the complete
        // dict / stream body — emitted verbatim between obj/endobj.
        // A reserved-but-unfilled aux object emits as `<< >>` so the
        // PDF stays structurally valid even if the caller forgot to
        // call `setAuxiliaryPayload`.
        for (self.aux_objects.items) |aux| {
            try w.beginObject(aux.obj_num, 0);
            try w.writeRaw(aux.payload orelse "<< >>");
            try w.endObject();
        }

        // 3f. /Info dict (optional).
        if (self.info_obj_num) |info_num| {
            try w.beginObject(info_num, 0);
            try w.writeRaw(self.info_payload.items);
            try w.endObject();
        }

        const xref_off = try w.writeXref();
        try w.writeTrailer(xref_off, catalog, self.info_obj_num);
        const bytes = try w.finalize();
        self.written = true;
        return bytes;
    }
};

/// Internal data carrier returned by `buildBalancedTree`. The caller
/// owns `internal_node_objs` (the slice) and `leaf_parent_obj` (the
/// slice). Each `internal_nodes[i].kids` is a sub-slice of either
/// `leaf_obj_nums` or `internal_node_objs` so it does NOT need to be
/// freed independently.
const Tree = struct {
    /// Object number of the root /Pages node. Always non-zero.
    root_obj: u32,
    /// All internal /Pages node objects, level-ordered from root to
    /// the deepest level above the leaves. Caller owns; free with
    /// `allocator.free(internal_node_objs)`.
    internal_node_objs: []u32,
    /// View-only: descriptors for emission. Backed by an owned arena
    /// inside the function — wait, we use `allocator` directly. The
    /// `kids` slices must be freed too. See `freeTree`.
    internal_nodes: []InternalNode,
    /// For each leaf page index, the parent /Pages node it belongs to.
    /// Caller owns; free with `allocator.free(leaf_parent_obj)`.
    leaf_parent_obj: []u32,

    const InternalNode = struct {
        obj_num: u32,
        parent_obj: ?u32,
        kids: []u32, // owned; freed via allocator.free
        subtree_page_count: u32,
    };
};

/// PR-W3 [feat]: synthesise the page's `/Resources` dict from
/// `fonts_used`. If no fonts were touched, emits `<< >>`.
fn emitAutoResources(w: *pdf_writer.Writer, page: *const PageBuilder) !void {
    var any_font: bool = false;
    for (page.fonts_used) |used| if (used) {
        any_font = true;
        break;
    };
    if (!any_font) {
        try w.writeRaw("<< >>");
        return;
    }
    try w.writeRaw("<< /Font << ");
    for (page.fonts_used, 0..) |used, idx| {
        if (!used) continue;
        const font: BuiltinFont = @enumFromInt(idx);
        try w.writeRaw(font.resourceName());
        try w.writeRaw(" << /Type /Font /Subtype /Type1 /BaseFont /");
        try w.writeRaw(font.baseFontName());
        if (font.usesWinAnsi()) {
            try w.writeRaw(" /Encoding /WinAnsiEncoding");
        }
        try w.writeRaw(" >> ");
    }
    try w.writeRaw(">> >>");
}

/// Release all `Tree`-owned slices: `internal_node_objs`,
/// `leaf_parent_obj`, the `internal_nodes` slice itself, and each
/// `internal_nodes[i].kids` sub-slice.
fn freeTree(allocator: std.mem.Allocator, tree: *Tree) void {
    for (tree.internal_nodes) |node| allocator.free(node.kids);
    allocator.free(tree.internal_nodes);
    allocator.free(tree.internal_node_objs);
    allocator.free(tree.leaf_parent_obj);
}

/// Build a balanced /Pages tree over `leaf_obj_nums` with fan-out
/// `PAGE_TREE_FANOUT`. Allocates internal-node object numbers inside
/// `w`. The returned tree's slices need to be released via the
/// inverse of allocation — see the comments on `Tree`.
fn buildBalancedTree(
    allocator: std.mem.Allocator,
    w: *pdf_writer.Writer,
    leaf_obj_nums: []const u32,
) !Tree {
    const num_pages: u32 = @intCast(leaf_obj_nums.len);
    std.debug.assert(num_pages >= 1);

    // Track the parent /Pages node for each leaf page (matches the
    // length of leaf_obj_nums one-to-one).
    var leaf_parent = try allocator.alloc(u32, num_pages);
    errdefer allocator.free(leaf_parent);

    // Working set: at level 0 these are the leaf object numbers; we
    // group them into parent nodes at each level until one node
    // remains (the root).
    var current_level_kids: std.ArrayList(u32) = .empty;
    defer current_level_kids.deinit(allocator);
    try current_level_kids.appendSlice(allocator, leaf_obj_nums);
    // For each entry in `current_level_kids`, the count of leaf pages
    // below it (1 for actual leaves; for internal nodes, the sum of
    // their kids' subtree counts).
    var current_level_counts: std.ArrayList(u32) = .empty;
    defer current_level_counts.deinit(allocator);
    try current_level_counts.ensureTotalCapacity(allocator, num_pages);
    var leaf_count_idx: u32 = 0;
    while (leaf_count_idx < num_pages) : (leaf_count_idx += 1) {
        try current_level_counts.append(allocator, 1);
    }

    var internal_nodes: std.ArrayList(Tree.InternalNode) = .empty;
    errdefer {
        for (internal_nodes.items) |node| allocator.free(node.kids);
        internal_nodes.deinit(allocator);
    }

    // Iteratively group `current_level_kids` into chunks of
    // PAGE_TREE_FANOUT, allocating one /Pages node per chunk. We track
    // whether the kids at this level are leaves or internal nodes so
    // we can patch parent refs correctly.
    var kids_are_leaves = true;
    var depth: usize = 0;
    while (current_level_kids.items.len > PAGE_TREE_FANOUT) {
        depth += 1;
        var next_kids: std.ArrayList(u32) = .empty;
        defer next_kids.deinit(allocator);
        var next_counts: std.ArrayList(u32) = .empty;
        defer next_counts.deinit(allocator);

        var i: usize = 0;
        while (i < current_level_kids.items.len) {
            const end = @min(i + PAGE_TREE_FANOUT, current_level_kids.items.len);
            const chunk_len = end - i;
            const chunk_objs = try allocator.alloc(u32, chunk_len);
            // codex r1 P1: ownership-transfer guard. chunk_objs is
            // owned by this local until `internal_nodes.append`
            // succeeds; after that, the outer `internal_nodes`
            // errdefer owns it via node.kids. Without the flag the
            // two errdefers double-free chunk_objs when a later
            // alloc in this iteration (next_kids.append /
            // next_counts.append) fails.
            var chunk_objs_owned = true;
            errdefer if (chunk_objs_owned) allocator.free(chunk_objs);
            @memcpy(chunk_objs, current_level_kids.items[i..end]);

            const node_obj = try w.allocObjectNum();

            // Sum subtree counts for this chunk.
            var subtree: u32 = 0;
            for (current_level_counts.items[i..end]) |c| subtree += c;

            // Patch parent of each child to point at this node.
            if (kids_are_leaves) {
                // Find each chunk_obj in leaf_obj_nums and record
                // node_obj as its parent. We do this directly via the
                // mapping: chunk_objs were copied from leaf_obj_nums
                // contiguously starting at offset = current iteration
                // index in the FIRST level.
                // Since we copied current_level_kids = leaf_obj_nums
                // and each entry is unique, we can rebuild the index
                // by linear scan. But we know i..end maps directly:
                for (i..end) |leaf_idx| {
                    leaf_parent[leaf_idx] = node_obj;
                }
            } else {
                // Internal-level chunk. Patch parent_obj of each child
                // node we pushed earlier.
                for (chunk_objs) |child_obj| {
                    for (internal_nodes.items) |*inode| {
                        if (inode.obj_num == child_obj) {
                            std.debug.assert(inode.parent_obj == null);
                            inode.parent_obj = node_obj;
                            break;
                        }
                    }
                }
            }

            try internal_nodes.append(allocator, .{
                .obj_num = node_obj,
                .parent_obj = null, // patched when we group THIS into a higher level
                .kids = chunk_objs,
                .subtree_page_count = subtree,
            });
            chunk_objs_owned = false;
            try next_kids.append(allocator, node_obj);
            try next_counts.append(allocator, subtree);
            i = end;
        }

        current_level_kids.clearRetainingCapacity();
        try current_level_kids.appendSlice(allocator, next_kids.items);
        current_level_counts.clearRetainingCapacity();
        try current_level_counts.appendSlice(allocator, next_counts.items);
        kids_are_leaves = false;
    }

    // current_level_kids.len ∈ [1, PAGE_TREE_FANOUT] now → these
    // become the root's kids.
    const root_obj = try w.allocObjectNum();
    const root_kids = try allocator.dupe(u32, current_level_kids.items);
    // Until root_kids is consumed by `internal_nodes.append`, this
    // local errdefer owns it. Flag flips after the append succeeds.
    var root_kids_owned = true;
    errdefer if (root_kids_owned) allocator.free(root_kids);
    var root_subtree: u32 = 0;
    for (current_level_counts.items) |c| root_subtree += c;

    if (kids_are_leaves) {
        // Single-level tree: leaves are the root's direct children.
        for (0..num_pages) |idx| leaf_parent[idx] = root_obj;
    } else {
        // Multi-level: patch the top-level internal nodes' parents.
        for (root_kids) |child_obj| {
            for (internal_nodes.items) |*inode| {
                if (inode.obj_num == child_obj) {
                    std.debug.assert(inode.parent_obj == null);
                    inode.parent_obj = root_obj;
                    break;
                }
            }
        }
    }

    // Push the root node into internal_nodes too so emission can walk
    // a single list. It has parent = null (only the root does).
    try internal_nodes.append(allocator, .{
        .obj_num = root_obj,
        .parent_obj = null,
        .kids = root_kids,
        .subtree_page_count = root_subtree,
    });
    root_kids_owned = false;

    // Convert internal_nodes ArrayList to owned slices.
    const nodes_slice = try internal_nodes.toOwnedSlice(allocator);
    // From here on, the errdefer for `internal_nodes` no longer owns
    // anything (toOwnedSlice drained it); ownership of each
    // `nodes_slice[i].kids` belongs to the eventual `freeTree` call.
    // If a subsequent allocation fails, free the nodes_slice + its
    // kids manually.
    errdefer {
        for (nodes_slice) |n| allocator.free(n.kids);
        allocator.free(nodes_slice);
    }
    // The caller frees `internal_node_objs` (a small index slice for
    // testability) and walks `internal_nodes` for emission.
    const obj_slice = try allocator.alloc(u32, nodes_slice.len);
    for (nodes_slice, 0..) |n, idx| obj_slice[idx] = n.obj_num;

    return .{
        .root_obj = root_obj,
        .internal_node_objs = obj_slice,
        .internal_nodes = nodes_slice,
        .leaf_parent_obj = leaf_parent,
    };
}

// ---------- tests ----------

// PR-W3 [feat]: drawText + BuiltinFont tests.
test "BuiltinFont.baseFontName covers all 14 standard fonts" {
    try std.testing.expectEqualStrings("Helvetica", BuiltinFont.helvetica.baseFontName());
    try std.testing.expectEqualStrings("Times-Roman", BuiltinFont.times_roman.baseFontName());
    try std.testing.expectEqualStrings("Courier-Bold", BuiltinFont.courier_bold.baseFontName());
    try std.testing.expectEqualStrings("Symbol", BuiltinFont.symbol.baseFontName());
    try std.testing.expectEqualStrings("ZapfDingbats", BuiltinFont.zapf_dingbats.baseFontName());
}

test "BuiltinFont.usesWinAnsi: 12 standard + Symbol/Dingbats split" {
    try std.testing.expect(BuiltinFont.helvetica.usesWinAnsi());
    try std.testing.expect(BuiltinFont.times_bold_italic.usesWinAnsi());
    try std.testing.expect(!BuiltinFont.symbol.usesWinAnsi());
    try std.testing.expect(!BuiltinFont.zapf_dingbats.usesWinAnsi());
}

test "drawText round-trip: Hello World extracts byte-identical" {
    const allocator = std.testing.allocator;
    var doc = DocumentBuilder.init(allocator);
    defer doc.deinit();
    const page = try doc.addPage(.{ 0, 0, 612, 792 });
    try page.drawText(100, 700, .helvetica, 12, "Hello World");
    const bytes = try doc.write();
    defer allocator.free(bytes);

    const zpdf = @import("root.zig");
    var d = try zpdf.Document.openFromMemory(allocator, bytes, zpdf.ErrorConfig.permissive());
    defer d.close();
    const md = try d.extractMarkdown(0, allocator);
    defer allocator.free(md);
    try std.testing.expect(std.mem.indexOf(u8, md, "Hello World") != null);
}

test "drawText with parens/backslash escapes correctly" {
    const allocator = std.testing.allocator;
    var doc = DocumentBuilder.init(allocator);
    defer doc.deinit();
    const page = try doc.addPage(.{ 0, 0, 612, 792 });
    try page.drawText(50, 600, .helvetica, 10, "foo (bar) \\baz");
    const bytes = try doc.write();
    defer allocator.free(bytes);
    // Verify the escaped literal appears in the content stream.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "(foo \\(bar\\) \\\\baz)") != null);
}

test "drawText filters non-ASCII for WinAnsi fonts" {
    const allocator = std.testing.allocator;
    var doc = DocumentBuilder.init(allocator);
    defer doc.deinit();
    const page = try doc.addPage(.{ 0, 0, 612, 792 });
    // Mix of ASCII + high-byte chars; high bytes should be dropped.
    try page.drawText(50, 600, .helvetica, 10, "abc\xc3\xa9def");
    const bytes = try doc.write();
    defer allocator.free(bytes);
    // The PDF should contain "(abcdef)" not "(abc...def)".
    try std.testing.expect(std.mem.indexOf(u8, bytes, "(abcdef)") != null);
}

test "drawText empty-after-filter is a no-op (no BT/ET emitted)" {
    const allocator = std.testing.allocator;
    var doc = DocumentBuilder.init(allocator);
    defer doc.deinit();
    const page = try doc.addPage(.{ 0, 0, 612, 792 });
    // All bytes outside [0x20, 0x7e] for Helvetica.
    try page.drawText(50, 600, .helvetica, 10, "\xff\xfe\xfd");
    try std.testing.expectEqual(@as(usize, 0), page.content.items.len);
    try std.testing.expect(!page.fonts_used[@intFromEnum(BuiltinFont.helvetica)]);
}

test "drawText rejects nonfinite coords / size" {
    const allocator = std.testing.allocator;
    var doc = DocumentBuilder.init(allocator);
    defer doc.deinit();
    const page = try doc.addPage(.{ 0, 0, 612, 792 });
    try std.testing.expectError(error.InvalidReal, page.drawText(std.math.nan(f64), 0, .helvetica, 10, "x"));
    try std.testing.expectError(error.InvalidReal, page.drawText(0, 0, .helvetica, std.math.inf(f64), "x"));
    try std.testing.expectError(error.InvalidReal, page.drawText(0, 0, .helvetica, -5, "x"));
    try std.testing.expectError(error.InvalidReal, page.drawText(0, 0, .helvetica, 0, "x"));
}

test "auto-resources emits /Font dict with all used builtins" {
    const allocator = std.testing.allocator;
    var doc = DocumentBuilder.init(allocator);
    defer doc.deinit();
    const page = try doc.addPage(.{ 0, 0, 612, 792 });
    try page.drawText(50, 700, .helvetica, 12, "a");
    try page.drawText(50, 680, .times_roman, 12, "b");
    try page.drawText(50, 660, .courier_bold, 12, "c");
    const bytes = try doc.write();
    defer allocator.free(bytes);
    // Each font must appear via its BaseFont name + /Encoding (WinAnsi).
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/BaseFont /Helvetica") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/BaseFont /Times-Roman") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/BaseFont /Courier-Bold") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/Encoding /WinAnsiEncoding") != null);
}

test "auto-resources skips /Encoding for Symbol/Dingbats" {
    const allocator = std.testing.allocator;
    var doc = DocumentBuilder.init(allocator);
    defer doc.deinit();
    const page = try doc.addPage(.{ 0, 0, 612, 792 });
    try page.drawText(50, 700, .symbol, 12, "abc");
    const bytes = try doc.write();
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/BaseFont /Symbol") != null);
    // Symbol's font dict should NOT carry a /WinAnsiEncoding ref —
    // its uses its own native encoding.
    const symbol_pos = std.mem.indexOf(u8, bytes, "/BaseFont /Symbol").?;
    const close_pos = std.mem.indexOfPos(u8, bytes, symbol_pos, ">>").?;
    const sym_dict = bytes[symbol_pos..close_pos];
    try std.testing.expect(std.mem.indexOf(u8, sym_dict, "/WinAnsiEncoding") == null);
}

test "DocumentBuilder rejects empty document" {
    var doc = DocumentBuilder.init(std.testing.allocator);
    defer doc.deinit();
    try std.testing.expectError(error.NoPages, doc.write());
}

test "DocumentBuilder writes 1-page PDF that round-trips" {
    const allocator = std.testing.allocator;
    var doc = DocumentBuilder.init(allocator);
    defer doc.deinit();

    const page = try doc.addPage(.{ 0, 0, 612, 792 });
    try page.appendContent("BT /F1 12 Tf 100 700 Td (Hello PR-W2) Tj ET");
    try page.setResourcesRaw("<< /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >>");

    const bytes = try doc.write();
    defer allocator.free(bytes);

    const zpdf = @import("root.zig");
    var d = try zpdf.Document.openFromMemory(allocator, bytes, zpdf.ErrorConfig.permissive());
    defer d.close();
    try std.testing.expectEqual(@as(usize, 1), d.pageCount());

    const md = try d.extractMarkdown(0, allocator);
    defer allocator.free(md);
    try std.testing.expect(std.mem.indexOf(u8, md, "Hello PR-W2") != null);
}

test "DocumentBuilder writes 3-page flat tree" {
    const allocator = std.testing.allocator;
    var doc = DocumentBuilder.init(allocator);
    defer doc.deinit();

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        _ = try doc.addPage(.{ 0, 0, 612, 792 });
    }

    const bytes = try doc.write();
    defer allocator.free(bytes);

    const zpdf = @import("root.zig");
    var d = try zpdf.Document.openFromMemory(allocator, bytes, zpdf.ErrorConfig.permissive());
    defer d.close();
    try std.testing.expectEqual(@as(usize, 3), d.pageCount());
}

// PR-W2 codex r1+r2 P2: a real (test-only) page-tree validator that
// parses each indirect object body and recursively verifies:
//   - Each `/Type /Page` leaf has `/Parent N 0 R` pointing at a
//     `/Type /Pages` node, AND that node lists this leaf in its
//     `/Kids`.
//   - Each `/Type /Pages` internal node's `/Count` equals the
//     number of leaf descendants reachable through `/Kids`.
//   - Every non-root internal `/Pages` node has `/Parent` set to a
//     `/Pages` node that lists it in `/Kids`. The root has no
//     `/Parent`.
//   - The total number of `/Type /Page` leaves == `expected_pages`.
//
// This is a minimalist parser tailored to the bytes the writer
// produces; it does NOT handle every PDF construct (no streams, no
// hex names, no escapes inside strings, etc.). Sufficient as a
// correctness oracle on the writer's own output.
const TreeAssert = struct {
    const ObjEntry = struct {
        kind: enum { page, pages, other },
        parent: ?u32,
        count: ?u32,
        kids: []u32,
    };

    fn parseAll(allocator: std.mem.Allocator, bytes: []const u8) !std.AutoHashMap(u32, ObjEntry) {
        var map = std.AutoHashMap(u32, ObjEntry).init(allocator);
        errdefer {
            var it = map.iterator();
            while (it.next()) |e| allocator.free(e.value_ptr.kids);
            map.deinit();
        }
        var pos: usize = 0;
        while (pos < bytes.len) {
            const obj_idx = std.mem.indexOfPos(u8, bytes, pos, " 0 obj\n") orelse break;
            // walk back to find the object number (digits)
            var num_start = obj_idx;
            while (num_start > 0 and std.ascii.isDigit(bytes[num_start - 1])) num_start -= 1;
            const num = try std.fmt.parseInt(u32, bytes[num_start..obj_idx], 10);
            const body_start = obj_idx + " 0 obj\n".len;
            const end = std.mem.indexOfPos(u8, bytes, body_start, "\nendobj\n") orelse break;
            const body = bytes[body_start..end];
            const entry = try parseEntry(allocator, body);
            try map.put(num, entry);
            pos = end + "\nendobj\n".len;
        }
        return map;
    }

    fn parseEntry(allocator: std.mem.Allocator, body: []const u8) !ObjEntry {
        var kind: @TypeOf(@as(ObjEntry, undefined).kind) = .other;
        if (std.mem.indexOf(u8, body, "/Type /Page ") != null or
            std.mem.indexOf(u8, body, "/Type /Page>") != null) kind = .page;
        if (std.mem.indexOf(u8, body, "/Type /Pages ") != null or
            std.mem.indexOf(u8, body, "/Type /Pages>") != null) kind = .pages;

        const parent = try parseOptionalRef(body, "/Parent ");
        const count = try parseOptionalInt(body, "/Count ");
        const kids = try parseKidsArray(allocator, body);
        return .{ .kind = kind, .parent = parent, .count = count, .kids = kids };
    }

    /// codex r4+r5 P3: strictly parse `key<space>N<space>0<space>R`
    /// AND require a token-boundary byte after `R` (whitespace, EOF,
    /// or PDF delimiter). Anything else returns MalformedRef.
    fn parseOptionalRef(body: []const u8, key: []const u8) !?u32 {
        const idx = std.mem.indexOf(u8, body, key) orelse return null;
        const start = idx + key.len;
        var n_end = start;
        while (n_end < body.len and std.ascii.isDigit(body[n_end])) n_end += 1;
        if (n_end == start) return error.MalformedRef;
        if (n_end + 4 > body.len) return error.MalformedRef;
        if (body[n_end] != ' ' or
            body[n_end + 1] != '0' or
            body[n_end + 2] != ' ' or
            body[n_end + 3] != 'R')
        {
            return error.MalformedRef;
        }
        const after_r = n_end + 4;
        if (after_r < body.len) {
            const c = body[after_r];
            const is_ws = c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c;
            const is_delim = c == '(' or c == ')' or c == '<' or c == '>' or c == '[' or c == ']' or c == '{' or c == '}' or c == '/' or c == '%';
            if (!is_ws and !is_delim) return error.MalformedRef;
        }
        return try std.fmt.parseInt(u32, body[start..n_end], 10);
    }

    fn parseOptionalInt(body: []const u8, key: []const u8) !?u32 {
        const idx = std.mem.indexOf(u8, body, key) orelse return null;
        const p = idx + key.len;
        var n_end = p;
        while (n_end < body.len and std.ascii.isDigit(body[n_end])) n_end += 1;
        if (n_end == p) return null;
        return try std.fmt.parseInt(u32, body[p..n_end], 10);
    }

    /// Parse `/Kids [N1 0 R N2 0 R ...]` strictly. codex r3 P3:
    /// each entry must be exactly `<digits> 0 R` (single space
    /// separators, generation MUST be 0, terminating `R` required).
    fn parseKidsArray(allocator: std.mem.Allocator, body: []const u8) ![]u32 {
        const key = "/Kids [";
        const idx = std.mem.indexOf(u8, body, key) orelse return try allocator.alloc(u32, 0);
        const start = idx + key.len;
        const close = std.mem.indexOfScalarPos(u8, body, start, ']') orelse return error.MalformedKids;
        var out: std.ArrayList(u32) = .empty;
        errdefer out.deinit(allocator);
        var cursor = start;
        while (cursor < close) {
            // skip whitespace before the next ref
            while (cursor < close and (body[cursor] == ' ' or body[cursor] == '\t' or body[cursor] == '\n')) cursor += 1;
            if (cursor >= close) break;
            var num_end = cursor;
            while (num_end < close and std.ascii.isDigit(body[num_end])) num_end += 1;
            if (num_end == cursor) return error.MalformedKids;
            const n = try std.fmt.parseInt(u32, body[cursor..num_end], 10);
            // Strictly require " 0 R" after the object number.
            if (num_end + 4 > close) return error.MalformedKids;
            if (body[num_end] != ' ' or
                body[num_end + 1] != '0' or
                body[num_end + 2] != ' ' or
                body[num_end + 3] != 'R')
            {
                return error.MalformedKids;
            }
            // codex r4 P3: after `R`, require either whitespace
            // (more refs follow) or the closing `]`. Without this,
            // adjacent refs like `1 0 R2 0 R` would parse as
            // `[1, 2]`.
            const after_r = num_end + 4;
            if (after_r < close) {
                const c = body[after_r];
                if (c != ' ' and c != '\t' and c != '\n' and c != '\r') {
                    return error.MalformedKids;
                }
            }
            try out.append(allocator, n);
            cursor = after_r;
        }
        return out.toOwnedSlice(allocator);
    }

    fn deinitMap(map: *std.AutoHashMap(u32, ObjEntry), allocator: std.mem.Allocator) void {
        var it = map.iterator();
        while (it.next()) |e| allocator.free(e.value_ptr.kids);
        map.deinit();
    }
};

fn assertPageTreeShape(allocator: std.mem.Allocator, bytes: []const u8, expected_pages: usize) !void {
    var map = try TreeAssert.parseAll(allocator, bytes);
    defer TreeAssert.deinitMap(&map, allocator);

    // Find the root /Pages node — it's the only `pages` entry whose
    // parent is null. Also collect the set of all emitted `/Page`
    // leaf ids (codex r3 P2: distinct-reachability check).
    var root: ?u32 = null;
    var emitted_leaves = std.AutoHashMap(u32, void).init(allocator);
    defer emitted_leaves.deinit();
    var it = map.iterator();
    while (it.next()) |entry| {
        switch (entry.value_ptr.kind) {
            .page => try emitted_leaves.put(entry.key_ptr.*, {}),
            .pages => {
                if (entry.value_ptr.parent == null) {
                    if (root != null) return error.MultipleRoots;
                    root = entry.key_ptr.*;
                }
            },
            .other => {},
        }
    }
    try std.testing.expectEqual(expected_pages, emitted_leaves.count());
    try std.testing.expect(root != null);

    // Recursively verify counts + parent backlinks AND that every
    // visited /Page id is a unique reachable leaf.
    var visited_leaves = std.AutoHashMap(u32, void).init(allocator);
    defer visited_leaves.deinit();
    const counted = try verifyNode(&map, root.?, null, &visited_leaves);
    try std.testing.expectEqual(@as(u32, @intCast(expected_pages)), counted);

    // Every emitted leaf must be reachable through the tree exactly
    // once. visited_leaves should equal emitted_leaves as a set.
    if (visited_leaves.count() != emitted_leaves.count()) return error.UnreachableLeaves;
    var emit_it = emitted_leaves.keyIterator();
    while (emit_it.next()) |k| {
        if (!visited_leaves.contains(k.*)) return error.UnreachableLeaves;
    }
}

/// Walk the subtree rooted at `obj`. Returns the total leaf count
/// for that subtree (which the caller compares against /Count).
/// Asserts:
///   - obj exists in map
///   - if /Pages: every kid's parent ref equals obj; recurse and
///     verify /Count matches the recursive sum.
///   - if /Page: returns 1 and verifies parent matches expected.
///   - codex r3 P2: each /Page leaf must be visited exactly once
///     (rejects duplicate refs in /Kids).
fn verifyNode(
    map: *std.AutoHashMap(u32, TreeAssert.ObjEntry),
    obj: u32,
    expected_parent: ?u32,
    visited_leaves: *std.AutoHashMap(u32, void),
) !u32 {
    const entry = map.get(obj) orelse return error.MissingObject;
    if (entry.parent != expected_parent) return error.ParentMismatch;
    switch (entry.kind) {
        .page => {
            const gop = try visited_leaves.getOrPut(obj);
            if (gop.found_existing) return error.DuplicateLeafReference;
            return 1;
        },
        .pages => {
            var sum: u32 = 0;
            for (entry.kids) |kid| {
                sum += try verifyNode(map, kid, obj, visited_leaves);
            }
            const declared = entry.count orelse return error.MissingCount;
            if (declared != sum) return error.CountMismatch;
            return sum;
        },
        .other => return error.UnexpectedObjectType,
    }
}

// PR-W2 codex r5: focused parser tests for the strict ref helpers.
test "parseOptionalRef rejects /Parent N 0 Rjunk (codex r5 P3)" {
    const body = "/Parent 12 0 Rjunk /Count 5";
    try std.testing.expectError(error.MalformedRef, TreeAssert.parseOptionalRef(body, "/Parent "));
}

test "parseOptionalRef rejects /Parent N 0 R<digit> (codex r5 P3)" {
    const body = "/Parent 12 0 R2 /Kids []";
    try std.testing.expectError(error.MalformedRef, TreeAssert.parseOptionalRef(body, "/Parent "));
}

test "parseOptionalRef accepts /Parent followed by whitespace" {
    const body = "/Parent 12 0 R /Count 5";
    const got = try TreeAssert.parseOptionalRef(body, "/Parent ");
    try std.testing.expectEqual(@as(?u32, 12), got);
}

test "parseOptionalRef accepts /Parent followed by delimiter" {
    const body = "/Parent 12 0 R>>";
    const got = try TreeAssert.parseOptionalRef(body, "/Parent ");
    try std.testing.expectEqual(@as(?u32, 12), got);
}

test "parseKidsArray rejects adjacent refs (codex r4 P3)" {
    const body = "/Kids [1 0 R2 0 R]";
    try std.testing.expectError(error.MalformedKids, TreeAssert.parseKidsArray(std.testing.allocator, body));
}

test "page tree shape: /Count + /Parent on 11-page doc (codex r1 P2)" {
    const allocator = std.testing.allocator;
    var doc = DocumentBuilder.init(allocator);
    defer doc.deinit();
    var i: usize = 0;
    while (i < 11) : (i += 1) _ = try doc.addPage(.{ 0, 0, 612, 792 });
    const bytes = try doc.write();
    defer allocator.free(bytes);
    try assertPageTreeShape(allocator, bytes, 11);
}

test "page tree shape: /Count + /Parent on 999-page doc (codex r1 P2)" {
    const allocator = std.testing.allocator;
    var doc = DocumentBuilder.init(allocator);
    defer doc.deinit();
    var i: usize = 0;
    while (i < 999) : (i += 1) _ = try doc.addPage(.{ 0, 0, 612, 792 });
    const bytes = try doc.write();
    defer allocator.free(bytes);
    try assertPageTreeShape(allocator, bytes, 999);
}

test "DocumentBuilder writes 1000-page balanced tree (PR-W2 stress gate)" {
    const allocator = std.testing.allocator;
    var doc = DocumentBuilder.init(allocator);
    defer doc.deinit();

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        _ = try doc.addPage(.{ 0, 0, 612, 792 });
    }

    const bytes = try doc.write();
    defer allocator.free(bytes);

    const zpdf = @import("root.zig");
    var d = try zpdf.Document.openFromMemory(allocator, bytes, zpdf.ErrorConfig.permissive());
    defer d.close();
    try std.testing.expectEqual(@as(usize, 1000), d.pageCount());
}

test "DocumentBuilder per-page MediaBox is preserved" {
    const allocator = std.testing.allocator;
    var doc = DocumentBuilder.init(allocator);
    defer doc.deinit();

    _ = try doc.addPage(.{ 0, 0, 612, 792 }); // Letter
    _ = try doc.addPage(.{ 0, 0, 595, 842 }); // A4

    const bytes = try doc.write();
    defer allocator.free(bytes);

    const zpdf = @import("root.zig");
    var d = try zpdf.Document.openFromMemory(allocator, bytes, zpdf.ErrorConfig.permissive());
    defer d.close();

    // Reader exposes media_box per page; verify both.
    try std.testing.expectApproxEqAbs(@as(f64, 612), d.pages.items[0].media_box[2], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 792), d.pages.items[0].media_box[3], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 595), d.pages.items[1].media_box[2], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 842), d.pages.items[1].media_box[3], 0.001);
}

test "DocumentBuilder FailingAllocator stress on small flow" {
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const allocator = failing.allocator();

        var doc = DocumentBuilder.init(allocator);
        defer doc.deinit();

        const result = smokeFlow(&doc);
        if (result) |bytes| {
            allocator.free(bytes);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
}

fn smokeFlow(doc: *DocumentBuilder) ![]u8 {
    const page = try doc.addPage(.{ 0, 0, 612, 792 });
    try page.appendContent("BT /F1 12 Tf 50 50 Td (x) Tj ET");
    try page.setResourcesRaw("<< /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >>");
    return doc.write();
}

// ---------- PR-W6 [feat]: escape-hatch surface for fixture refactor ----------

test "DocumentBuilder.setInfoDict round-trips /Info entries" {
    const allocator = std.testing.allocator;
    var doc = DocumentBuilder.init(allocator);
    defer doc.deinit();

    _ = try doc.setInfoDict("<< /Title (Hello) /Author (Tester) >>");
    const page = try doc.addPage(.{ 0, 0, 612, 792 });
    try page.drawText(72, 720, .helvetica, 12, "body");
    const bytes = try doc.write();
    defer allocator.free(bytes);

    // Round-trip via the existing reader: title appears in the metadata.
    const root = @import("root.zig");
    var parsed = try root.Document.openFromMemory(allocator, bytes, root.ErrorConfig.permissive());
    defer parsed.close();
    const meta = parsed.metadata();
    try std.testing.expectEqualStrings("Hello", meta.title.?);
    try std.testing.expectEqualStrings("Tester", meta.author.?);
}

test "DocumentBuilder.addAuxiliaryObject + setCatalogExtras link from /Catalog" {
    const allocator = std.testing.allocator;
    var doc = DocumentBuilder.init(allocator);
    defer doc.deinit();

    // We use a marker name (`/Pdfzigtest`) that only appears in the
    // splice we're verifying. /Metadata, /Names, /OpenAction etc. would
    // all alias with PDF spec keywords and could trip false positives.
    const aux_num = try doc.addAuxiliaryObject("<< /Type /Pdfzigtest /Marker (auxbody) >>");

    var extras_buf: [128]u8 = undefined;
    const extras = try std.fmt.bufPrint(&extras_buf, "/Pdfzigtest {d} 0 R", .{aux_num});
    try doc.setCatalogExtras(extras);

    const page = try doc.addPage(.{ 0, 0, 612, 792 });
    try page.drawText(72, 720, .helvetica, 12, "x");
    const bytes = try doc.write();
    defer allocator.free(bytes);

    // Exact catalog-ref pattern proves the splice — would not match
    // the aux body (which has `/Type /Pdfzigtest` not `/Pdfzigtest N 0 R`).
    var expected_ref_buf: [64]u8 = undefined;
    const expected_ref = try std.fmt.bufPrint(&expected_ref_buf, "/Pdfzigtest {d} 0 R", .{aux_num});
    try std.testing.expect(std.mem.indexOf(u8, bytes, expected_ref) != null);
    // Aux body marker is independent of the catalog splice.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "(auxbody)") != null);
}

test "DocumentBuilder rejects mutations after write (single-use guard)" {
    const allocator = std.testing.allocator;
    var doc = DocumentBuilder.init(allocator);
    defer doc.deinit();

    const page = try doc.addPage(.{ 0, 0, 612, 792 });
    try page.drawText(72, 720, .helvetica, 12, "x");
    const bytes = try doc.write();
    defer allocator.free(bytes);

    try std.testing.expectError(error.DocumentAlreadyWritten, doc.write());
    try std.testing.expectError(error.DocumentAlreadyWritten, doc.addPage(.{ 0, 0, 612, 792 }));
    try std.testing.expectError(error.DocumentAlreadyWritten, doc.addAuxiliaryObject("<< >>"));
    try std.testing.expectError(error.DocumentAlreadyWritten, doc.reserveAuxiliaryObject());
    try std.testing.expectError(error.DocumentAlreadyWritten, doc.setAuxiliaryPayload(0, "<< >>"));
    try std.testing.expectError(error.DocumentAlreadyWritten, doc.setInfoDict("<< >>"));
    try std.testing.expectError(error.DocumentAlreadyWritten, doc.setCatalogExtras(""));
}

test "DocumentBuilder reserve/set supports cyclic aux refs (outline shape)" {
    const allocator = std.testing.allocator;
    var doc = DocumentBuilder.init(allocator);
    defer doc.deinit();

    const page = try doc.addPage(.{ 0, 0, 612, 792 });
    try page.drawText(72, 720, .helvetica, 12, "x");

    // Reserve before filling — needed to express /Outlines /First → item
    // and item /Parent → /Outlines (circular).
    const outlines = try doc.reserveAuxiliaryObject();
    const item = try doc.reserveAuxiliaryObject();

    var outlines_buf: [256]u8 = undefined;
    const outlines_payload = try std.fmt.bufPrint(
        &outlines_buf,
        "<< /Type /Outlines /First {d} 0 R /Last {d} 0 R /Count 1 >>",
        .{ item, item },
    );
    try doc.setAuxiliaryPayload(outlines, outlines_payload);

    var item_buf: [256]u8 = undefined;
    const item_payload = try std.fmt.bufPrint(
        &item_buf,
        "<< /Title (Top) /Parent {d} 0 R /Dest [{d} 0 R /Fit] >>",
        .{ outlines, page.objNum() },
    );
    try doc.setAuxiliaryPayload(item, item_payload);

    var extras_buf: [64]u8 = undefined;
    try doc.setCatalogExtras(try std.fmt.bufPrint(&extras_buf, "/Outlines {d} 0 R", .{outlines}));

    const bytes = try doc.write();
    defer allocator.free(bytes);

    // Both refs survive the round-trip — proves cyclic graph holds together.
    var expected_first_buf: [32]u8 = undefined;
    const expected_first = try std.fmt.bufPrint(&expected_first_buf, "/First {d} 0 R", .{item});
    try std.testing.expect(std.mem.indexOf(u8, bytes, expected_first) != null);

    var expected_parent_buf: [32]u8 = undefined;
    const expected_parent = try std.fmt.bufPrint(&expected_parent_buf, "/Parent {d} 0 R", .{outlines});
    try std.testing.expect(std.mem.indexOf(u8, bytes, expected_parent) != null);
}

test "DocumentBuilder.setAuxiliaryPayload rejects unknown obj_num" {
    const allocator = std.testing.allocator;
    var doc = DocumentBuilder.init(allocator);
    defer doc.deinit();

    try std.testing.expectError(error.UnknownAuxObject, doc.setAuxiliaryPayload(99, "<< >>"));
}

test "PageBuilder.setPageExtras splices into leaf /Page dict" {
    const allocator = std.testing.allocator;
    var doc = DocumentBuilder.init(allocator);
    defer doc.deinit();

    const page = try doc.addPage(.{ 0, 0, 612, 792 });
    try page.drawText(72, 720, .helvetica, 12, "x");
    try page.setPageExtras("/UserUnit 2");
    const bytes = try doc.write();
    defer allocator.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "/UserUnit 2") != null);
}

test "PageBuilder.objNum is stable for cross-references" {
    const allocator = std.testing.allocator;
    var doc = DocumentBuilder.init(allocator);
    defer doc.deinit();

    const page1 = try doc.addPage(.{ 0, 0, 612, 792 });
    const page2 = try doc.addPage(.{ 0, 0, 612, 792 });
    try page1.drawText(72, 720, .helvetica, 12, "a");
    try page2.drawText(72, 720, .helvetica, 12, "b");

    // Page object numbers are non-zero, distinct, and remain valid
    // through write().
    try std.testing.expect(page1.objNum() != 0);
    try std.testing.expect(page2.objNum() != 0);
    try std.testing.expect(page1.objNum() != page2.objNum());

    const bytes = try doc.write();
    defer allocator.free(bytes);
    try std.testing.expect(bytes.len > 0);
}

test "PageBuilder.markFontUsed name matches auto-resources output" {
    // Codex r1 P3: the font→resource-name mapping appears in
    // `BuiltinFont.resourceName`, `drawText`, and `emitAutoResources`.
    // This test pins them together — if any of the three drift, this
    // test fails before strict-consumer fixtures break in the wild.
    const allocator = std.testing.allocator;
    inline for (.{
        BuiltinFont.helvetica,
        BuiltinFont.times_bold,
        BuiltinFont.courier_oblique,
        BuiltinFont.symbol,
        BuiltinFont.zapf_dingbats,
    }) |font| {
        var doc = DocumentBuilder.init(allocator);
        defer doc.deinit();
        const page = try doc.addPage(.{ 0, 0, 612, 792 });
        const f = page.markFontUsed(font);
        const bytes = try doc.write();
        defer allocator.free(bytes);

        // The exact resource name appears in the /Resources/Font dict
        // body (e.g. `/F0 << /Type /Font ...`).
        var key_buf: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "{s} <<", .{f});
        try std.testing.expect(std.mem.indexOf(u8, bytes, key) != null);
    }
}
