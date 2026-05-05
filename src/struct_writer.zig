//! PR-W10c [feat]: PDF structure-tree writer.
//!
//! Builds a `/StructTreeRoot` + a forest of `/StructElem` indirect
//! objects from a caller-provided `TaggedElement` tree. Pairs with
//! `PageBuilder.beginTag/endTag` (PR-WX1) — the user wires MCIDs
//! produced by `beginTag` into `TaggedChild.mcid` leaves on this
//! tree, and `emit()` emits the matching `/StructTreeRoot` ->
//! `/StructElem` -> `<< /Type /MCR /MCID N /Pg page-ref >>` chain.
//!
//! ## Two-pass emission
//!
//! Forward references are inevitable in a tree (parent points at
//! children, children point back at parent). We resolve this with a
//! pre-pass that allocates an `obj_num` for every node before
//! anything is written; pass 2 then emits bodies that can freely
//! reference any other node by its already-known obj_num. No
//! placeholder strings, no second-write-back. This mirrors the
//! `buildBalancedTree` / page-tree emission pattern in
//! `pdf_document.zig`.
//!
//! ## Bounded recursion
//!
//! `MAX_DEPTH = 64` is enforced in pass 1 (`prepass`). Past 64,
//! `error.StructTreeTooDeep` propagates out of `setRoot`. The reader
//! caps at 256, so 64 leaves a comfortable headroom and matches the
//! TigerStyle "name your hard bounds" rule.

const std = @import("std");
const pdf_writer = @import("pdf_writer.zig");

/// Maximum nesting depth accepted by the writer. Tighter than the
/// reader's 256 (see `structtree.MAX_STRUCT_DEPTH`) to keep round-
/// trip safe — a writer that emits exactly at the reader's cap
/// trips the reader's truncation marker.
pub const MAX_DEPTH: u32 = 64;

/// User-facing tagged element. The caller builds a tree of these on
/// their own allocator, hands the root to `StructTreeBuilder.setRoot`,
/// and is free to free the tree after `DocumentBuilder.write()`
/// returns — the writer copies nothing; it only reads the tree
/// during `emit()`.
pub const TaggedElement = struct {
    /// Standard PDF/UA structure type: "Document", "P", "H1", "Figure", etc.
    /// Caller owns; not duped. Must outlive `emit()`.
    tag: []const u8,
    /// Optional `/T` entry. Caller-owned.
    title: ?[]const u8 = null,
    /// Optional `/Alt` entry — required on Figure/Formula/Form per
    /// PDF/UA-1 §7.3 (validator lives in `structtree.validateAltText`,
    /// PR-22e).
    alt: ?[]const u8 = null,
    /// Direct children. Slice is borrowed; caller-owned. May be empty.
    children: []TaggedChild = &.{},
};

pub const TaggedChild = union(enum) {
    /// Nested structure element. Pointer is borrowed; caller owns the
    /// pointee and must keep it alive across `emit()`.
    element: *TaggedElement,
    /// Marked-content reference: leaf binding to a BDC/EMC pair on a
    /// specific page. `page_idx` is a 0-based index into
    /// `DocumentBuilder.pages`; `mcid` is the value returned by
    /// `PageBuilder.beginTag` for that page.
    mcid: struct { page_idx: usize, mcid: u32 },
};

pub const Error = pdf_writer.Writer.Error || error{
    StructTreeTooDeep,
    /// `setRoot` rejects a re-entry. The builder is single-use; if
    /// the caller wants to swap trees they must `deinit` and re-init.
    StructTreeAlreadySet,
    /// `emit()` was called without a prior `setRoot`. The
    /// `DocumentBuilder` only invokes us when `struct_tree != null`,
    /// but the type system can't see that — keep the explicit error
    /// so an internal mistake surfaces as a real error rather than
    /// `unreachable`.
    StructTreeNotSet,
};

