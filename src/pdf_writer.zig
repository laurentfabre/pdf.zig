//! PR-W1 [feat]: low-level PDF object emitter for greenfield authoring.
//!
//! This module is the foundation under `pdf_document.zig` (PR-W2). It does
//! NOT compose pages, fonts, or content streams — it just emits the PDF
//! object syntax. Callers allocate object numbers, write objects in any
//! order, then finalize with `writeXref` + `writeTrailer`.
//!
//! ## Lifecycle
//!
//! ```zig
//! var w = pdf_writer.Writer.init(allocator);
//! defer w.deinit();
//! try w.writeHeader();               // emits %PDF-1.4 + binary marker
//!
//! const root_num = try w.allocObjectNum();
//! try w.beginObject(root_num, 0);
//! try w.writeRaw("<< /Type /Catalog >>");
//! try w.endObject();
//!
//! const xref_offset = try w.writeXref();
//! try w.writeTrailer(xref_offset, root_num, null);
//! const bytes = try w.finalize();    // caller owns; allocator.free when done
//! ```
//!
//! Object numbering is caller-responsibility: `allocObjectNum` returns the
//! next free number monotonically. `beginObject(N, G)` records the byte
//! offset for xref later. The caller MUST emit each allocated number
//! exactly once, otherwise the xref will reference a non-object.
//!
//! ## Encoding rules
//!
//! - Names use `#XX` escapes for non-ASCII / special chars (ISO 32000-1 §7.3.5).
//! - String literals escape `(`, `)`, `\` and emit non-printable bytes as
//!   `\nnn` octal (§7.3.4.2). UTF-16BE is the caller's responsibility.
//! - Hex strings emit lowercase `<deadbeef>` (§7.3.4.3).
//! - Reals use the spec's restricted form (no exponent, no NaN/inf — those
//!   are rejected with `error.InvalidReal`).
//!
//! ## What this module does NOT do
//!
//! - Object composition (dicts, arrays, stream wrappers) — call `writeRaw`.
//! - Content stream operators — that's `pdf_document.zig` (PR-W3).
//! - FlateDecode compression — that's PR-W4 via `writeStreamCompressed`.
//! - Linearization, encryption, signatures — Tier 2/3.

const std = @import("std");

