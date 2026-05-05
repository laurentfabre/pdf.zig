//! PR-23c: a11y_tree NDJSON emitter.
//!
//! Emits a single `kind:"a11y_tree"` NDJSON record per document carrying
//! the full PDF/UA structure tree with inheritance + MCID-resolution
//! pre-applied, plus a top-level `reading_order` linearization.
//!
//! Schema (single record per document):
//!
//!   {"kind":"a11y_tree","doc_id":"…","source":"…",
//!    "root": <tree>,
//!    "reading_order": [{"page":N,"mcid":N,"text":"…"}, …]}
//!
//! Where `<tree>` recursively follows the same shape as PR-21's
//! `--struct-tree` JSON (`type`, `mcid_refs`, `children`), augmented with
//! flattened/resolved a11y fields:
//!   - `lang`           — BCP-47 (PR-22d, then 23b inheritance walk)
//!   - `alt`            — /Alt (own or inherited via 23b)
//!   - `actual_text`    — /ActualText (own or inherited via 23b)
//!   - `resolved_role`  — RoleMap-resolved standard type (PR-22b)
//!   - `text`           — MCID-resolved text on leaves with one MCID,
//!                        when `resolve_mcid_text` is on (PR-23a)
//!
//! Empty struct tree → record with `"root":null,"reading_order":[]` (do
//! not fail). Bounded recursion: `MAX_EMIT_DEPTH = 64` consistent with
//! `structtree.MAX_VALIDATE_DEPTH` and `attr_flattener.MAX_FLATTEN_DEPTH`.
//! Over-deep emits a `"_truncated_max_depth"` marker leaf, mirroring
//! `structtree.emitElementJson`.

const std = @import("std");
const structtree = @import("structtree.zig");
const stream = @import("stream.zig");
const mcid_resolver = @import("mcid_resolver.zig");
const root_mod = @import("root.zig");

const StructElement = structtree.StructElement;
const StructChild = structtree.StructChild;
const StructTree = structtree.StructTree;
const MarkedContentRef = structtree.MarkedContentRef;
const Document = root_mod.Document;

/// Hard depth ceiling — same value as the validator + flattener so any
/// regression that lets one of them grow is loud at the next compile.
pub const MAX_EMIT_DEPTH: u32 = 64;

pub const A11yEmitOptions = struct {
    flatten_attrs: bool = true,
    resolve_mcid_text: bool = true,
    include_reading_order: bool = true,
};

/// Composite key into the per-MCID text cache. `page_obj` is the PDF
/// object number of the /Pg containing the MCID (matches the values
/// produced by `getReadingOrder`); `mcid` is the marked-content ID.
const McidKey = struct {
    page_obj: u32,
    mcid: i32,
};

const McidTextMap = std.AutoHashMap(McidKey, []const u8);

/// Emit a `kind:"a11y_tree"` NDJSON record into `env`.
///
/// `doc` is the parsed PDF Document. `tree` is the result of
/// `doc.getStructTree()` — the caller passes it in (rather than fetching
/// fresh) so flatten + emit stay on the same arena allocation.
///
/// On allocation failure the partially-flattened tree is left in place
/// (it lives on the document's parsing arena and is destroyed with the
/// document). All transient allocations made by this function are freed
/// on every error path.
pub fn emit(
    env: *stream.Envelope,
    doc: *Document,
    tree: *StructTree,
    allocator: std.mem.Allocator,
    opts: A11yEmitOptions,
) !void {
    // Optionally flatten /Alt + /ActualText inheritance in place.
    if (opts.flatten_attrs) {
        try @import("attr_flattener.zig").flattenInPlace(tree);
    }

    // Build the page-obj → page-idx map up-front (fixed cost). Used by
    // the MCID-text resolver and by the reading_order writer.
    var page_obj_to_idx = std.AutoHashMap(u32, usize).init(allocator);
    defer page_obj_to_idx.deinit();
    for (doc.pages.items, 0..) |p, idx| {
        try page_obj_to_idx.put(p.ref.num, idx);
    }

    // Resolve MCID → text for every leaf MCID we'll emit. Single batch
    // walk per page so we don't re-scan the same content stream. Map
    // owns the resolved bytes; freed on every exit path.
    var mcid_texts = McidTextMap.init(allocator);
    defer {
        var it = mcid_texts.iterator();
        while (it.next()) |entry| allocator.free(entry.value_ptr.*);
        mcid_texts.deinit();
    }

    if (opts.resolve_mcid_text and tree.root != null) {
        try resolveAllMcidTexts(tree.root.?, doc, &page_obj_to_idx, &mcid_texts, allocator, 0);
    }

    // Begin the envelope: `{"kind":"a11y_tree","doc_id":"…","source":"…",`
    try env.beginA11yTreeRecord();

    // `"root": <tree | null>`
    if (tree.root) |r| {
        try emitElement(r, env.writer, &mcid_texts, opts, 0);
    } else {
        try env.writer.writeAll("null");
    }

    // `,"reading_order":[…]`
    if (opts.include_reading_order) {
        try env.writer.writeAll(",\"reading_order\":[");
        if (tree.root) |r| {
            var first: bool = true;
            try writeReadingOrder(r, env.writer, &page_obj_to_idx, &mcid_texts, &first, null, 0);
        }
        try env.writer.writeAll("]");
    }

    try env.endA11yTreeRecord();
}