/// Internal pass-1 record. One per `TaggedElement` reachable from
/// the root. Stored in a flat list so pass 2 can iterate without
/// re-walking the tree.
const NodeRecord = struct {
    elem: *const TaggedElement,
    obj_num: u32,
    /// `null` only for the root element (its parent is the
    /// `StructTreeRoot`, whose obj_num lives in `tree_root_obj`).
    parent_obj: ?u32,
};

pub const StructTreeBuilder = struct {
    allocator: std.mem.Allocator,
    /// Caller-owned root pointer; null until `setRoot`.
    root: ?*TaggedElement = null,
    /// Pre-allocated obj_nums + parent back-pointers. Filled by
    /// `prepass`, drained by `emitBodies`. Empty at `init` and after
    /// `deinit`.
    nodes: std.ArrayList(NodeRecord) = .empty,
    /// Indirect-object number of the `/StructTreeRoot` itself.
    /// Allocated in `emit` before walking nodes so the first
    /// element's `/P` can resolve.
    tree_root_obj: u32 = 0,
    /// `pages.items[i].obj_num` for each page in the document, copied
    /// in by `emit()`. Borrowed slice — the caller (`DocumentBuilder.write`)
    /// owns the underlying buffer.
    page_obj_nums: []const u32 = &.{},

    pub fn init(allocator: std.mem.Allocator) StructTreeBuilder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *StructTreeBuilder) void {
        self.nodes.deinit(self.allocator);
        self.* = undefined;
    }

    /// Caller transfers logical ownership of the tree to the builder
    /// for the lifetime of `emit()`, but no bytes are duped — the
    /// caller MUST keep the tree alive until `DocumentBuilder.write`
    /// has returned. Validates depth in a single recursive pass; if
    /// the tree is too deep, no state is mutated.
    pub fn setRoot(self: *StructTreeBuilder, root: *TaggedElement) !void {
        if (self.root != null) return error.StructTreeAlreadySet;
        try validateDepth(root, 0);
        self.root = root;
    }

    /// Reserve the indirect-object number for `/StructTreeRoot`
    /// without emitting anything. `DocumentBuilder.write()` calls
    /// this BEFORE the catalog dict is written so `/StructTreeRoot N 0 R`
    /// can be spliced into the catalog body. Idempotent: a second
    /// call returns the same number.
    pub fn reserve(self: *StructTreeBuilder, w: *pdf_writer.Writer) !u32 {
        if (self.tree_root_obj != 0) return self.tree_root_obj;
        if (self.root == null) return error.StructTreeNotSet;
        self.tree_root_obj = try w.allocObjectNum();
        return self.tree_root_obj;
    }

    /// Called by `DocumentBuilder.write()` after page leaf objects
    /// have been emitted (so `page_obj_nums` is stable). `page_obj_nums`
    /// must be `pages.items.len` long. Returns the obj_num of the
    /// `/StructTreeRoot` for the catalog `/StructTreeRoot <ref>` entry.
    /// `reserve()` must have been called earlier (the
    /// `DocumentBuilder.write()` flow does this) so the catalog can
    /// reference the root obj_num without forward-fixup.
    pub fn emit(
        self: *StructTreeBuilder,
        w: *pdf_writer.Writer,
        page_obj_nums: []const u32,
    ) !u32 {
        const root = self.root orelse return error.StructTreeNotSet;
        self.page_obj_nums = page_obj_nums;

        // Pass 1: allocate one obj_num per StructElement. The
        // /StructTreeRoot's own obj_num was allocated by `reserve()`
        // earlier so the catalog could splice `/StructTreeRoot N 0 R`.
        // After prepass, every cross-ref resolves to a known number.
        if (self.tree_root_obj == 0) {
            self.tree_root_obj = try w.allocObjectNum();
        }
        try self.prepass(w, root, null);

        // Pass 2: emit the indirect objects. /StructTreeRoot first
        // (its body references the first element), then each
        // StructElement in pre-order.
        try self.emitTreeRoot(w);
        for (self.nodes.items) |node| {
            try self.emitElement(w, node);
        }

        return self.tree_root_obj;
    }

    /// Recursive depth check. Touches no state — caller can re-run
    /// without rollback concerns.
    fn validateDepth(elem: *const TaggedElement, depth: u32) Error!void {
        if (depth >= MAX_DEPTH) return error.StructTreeTooDeep;
        for (elem.children) |child| switch (child) {
            .element => |e| try validateDepth(e, depth + 1),
            .mcid => {},
        };
    }

    /// Pass 1: pre-order walk; reserve one obj_num per element + push
    /// a NodeRecord. Runs after `tree_root_obj` is allocated so the
    /// root element's `parent_obj` is filled with the StructTreeRoot
    /// number and not a sentinel.
    ///
    /// `errdefer` here is partial — if pass-1 fails halfway, the
    /// already-reserved obj_nums become "dangling" from the writer's
    /// perspective. The caller (`DocumentBuilder.write`) is documented
    /// as poison-on-error: any writer error past this point requires
    /// `deinit` without retry.
    fn prepass(
        self: *StructTreeBuilder,
        w: *pdf_writer.Writer,
        elem: *const TaggedElement,
        parent_obj: ?u32,
    ) !void {
        const my_obj = try w.allocObjectNum();
        const effective_parent = parent_obj orelse self.tree_root_obj;
        try self.nodes.append(self.allocator, .{
            .elem = elem,
            .obj_num = my_obj,
            .parent_obj = effective_parent,
        });
        for (elem.children) |child| switch (child) {
            .element => |e| try self.prepass(w, e, my_obj),
            .mcid => {},
        };
    }

    fn emitTreeRoot(self: *StructTreeBuilder, w: *pdf_writer.Writer) !void {
        // The first node we recorded is the root TaggedElement. Its
        // obj_num goes into /K. (We could also emit /K as an array,
        // but the spec accepts a single ref and that's what every
        // round-trip fixture in the wild uses.)
        std.debug.assert(self.nodes.items.len > 0); // prepass guarantees ≥1
        const root_elem_obj = self.nodes.items[0].obj_num;

        try w.beginObject(self.tree_root_obj, 0);
        try w.writeRaw("<< /Type /StructTreeRoot /K ");
        try w.writeRef(root_elem_obj, 0);
        try w.writeRaw(" >>");
        try w.endObject();
    }

    fn emitElement(
        self: *StructTreeBuilder,
        w: *pdf_writer.Writer,
        node: NodeRecord,
    ) !void {
        try w.beginObject(node.obj_num, 0);
        try w.writeRaw("<< /Type /StructElem /S /");
        try w.writeRaw(node.elem.tag);
        try w.writeRaw(" /P ");
        // parent_obj is non-null for every node prepass produces.
        try w.writeRef(node.parent_obj.?, 0);

        if (node.elem.title) |t| {
            try w.writeRaw(" /T ");
            try w.writeStringLiteral(t);
        }
        if (node.elem.alt) |a| {
            try w.writeRaw(" /Alt ");
            try w.writeStringLiteral(a);
        }

        // /K array. Mixed children: nested-element refs interleave
        // with `<< /Type /MCR /MCID N /Pg pg-ref >>` dicts. We always
        // emit /K as an array — even for a single child — to keep the
        // shape uniform. Empty children -> empty array, which the
        // reader accepts.
        try w.writeRaw(" /K [");
        var first = true;
        for (node.elem.children) |child| {
            if (!first) try w.writeRaw(" ");
            first = false;
            switch (child) {
                .element => |sub| {
                    const sub_obj = try self.lookupObj(sub);
                    try w.writeRef(sub_obj, 0);
                },
                .mcid => |mcr| {
                    if (mcr.page_idx >= self.page_obj_nums.len) {
                        return error.StructTreeNotSet; // page_idx out-of-range
                    }
                    const page_obj = self.page_obj_nums[mcr.page_idx];
                    try w.writeRaw("<< /Type /MCR /MCID ");
                    try w.writeInt(@intCast(mcr.mcid));
                    try w.writeRaw(" /Pg ");
                    try w.writeRef(page_obj, 0);
                    try w.writeRaw(" >>");
                },
            }
        }
        try w.writeRaw("]");

        // Per-element /Pg: if any of this element's MCID children
        // sits on a single distinct page, the spec lets us hoist /Pg
        // up so the MCR dicts can elide their own /Pg. We DON'T do
        // that hoist here — keeping /Pg on each MCR is verbose but
        // unambiguous, and the reader already resolves both forms
        // (see `parseKids` in structtree.zig: the MCR-level /Pg wins
        // over the parent /Pg). Simpler is better.

        try w.writeRaw(" >>");
        try w.endObject();
    }

    /// Linear scan over `nodes` to resolve a child element pointer
    /// to its pre-allocated obj_num. Tagged trees are small (10²–10³
    /// nodes max in real PDF/UA documents) so the n² total cost is a
    /// non-issue, and the alternative — a hash map keyed by pointer —
    /// adds hash setup overhead that wipes out the win.
    fn lookupObj(self: *const StructTreeBuilder, target: *const TaggedElement) !u32 {
        for (self.nodes.items) |n| {
            if (n.elem == target) return n.obj_num;
        }
        // prepass walks every reachable element, so a child not in
        // the table means the caller mutated the tree between
        // setRoot and emit. That's a contract violation, not a
        // recoverable runtime condition — but we surface it as an
        // error rather than `unreachable` so fuzzers can still
        // exercise the path.
        return error.StructTreeNotSet;
    }
};

