//! PR-23b: inherited-attribute flattener.
//!
//! Given a parsed `StructTree`, produce a `*const StructElement → FlattenedAttrs`
//! map where each element exposes the *effective* values of `/Lang`,
//! `/Alt`, `/ActualText`, and `resolved_role` it would inherit from a
//! depth-first walk through its ancestors. Consumers (`a11y_tree`
//! NDJSON emitter, screen-reader linearizer) can then read each leaf
//! without doing parent walks of their own.
//!
//! Inheritance rules:
//!   - `lang`           — already populated by PR-22d's `propagateLang`;
//!                        copied as-is from the element. (No re-walk.)
//!   - `alt_text`       — element's own `/Alt` if set; otherwise nearest
//!                        ancestor's `/Alt`.
//!   - `actual_text`    — element's own `/ActualText` if set; otherwise
//!                        nearest ancestor's `/ActualText`.
//!   - `resolved_role`  — already populated by PR-22b's `parseRoleMap`;
//!                        copied as-is. (No re-walk.)
//!
//! Slices in `FlattenedAttrs` borrow from the tree's allocator —
//! lifetime is bound to the tree's. The map itself owns its buckets and
//! must be `deinit`ed by the caller.

const std = @import("std");
const structtree = @import("structtree.zig");

const StructElement = structtree.StructElement;
const StructTree = structtree.StructTree;
const StructChild = structtree.StructChild;

const Document = @import("root.zig").Document;

/// Bound matching `MAX_VALIDATE_DEPTH` (also 64 in `structtree.zig`).
/// Adversarial PDFs must not crash the flattener; depths beyond this
/// surface as `error.StructTreeTooDeep`.
pub const MAX_FLATTEN_DEPTH: u32 = 64;

pub const FlattenedAttrs = struct {
    lang: ?[]const u8 = null,
    alt_text: ?[]const u8 = null,
    actual_text: ?[]const u8 = null,
    resolved_role: ?[]const u8 = null,
};

/// Walks the struct tree depth-first, returning a map from element
/// pointer to its fully-flattened attribute set. Element pointers are
/// stable for the tree's lifetime (each element is heap-allocated by
/// `parseStructTree`).
pub fn flatten(
    tree: *const StructTree,
    allocator: std.mem.Allocator,
) !std.AutoHashMap(*const StructElement, FlattenedAttrs) {
    var map = std.AutoHashMap(*const StructElement, FlattenedAttrs).init(allocator);
    errdefer map.deinit();

    const root = tree.root orelse return map;
    try walk(root, .{}, &map, 0);
    return map;
}

fn walk(
    elem: *const StructElement,
    inherited: FlattenedAttrs,
    map: *std.AutoHashMap(*const StructElement, FlattenedAttrs),
    depth: u32,
) !void {
    if (depth >= MAX_FLATTEN_DEPTH) return error.StructTreeTooDeep;

    // Element-level value wins; otherwise inherit from nearest ancestor.
    // `lang` and `resolved_role` are pre-populated by PR-22d / PR-22b
    // respectively, so we just propagate `elem.lang` / `elem.resolved_role`
    // as a belt-and-braces fallback for the (legal) case where a caller
    // built a tree manually without invoking those passes.
    const effective: FlattenedAttrs = .{
        .lang = elem.lang orelse inherited.lang,
        .alt_text = elem.alt_text orelse inherited.alt_text,
        .actual_text = elem.actual_text orelse inherited.actual_text,
        .resolved_role = elem.resolved_role orelse inherited.resolved_role,
    };

    try map.put(elem, effective);

    for (elem.children) |child| {
        switch (child) {
            .element => |sub| try walk(sub, effective, map, depth + 1),
            .mcid => {},
        }
    }
}

/// Opt-in companion to `structtree.parseStructTree`. Parses the tree,
/// then walks it propagating `/Alt` and `/ActualText` from each element
/// to its descendants (as `flatten` does), but writes the inherited
/// values back onto the descendant elements themselves so downstream
/// emitters see flattened fields directly.
///
/// `lang` and `resolved_role` are already populated by 22d / 22b during
/// `parseStructTree`; this function only fills the gaps for `alt_text`
/// and `actual_text`. The slices written are borrowed from the original
/// ancestor — same lifetime as the tree's allocator (no copy, no new
/// allocation).
///
/// Why opt-in: the default `parseStructTree` is byte-equivalent to
/// pre-23b output, so the SX1 golden remains stable. Callers who need
/// flattened attrs (a11y_tree NDJSON emitter, screen-reader linearizer)
/// invoke this explicitly.
pub fn parseStructTreeWithFlattenedAttrs(
    doc: *anyopaque,
) !StructTree {
    const document: *Document = @ptrCast(@alignCast(doc));

    var tree = try document.getStructTree();
    errdefer tree.deinit();

    try flattenInPlace(&tree);
    return tree;
}