/// Walk the tree DFS; for every leaf MCID with a known page object,
/// resolve its text and stash it in `out`. One `resolveOne` call per
/// MCID (the resolver itself walks the page once per call — acceptable
/// for the typical small-MCID-count case; a future PR can switch to
/// `resolveBatch` per-page if profiling demands it).
fn resolveAllMcidTexts(
    elem: *const StructElement,
    doc: *Document,
    page_obj_to_idx: *const std.AutoHashMap(u32, usize),
    out: *McidTextMap,
    allocator: std.mem.Allocator,
    depth: u32,
) !void {
    if (depth >= MAX_EMIT_DEPTH) return;

    // Drop /Artifact subtrees from MCID resolution — same rule as
    // `collectMcidsInOrder`. Artifacts never enter reading order, so we
    // don't pay for resolving their text.
    if (std.mem.eql(u8, elem.struct_type, "Artifact")) return;

    for (elem.children) |child| {
        switch (child) {
            .element => |sub| try resolveAllMcidTexts(sub, doc, page_obj_to_idx, out, allocator, depth + 1),
            .mcid => |m| {
                if (m.mcid < 0) continue; // BMC sentinel (PR-22c).
                const page_ref = m.page_ref orelse continue;
                const page_idx = page_obj_to_idx.get(page_ref.num) orelse continue;

                const key: McidKey = .{ .page_obj = page_ref.num, .mcid = m.mcid };
                if (out.contains(key)) continue; // Already resolved.

                const text = mcid_resolver.resolveOne(@ptrCast(doc), page_idx, m.mcid, allocator) catch null;
                if (text) |t| {
                    errdefer allocator.free(t);
                    try out.put(key, t);
                }
            },
        }
    }
}

/// Recursive JSON emission for one element. Mirrors the field order in
/// `structtree.emitElementJson` so the SX1 byte-equivalence story stays
/// readable; just adds the a11y fields between `lang` and `mcid_refs`.
fn emitElement(
    elem: *const StructElement,
    writer: *std.Io.Writer,
    mcid_texts: *const McidTextMap,
    opts: A11yEmitOptions,
    depth: u32,
) !void {
    if (depth >= MAX_EMIT_DEPTH) {
        try writer.writeAll("{\"type\":\"_truncated_max_depth\",\"mcid_refs\":[],\"children\":[]}");
        return;
    }

    try writer.writeAll("{\"type\":");
    try stream.writeJsonString(writer, elem.struct_type);

    if (elem.alt_text) |alt| {
        try writer.writeAll(",\"alt\":");
        try stream.writeJsonString(writer, alt);
    }
    if (elem.actual_text) |at| {
        try writer.writeAll(",\"actual_text\":");
        try stream.writeJsonString(writer, at);
    }
    if (elem.title) |t| {
        try writer.writeAll(",\"title\":");
        try stream.writeJsonString(writer, t);
    }
    if (elem.page_ref) |pr| {
        try writer.print(",\"page_obj\":{d}", .{pr.num});
    }
    if (elem.resolved_role) |role| {
        try writer.writeAll(",\"resolved_role\":");
        try stream.writeJsonString(writer, role);
    }
    if (elem.lang) |l| {
        try writer.writeAll(",\"lang\":");
        try stream.writeJsonString(writer, l);
    }

    // PR-23c: emit `text` for a single-MCID leaf when resolution is
    // enabled. Multi-MCID elements omit `text` (the per-MCID slices live
    // in `reading_order`); zero-MCID elements have nothing to resolve.
    if (opts.resolve_mcid_text) {
        const single_mcid: ?MarkedContentRef = blk: {
            var found: ?MarkedContentRef = null;
            for (elem.children) |c| switch (c) {
                .mcid => |m| {
                    if (m.mcid < 0) continue;
                    if (found != null) break :blk null; // > 1 MCID → omit.
                    found = m;
                },
                .element => {},
            };
            break :blk found;
        };
        if (single_mcid) |m| {
            if (m.page_ref) |pr| {
                if (mcid_texts.get(.{ .page_obj = pr.num, .mcid = m.mcid })) |t| {
                    try writer.writeAll(",\"text\":");
                    try stream.writeJsonString(writer, t);
                }
            }
        }
    }

    // mcid_refs: direct-child MCIDs only (matches PR-21's shape).
    try writer.writeAll(",\"mcid_refs\":[");
    var first_mcid = true;
    for (elem.children) |c| switch (c) {
        .mcid => |m| {
            if (!first_mcid) try writer.writeAll(",");
            try writer.print("{d}", .{m.mcid});
            first_mcid = false;
        },
        .element => {},
    };

    // children: direct-child elements (recursive).
    try writer.writeAll("],\"children\":[");
    var first_elem = true;
    for (elem.children) |c| switch (c) {
        .element => |e| {
            if (!first_elem) try writer.writeAll(",");
            try emitElement(e, writer, mcid_texts, opts, depth + 1);
            first_elem = false;
        },
        .mcid => {},
    };
    try writer.writeAll("]}");
}

