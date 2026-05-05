//! PR-23a: MCID → text resolver
//!
//! Walks a page's content stream once, collecting the UTF-8 text bytes
//! that fall between BDC/EMC pairs whose MCID matches the caller's
//! query. Reuses `structtree.MarkedContentExtractor` (declared at
//! `structtree.zig::543`) — this module is just a thin caller-owned
//! surface around `Document.buildMarkedContentExtractor`.
//!
//! ## Why `*anyopaque` for `Document`?
//!
//! `structtree.zig` is imported by `root.zig` (where `Document` lives),
//! so `structtree` cannot back-import `root.zig` without a circular
//! dependency. PR-SX1 already pre-staged this dependency direction by
//! making `structtree.resolveMcidText` take `doc: *anyopaque`. This
//! file does the same thing: callers pass `@ptrCast(doc)` and we cast
//! back to `*Document` at the boundary. The contract is:
//!
//!   - Caller MUST pass a non-null `*Document` (alignment-correct).
//!   - We trap on a misaligned/null cast in Debug/ReleaseSafe via
//!     `@alignCast`'s safety check.
//!   - In ReleaseFast a wrong-type pointer is UB — same as a C void*
//!     misuse. Don't do that.
//!
//! ## Bounded reads
//!
//! `MAX_MCID_TEXT_BYTES` (1 MB) is the hard cap on resolved-text size
//! per MCID. A pathological content stream with a missing EMC could
//! otherwise accumulate the rest of the page into one MCID's buffer.
//! At 1 MB we truncate and return what we have — see
//! `[TigerStyle]` "negative-space asserts": this is the negative
//! space saying "an MCID's text doesn't exceed a megabyte."

const std = @import("std");
const structtree = @import("structtree.zig");
const root = @import("root.zig");

const Document = root.Document;
const MarkedContentExtractor = structtree.MarkedContentExtractor;

/// Hard cap on resolved text size per MCID (1 MB). A content stream
/// missing EMC could otherwise accumulate unbounded data into one MCID
/// bucket. We truncate and return the prefix we've collected.
pub const MAX_MCID_TEXT_BYTES: usize = 1 * 1024 * 1024;

/// PR-23a: a resolved span — the MCID's text, the page it lives on,
/// and (when bounds become available downstream) its bbox. PR-23a
/// itself does not populate `bbox`; PR-23b/23c hook bounds in.
pub const ResolvedSpan = struct {
    page_idx: usize,
    mcid: i32,
    text: []const u8,
    bbox: ?[4]f64 = null,
};

/// Walk `page_idx`'s content stream once, return the concatenated text
/// bytes inside any BDC/EMC pair whose MCID matches `mcid`. Caller
/// owns the result (allocated from `allocator`) — free with
/// `allocator.free(text)`. Returns `null` when:
///   - `mcid == -1` (BMC sentinel from PR-22c — no MCID to match)
///   - the MCID is not present on this page (e.g. it lives on a
///     different page in a multi-page document)
pub fn resolveOne(
    doc: *anyopaque,
    page_idx: usize,
    mcid: i32,
    allocator: std.mem.Allocator,
) !?[]const u8 {
    // PR-22c: BMC entries (no MCID property dict) are surfaced as
    // mcid = -1. There is no text to resolve for them — return null
    // rather than scanning the whole stream.
    if (mcid == -1) return null;

    const document: *Document = @ptrCast(@alignCast(doc));

    const extractor = try document.buildMarkedContentExtractor(page_idx, allocator);
    defer {
        extractor.deinit();
        allocator.destroy(extractor);
    }

    const text = extractor.getTextForMcid(mcid) orelse return null;

    // Bounded: cap per-MCID text at MAX_MCID_TEXT_BYTES. Truncation
    // is silent — the caller sees a 1 MB prefix, which is still
    // strictly more useful than failing. A future PR could surface
    // a `truncated: bool` field if downstream needs to know.
    const len = @min(text.len, MAX_MCID_TEXT_BYTES);
    const owned = try allocator.alloc(u8, len);
    errdefer allocator.free(owned);
    @memcpy(owned, text[0..len]);
    return owned;
}