pub const Writer = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8),
    /// One entry per allocated object number. Index N is object N. Index 0
    /// is the always-free entry the xref table requires (per §7.5.4).
    objects: std.ArrayList(ObjectInfo),
    /// True between beginObject / endObject. Used to assert no nested
    /// indirect-object emission.
    in_object: bool,

    pub const ObjectInfo = struct {
        /// Byte offset of the leading `N G obj` token. 0 = unallocated/free.
        offset: u64,
        generation: u16,
        in_use: bool,
        /// PR-W1 codex r1 P2: distinguish "allocated but not yet
        /// emitted" from "free" (= xref `f` entry). Object 0 is the
        /// only legal `allocated=false, in_use=false` slot.
        allocated: bool,
    };

    pub const Error = error{
        OutOfMemory,
        ObjectNotEmitted,
        ObjectAlreadyEmitted,
        InvalidReal,
        UnbalancedObject,
        /// PR-W1 codex r1 P2: writeXref refuses to emit a dangling
        /// xref. Caller forgot to `beginObject` for an allocated num.
        DanglingObjectAllocation,
        /// PR-W1 codex r1 P3: tier-1 writer is generation-0 only.
        /// Multi-generation support is a Tier-2 follow-up.
        UnsupportedGeneration,
    };

    pub fn init(allocator: std.mem.Allocator) Writer {
        return .{
            .allocator = allocator,
            .buf = .empty,
            .objects = .empty,
            .in_object = false,
        };
    }

    pub fn deinit(self: *Writer) void {
        self.buf.deinit(self.allocator);
        self.objects.deinit(self.allocator);
    }

    /// Reserve a new object number. The slot starts unemitted; the caller
    /// MUST follow up with `beginObject(num, 0)` exactly once before
    /// `writeXref`.
    pub fn allocObjectNum(self: *Writer) Error!u32 {
        // Object 0 is special: per §7.5.4 it's the free-list head and must
        // never be a real object. Bootstrap it on first allocation.
        if (self.objects.items.len == 0) {
            try self.objects.append(self.allocator, .{
                .offset = 0,
                .generation = 65535,
                .in_use = false,
                .allocated = false,
            });
        }
        const num: u32 = @intCast(self.objects.items.len);
        try self.objects.append(self.allocator, .{
            .offset = 0, // patched in beginObject
            .generation = 0,
            .in_use = false, // flipped to true in beginObject
            .allocated = true, // codex r1 P2: tracks "must be emitted"
        });
        return num;
    }

    /// Emit `%PDF-1.4` + binary marker. Must be called exactly once at
    /// the start; the xref offsets won't be correct otherwise.
    pub fn writeHeader(self: *Writer) Error!void {
        try self.buf.appendSlice(self.allocator, "%PDF-1.4\n");
        // Binary marker: 4 high-byte chars per §7.5.2 so file utilities
        // detect this as binary, not text.
        try self.buf.appendSlice(self.allocator, "%\xE2\xE3\xCF\xD3\n");
    }

    pub fn beginObject(self: *Writer, num: u32, generation: u16) Error!void {
        // codex r1 P3: enforce generation = 0 for the v1 writer. Multi-
        // generation requires versioning support that lives in Tier 2.
        if (generation != 0) return error.UnsupportedGeneration;
        if (self.in_object) return error.UnbalancedObject;
        if (num == 0 or num >= self.objects.items.len) return error.ObjectNotEmitted;
        if (self.objects.items[num].in_use) return error.ObjectAlreadyEmitted;
        const offset = self.buf.items.len;
        self.objects.items[num] = .{
            .offset = offset,
            .generation = generation,
            .in_use = true,
            .allocated = true,
        };
        try self.buf.writer(self.allocator).print("{d} {d} obj\n", .{ num, generation });
        self.in_object = true;
    }

    pub fn endObject(self: *Writer) Error!void {
        if (!self.in_object) return error.UnbalancedObject;
        try self.buf.appendSlice(self.allocator, "\nendobj\n");
        self.in_object = false;
    }

    // --- Low-level token emitters (these don't add separator whitespace;
    //     callers are expected to compose dicts/arrays via writeRaw) ---

    pub fn writeRaw(self: *Writer, bytes: []const u8) Error!void {
        try self.buf.appendSlice(self.allocator, bytes);
    }

    /// Emit `/name`, escaping special chars per §7.3.5 (`#XX` hex escape
    /// for any byte outside `[0x21, 0x7e]` or in the delimiter set).
    pub fn writeName(self: *Writer, name: []const u8) Error!void {
        try self.buf.append(self.allocator, '/');
        for (name) |b| {
            if (b < 0x21 or b > 0x7e or isDelimiter(b) or b == '#') {
                try self.buf.writer(self.allocator).print("#{x:0>2}", .{b});
            } else {
                try self.buf.append(self.allocator, b);
            }
        }
    }

    /// Emit `(literal-string)`, escaping `(`, `)`, `\`, and non-printable
    /// bytes via `\nnn` octal (§7.3.4.2).
    pub fn writeStringLiteral(self: *Writer, s: []const u8) Error!void {
        try self.buf.append(self.allocator, '(');
        for (s) |b| {
            switch (b) {
                '(' => try self.buf.appendSlice(self.allocator, "\\("),
                ')' => try self.buf.appendSlice(self.allocator, "\\)"),
                '\\' => try self.buf.appendSlice(self.allocator, "\\\\"),
                '\n' => try self.buf.appendSlice(self.allocator, "\\n"),
                '\r' => try self.buf.appendSlice(self.allocator, "\\r"),
                '\t' => try self.buf.appendSlice(self.allocator, "\\t"),
                0x08 => try self.buf.appendSlice(self.allocator, "\\b"),
                0x0c => try self.buf.appendSlice(self.allocator, "\\f"),
                else => {
                    if (b < 0x20 or b == 0x7f) {
                        try self.buf.writer(self.allocator).print("\\{o:0>3}", .{b});
                    } else {
                        try self.buf.append(self.allocator, b);
                    }
                },
            }
        }
        try self.buf.append(self.allocator, ')');
    }

    /// Emit `<deadbeef>` lowercase hex string (§7.3.4.3).
    pub fn writeStringHex(self: *Writer, bytes: []const u8) Error!void {
        try self.buf.append(self.allocator, '<');
        for (bytes) |b| {
            try self.buf.writer(self.allocator).print("{x:0>2}", .{b});
        }
        try self.buf.append(self.allocator, '>');
    }

    pub fn writeInt(self: *Writer, n: i64) Error!void {
        try self.buf.writer(self.allocator).print("{d}", .{n});
    }

    /// Emit a real number per §7.3.3 (no exponent form). Rejects NaN/inf
    /// via `error.InvalidReal` — those are not valid PDF syntax.
    pub fn writeReal(self: *Writer, n: f64) Error!void {
        if (!std.math.isFinite(n)) return error.InvalidReal;
        // Use a fixed precision that's plenty for graphic coordinates.
        // Strip trailing zeros for compactness. codex r1 P3: very large
        // f64 values can exceed the 32-byte buffer; surface that as
        // InvalidReal rather than panic via `catch unreachable`.
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d:.6}", .{n}) catch return error.InvalidReal;
        const trimmed = stripTrailingZeros(s);
        try self.buf.appendSlice(self.allocator, trimmed);
    }

    /// Emit `N G R` (indirect reference, §7.3.10).
    pub fn writeRef(self: *Writer, num: u32, generation: u16) Error!void {
        try self.buf.writer(self.allocator).print("{d} {d} R", .{ num, generation });
    }

    /// Emit a stream object: `<< /Length N >>\nstream\n<body>\nendstream\n`.
    /// Must be called BETWEEN beginObject and endObject. `extra_dict` is
    /// raw bytes inserted into the stream dict (e.g. " /Filter /FlateDecode").
    pub fn writeStream(
        self: *Writer,
        body: []const u8,
        extra_dict: []const u8,
    ) Error!void {
        if (!self.in_object) return error.UnbalancedObject;
        try self.buf.writer(self.allocator).print(
            "<< /Length {d}{s} >>\nstream\n",
            .{ body.len, extra_dict },
        );
        try self.buf.appendSlice(self.allocator, body);
        try self.buf.appendSlice(self.allocator, "\nendstream");
    }

    /// Emit the xref table. Returns the byte offset of the `xref` keyword
    /// (caller passes this to `writeTrailer`'s `startxref`).
    pub fn writeXref(self: *Writer) Error!u64 {
        if (self.in_object) return error.UnbalancedObject;
        // Bootstrap object 0 if no allocations happened (degenerate).
        if (self.objects.items.len == 0) {
            try self.objects.append(self.allocator, .{
                .offset = 0,
                .generation = 65535,
                .in_use = false,
                .allocated = false,
            });
        }
        // codex r1 P2: refuse to emit a dangling xref. Every allocated
        // slot must have been emitted via beginObject + endObject.
        for (self.objects.items, 0..) |obj, idx| {
            if (idx == 0) continue;
            if (obj.allocated and !obj.in_use) return error.DanglingObjectAllocation;
        }
        const xref_offset = self.buf.items.len;
        try self.buf.writer(self.allocator).print(
            "xref\n0 {d}\n",
            .{self.objects.items.len},
        );
        for (self.objects.items) |obj| {
            // §7.5.4: each entry is exactly 20 bytes including the trailing
            // 2-byte newline. `f` = free, `n` = in-use.
            const marker: u8 = if (obj.in_use) 'n' else 'f';
            try self.buf.writer(self.allocator).print(
                "{d:0>10} {d:0>5} {c} \n",
                .{ obj.offset, obj.generation, marker },
            );
        }
        return xref_offset;
    }

    /// Emit `trailer << /Size N /Root R >> startxref OFF %%EOF`.
    pub fn writeTrailer(
        self: *Writer,
        xref_offset: u64,
        root_obj: u32,
        info_obj: ?u32,
    ) Error!void {
        if (self.in_object) return error.UnbalancedObject;
        // codex r1 P2: validate refs point at emitted objects; tier-1
        // writer is generation-0 only so we hardcode `0 R`.
        try self.assertEmittedRef(root_obj);
        if (info_obj) |inum| try self.assertEmittedRef(inum);
        try self.buf.writer(self.allocator).print(
            "trailer\n<< /Size {d} /Root {d} 0 R",
            .{ self.objects.items.len, root_obj },
        );
        if (info_obj) |inum| {
            try self.buf.writer(self.allocator).print(" /Info {d} 0 R", .{inum});
        }
        try self.buf.writer(self.allocator).print(
            " >>\nstartxref\n{d}\n%%EOF\n",
            .{xref_offset},
        );
    }

    fn assertEmittedRef(self: *const Writer, num: u32) Error!void {
        if (num == 0 or num >= self.objects.items.len) return error.ObjectNotEmitted;
        if (!self.objects.items[num].in_use) return error.ObjectNotEmitted;
    }

    /// Transfer ownership of the assembled bytes to the caller.
    /// The `Writer` is reset to its empty state; further calls are valid
    /// but uncommon. Caller frees with `allocator.free(returned_bytes)`.
    pub fn finalize(self: *Writer) Error![]u8 {
        const out = try self.buf.toOwnedSlice(self.allocator);
        // Reset metadata so re-use is well-defined; the caller can keep
        // calling allocObjectNum etc. on the same Writer if they want a
        // second document.
        self.objects.clearRetainingCapacity();
        self.in_object = false;
        return out;
    }
};