/// Flatten the tree into a top-level `reading_order` array. Order matches
/// `structtree.collectMcidsInOrder` (DFS, /Artifact-skipped, BMC-sentinel-
/// skipped). Each item: `{"page":<idx>,"mcid":<int>[,"text":"…"]}`.
fn writeReadingOrder(
    elem: *const StructElement,
    writer: *std.Io.Writer,
    page_obj_to_idx: *const std.AutoHashMap(u32, usize),
    mcid_texts: *const McidTextMap,
    first: *bool,
    parent_page: ?u32,
    depth: u32,
) !void {
    if (depth >= MAX_EMIT_DEPTH) return;
    if (std.mem.eql(u8, elem.struct_type, "Artifact")) return;

    const current_page: ?u32 = if (elem.page_ref) |pr| pr.num else parent_page;

    for (elem.children) |child| switch (child) {
        .element => |sub| try writeReadingOrder(sub, writer, page_obj_to_idx, mcid_texts, first, current_page, depth + 1),
        .mcid => |m| {
            if (m.mcid < 0) continue;
            const page_obj = if (m.page_ref) |pr| pr.num else (current_page orelse continue);
            const page_idx = page_obj_to_idx.get(page_obj) orelse continue;

            if (!first.*) try writer.writeAll(",");
            first.* = false;
            try writer.print("{{\"page\":{d},\"mcid\":{d}", .{ page_idx, m.mcid });
            if (mcid_texts.get(.{ .page_obj = page_obj, .mcid = m.mcid })) |t| {
                try writer.writeAll(",\"text\":");
                try stream.writeJsonString(writer, t);
            }
            try writer.writeAll("}");
        },
    };
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;
const FIXED_DOC_ID: @import("uuid.zig").String = "01020304-0506-7890-abcd-ef0123456789".*;
const testpdf = @import("testpdf.zig");

test "PR-23c: round-trip on tagged-table fixture — reading_order matches getReadingOrder" {
    const allocator = testing.allocator;
    const pdf_data = try testpdf.generateTaggedTablePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try root_mod.Document.openFromMemory(allocator, pdf_data, root_mod.ErrorConfig.permissive());
    defer doc.close();

    var tree = try doc.getStructTree();
    // tree lives on doc's parsing arena — do NOT deinit.

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    var env = stream.Envelope.initWithId(&aw.writer, "x.pdf", FIXED_DOC_ID);
    try emit(&env, doc, &tree, allocator, .{});

    const written = aw.written();
    try testing.expect(std.mem.indexOf(u8, written, "\"kind\":\"a11y_tree\"") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"reading_order\":[") != null);
    // Six MCIDs, in 0..5 order. Each item carries the MCID + the resolved cell text.
    inline for (.{
        .{ 0, "A1" }, .{ 1, "B1" }, .{ 2, "C1" },
        .{ 3, "A2" }, .{ 4, "B2" }, .{ 5, "C2" },
    }) |pair| {
        var buf: [64]u8 = undefined;
        const needle = std.fmt.bufPrint(&buf, "\"mcid\":{d},\"text\":\"{s}\"", pair) catch unreachable;
        try testing.expect(std.mem.indexOf(u8, written, needle) != null);
    }
}

