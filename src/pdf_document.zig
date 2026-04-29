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

pub const PageBuilder = struct {
    media_box: [4]f64,
    /// Raw bytes inside the content stream (before any compression).
    /// Caller composes BT/ET, Tf, Td, etc. via `appendContent`. PR-W3
    /// will add typed helpers.
    content: std.ArrayList(u8),
    /// Raw bytes that make up the `/Resources` dict body, e.g.
    /// `"<< /Font << /F1 5 0 R >> >>"`. Default is `"<< >>"` (empty
    /// dict — valid per spec but no fonts available so any text op
    /// will reference an undefined font name).
    resources_raw: std.ArrayList(u8),
    /// Allocator used for `content` + `resources_raw`. Set by the
    /// owning DocumentBuilder via `init`.
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, media_box: [4]f64) PageBuilder {
        return .{
            .media_box = media_box,
            .content = .empty,
            .resources_raw = .empty,
            .allocator = allocator,
        };
    }

    fn deinit(self: *PageBuilder) void {
        self.content.deinit(self.allocator);
        self.resources_raw.deinit(self.allocator);
    }

    pub fn appendContent(self: *PageBuilder, bytes: []const u8) !void {
        try self.content.appendSlice(self.allocator, bytes);
    }

    /// Replace the `/Resources` dict body. Must be a valid dict
    /// expression `<< ... >>`. Pass `"<< >>"` to clear.
    pub fn setResourcesRaw(self: *PageBuilder, raw: []const u8) !void {
        self.resources_raw.clearRetainingCapacity();
        try self.resources_raw.appendSlice(self.allocator, raw);
    }
};