fn isDelimiter(b: u8) bool {
    return switch (b) {
        '(', ')', '<', '>', '[', ']', '{', '}', '/', '%' => true,
        else => false,
    };
}

fn stripTrailingZeros(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '.') == null) return s;
    var end = s.len;
    while (end > 0 and s[end - 1] == '0') end -= 1;
    if (end > 0 and s[end - 1] == '.') end -= 1;
    return s[0..end];
}

// ---------- tests ----------

test "writeHeader emits %PDF-1.4 with binary marker" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    try w.writeHeader();
    const got = w.buf.items;
    try std.testing.expect(std.mem.startsWith(u8, got, "%PDF-1.4\n"));
    try std.testing.expect(std.mem.indexOfScalar(u8, got, 0xE2) != null);
}

test "writeName basic name" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    try w.writeName("Type");
    try std.testing.expectEqualStrings("/Type", w.buf.items);
}

test "writeName escapes special chars" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    try w.writeName("With Space");
    // ' ' (0x20) is below 0x21 → escape #20.
    try std.testing.expectEqualStrings("/With#20Space", w.buf.items);
}

test "writeName escapes # itself" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    try w.writeName("a#b");
    try std.testing.expectEqualStrings("/a#23b", w.buf.items);
}

test "writeStringLiteral escapes parens, backslash, control" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    try w.writeStringLiteral("a(b)\\c\nd\te");
    try std.testing.expectEqualStrings("(a\\(b\\)\\\\c\\nd\\te)", w.buf.items);
}