/// Batch resolve. Walks the content stream **once** for the whole
/// `mcids` slice — strictly cheaper than `mcids.len` individual
/// `resolveOne` calls when several MCIDs live on the same page.
///
/// Returns a slice of optional text, parallel to `mcids`. Each
/// `Some(text)` is allocated from `allocator` and caller-owned;
/// each `None` means the MCID was not found on this page (or is the
/// BMC sentinel).
///
/// Caller must free both: each non-null `result[i]` and the outer
/// slice `result` itself.
pub fn resolveBatch(
    doc: *anyopaque,
    page_idx: usize,
    mcids: []const i32,
    allocator: std.mem.Allocator,
) ![]?[]const u8 {
    const document: *Document = @ptrCast(@alignCast(doc));

    var results = try allocator.alloc(?[]const u8, mcids.len);
    @memset(results, null);
    errdefer {
        for (results) |maybe| if (maybe) |t| allocator.free(t);
        allocator.free(results);
    }

    // Empty-input fast path: no need to walk the content stream.
    if (mcids.len == 0) return results;

    const extractor = try document.buildMarkedContentExtractor(page_idx, allocator);
    defer {
        extractor.deinit();
        allocator.destroy(extractor);
    }

    for (mcids, 0..) |m, i| {
        if (m == -1) continue; // BMC sentinel; leave null
        const text = extractor.getTextForMcid(m) orelse continue;
        const len = @min(text.len, MAX_MCID_TEXT_BYTES);
        const owned = try allocator.alloc(u8, len);
        // No errdefer-free here — the outer `errdefer` walks
        // `results[0..i]` plus already-set later slots and frees
        // them. Once we assign `results[i] = owned`, ownership is
        // transferred into the result vector.
        @memcpy(owned, text[0..len]);
        results[i] = owned;
    }

    return results;
}

/// Opt-in companion to `structtree.parseStructTree`. Parses the tree,
/// then walks each `StructElement`'s direct-child MCIDs and populates
/// `mcid_text` with the concatenated bytes. The text is allocated from
/// the same allocator as the tree, so a single `tree.deinit()` plus a
/// dedicated free of every populated `mcid_text` cleans everything
/// up — see the helper `freeMcidTexts` below.
///
/// Why opt-in: existing callers expect `parseStructTree` to be a pure
/// structural walk with no content-stream side-effects. Adding the
/// content-stream walk to the default path would surprise them and
/// regress allocation budget on docs that don't need MCID text.
pub fn parseStructTreeWithMcidText(
    allocator: std.mem.Allocator,
    doc: *anyopaque,
) !structtree.StructTree {
    const document: *Document = @ptrCast(@alignCast(doc));

    var tree = try document.getStructTree();
    errdefer tree.deinit();

    // Build a per-page index: page object number → 0-based page index.
    // The struct-tree stores `page_ref` as an `ObjRef`, but our
    // resolver needs an index. Cache once for the duration of the walk.
    var page_obj_to_idx = std.AutoHashMap(u32, usize).init(allocator);
    defer page_obj_to_idx.deinit();
    for (document.pages.items, 0..) |p, idx| {
        try page_obj_to_idx.put(p.ref.num, idx);
    }

    // Cache extractors per page so a doc with many MCIDs/page still
    // walks each content stream only once.
    var extractor_cache = std.AutoHashMap(usize, *MarkedContentExtractor).init(allocator);
    defer {
        var it = extractor_cache.valueIterator();
        while (it.next()) |ep| {
            ep.*.deinit();
            allocator.destroy(ep.*);
        }
        extractor_cache.deinit();
    }

    for (tree.elements) |elem| {
        // Skip: no children at all, or no MCID children. Avoids
        // building an extractor for elements that don't need one.
        var mcid_count: usize = 0;
        for (elem.children) |c| switch (c) {
            .mcid => mcid_count += 1,
            .element => {},
        };
        if (mcid_count == 0) continue;

        // Fold all direct-child MCIDs into a single concatenated
        // string. We trust the struct-tree-imposed order.
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);

        for (elem.children) |c| {
            const mcr = switch (c) {
                .mcid => |m| m,
                .element => continue,
            };
            if (mcr.mcid == -1) continue;
            const page_obj = if (mcr.page_ref) |pr| pr.num else if (elem.page_ref) |pr| pr.num else continue;
            const page_idx = page_obj_to_idx.get(page_obj) orelse continue;

            const gop = try extractor_cache.getOrPut(page_idx);
            if (!gop.found_existing) {
                const ex = document.buildMarkedContentExtractor(page_idx, allocator) catch |err| {
                    _ = extractor_cache.remove(page_idx);
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    continue;
                };
                gop.value_ptr.* = ex;
            }
            const extractor = gop.value_ptr.*;

            const text = extractor.getTextForMcid(mcr.mcid) orelse continue;
            const remaining = MAX_MCID_TEXT_BYTES - @min(buf.items.len, MAX_MCID_TEXT_BYTES);
            const take = @min(text.len, remaining);
            try buf.appendSlice(allocator, text[0..take]);
            if (take < text.len) break; // hit cap
        }

        if (buf.items.len > 0) {
            elem.mcid_text = try buf.toOwnedSlice(allocator);
        } else {
            buf.deinit(allocator);
        }
    }

    return tree;
}

/// Companion to `parseStructTreeWithMcidText`: free every populated
/// `mcid_text` slice. Tree's own deinit handles `children` + element
/// pointers but not the opt-in mcid_text (which we allocated on the
/// caller's allocator). Must be called BEFORE `tree.deinit()`.
pub fn freeMcidTexts(tree: *const structtree.StructTree, allocator: std.mem.Allocator) void {
    for (tree.elements) |elem| {
        if (elem.mcid_text) |t| {
            allocator.free(t);
            elem.mcid_text = null;
        }
    }
}