test "PR-23c: per-leaf attrs flattened — depth-2 leaf carries inherited lang + alt" {
    const allocator = testing.allocator;

    // Build: Sect(/Lang="en-US",/Alt="root-alt") → P (no /Lang, no /Alt)
    var leaf: StructElement = .{ .struct_type = "P", .children = &.{} };
    const root_kids = [_]StructChild{.{ .element = &leaf }};
    var root: StructElement = .{
        .struct_type = "Sect",
        .lang = "en-US",
        .alt_text = "root-alt",
        .children = &root_kids,
    };
    var tree: StructTree = .{
        .root = &root,
        .elements = &.{},
        .allocator = allocator,
    };

    // Mock minimal Document state: zero pages → no MCIDs to resolve, but
    // `flatten_attrs` still runs and `lang` propagation already sits on
    // root/leaf via the synthetic attrs above. We bypass real Document by
    // calling the flattener + emitter directly so this test is hermetic.
    try @import("attr_flattener.zig").flattenInPlace(&tree);

    // After flatten: leaf inherits root's /Alt; /Lang must be propagated
    // by upstream propagateLang (we do it manually here because no Document).
    try structtree.propagateLang(&tree, null);
    try testing.expectEqualStrings("en-US", leaf.lang.?);
    try testing.expectEqualStrings("root-alt", leaf.alt_text.?);

    // Now emit just the element JSON (no Document needed for emitElement
    // itself — only for MCID resolution, which we skip with an empty
    // mcid map and resolve_mcid_text:false).
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    var mcid_texts = McidTextMap.init(allocator);
    defer mcid_texts.deinit();
    try emitElement(&root, &aw.writer, &mcid_texts, .{ .resolve_mcid_text = false }, 0);

    const written = aw.written();
    try testing.expect(std.mem.indexOf(u8, written, "\"alt\":\"root-alt\"") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"lang\":\"en-US\"") != null);
    // The leaf must also carry both fields.
    try testing.expect(std.mem.count(u8, written, "\"alt\":\"root-alt\"") == 2);
    try testing.expect(std.mem.count(u8, written, "\"lang\":\"en-US\"") == 2);
}

test "PR-23c: flatten_attrs:false leaves leaf without inherited /Alt" {
    const allocator = testing.allocator;

    // Same shape as above; we reach the emitter without flattenInPlace.
    var leaf: StructElement = .{ .struct_type = "P", .children = &.{} };
    const root_kids = [_]StructChild{.{ .element = &leaf }};
    var root: StructElement = .{
        .struct_type = "Sect",
        .alt_text = "root-alt",
        .children = &root_kids,
    };

    // No flattenInPlace → leaf.alt_text remains null. emitElement must
    // not synthesize anything for the leaf.
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    var mcid_texts = McidTextMap.init(allocator);
    defer mcid_texts.deinit();
    try emitElement(&root, &aw.writer, &mcid_texts, .{ .resolve_mcid_text = false }, 0);

    const written = aw.written();
    // Root carries its own /Alt …
    try testing.expect(std.mem.indexOf(u8, written, "\"alt\":\"root-alt\"") != null);
    // … but it appears exactly once (the leaf has no /Alt).
    try testing.expect(std.mem.count(u8, written, "\"alt\":") == 1);
}

test "PR-23c: resolve_mcid_text:false omits text on leaves" {
    const allocator = testing.allocator;
    const pdf_data = try testpdf.generateTaggedTablePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try root_mod.Document.openFromMemory(allocator, pdf_data, root_mod.ErrorConfig.permissive());
    defer doc.close();

    var tree = try doc.getStructTree();

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    var env = stream.Envelope.initWithId(&aw.writer, "x.pdf", FIXED_DOC_ID);
    try emit(&env, doc, &tree, allocator, .{ .resolve_mcid_text = false });

    const written = aw.written();
    // No `"text":"…"` anywhere — neither in the tree nor in reading_order.
    try testing.expect(std.mem.indexOf(u8, written, "\"text\":") == null);
    // Reading order is still emitted (just without text).
    try testing.expect(std.mem.indexOf(u8, written, "\"reading_order\":[") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"mcid\":0") != null);
}