test "writeStringLiteral emits high-byte non-printables as octal" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    const s = [_]u8{0x01};
    try w.writeStringLiteral(&s);
    try std.testing.expectEqualStrings("(\\001)", w.buf.items);
}

test "writeStringHex emits lowercase pairs" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    try w.writeStringHex(&[_]u8{ 0xde, 0xad, 0xbe, 0xef });
    try std.testing.expectEqualStrings("<deadbeef>", w.buf.items);
}

test "writeReal strips trailing zeros" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    try w.writeReal(1.5);
    try std.testing.expectEqualStrings("1.5", w.buf.items);
}

test "writeReal of integer drops decimal point" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    try w.writeReal(42.0);
    try std.testing.expectEqualStrings("42", w.buf.items);
}

test "writeReal rejects NaN and inf" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    try std.testing.expectError(error.InvalidReal, w.writeReal(std.math.nan(f64)));
    try std.testing.expectError(error.InvalidReal, w.writeReal(std.math.inf(f64)));
}

test "writeRef emits N G R" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    try w.writeRef(7, 3);
    try std.testing.expectEqualStrings("7 3 R", w.buf.items);
}

test "allocObjectNum starts at 1 and is monotonic" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    try std.testing.expectEqual(@as(u32, 1), try w.allocObjectNum());
    try std.testing.expectEqual(@as(u32, 2), try w.allocObjectNum());
    try std.testing.expectEqual(@as(u32, 3), try w.allocObjectNum());
}

test "beginObject before allocObjectNum errors" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    try std.testing.expectError(error.ObjectNotEmitted, w.beginObject(99, 0));
}

test "endObject without beginObject errors" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    try std.testing.expectError(error.UnbalancedObject, w.endObject());
}

// PR-W1 codex r1 P2/P3 regression tests.
test "writeXref rejects dangling allocation (codex r1 P2)" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    try w.writeHeader();
    _ = try w.allocObjectNum(); // allocate but never beginObject
    try std.testing.expectError(error.DanglingObjectAllocation, w.writeXref());
}

test "writeTrailer rejects ref to unallocated object (codex r1 P2)" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    try w.writeHeader();
    const a = try w.allocObjectNum();
    try w.beginObject(a, 0);
    try w.writeRaw("<< /Type /Catalog >>");
    try w.endObject();
    _ = try w.writeXref();
    try std.testing.expectError(error.ObjectNotEmitted, w.writeTrailer(0, 99, null));
}