/// Mutate every element in `tree` so its `alt_text` / `actual_text`
/// reflect inheritance from the nearest ancestor (if not already set).
/// Bounded by `MAX_FLATTEN_DEPTH`; over-deep trees → `error.StructTreeTooDeep`.
pub fn flattenInPlace(tree: *StructTree) !void {
    const root = tree.root orelse return;
    try flattenInPlaceWalk(@constCast(root), null, null, 0);
}

fn flattenInPlaceWalk(
    elem: *StructElement,
    inherited_alt: ?[]const u8,
    inherited_actual: ?[]const u8,
    depth: u32,
) !void {
    if (depth >= MAX_FLATTEN_DEPTH) return error.StructTreeTooDeep;

    if (elem.alt_text == null) elem.alt_text = inherited_alt;
    if (elem.actual_text == null) elem.actual_text = inherited_actual;

    const eff_alt = elem.alt_text;
    const eff_actual = elem.actual_text;

    for (elem.children) |child| {
        switch (child) {
            .element => |sub| try flattenInPlaceWalk(@constCast(sub), eff_alt, eff_actual, depth + 1),
            .mcid => {},
        }
    }
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

test "PR-23b: empty tree → empty map" {
    const empty: StructTree = .{
        .root = null,
        .elements = &.{},
        .allocator = testing.allocator,
    };
    var map = try flatten(&empty, testing.allocator);
    defer map.deinit();
    try testing.expectEqual(@as(usize, 0), map.count());
}

test "PR-23b: single-element tree → one entry with own attrs" {
    const root: StructElement = .{
        .struct_type = "Document",
        .alt_text = "doc-alt",
        .actual_text = "doc-actual",
        .lang = "en-US",
        .children = &.{},
    };
    const tree: StructTree = .{
        .root = &root,
        .elements = &.{},
        .allocator = testing.allocator,
    };

    var map = try flatten(&tree, testing.allocator);
    defer map.deinit();

    try testing.expectEqual(@as(usize, 1), map.count());
    const entry = map.get(&root) orelse return error.TestExpectedRootInMap;
    try testing.expectEqualStrings("doc-alt", entry.alt_text.?);
    try testing.expectEqualStrings("doc-actual", entry.actual_text.?);
    try testing.expectEqualStrings("en-US", entry.lang.?);
    try testing.expectEqual(@as(?[]const u8, null), entry.resolved_role);
}

test "PR-23b: 3-level tree — leaf inherits root's /Alt" {
    // Build: Document(/Alt="root-alt") → P → Span (no /Alt)
    const leaf: StructElement = .{
        .struct_type = "Span",
        .children = &.{},
    };
    const mid_kids = [_]StructChild{.{ .element = &leaf }};
    const mid: StructElement = .{
        .struct_type = "P",
        .children = &mid_kids,
    };
    const root_kids = [_]StructChild{.{ .element = &mid }};
    const root: StructElement = .{
        .struct_type = "Document",
        .alt_text = "root-alt",
        .children = &root_kids,
    };
    const tree: StructTree = .{
        .root = &root,
        .elements = &.{},
        .allocator = testing.allocator,
    };

    var map = try flatten(&tree, testing.allocator);
    defer map.deinit();

    try testing.expectEqual(@as(usize, 3), map.count());
    const root_entry = map.get(&root).?;
    const mid_entry = map.get(&mid).?;
    const leaf_entry = map.get(&leaf).?;
    try testing.expectEqualStrings("root-alt", root_entry.alt_text.?);
    try testing.expectEqualStrings("root-alt", mid_entry.alt_text.?);
    try testing.expectEqualStrings("root-alt", leaf_entry.alt_text.?);
}

test "PR-23b: inheritance shadowing — middle /Alt overrides root's" {
    // Build: Document(/Alt="root") → Sect(/Alt="mid") → P (no /Alt)
    const leaf: StructElement = .{
        .struct_type = "P",
        .children = &.{},
    };
    const mid_kids = [_]StructChild{.{ .element = &leaf }};
    const mid: StructElement = .{
        .struct_type = "Sect",
        .alt_text = "mid",
        .children = &mid_kids,
    };
    const root_kids = [_]StructChild{.{ .element = &mid }};
    const root: StructElement = .{
        .struct_type = "Document",
        .alt_text = "root",
        .children = &root_kids,
    };
    const tree: StructTree = .{
        .root = &root,
        .elements = &.{},
        .allocator = testing.allocator,
    };

    var map = try flatten(&tree, testing.allocator);
    defer map.deinit();

    try testing.expectEqualStrings("root", map.get(&root).?.alt_text.?);
    try testing.expectEqualStrings("mid", map.get(&mid).?.alt_text.?);
    try testing.expectEqualStrings("mid", map.get(&leaf).?.alt_text.?);
}

test "PR-23b: /ActualText inherits independently from /Alt" {
    // Document(/Alt="A") → Span(/ActualText="X")
    // Span inherits /Alt="A"; Document does NOT inherit Span's /ActualText.
    const leaf: StructElement = .{
        .struct_type = "Span",
        .actual_text = "X",
        .children = &.{},
    };
    const root_kids = [_]StructChild{.{ .element = &leaf }};
    const root: StructElement = .{
        .struct_type = "Document",
        .alt_text = "A",
        .children = &root_kids,
    };
    const tree: StructTree = .{
        .root = &root,
        .elements = &.{},
        .allocator = testing.allocator,
    };

    var map = try flatten(&tree, testing.allocator);
    defer map.deinit();

    const root_entry = map.get(&root).?;
    const leaf_entry = map.get(&leaf).?;
    try testing.expectEqualStrings("A", root_entry.alt_text.?);
    try testing.expectEqual(@as(?[]const u8, null), root_entry.actual_text);
    try testing.expectEqualStrings("A", leaf_entry.alt_text.?);
    try testing.expectEqualStrings("X", leaf_entry.actual_text.?);
}

test "PR-23b: depth bound — over-deep tree returns error.StructTreeTooDeep" {
    // Build a chain of MAX_FLATTEN_DEPTH + 1 nested elements. Storage
    // for the chain has to outlive `flatten()`, so allocate up-front.
    const allocator = testing.allocator;
    const N: usize = MAX_FLATTEN_DEPTH + 4;

    const chain = try allocator.alloc(StructElement, N);
    defer allocator.free(chain);
    const child_slots = try allocator.alloc(StructChild, N);
    defer allocator.free(child_slots);

    // Build bottom-up: chain[N-1] is the leaf; each parent's children
    // is a single-element slice into `child_slots`.
    var i: usize = N;
    while (i > 0) {
        i -= 1;
        chain[i] = .{
            .struct_type = "P",
            .children = if (i == N - 1) &.{} else child_slots[i .. i + 1],
        };
        if (i < N - 1) {
            child_slots[i] = .{ .element = &chain[i + 1] };
        }
    }

    const tree: StructTree = .{
        .root = &chain[0],
        .elements = &.{},
        .allocator = allocator,
    };

    try testing.expectError(error.StructTreeTooDeep, flatten(&tree, allocator));
}

test "PR-23b: flattenInPlace — depth-2 inherits from depth-1 ancestor" {
    // Depth-1 (root) has /Alt; depth-2 child does not. After
    // `flattenInPlace`, the depth-2 element's `alt_text` is the
    // borrowed slice from the root.
    var leaf: StructElement = .{
        .struct_type = "TD",
        .children = &.{},
    };
    const root_kids = [_]StructChild{.{ .element = &leaf }};
    var root: StructElement = .{
        .struct_type = "Table",
        .alt_text = "table-summary",
        .children = &root_kids,
    };
    var tree: StructTree = .{
        .root = &root,
        .elements = &.{},
        .allocator = testing.allocator,
    };

    try flattenInPlace(&tree);
    try testing.expectEqualStrings("table-summary", leaf.alt_text.?);
    try testing.expectEqualStrings("table-summary", root.alt_text.?);
}

test "PR-23b: flattenInPlace — depth bound returns error.StructTreeTooDeep" {
    const allocator = testing.allocator;
    const N: usize = MAX_FLATTEN_DEPTH + 4;

    const chain = try allocator.alloc(StructElement, N);
    defer allocator.free(chain);
    const child_slots = try allocator.alloc(StructChild, N);
    defer allocator.free(child_slots);

    var i: usize = N;
    while (i > 0) {
        i -= 1;
        chain[i] = .{
            .struct_type = "P",
            .children = if (i == N - 1) &.{} else child_slots[i .. i + 1],
        };
        if (i < N - 1) {
            child_slots[i] = .{ .element = &chain[i + 1] };
        }
    }

    var tree: StructTree = .{
        .root = &chain[0],
        .elements = &.{},
        .allocator = allocator,
    };

    try testing.expectError(error.StructTreeTooDeep, flattenInPlace(&tree));
}

test "PR-23b: FailingAllocator sweep — no leaks on partial-fill OOM" {
    // Tree shape: 5 nested elements. FailingAllocator pinches at every
    // possible point in the HashMap's `put` path; each failure must
    // unwind cleanly (errdefer on `map`).
    const e4: StructElement = .{ .struct_type = "Span", .children = &.{} };
    const c3 = [_]StructChild{.{ .element = &e4 }};
    const e3: StructElement = .{ .struct_type = "P", .children = &c3 };
    const c2 = [_]StructChild{.{ .element = &e3 }};
    const e2: StructElement = .{ .struct_type = "Sect", .children = &c2 };
    const c1 = [_]StructChild{.{ .element = &e2 }};
    const e1: StructElement = .{ .struct_type = "Part", .children = &c1 };
    const c0 = [_]StructChild{.{ .element = &e1 }};
    const root: StructElement = .{ .struct_type = "Document", .children = &c0 };
    const tree: StructTree = .{
        .root = &root,
        .elements = &.{},
        .allocator = testing.allocator,
    };

    var fail_index: usize = 0;
    while (fail_index < 16) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const result = flatten(&tree, failing.allocator());
        if (result) |*ok| {
            var m = ok.*;
            m.deinit();
            break; // succeeded — no more failure points to exercise
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
        }
    }
}