// =====================================================================
// Tests
// =====================================================================

test "PR-W10c: empty TaggedElement validates" {
    var leaf: TaggedElement = .{ .tag = "P" };
    var builder = StructTreeBuilder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.setRoot(&leaf);
}

test "PR-W10c: setRoot rejects re-entry" {
    var leaf_a: TaggedElement = .{ .tag = "P" };
    var leaf_b: TaggedElement = .{ .tag = "P" };
    var builder = StructTreeBuilder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.setRoot(&leaf_a);
    try std.testing.expectError(error.StructTreeAlreadySet, builder.setRoot(&leaf_b));
}

test "PR-W10c: depth 64 ok, depth 65 rejected" {
    const allocator = std.testing.allocator;
    // Build a 65-deep linear chain on the heap.
    var elems: [66]TaggedElement = undefined;
    var kids: [66][1]TaggedChild = undefined;
    var i: usize = 0;
    while (i < 66) : (i += 1) {
        elems[i] = .{ .tag = "Sect" };
    }
    // Wire i -> i+1 for i in 0..64 (so the deepest path has 65 levels: indices 0..64).
    i = 0;
    while (i < 65) : (i += 1) {
        kids[i] = .{TaggedChild{ .element = &elems[i + 1] }};
        elems[i].children = kids[i][0..];
    }
    // Variant A: depth 64 (indices 0..63 chained, 63 is leaf).
    elems[63].children = &.{};
    {
        var b = StructTreeBuilder.init(allocator);
        defer b.deinit();
        try b.setRoot(&elems[0]); // depth: 0..63 = 64 levels. OK.
    }
    // Variant B: depth 65 (indices 0..64 chained).
    elems[63].children = kids[63][0..]; // restore the link
    elems[64].children = &.{};
    {
        var b = StructTreeBuilder.init(allocator);
        defer b.deinit();
        try std.testing.expectError(error.StructTreeTooDeep, b.setRoot(&elems[0]));
    }
}