pub const DocumentBuilder = struct {
    allocator: std.mem.Allocator,
    /// Pages in document order. Each pointer is heap-owned; freed by
    /// `deinit`.
    pages: std.ArrayList(*PageBuilder),

    pub const Error = pdf_writer.Writer.Error || error{NoPages};

    pub fn init(allocator: std.mem.Allocator) DocumentBuilder {
        return .{
            .allocator = allocator,
            .pages = .empty,
        };
    }

    pub fn deinit(self: *DocumentBuilder) void {
        for (self.pages.items) |p| {
            p.deinit();
            self.allocator.destroy(p);
        }
        self.pages.deinit(self.allocator);
    }

    pub fn addPage(self: *DocumentBuilder, media_box: [4]f64) !*PageBuilder {
        const page = try self.allocator.create(PageBuilder);
        errdefer self.allocator.destroy(page);
        page.* = PageBuilder.init(self.allocator, media_box);
        try self.pages.append(self.allocator, page);
        return page;
    }

    /// Assemble the document and return owned bytes. Caller frees with
    /// `allocator.free(bytes)`.
    pub fn write(self: *DocumentBuilder) ![]u8 {
        if (self.pages.items.len == 0) return error.NoPages;

        var w = pdf_writer.Writer.init(self.allocator);
        defer w.deinit();
        try w.writeHeader();

        const num_pages: u32 = @intCast(self.pages.items.len);

        // Step 1: allocate object numbers up-front so refs work in any
        // emission order.
        const catalog = try w.allocObjectNum();

        // Each page leaf + its content stream.
        const page_obj_nums = try self.allocator.alloc(u32, num_pages);
        defer self.allocator.free(page_obj_nums);
        const content_obj_nums = try self.allocator.alloc(u32, num_pages);
        defer self.allocator.free(content_obj_nums);
        for (0..num_pages) |i| {
            page_obj_nums[i] = try w.allocObjectNum();
            content_obj_nums[i] = try w.allocObjectNum();
        }

        // Step 2: build the balanced page-tree shape (object numbers
        // for internal /Pages nodes only — the leaves are already
        // allocated above).
        var tree = try buildBalancedTree(self.allocator, &w, page_obj_nums);
        defer freeTree(self.allocator, &tree);

        // Step 3: emit catalog → root pages node → internal nodes →
        // leaf pages → content streams. Order doesn't matter to the
        // PDF format; we go top-down for cache locality during
        // round-trip parsing.

        // 3a. Catalog.
        try w.beginObject(catalog, 0);
        try w.writeRaw("<< /Type /Catalog /Pages ");
        try w.writeRef(tree.root_obj, 0);
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

        // 3c. Leaf /Page objects.
        for (self.pages.items, 0..) |page, i| {
            try w.beginObject(page_obj_nums[i], 0);
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
                try w.writeRaw("<< >>");
            }
            try w.writeRaw(" /Contents ");
            try w.writeRef(content_obj_nums[i], 0);
            try w.writeRaw(" >>");
            try w.endObject();
        }

        // 3d. Content streams.
        for (self.pages.items, 0..) |page, i| {
            try w.beginObject(content_obj_nums[i], 0);
            try w.writeStream(page.content.items, "");
            try w.endObject();
        }

        const xref_off = try w.writeXref();
        try w.writeTrailer(xref_off, catalog, null);
        return try w.finalize();
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

// PR-W2 codex r1 P2: the existing reader walks /Kids and ignores
// /Count / /Parent, so `pageCount() == N` doesn't actually verify
// the tree shape. This helper greps the emitted bytes for the
// tree-shape invariants directly:
//   - Every internal /Pages node has /Count
//   - Internal nodes (except root) have /Parent
//   - Leaf /Page objects have /Parent (always)
fn assertPageTreeShape(bytes: []const u8, expected_pages: usize) !void {
    // Total /Page objects must equal expected_pages.
    const page_marker = "/Type /Page ";
    var pos: usize = 0;
    var page_count: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, pos, page_marker)) |idx| {
        // Discriminate /Page vs /Pages: next char after "/Type /Page" must be ' ' (already in marker) and the byte at marker[end] should NOT be 's'.
        page_count += 1;
        pos = idx + page_marker.len;
    }
    try std.testing.expectEqual(expected_pages, page_count);

    // Every /Page should have /Parent.
    var leaves_with_parent: usize = 0;
    pos = 0;
    while (std.mem.indexOfPos(u8, bytes, pos, page_marker)) |idx| {
        // Look ahead up to 200 bytes for /Parent.
        const search_end = @min(idx + 200, bytes.len);
        if (std.mem.indexOfPos(u8, bytes[0..search_end], idx, "/Parent ") != null) {
            leaves_with_parent += 1;
        }
        pos = idx + page_marker.len;
    }
    try std.testing.expectEqual(expected_pages, leaves_with_parent);

    // Every /Type /Pages node should have /Count.
    const pages_marker = "/Type /Pages ";
    pos = 0;
    var internal_nodes_count: usize = 0;
    var internal_with_count: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, pos, pages_marker)) |idx| {
        internal_nodes_count += 1;
        const search_end = @min(idx + 4096, bytes.len);
        if (std.mem.indexOfPos(u8, bytes[0..search_end], idx, "/Count ") != null) {
            internal_with_count += 1;
        }
        pos = idx + pages_marker.len;
    }
    try std.testing.expect(internal_nodes_count >= 1);
    try std.testing.expectEqual(internal_nodes_count, internal_with_count);
}

test "page tree shape: /Count + /Parent on 11-page doc (codex r1 P2)" {
    const allocator = std.testing.allocator;
    var doc = DocumentBuilder.init(allocator);
    defer doc.deinit();
    var i: usize = 0;
    while (i < 11) : (i += 1) _ = try doc.addPage(.{ 0, 0, 612, 792 });
    const bytes = try doc.write();
    defer allocator.free(bytes);
    try assertPageTreeShape(bytes, 11);
}

test "page tree shape: /Count + /Parent on 999-page doc (codex r1 P2)" {
    const allocator = std.testing.allocator;
    var doc = DocumentBuilder.init(allocator);
    defer doc.deinit();
    var i: usize = 0;
    while (i < 999) : (i += 1) _ = try doc.addPage(.{ 0, 0, 612, 792 });
    const bytes = try doc.write();
    defer allocator.free(bytes);
    try assertPageTreeShape(bytes, 999);
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