// =====================================================================
// Tests
// ---------------------------------------------------------------------
// Fixture: testpdf.generateTaggedTablePdf — single-page tagged PDF
// with a 2×3 table whose six TD cells carry MCIDs 0..5 and texts
// A1/B1/C1/A2/B2/C2.
// =====================================================================

const testpdf = @import("testpdf.zig");

test "PR-23a: resolveOne returns the MCID's bracketed text" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateTaggedTablePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try Document.openFromMemory(allocator, pdf_data, root.ErrorConfig.default());
    defer doc.close();

    const text = try resolveOne(@ptrCast(doc), 0, 0, allocator);
    try std.testing.expect(text != null);
    defer allocator.free(text.?);
    try std.testing.expectEqualStrings("A1", text.?);
}

test "PR-23a: resolveOne returns null for BMC sentinel (mcid == -1)" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateTaggedTablePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try Document.openFromMemory(allocator, pdf_data, root.ErrorConfig.default());
    defer doc.close();

    const text = try resolveOne(@ptrCast(doc), 0, -1, allocator);
    try std.testing.expect(text == null);
}

test "PR-23a: resolveOne returns null for missing MCID" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateTaggedTablePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try Document.openFromMemory(allocator, pdf_data, root.ErrorConfig.default());
    defer doc.close();

    // MCID 99 doesn't exist in the fixture (it has 0..5 only).
    const text = try resolveOne(@ptrCast(doc), 0, 99, allocator);
    try std.testing.expect(text == null);
}

test "PR-23a: resolveBatch resolves multiple MCIDs in one stream walk" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateTaggedTablePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try Document.openFromMemory(allocator, pdf_data, root.ErrorConfig.default());
    defer doc.close();

    const mcids = [_]i32{ 0, 1, 99, -1, 5 };
    const results = try resolveBatch(@ptrCast(doc), 0, &mcids, allocator);
    defer {
        for (results) |maybe| if (maybe) |t| allocator.free(t);
        allocator.free(results);
    }

    try std.testing.expect(results[0] != null);
    try std.testing.expectEqualStrings("A1", results[0].?);
    try std.testing.expect(results[1] != null);
    try std.testing.expectEqualStrings("B1", results[1].?);
    try std.testing.expect(results[2] == null); // mcid 99: not on page
    try std.testing.expect(results[3] == null); // BMC sentinel
    try std.testing.expect(results[4] != null);
    try std.testing.expectEqualStrings("C2", results[4].?);
}

test "PR-23a: resolveBatch with empty input returns empty slice" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateTaggedTablePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try Document.openFromMemory(allocator, pdf_data, root.ErrorConfig.default());
    defer doc.close();

    const empty: []const i32 = &.{};
    const results = try resolveBatch(@ptrCast(doc), 0, empty, allocator);
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "PR-23a: resolveOne errors on out-of-range page index" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateTaggedTablePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try Document.openFromMemory(allocator, pdf_data, root.ErrorConfig.default());
    defer doc.close();

    // Fixture has one page (idx 0). Page 1 is out of range; an MCID
    // belonging to that page can never be found via this call.
    const result = resolveOne(@ptrCast(doc), 1, 0, allocator);
    try std.testing.expectError(error.PageNotFound, result);
}

test "PR-23a: parseStructTreeWithMcidText populates mcid_text on TD elements" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateTaggedTablePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try Document.openFromMemory(allocator, pdf_data, root.ErrorConfig.default());
    defer doc.close();

    var tree = try parseStructTreeWithMcidText(allocator, @ptrCast(doc));
    defer {
        freeMcidTexts(&tree, allocator);
        tree.deinit();
    }

    // Walk all elements: every TD should have a 2-byte mcid_text
    // matching its cell label.
    var td_count: usize = 0;
    for (tree.elements) |elem| {
        if (std.mem.eql(u8, elem.struct_type, "TD")) {
            td_count += 1;
            try std.testing.expect(elem.mcid_text != null);
            try std.testing.expectEqual(@as(usize, 2), elem.mcid_text.?.len);
        }
    }
    try std.testing.expectEqual(@as(usize, 6), td_count);
}

test "PR-23a: structtree.resolveMcidText delegates to mcid_resolver" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateTaggedTablePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try Document.openFromMemory(allocator, pdf_data, root.ErrorConfig.default());
    defer doc.close();

    const text = try structtree.resolveMcidText(@ptrCast(doc), 0, 2, allocator);
    try std.testing.expect(text != null);
    defer allocator.free(text.?);
    try std.testing.expectEqualStrings("C1", text.?);
}