test "PR-W10c: emit produces /StructTreeRoot + /StructElem with MCR" {
    const allocator = std.testing.allocator;
    var w = pdf_writer.Writer.init(allocator);
    defer w.deinit();
    try w.writeHeader();
    // Reserve a fake page obj_num so /Pg refs land somewhere.
    const fake_page_obj = try w.allocObjectNum();
    try w.beginObject(fake_page_obj, 0);
    try w.writeRaw("<< /Type /Page >>");
    try w.endObject();

    // Build:  Document -> P -> [MCID 0 on page 0]
    var p_kids: [1]TaggedChild = .{.{ .mcid = .{ .page_idx = 0, .mcid = 0 } }};
    var p_elem: TaggedElement = .{ .tag = "P", .children = p_kids[0..] };
    var doc_kids: [1]TaggedChild = .{.{ .element = &p_elem }};
    var doc_elem: TaggedElement = .{ .tag = "Document", .children = doc_kids[0..] };

    var builder = StructTreeBuilder.init(allocator);
    defer builder.deinit();
    try builder.setRoot(&doc_elem);

    const page_obj_nums = [_]u32{fake_page_obj};
    const root_obj = try builder.emit(&w, page_obj_nums[0..]);
    _ = try w.writeXref();
    try w.writeTrailer(0, root_obj, null); // catalog field unused by the test

    const bytes = try w.finalize();
    defer allocator.free(bytes);

    // Spot-check: every artefact made it onto the wire.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/Type /StructTreeRoot") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/Type /StructElem") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/S /Document") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/S /P") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/Type /MCR") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/MCID 0") != null);
}