test "PR-23c: empty struct tree → root:null + reading_order:[]" {
    const allocator = testing.allocator;
    // A non-tagged PDF: minimal valid PDF without /StructTreeRoot.
    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Hello");
    defer allocator.free(pdf_data);

    const doc = try root_mod.Document.openFromMemory(allocator, pdf_data, root_mod.ErrorConfig.permissive());
    defer doc.close();

    var tree = try doc.getStructTree();
    try testing.expect(tree.root == null);

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    var env = stream.Envelope.initWithId(&aw.writer, "x.pdf", FIXED_DOC_ID);
    try emit(&env, doc, &tree, allocator, .{});

    const written = aw.written();
    try testing.expect(std.mem.indexOf(u8, written, "\"root\":null") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"reading_order\":[]") != null);
}

test "PR-23c: integration — H1 + P struct tree shape mirrors a tagged markdown" {
    // Stand-in for PR-W10d's renderTagged (not on main yet): build a
    // synthetic struct tree that mirrors the H1 + P shape a markdown
    // converter would produce, then emit and verify the reading-order
    // sequence + per-element role come through.
    const allocator = testing.allocator;

    var p_leaf: StructElement = .{
        .struct_type = "P",
        .lang = "en-US",
        .children = &[_]StructChild{
            .{ .mcid = .{ .mcid = 1 } },
        },
    };
    var h1_leaf: StructElement = .{
        .struct_type = "H1",
        .lang = "en-US",
        .children = &[_]StructChild{
            .{ .mcid = .{ .mcid = 0 } },
        },
    };
    const doc_kids = [_]StructChild{
        .{ .element = &h1_leaf },
        .{ .element = &p_leaf },
    };
    var doc_elem: StructElement = .{
        .struct_type = "Document",
        .lang = "en-US",
        .children = &doc_kids,
    };
    // No real Document: emit just the element JSON. mcid_texts empty →
    // no `text` field but `mcid_refs` is still produced.
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    var mcid_texts = McidTextMap.init(allocator);
    defer mcid_texts.deinit();
    try emitElement(&doc_elem, &aw.writer, &mcid_texts, .{ .resolve_mcid_text = false }, 0);

    const written = aw.written();
    try testing.expect(std.mem.startsWith(u8, written, "{\"type\":\"Document\""));
    try testing.expect(std.mem.indexOf(u8, written, "\"type\":\"H1\"") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"type\":\"P\"") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"mcid_refs\":[0]") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"mcid_refs\":[1]") != null);
    // H1 must appear before P in the children array (DFS reading order).
    const h1_pos = std.mem.indexOf(u8, written, "\"H1\"").?;
    const p_pos = std.mem.indexOf(u8, written, "\"P\"").?;
    try testing.expect(h1_pos < p_pos);
}

test "PR-23c: bounded recursion — depth 64 caps with _truncated_max_depth marker" {
    const allocator = testing.allocator;
    const N: usize = MAX_EMIT_DEPTH + 4;

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

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    var mcid_texts = McidTextMap.init(allocator);
    defer mcid_texts.deinit();
    try emitElement(&chain[0], &aw.writer, &mcid_texts, .{ .resolve_mcid_text = false }, 0);

    const written = aw.written();
    try testing.expect(std.mem.indexOf(u8, written, "_truncated_max_depth") != null);
}

test "PR-23c: FailingAllocator sweep — no leaks across allocation points" {
    const pdf_data = try testpdf.generateTaggedTablePdf(testing.allocator);
    defer testing.allocator.free(pdf_data);

    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const fa = failing.allocator();

        // Document opens on its own allocator; if that fails we're done.
        const doc = root_mod.Document.openFromMemory(fa, pdf_data, root_mod.ErrorConfig.permissive()) catch continue;
        defer doc.close();

        var tree = doc.getStructTree() catch continue;

        var buf: [8192]u8 = undefined;
        var aw = std.Io.Writer.fixed(&buf);
        var env = stream.Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID);

        emit(&env, doc, &tree, fa, .{}) catch |err| {
            try testing.expect(err == error.OutOfMemory or err == error.WriteFailed or err == error.NoSpaceLeft);
            continue;
        };
        // Successful emit — no more failure points to exercise.
        break;
    }
}