test "writeTrailer rejects ref to allocated-but-not-emitted (codex r1 P2)" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    try w.writeHeader();
    const a = try w.allocObjectNum();
    const b = try w.allocObjectNum(); // allocate, never emit
    try w.beginObject(a, 0);
    try w.writeRaw("<< >>");
    try w.endObject();
    // writeXref will error first; just verify the trailer assertion in
    // isolation — directly call writeTrailer with a dangling ref `b`.
    // (writeXref catches the error before we get here in the normal
    // flow, but the trailer guard is defense-in-depth.)
    try std.testing.expectError(error.ObjectNotEmitted, w.writeTrailer(0, b, null));
}

test "beginObject rejects nonzero generation (codex r1 P3)" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    const a = try w.allocObjectNum();
    try std.testing.expectError(error.UnsupportedGeneration, w.beginObject(a, 1));
}

test "writeReal rejects values too large for buffer (codex r1 P3)" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    // 1e300 stringifies to >40 digits with .6 precision; even with the
    // bumped 64-byte buffer, 1e306+ overflows. Verify InvalidReal is
    // returned instead of panic-via-unreachable.
    try std.testing.expectError(error.InvalidReal, w.writeReal(1e308));
}

test "beginObject twice on same number errors" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    const n = try w.allocObjectNum();
    try w.beginObject(n, 0);
    try w.endObject();
    try std.testing.expectError(error.ObjectAlreadyEmitted, w.beginObject(n, 0));
}

test "round-trip: 1-page minimal PDF parses cleanly" {
    const allocator = std.testing.allocator;
    var w = Writer.init(allocator);
    defer w.deinit();

    try w.writeHeader();

    const catalog = try w.allocObjectNum();
    const pages = try w.allocObjectNum();
    const page = try w.allocObjectNum();
    const contents = try w.allocObjectNum();
    const font = try w.allocObjectNum();

    // Catalog.
    try w.beginObject(catalog, 0);
    try w.writeRaw("<< /Type /Catalog /Pages ");
    try w.writeRef(pages, 0);
    try w.writeRaw(" >>");
    try w.endObject();

    // Pages root.
    try w.beginObject(pages, 0);
    try w.writeRaw("<< /Type /Pages /Kids [");
    try w.writeRef(page, 0);
    try w.writeRaw("] /Count 1 >>");
    try w.endObject();

    // Single page.
    try w.beginObject(page, 0);
    try w.writeRaw("<< /Type /Page /Parent ");
    try w.writeRef(pages, 0);
    try w.writeRaw(" /MediaBox [0 0 612 792] /Resources << /Font << /F1 ");
    try w.writeRef(font, 0);
    try w.writeRaw(" >> >> /Contents ");
    try w.writeRef(contents, 0);
    try w.writeRaw(" >>");
    try w.endObject();

    // Content stream.
    try w.beginObject(contents, 0);
    const body = "BT /F1 12 Tf 100 700 Td (Hello pdf.zig) Tj ET";
    try w.writeStream(body, "");
    try w.endObject();

    // Font.
    try w.beginObject(font, 0);
    try w.writeRaw("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>");
    try w.endObject();

    const xref_off = try w.writeXref();
    try w.writeTrailer(xref_off, catalog, null);

    const bytes = try w.finalize();
    defer allocator.free(bytes);

    // Round-trip via the existing reader.
    const zpdf = @import("root.zig");
    var doc = try zpdf.Document.openFromMemory(allocator, bytes, zpdf.ErrorConfig.permissive());
    defer doc.close();
    try std.testing.expectEqual(@as(usize, 1), doc.pageCount());

    // Extract text and expect our literal back.
    const md = try doc.extractMarkdown(0, allocator);
    defer allocator.free(md);
    try std.testing.expect(std.mem.indexOf(u8, md, "Hello pdf.zig") != null);
}

test "FailingAllocator stress on round-trip flow (no leaks)" {
    const strokes_iter: usize = 0;
    _ = strokes_iter;
    var fail_index: usize = 0;
    while (fail_index < 96) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const allocator = failing.allocator();
        var w = Writer.init(allocator);
        defer w.deinit();

        const result = roundTripSmoke(&w);
        if (result) {} else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
}

fn roundTripSmoke(w: *Writer) Writer.Error!void {
    try w.writeHeader();
    const a = try w.allocObjectNum();
    const b = try w.allocObjectNum();
    try w.beginObject(a, 0);
    try w.writeRaw("<< /Type /Catalog /Pages ");
    try w.writeRef(b, 0);
    try w.writeRaw(" >>");
    try w.endObject();
    try w.beginObject(b, 0);
    try w.writeRaw("<< /Type /Pages /Kids [] /Count 0 >>");
    try w.endObject();
    const x = try w.writeXref();
    try w.writeTrailer(x, a, null);
}