test "PR-W10c: title and alt are emitted as PDF string literals" {
    const allocator = std.testing.allocator;
    var w = pdf_writer.Writer.init(allocator);
    defer w.deinit();
    try w.writeHeader();
    const fake_page_obj = try w.allocObjectNum();
    try w.beginObject(fake_page_obj, 0);
    try w.writeRaw("<< /Type /Page >>");
    try w.endObject();

    var fig: TaggedElement = .{
        .tag = "Figure",
        .title = "A figure",
        .alt = "alt text here",
    };
    var builder = StructTreeBuilder.init(allocator);
    defer builder.deinit();
    try builder.setRoot(&fig);
    const page_obj_nums = [_]u32{fake_page_obj};
    _ = try builder.emit(&w, page_obj_nums[0..]);
    _ = try w.writeXref();
    try w.writeTrailer(0, 1, null);

    const bytes = try w.finalize();
    defer allocator.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "/T (A figure)") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/Alt (alt text here)") != null);
}

test "PR-W10c: FailingAllocator sweep on emit — no leaks" {
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const allocator = failing.allocator();

        var w = pdf_writer.Writer.init(allocator);
        defer w.deinit();
        w.writeHeader() catch continue;
        const fake_page_obj = w.allocObjectNum() catch continue;
        w.beginObject(fake_page_obj, 0) catch continue;
        w.writeRaw("<< /Type /Page >>") catch continue;
        w.endObject() catch continue;

        var p1_kids: [1]TaggedChild = .{.{ .mcid = .{ .page_idx = 0, .mcid = 0 } }};
        var p1: TaggedElement = .{ .tag = "P", .children = p1_kids[0..] };
        var p2_kids: [1]TaggedChild = .{.{ .mcid = .{ .page_idx = 0, .mcid = 1 } }};
        var p2: TaggedElement = .{ .tag = "P", .children = p2_kids[0..] };
        var doc_kids: [2]TaggedChild = .{
            .{ .element = &p1 },
            .{ .element = &p2 },
        };
        var doc: TaggedElement = .{ .tag = "Document", .children = doc_kids[0..] };

        var builder = StructTreeBuilder.init(allocator);
        defer builder.deinit();
        builder.setRoot(&doc) catch continue;

        const page_obj_nums = [_]u32{fake_page_obj};
        _ = builder.emit(&w, page_obj_nums[0..]) catch {
            // Failure mid-emit is the contract: caller treats the
            // doc as poisoned and `deinit`s. The `defer`s above
            // handle the actual cleanup; the test passes if the
            // testing allocator finds no leak afterward.
            continue;
        };
    }
}
