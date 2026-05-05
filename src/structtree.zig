//! PDF Structure Tree Parser
//!
//! Parses the document's logical structure tree (StructTreeRoot) to enable
//! reading order extraction based on semantic tagging (PDF/UA, Tagged PDF).
//!
//! Structure tree elements define the logical reading order through:
//! - /S (structure type): Document, Part, Sect, P, H1-H6, Table, TR, TH, TD, etc.
//! - /K (kids): child elements or MCIDs (marked content IDs)
//! - /P (parent): parent element reference
//!
//! MCIDs link structure elements to content via BDC/EMC operators in content streams.

const std = @import("std");
const parser = @import("parser.zig");
const pagetree = @import("pagetree.zig");
const xref_mod = @import("xref.zig");
const stream = @import("stream.zig");

const Object = parser.Object;
const ObjRef = parser.ObjRef;
const XRefTable = xref_mod.XRefTable;

/// PR-SX1: minimal type alias for the wave-3.2 RoleMap parser. Today's
/// stub takes the catalog as a parsed `Object.Dict` and a resolver
/// callback so PR-22b can walk `/RoleMap` without re-importing parser
/// internals on top of what `parseStructTree` already imports.
pub const ObjectDict = parser.Object.Dict;

/// PR-SX1: resolver callback shape for wave-3.2 stubs. The opaque
/// context is carried through so callers can supply their own
/// (allocator, data, xref, cache) tuple without leaking concrete types
/// into this file. PR-22b's body will call `resolve_fn(ctx, ref)` to
/// dereference `/RoleMap` entries that are themselves indirect.
pub const ResolveFn = *const fn (ctx: *anyopaque, ref: ObjRef) anyerror!Object;

/// A node in the structure tree
pub const StructElement = struct {
    /// Structure type (Document, Part, Sect, P, H1, Table, TR, TD, Figure, etc.)
    struct_type: []const u8,
    /// Title/alt text if present
    title: ?[]const u8 = null,
    alt_text: ?[]const u8 = null,
    /// PR-22e: `/ActualText` content. Per ISO 32000-1 §14.9.4
    /// `/ActualText` substitutes the natural-language string a screen
    /// reader should announce in place of the structure's marked
    /// content. PDF/UA-1 §7.3 accepts `/ActualText` as a valid
    /// substitute for `/Alt` on Figure/Formula/Form. Today only
    /// populated by parseStructElement / parseKids when present on
    /// the source dict; the validator accepts either field.
    actual_text: ?[]const u8 = null,
    /// Children: either more elements or MCIDs
    children: []const StructChild,
    /// Page reference (if this element is on a specific page)
    page_ref: ?ObjRef = null,

    // -- PR-SX1: nullable extension slots --------------------------------
    // Pre-staged so wave-3.2 PRs (22b, 22d, 23a) can each fill in one
    // slot without touching the struct definition. Today they are always
    // null; `emitElementJson` does NOT serialize them, so the existing
    // `--struct-tree` JSON output remains byte-identical. Each consumer
    // PR will add the matching JSON key once the field is populated.

    /// Populated by PR-22d (`/Lang` propagation). BCP-47 tag inherited
    /// from `StructTreeRoot` → ancestor → leaf. Today: always null.
    lang: ?[]const u8 = null,

    /// Populated by PR-22b (`/RoleMap` resolution). Standard PDF/UA
    /// structure type that `struct_type` resolves to via the catalog's
    /// `/RoleMap`. Today: always null.
    resolved_role: ?[]const u8 = null,

    /// Populated by PR-23a (MCID → text resolver). The text bytes the
    /// element's MCID brackets in its page's content stream, owned by
    /// the same allocator that built the tree. Today: always null.
    mcid_text: ?[]const u8 = null,
};

/// Child of a structure element - either another element or a marked content reference
pub const StructChild = union(enum) {
    /// Reference to another structure element
    element: *const StructElement,
    /// Marked Content ID on a page
    mcid: MarkedContentRef,
};

/// Reference to marked content in a page's content stream
pub const MarkedContentRef = struct {
    /// The MCID value
    mcid: i32,
    /// Page reference (if different from parent)
    page_ref: ?ObjRef = null,
    /// Content stream reference (for XObjects)
    stream_ref: ?ObjRef = null,
};

/// Parsed structure tree
pub const StructTree = struct {
    /// Root element (typically /Document)
    root: ?*const StructElement,
    /// All elements as individual heap allocations (stable pointers, used for cleanup)
    elements: []*StructElement,
    /// Allocator used
    allocator: std.mem.Allocator,

    pub fn deinit(self: *StructTree) void {
        for (self.elements) |elem| {
            self.allocator.free(elem.children);
            self.allocator.destroy(elem);
        }
        self.allocator.free(self.elements);
    }

    /// Get reading order as a flat list of MCIDs per page
    /// Returns a map: page_index -> []MarkedContentRef in reading order
    pub fn getReadingOrder(self: *const StructTree, allocator: std.mem.Allocator) !std.AutoHashMap(usize, std.ArrayList(MarkedContentRef)) {
        var result = std.AutoHashMap(usize, std.ArrayList(MarkedContentRef)).init(allocator);
        errdefer {
            var it = result.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(allocator);
            }
            result.deinit();
        }

        if (self.root) |root| {
            try collectMcidsInOrder(root, &result, allocator, null, 0);
        }

        return result;
    }
};

/// PR-21 [feat]: emit a `StructElement` (and its full subtree) as
/// JSON into `writer`. Schema per node:
///
///   { "type": "Sect",
///     ["alt": "Section title",]
///     ["page_obj": <PDF object number>,]
///     "mcid_refs": [3, 4, 5],
///     "children": [<recursive>] }
///
/// `mcid_refs` collects every direct-child MCID; `children` collects
/// only direct-child elements (so the tree shape is recursive on
/// `children` alone). Depth is bounded by `MAX_STRUCT_DEPTH` to match
/// the parser's invariant. `page_obj` is emitted as the raw PDF
/// object number (not a 0-based page index) — the consumer correlates
/// against `kind:"meta"` / `kind:"page"` records if they need indices.
pub fn emitElementJson(elem: *const StructElement, writer: *std.Io.Writer, depth: u32) !void {
    if (depth >= MAX_STRUCT_DEPTH) {
        // Safety net: emit a marker leaf to keep the JSON parseable.
        try writer.writeAll("{\"type\":\"_truncated_max_depth\",\"mcid_refs\":[],\"children\":[]}");
        return;
    }

    try writer.writeAll("{\"type\":");
    try stream.writeJsonString(writer, elem.struct_type);
    if (elem.alt_text) |alt| {
        try writer.writeAll(",\"alt\":");
        try stream.writeJsonString(writer, alt);
    }
    if (elem.title) |t| {
        try writer.writeAll(",\"title\":");
        try stream.writeJsonString(writer, t);
    }
    if (elem.page_ref) |pr| {
        try writer.print(",\"page_obj\":{d}", .{pr.num});
    }
    // PR-22b: emit `/RoleMap`-resolved standard structure type when the
    // alias chain resolved (else null = field omitted). Placement
    // (after page_obj, before mcid_refs) keeps the byte-identical SX1
    // golden valid for any element that has no /RoleMap entry.
    if (elem.resolved_role) |role| {
        try writer.writeAll(",\"resolved_role\":");
        try stream.writeJsonString(writer, role);
    }
    // PR-22d: emit BCP-47 `/Lang` (explicit or inherited from
    // ancestor / catalog). Only present when non-null, so the
    // pre-22d byte-identical golden remains stable on /Lang-free
    // fixtures.
    if (elem.lang) |l| {
        try writer.writeAll(",\"lang\":");
        try stream.writeJsonString(writer, l);
    }

    // Direct-child MCIDs first.
    try writer.writeAll(",\"mcid_refs\":[");
    var first_mcid = true;
    for (elem.children) |c| {
        switch (c) {
            .mcid => |m| {
                if (!first_mcid) try writer.writeAll(",");
                try writer.print("{d}", .{m.mcid});
                first_mcid = false;
            },
            .element => {},
        }
    }

    // Direct-child elements (recursive).
    try writer.writeAll("],\"children\":[");
    var first_elem = true;
    for (elem.children) |c| {
        switch (c) {
            .element => |e| {
                if (!first_elem) try writer.writeAll(",");
                try emitElementJson(e, writer, depth + 1);
                first_elem = false;
            },
            .mcid => {},
        }
    }
    try writer.writeAll("]}");
}

const MAX_STRUCT_DEPTH: u32 = 256;

// =====================================================================
// PR-SX1: wave-3.2 public-API stubs
// ---------------------------------------------------------------------
// Each function below is a no-op today; the body comment names the
// wave-3.2 PR that will fill it in. Signatures are pre-staged to match
// what the consuming PRs need so SX1's `feat/sx1-...` worktree merges
// cleanly with 22b, 22d, 22e, and 23a in parallel.
// =====================================================================

/// PR-22b: ISO 32000-1 §14.8.4 standard structure types. Custom roles
/// in `/RoleMap` must ultimately resolve to a member of this set; a
/// chain that ends elsewhere returns `error.RoleMapResolvesToNonStandard`.
const STANDARD_STRUCTURE_TYPES = [_][]const u8{
    "Document", "Part",      "Art",     "Sect",     "Div",
    "BlockQuote", "Caption", "TOC",     "TOCI",     "Index",
    "NonStruct", "Private",  "H",       "H1",       "H2",
    "H3",        "H4",       "H5",      "H6",       "P",
    "L",         "LI",       "LBody",   "Lbl",      "Span",
    "Quote",     "Note",     "Reference", "BibEntry", "Code",
    "Link",      "Annot",    "Ruby",    "Warichu",  "Figure",
    "Formula",   "Form",     "Table",   "TR",       "TH",
    "TD",        "THead",    "TBody",   "TFoot",    "Artifact",
};

/// PR-22b: max chain length when following `A → B → C → ...`. A
/// well-formed RoleMap shouldn't need more than one hop in practice; 8
/// gives slack for layered author tooling without admitting a cycle.
const MAX_ROLEMAP_CHAIN: u8 = 8;

fn isStandardStructureType(name: []const u8) bool {
    for (STANDARD_STRUCTURE_TYPES) |std_name| {
        if (std.mem.eql(u8, std_name, name)) return true;
    }
    return false;
}

/// PR-22b: parse `/RoleMap` from the StructTreeRoot dict (the SX1 stub
/// names the parameter `catalog`; semantically it's the dict that may
/// carry `/RoleMap`). For each entry, follow the alias chain — bounded
/// by `MAX_ROLEMAP_CHAIN`, with self- and cycle-detection — until a
/// standard PDF/UA structure type is reached. Then walk `tree.elements`
/// and set `resolved_role` on every element whose `struct_type` is a
/// key in the map.
///
/// Errors:
/// - `error.RoleMapCycle` — chain repeats or exceeds `MAX_ROLEMAP_CHAIN`.
/// - `error.RoleMapResolvesToNonStandard` — chain terminates outside the
///   ISO 32000-1 §14.8.4 standard-types set.
///
/// Soft-fails (returns successfully, no resolution) when:
/// - `/RoleMap` is absent.
/// - `/RoleMap` is present but not a dict (or resolves via ref to a
///   non-dict).
///
/// `resolve_fn` is invoked to dereference `/RoleMap` itself when it is
/// stored as an indirect reference. Map values are typically inline
/// names; if a value happens to be a `.reference`, `resolve_fn` is also
/// used to look it up.
pub fn parseRoleMap(
    tree: *StructTree,
    catalog: ObjectDict,
    resolve_fn: ResolveFn,
    resolve_ctx: *anyopaque,
) !void {
    // Look up /RoleMap. May be inline dict or indirect ref.
    const rolemap_obj = catalog.get("RoleMap") orelse return;
    const rolemap_dict = switch (rolemap_obj) {
        .dict => |d| d,
        .reference => |r| blk: {
            const resolved = resolve_fn(resolve_ctx, r) catch return;
            break :blk switch (resolved) {
                .dict => |d| d,
                else => return,
            };
        },
        else => return,
    };

    // Bounded read: empty map = nothing to do.
    if (rolemap_dict.entries.len == 0) return;

    // Walk every element; for each one whose struct_type matches a
    // /RoleMap key, follow the chain to a standard type. Each lookup
    // is independent so a non-matching element costs at most one
    // string compare per entry.
    for (tree.elements) |elem| {
        const direct = rolemap_dict.get(elem.struct_type) orelse continue;
        const resolved_name = try followRoleMapChain(
            rolemap_dict,
            elem.struct_type,
            direct,
            resolve_fn,
            resolve_ctx,
        );
        elem.resolved_role = resolved_name;
    }
}

/// PR-22b: follow `start` through `/RoleMap` until a standard type is
/// reached. `origin` is the element's own `struct_type`, used to
/// detect immediate self-cycles (`/A /A`). Caller has already verified
/// `origin` is a key in `rolemap`.
fn followRoleMapChain(
    rolemap: ObjectDict,
    origin: []const u8,
    start: Object,
    resolve_fn: ResolveFn,
    resolve_ctx: *anyopaque,
) ![]const u8 {
    // Resolve the first step's name (may be an indirect ref).
    var current_name = try roleMapValueName(start, resolve_fn, resolve_ctx) orelse
        return error.RoleMapResolvesToNonStandard;

    // Self-cycle: /A /A.
    if (std.mem.eql(u8, current_name, origin)) return error.RoleMapCycle;

    var hops: u8 = 0;
    while (hops < MAX_ROLEMAP_CHAIN) : (hops += 1) {
        // Terminal: current_name is a standard type — done.
        if (isStandardStructureType(current_name)) return current_name;

        // Otherwise follow another hop. If current_name isn't even a
        // key, the chain terminates outside the standard set.
        const next_obj = rolemap.get(current_name) orelse
            return error.RoleMapResolvesToNonStandard;
        const next_name = try roleMapValueName(next_obj, resolve_fn, resolve_ctx) orelse
            return error.RoleMapResolvesToNonStandard;

        // Cycle: chain returns to origin.
        if (std.mem.eql(u8, next_name, origin)) return error.RoleMapCycle;
        // Cycle: chain returns to the immediately-previous step.
        if (std.mem.eql(u8, next_name, current_name)) return error.RoleMapCycle;

        current_name = next_name;
    }
    return error.RoleMapCycle;
}

/// PR-22b: extract the name out of a /RoleMap value, following one
/// indirect reference if needed. Returns null for any non-name shape.
fn roleMapValueName(
    val: Object,
    resolve_fn: ResolveFn,
    resolve_ctx: *anyopaque,
) !?[]const u8 {
    return switch (val) {
        .name => |n| n,
        .reference => |r| blk: {
            const resolved = resolve_fn(resolve_ctx, r) catch return null;
            break :blk switch (resolved) {
                .name => |n| n,
                else => null,
            };
        },
        else => null,
    };
}

/// PR-22d: BCP-47 sanity bound. RFC 5646 §2.1 caps the longest
/// well-formed registered tag at 35 bytes; anything longer (or
/// containing control bytes / non-alnum-non-hyphen) is treated as
/// hostile/malformed and dropped to null. Bounded so a 1MB malicious
/// `/Lang` cannot propagate through the tree.
const MAX_LANG_LEN: usize = 35;

/// PR-22d: cheap structural check on a `/Lang` value before we adopt
/// it as an attribute. Accepts only ASCII alphanumerics + `-`, of
/// length 1..=MAX_LANG_LEN. Empty / oversized / pathological values
/// are rejected (caller falls back to null inheritance).
fn isValidBcp47(s: []const u8) bool {
    if (s.len == 0 or s.len > MAX_LANG_LEN) return false;
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '-';
        if (!ok) return false;
    }
    return true;
}

/// PR-22d. Top-down depth-first walk. Each element inherits its
/// nearest ancestor's effective `/Lang` (which transitively bottoms
/// out at `root_lang` — the catalog's `/Lang`). An explicit
/// element-level `/Lang` set during parsing wins and *becomes* the
/// effective lang for its subtree.
///
/// No allocations: `lang` slices borrow from the parsed-PDF backing
/// buffer (same lifetime convention as `struct_type` / `title` /
/// `alt_text`). Depth bounded by `MAX_STRUCT_DEPTH` to keep us
/// honest against pathological inputs; the parser already enforces
/// the same bound when building the tree, so this is a redundant
/// belt-and-braces check (TigerStyle pair-assertion).
pub fn propagateLang(tree: *StructTree, root_lang: ?[]const u8) !void {
    const root = tree.root orelse return;
    const effective_root = if (root_lang) |l| (if (isValidBcp47(l)) l else null) else null;
    try propagateLangWalk(@constCast(root), effective_root, 0);
}

fn propagateLangWalk(
    elem: *StructElement,
    inherited: ?[]const u8,
    depth: u32,
) !void {
    if (depth >= MAX_STRUCT_DEPTH) return error.StructTreeTooDeep;

    // Element-level explicit `/Lang` wins; otherwise inherit.
    if (elem.lang == null) {
        elem.lang = inherited;
    }
    const effective = elem.lang;

    for (elem.children) |child| {
        switch (child) {
            .element => |sub| {
                // children store *const StructElement; the underlying
                // storage is heap-owned and mutable in this pass.
                try propagateLangWalk(@constCast(sub), effective, depth + 1);
            },
            .mcid => {},
        }
    }
}

/// PR-22e: PDF/UA-1 §7.3 alt-text validator.
///
/// Walks the structure tree depth-first. Returns
///   - `error.MissingAltTextOnFigure`  for /Figure
///   - `error.MissingAltTextOnFormula` for /Formula
///   - `error.MissingAltTextOnForm`    for /Form
/// when the corresponding element lacks BOTH `/Alt` AND `/ActualText`.
/// `/ActualText` is accepted as a substitute per ISO 32000-1 §14.9.4
/// and PDF/UA-1 §7.3 (a screen reader will announce it in place of
/// the marked content).
///
/// `resolved_role` is honored when non-null: a custom role mapped via
/// `/RoleMap` to one of the gated standard types is treated as that
/// type for validation purposes (PR-22b populates this slot; today
/// it's always null and the test path goes through `struct_type`).
///
/// Recursion is bounded by `MAX_VALIDATE_DEPTH = 64`; deeper trees
/// are silently truncated rather than asserting (an adversarial PDF
/// must not be able to crash the validator). The validator is OFF
/// by default — callers (writer-side struct-tree builder, the
/// `--validate-pdfua` CLI flag) invoke it explicitly. Reader-side
/// parse never invokes it.
pub fn validateAltText(tree: *const StructTree) !void {
    const root = tree.root orelse return;
    try validateAltTextRec(root, 0);
}

/// PR-22e: depth bound for the alt-text walker. PDF/UA-1 documents
/// in the wild rarely nest beyond depth 12; 64 is the same ceiling
/// used elsewhere in the parser for adversarial input.
pub const MAX_VALIDATE_DEPTH: u32 = 64;

fn validateAltTextRec(elem: *const StructElement, depth: u32) error{
    MissingAltTextOnFigure,
    MissingAltTextOnFormula,
    MissingAltTextOnForm,
}!void {
    if (depth >= MAX_VALIDATE_DEPTH) return;

    // Pick the effective tag: a /RoleMap-resolved role overrides the
    // raw struct_type (a custom "MyFig" mapped to "Figure" still
    // requires /Alt). PR-22b populates resolved_role; today null.
    const tag = elem.resolved_role orelse elem.struct_type;

    const has_alt = elem.alt_text != null or elem.actual_text != null;
    if (!has_alt) {
        if (std.mem.eql(u8, tag, "Figure")) return error.MissingAltTextOnFigure;
        if (std.mem.eql(u8, tag, "Formula")) return error.MissingAltTextOnFormula;
        if (std.mem.eql(u8, tag, "Form")) return error.MissingAltTextOnForm;
    }

    for (elem.children) |child| {
        switch (child) {
            .element => |sub| try validateAltTextRec(sub, depth + 1),
            .mcid => {},
        }
    }
}

/// PR-22e: PDF/UA-1 umbrella validator. Today runs only the alt-text
/// rule (§7.3); slots are reserved here for the other §7.18.x rules
/// (heading order, tab order, table-summary) that follow-up PRs will
/// add. Callers who want one-call PDF/UA conformance should prefer
/// this over `validateAltText` directly.
pub fn validateAll(tree: *const StructTree) !void {
    try validateAltText(tree);
    // PR-22f+: validateHeadingOrder, validateTabOrder, validateTableSummary…
}

/// PR-23a [feat]: given a `Document` (passed as `*anyopaque` to keep
/// the dep one-way) and a page index + MCID, return the text bytes
/// the MCID brackets in the page's content stream. Caller owns the
/// returned slice (allocated from `allocator`); `null` means the MCID
/// was not found on this page (or `mcid == -1`, the BMC sentinel).
///
/// Thin delegate to `mcid_resolver.resolveOne` — kept here because
/// PR-SX1 staged this signature in the `structtree` namespace and
/// downstream callers (PR-23c a11y_emitter) will reach for
/// `structtree.resolveMcidText` on muscle memory. The function-level
/// `@import` defers cycle resolution past `structtree`'s decl phase.
pub fn resolveMcidText(
    doc: *anyopaque,
    page_idx: usize,
    mcid: i32,
    allocator: std.mem.Allocator,
) !?[]const u8 {
    const mcid_resolver = @import("mcid_resolver.zig");
    return mcid_resolver.resolveOne(doc, page_idx, mcid, allocator);
}

fn collectMcidsInOrder(
    elem: *const StructElement,
    result: *std.AutoHashMap(usize, std.ArrayList(MarkedContentRef)),
    allocator: std.mem.Allocator,
    parent_page: ?ObjRef,
    depth: u32,
) !void {
    if (depth >= MAX_STRUCT_DEPTH) return;

    // PR-22c: skip artifacts. Two layers of artifact-suppression
    // exist; this is the structure-tree side. /Artifact StructElems
    // (PDF/UA-1 §7.1) are out-of-band: page numbers, headers, layout
    // furniture. They never appear in the document's logical reading
    // order, so we drop the entire subtree.
    //
    // The complementary content-stream gate lives in `extractContentStream`
    // (root.zig) and skips text bracketed by `/Artifact BMC ... EMC`
    // even when no struct tree is present.
    if (std.mem.eql(u8, elem.struct_type, "Artifact")) return;

    const current_page = elem.page_ref orelse parent_page;

    for (elem.children) |child| {
        switch (child) {
            .element => |sub_elem| {
                try collectMcidsInOrder(sub_elem, result, allocator, current_page, depth + 1);
            },
            .mcid => |mcr| {
                // PR-22c: skip BMC sentinel refs. `mcid == -1` is
                // pushed by `MarkedContentExtractor.beginMarkedContent`
                // when a tag-only `/Tag BMC ... EMC` bracket has no
                // MCID property dict (PDF §14.7.2). Such refs never
                // appear in `/StructParents` chains and have no page
                // anchor — they MUST NOT enter reading order.
                if (mcr.mcid < 0) continue;

                const page_ref = mcr.page_ref orelse current_page;
                if (page_ref) |pr| {
                    // Use object number as page index proxy (will be resolved later)
                    const page_idx: usize = pr.num;

                    const gop = try result.getOrPut(page_idx);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = .empty;
                    }
                    try gop.value_ptr.append(allocator, mcr);
                }
            },
        }
    }
}

/// Parse the structure tree from a PDF document
pub fn parseStructTree(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    cache: *std.AutoHashMap(u32, Object),
) !StructTree {
    // Get Root from trailer
    const root_ref = switch (xref.trailer.get("Root") orelse return emptyTree(allocator)) {
        .reference => |r| r,
        else => return emptyTree(allocator),
    };

    // Resolve catalog
    const catalog = pagetree.resolveRef(allocator, data, xref, root_ref, cache) catch
        return emptyTree(allocator);

    const catalog_dict = switch (catalog) {
        .dict => |d| d,
        else => return emptyTree(allocator),
    };

    // Get StructTreeRoot
    const struct_tree_ref = switch (catalog_dict.get("StructTreeRoot") orelse return emptyTree(allocator)) {
        .reference => |r| r,
        else => return emptyTree(allocator),
    };

    const struct_tree_obj = pagetree.resolveRef(allocator, data, xref, struct_tree_ref, cache) catch
        return emptyTree(allocator);

    const struct_tree_dict = switch (struct_tree_obj) {
        .dict => |d| d,
        else => return emptyTree(allocator),
    };

    // Parse the tree starting from /K.
    // Elements are individually heap-allocated so that pointers stored in
    // StructChild.element remain stable even as the tracking list grows.
    var elements: std.ArrayList(*StructElement) = .empty;
    errdefer {
        for (elements.items) |elem| {
            allocator.free(elem.children);
            allocator.destroy(elem);
        }
        elements.deinit(allocator);
    }

    const root_kids = struct_tree_dict.get("K") orelse return emptyTree(allocator);
    const root_elem = try parseStructElement(allocator, data, xref, cache, root_kids, &elements);

    const elements_slice = try elements.toOwnedSlice(allocator);
    errdefer {
        for (elements_slice) |elem| {
            allocator.free(elem.children);
            allocator.destroy(elem);
        }
        allocator.free(elements_slice);
    }

    var tree = StructTree{
        .root = root_elem,
        .elements = elements_slice,
        .allocator = allocator,
    };

    // PR-22b: resolve `/RoleMap` aliases (StructTreeRoot dict carries
    // /RoleMap per ISO 32000-1 §14.7.4). Errors propagate so a malformed
    // /RoleMap is observable at the call site rather than silently
    // dropped (consistent with offensive-programming defaults inside
    // the parser's trust boundary).
    var ctx = ResolveCtx{
        .allocator = allocator,
        .data = data,
        .xref = xref,
        .cache = cache,
    };
    try parseRoleMap(&tree, struct_tree_dict, ResolveCtx.resolve, @ptrCast(&ctx));

    // PR-22d: catalog-level /Lang seeds the inheritance walk. Borrowed
    // slice from the parsed catalog dict — same lifetime convention as
    // every other string on a `StructElement`.
    const catalog_lang: ?[]const u8 = blk: {
        const raw = catalog_dict.getString("Lang") orelse break :blk null;
        if (!isValidBcp47(raw)) break :blk null;
        break :blk raw;
    };
    propagateLang(&tree, catalog_lang) catch {
        // The only error path is `error.StructTreeTooDeep`, which the
        // parser already prevents. If it ever fires, deinit the tree
        // we built so far and propagate the error to the caller.
        tree.deinit();
        return error.StructTreeTooDeep;
    };

    return tree;
}

/// PR-22b: glue that adapts `(allocator, data, xref, cache)` to the
/// opaque-context shape the wave-3.2 stubs use. Lets `parseRoleMap`
/// dereference indirect refs without re-importing parser internals.
const ResolveCtx = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    cache: *std.AutoHashMap(u32, Object),

    fn resolve(opaque_ctx: *anyopaque, ref: ObjRef) anyerror!Object {
        const self: *ResolveCtx = @ptrCast(@alignCast(opaque_ctx));
        return pagetree.resolveRef(self.allocator, self.data, self.xref, ref, self.cache);
    }
};

fn emptyTree(allocator: std.mem.Allocator) StructTree {
    return StructTree{
        .root = null,
        .elements = &.{},
        .allocator = allocator,
    };
}

fn parseStructElement(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    cache: *std.AutoHashMap(u32, Object),
    obj: Object,
    elements: *std.ArrayList(*StructElement),
) !?*const StructElement {
    // Resolve if reference
    const resolved = switch (obj) {
        .reference => |r| pagetree.resolveRef(allocator, data, xref, r, cache) catch return null,
        else => obj,
    };

    switch (resolved) {
        .dict => |dict| {
            // Check if it's a StructElem
            const type_name = dict.getName("Type");
            if (type_name != null and !std.mem.eql(u8, type_name.?, "StructElem")) {
                // Could be MCR (Marked Content Reference)
                if (std.mem.eql(u8, type_name.?, "MCR")) {
                    return null; // Handled separately
                }
            }

            const struct_type = dict.getName("S") orelse "Unknown";
            const title = dict.getString("T");
            const alt = dict.getString("Alt");
            const actual = dict.getString("ActualText");
            // PR-22d: optional `/Lang` (BCP-47) on this element. Only
            // adopt it when it passes the bounded sanity check; a
            // pathological 1MB or control-byte-laden value falls back
            // to null (so propagateLang inherits from an ancestor).
            const lang_attr: ?[]const u8 = blk: {
                const raw = dict.getString("Lang") orelse break :blk null;
                if (!isValidBcp47(raw)) break :blk null;
                break :blk raw;
            };
            const page_ref = switch (dict.get("Pg") orelse Object{ .null = {} }) {
                .reference => |r| r,
                else => null,
            };

            // Parse children
            var children: std.ArrayList(StructChild) = .empty;
            errdefer children.deinit(allocator);

            if (dict.get("K")) |kids| {
                try parseKids(allocator, data, xref, cache, kids, &children, elements, page_ref);
            }

            const children_slice = try children.toOwnedSlice(allocator);
            // children is now empty; guard the owned slice against subsequent errors.
            errdefer allocator.free(children_slice);

            // Heap-allocate the element so its address remains stable even as
            // the `elements` tracking list grows and its backing array is reallocated.
            const elem_ptr = try allocator.create(StructElement);
            errdefer allocator.destroy(elem_ptr);
            elem_ptr.* = .{
                .struct_type = struct_type,
                .title = title,
                .alt_text = alt,
                .actual_text = actual,
                .children = children_slice,
                .page_ref = page_ref,
                .lang = lang_attr,
            };
            try elements.append(allocator, elem_ptr);
            return elem_ptr;
        },
        .integer => |mcid| {
            // Direct MCID - shouldn't happen at top level but handle it
            _ = mcid;
            return null;
        },
        else => return null,
    }
}

fn parseKids(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    cache: *std.AutoHashMap(u32, Object),
    kids_obj: Object,
    children: *std.ArrayList(StructChild),
    elements: *std.ArrayList(*StructElement),
    parent_page: ?ObjRef,
) !void {
    switch (kids_obj) {
        .array => |arr| {
            for (arr) |item| {
                try parseKids(allocator, data, xref, cache, item, children, elements, parent_page);
            }
        },
        .integer => |mcid| {
            // Direct MCID
            try children.append(allocator, .{
                .mcid = .{
                    .mcid = @intCast(mcid),
                    .page_ref = parent_page,
                    .stream_ref = null,
                },
            });
        },
        .reference => |ref| {
            // Could be another StructElem or MCR
            const resolved = pagetree.resolveRef(allocator, data, xref, ref, cache) catch return;
            try parseKids(allocator, data, xref, cache, resolved, children, elements, parent_page);
        },
        .dict => |dict| {
            // Check if it's an MCR (Marked Content Reference)
            const type_name = dict.getName("Type");
            if (type_name != null and std.mem.eql(u8, type_name.?, "MCR")) {
                const mcid = dict.getInt("MCID") orelse return;
                const pg = switch (dict.get("Pg") orelse Object{ .null = {} }) {
                    .reference => |r| r,
                    else => parent_page,
                };
                const stm = switch (dict.get("Stm") orelse Object{ .null = {} }) {
                    .reference => |r| r,
                    else => null,
                };

                try children.append(allocator, .{
                    .mcid = .{
                        .mcid = @intCast(mcid),
                        .page_ref = pg,
                        .stream_ref = stm,
                    },
                });
            } else {
                // It's a StructElem
                const struct_type = dict.getName("S") orelse return;
                const title = dict.getString("T");
                const alt = dict.getString("Alt");
                const actual = dict.getString("ActualText");
                // PR-22d: per-element /Lang (see parseStructElement).
                const lang_attr: ?[]const u8 = blk: {
                    const raw = dict.getString("Lang") orelse break :blk null;
                    if (!isValidBcp47(raw)) break :blk null;
                    break :blk raw;
                };
                const page_ref = switch (dict.get("Pg") orelse Object{ .null = {} }) {
                    .reference => |r| r,
                    else => parent_page,
                };

                var sub_children: std.ArrayList(StructChild) = .empty;
                errdefer sub_children.deinit(allocator);

                if (dict.get("K")) |sub_kids| {
                    try parseKids(allocator, data, xref, cache, sub_kids, &sub_children, elements, page_ref);
                }

                const sub_children_slice = try sub_children.toOwnedSlice(allocator);
                errdefer allocator.free(sub_children_slice);

                const elem_ptr = try allocator.create(StructElement);
                errdefer allocator.destroy(elem_ptr);
                elem_ptr.* = .{
                    .struct_type = struct_type,
                    .title = title,
                    .alt_text = alt,
                    .actual_text = actual,
                    .children = sub_children_slice,
                    .page_ref = page_ref,
                    .lang = lang_attr,
                };
                try elements.append(allocator, elem_ptr);
                try children.append(allocator, .{ .element = elem_ptr });
            }
        },
        else => {},
    }
}

/// Content with MCID tagging
pub const TaggedContent = struct {
    /// MCID of this content
    mcid: i32,
    /// Structure type (P, Span, H1, etc.)
    tag: []const u8,
    /// Text content
    text: []const u8,
    /// Position (if available)
    x: f64 = 0,
    y: f64 = 0,
};

/// Extract text from content stream with MCID tracking
pub const MarkedContentExtractor = struct {
    allocator: std.mem.Allocator,
    /// Collected content by MCID
    content_by_mcid: std.AutoHashMap(i32, std.ArrayList(u8)),
    /// Current MCID stack
    mcid_stack: std.ArrayList(i32),
    /// Current tag stack
    tag_stack: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) MarkedContentExtractor {
        return .{
            .allocator = allocator,
            .content_by_mcid = std.AutoHashMap(i32, std.ArrayList(u8)).init(allocator),
            .mcid_stack = .empty,
            .tag_stack = .empty,
        };
    }

    pub fn deinit(self: *MarkedContentExtractor) void {
        var it = self.content_by_mcid.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.content_by_mcid.deinit();
        self.mcid_stack.deinit(self.allocator);
        self.tag_stack.deinit(self.allocator);
    }

    /// Called when BDC (begin marked content) is encountered
    pub fn beginMarkedContent(self: *MarkedContentExtractor, tag: []const u8, mcid: ?i32) !void {
        try self.tag_stack.append(self.allocator, tag);
        if (mcid) |m| {
            try self.mcid_stack.append(self.allocator, m);
            // Ensure we have a buffer for this MCID
            const gop = try self.content_by_mcid.getOrPut(m);
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
            }
        } else {
            // No MCID, push sentinel
            try self.mcid_stack.append(self.allocator, -1);
        }
    }

    /// Called when EMC (end marked content) is encountered
    pub fn endMarkedContent(self: *MarkedContentExtractor) void {
        if (self.mcid_stack.items.len > 0) {
            _ = self.mcid_stack.pop();
        }
        if (self.tag_stack.items.len > 0) {
            _ = self.tag_stack.pop();
        }
    }

    /// Get current MCID (innermost)
    pub fn currentMcid(self: *const MarkedContentExtractor) ?i32 {
        // Find innermost non-sentinel MCID
        var i = self.mcid_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (self.mcid_stack.items[i] >= 0) {
                return self.mcid_stack.items[i];
            }
        }
        return null;
    }

    /// Add text to current MCID
    pub fn addText(self: *MarkedContentExtractor, text: []const u8) !void {
        if (self.currentMcid()) |mcid| {
            if (self.content_by_mcid.getPtr(mcid)) |buf| {
                try buf.appendSlice(self.allocator, text);
            }
        }
    }

    /// Get text for an MCID
    ///
    /// PR-22c: returns null on any negative MCID. `-1` is the BMC
    /// sentinel (tag-only marked content with no property dict);
    /// other negatives are illegal per PDF §14.7.2 (MCID is a
    /// non-negative integer). Callers that walk `/StructParents`
    /// arrays should never hand us a negative, but a corrupt tree
    /// could — fail closed instead of indexing the hashmap with
    /// a value that has no business being a key.
    pub fn getTextForMcid(self: *const MarkedContentExtractor, mcid: i32) ?[]const u8 {
        if (mcid < 0) return null;
        if (self.content_by_mcid.get(mcid)) |buf| {
            return buf.items;
        }
        return null;
    }
};

// =====================================================================
// PR-SX1 tests
// ---------------------------------------------------------------------
// These pin the wave-3.2 contract: new `StructElement` fields default
// to null, and the four public-API stubs are callable and return their
// no-op result. A future copy-paste that defaults `lang` to `""`
// instead of null trips the first assertion below; a regression that
// changes a stub signature trips the second.
// =====================================================================

test "PR-SX1: StructElement extension fields default to null" {
    const elem: StructElement = .{
        .struct_type = "P",
        .children = &.{},
    };
    // Split asserts so the failing line points at the exact slot.
    try std.testing.expect(elem.lang == null);
    try std.testing.expect(elem.resolved_role == null);
    try std.testing.expect(elem.mcid_text == null);
    // Sanity: existing nullable fields are also null by default.
    try std.testing.expect(elem.title == null);
    try std.testing.expect(elem.alt_text == null);
    try std.testing.expect(elem.actual_text == null);
    try std.testing.expect(elem.page_ref == null);
}

test "PR-SX1: wave-3.2 stub APIs are callable no-ops" {
    const allocator = std.testing.allocator;

    var tree: StructTree = .{
        .root = null,
        .elements = &.{},
        .allocator = allocator,
    };

    // parseRoleMap: empty catalog dict, dummy resolver — must succeed.
    const empty_dict: ObjectDict = .{ .entries = &.{} };
    const dummy_ctx = struct {
        fn resolve(ctx: *anyopaque, ref: ObjRef) anyerror!Object {
            _ = ctx;
            _ = ref;
            return Object{ .null = {} };
        }
    };
    var ctx_storage: u8 = 0;
    try parseRoleMap(&tree, empty_dict, dummy_ctx.resolve, @ptrCast(&ctx_storage));

    // propagateLang: null root_lang must be accepted as no-op.
    try propagateLang(&tree, null);
    try propagateLang(&tree, "en-US");

    // validateAltText: empty tree must validate clean.
    try validateAltText(&tree);

    // PR-23a: resolveMcidText now delegates to mcid_resolver. The
    // BMC sentinel (mcid == -1) short-circuits before any cast or
    // content-stream walk, so this stays safe to call with a dummy
    // context — exercising the negative path the BMC path guarantees.
    const text = try resolveMcidText(@ptrCast(&ctx_storage), 0, -1, allocator);
    try std.testing.expect(text == null);
}

// =====================================================================
// PR-22b tests
// ---------------------------------------------------------------------
// Direct-on-API tests: build a `StructTree` with a single element and
// a synthetic `/RoleMap` dict, call `parseRoleMap`, observe
// `resolved_role`. No PDF round-trip needed — that's covered upstream
// by `parseStructTree` propagating into the wave-3.2 emitter goldens.
// =====================================================================

/// PR-22b: shared dummy resolver. /RoleMap fixtures here use only
/// inline names, so the resolver is never actually called; pre-staged
/// for future tests that exercise indirect-ref values.
fn pr22bDummyResolve(ctx: *anyopaque, ref: ObjRef) anyerror!Object {
    _ = ctx;
    _ = ref;
    return Object{ .null = {} };
}

/// PR-22b: build a single-element tree owned by `allocator`. Caller
/// must `deinit` it. The element's `struct_type` slice is borrowed —
/// it must outlive the returned tree (use a string literal).
fn pr22bMakeTreeOneElement(
    allocator: std.mem.Allocator,
    struct_type: []const u8,
) !StructTree {
    const elem = try allocator.create(StructElement);
    errdefer allocator.destroy(elem);
    elem.* = .{
        .struct_type = struct_type,
        .children = &.{},
    };

    const elements = try allocator.alloc(*StructElement, 1);
    elements[0] = elem;

    return StructTree{
        .root = elem,
        .elements = elements,
        .allocator = allocator,
    };
}

test "PR-22b: direct CustomP → P resolves to standard type" {
    const allocator = std.testing.allocator;
    var tree = try pr22bMakeTreeOneElement(allocator, "CustomP");
    defer tree.deinit();

    // /RoleMap << /CustomP /P >>
    var entries = [_]ObjectDict.Entry{
        .{ .key = "CustomP", .value = .{ .name = "P" } },
    };
    const rolemap_dict: ObjectDict = .{ .entries = &entries };
    var catalog_entries = [_]ObjectDict.Entry{
        .{ .key = "RoleMap", .value = .{ .dict = rolemap_dict } },
    };
    const catalog: ObjectDict = .{ .entries = &catalog_entries };

    var ctx: u8 = 0;
    try parseRoleMap(&tree, catalog, pr22bDummyResolve, @ptrCast(&ctx));

    try std.testing.expect(tree.elements[0].resolved_role != null);
    try std.testing.expectEqualStrings("P", tree.elements[0].resolved_role.?);
}

test "PR-22b: chained A → B → P resolves to terminal standard type" {
    const allocator = std.testing.allocator;
    var tree = try pr22bMakeTreeOneElement(allocator, "A");
    defer tree.deinit();

    // /RoleMap << /A /B  /B /P >>
    var entries = [_]ObjectDict.Entry{
        .{ .key = "A", .value = .{ .name = "B" } },
        .{ .key = "B", .value = .{ .name = "P" } },
    };
    const rolemap_dict: ObjectDict = .{ .entries = &entries };
    var catalog_entries = [_]ObjectDict.Entry{
        .{ .key = "RoleMap", .value = .{ .dict = rolemap_dict } },
    };
    const catalog: ObjectDict = .{ .entries = &catalog_entries };

    var ctx: u8 = 0;
    try parseRoleMap(&tree, catalog, pr22bDummyResolve, @ptrCast(&ctx));

    try std.testing.expectEqualStrings("P", tree.elements[0].resolved_role.?);
}

test "PR-22b: cycle A → B → A returns RoleMapCycle" {
    const allocator = std.testing.allocator;
    var tree = try pr22bMakeTreeOneElement(allocator, "A");
    defer tree.deinit();

    var entries = [_]ObjectDict.Entry{
        .{ .key = "A", .value = .{ .name = "B" } },
        .{ .key = "B", .value = .{ .name = "A" } },
    };
    const rolemap_dict: ObjectDict = .{ .entries = &entries };
    var catalog_entries = [_]ObjectDict.Entry{
        .{ .key = "RoleMap", .value = .{ .dict = rolemap_dict } },
    };
    const catalog: ObjectDict = .{ .entries = &catalog_entries };

    var ctx: u8 = 0;
    const result = parseRoleMap(&tree, catalog, pr22bDummyResolve, @ptrCast(&ctx));
    try std.testing.expectError(error.RoleMapCycle, result);
}

test "PR-22b: self-cycle A → A returns RoleMapCycle" {
    const allocator = std.testing.allocator;
    var tree = try pr22bMakeTreeOneElement(allocator, "A");
    defer tree.deinit();

    var entries = [_]ObjectDict.Entry{
        .{ .key = "A", .value = .{ .name = "A" } },
    };
    const rolemap_dict: ObjectDict = .{ .entries = &entries };
    var catalog_entries = [_]ObjectDict.Entry{
        .{ .key = "RoleMap", .value = .{ .dict = rolemap_dict } },
    };
    const catalog: ObjectDict = .{ .entries = &catalog_entries };

    var ctx: u8 = 0;
    const result = parseRoleMap(&tree, catalog, pr22bDummyResolve, @ptrCast(&ctx));
    try std.testing.expectError(error.RoleMapCycle, result);
}

test "PR-22b: non-standard terminal returns RoleMapResolvesToNonStandard" {
    const allocator = std.testing.allocator;
    var tree = try pr22bMakeTreeOneElement(allocator, "A");
    defer tree.deinit();

    // /A maps to a name that is neither standard nor a further key.
    var entries = [_]ObjectDict.Entry{
        .{ .key = "A", .value = .{ .name = "SomethingMadeUp" } },
    };
    const rolemap_dict: ObjectDict = .{ .entries = &entries };
    var catalog_entries = [_]ObjectDict.Entry{
        .{ .key = "RoleMap", .value = .{ .dict = rolemap_dict } },
    };
    const catalog: ObjectDict = .{ .entries = &catalog_entries };

    var ctx: u8 = 0;
    const result = parseRoleMap(&tree, catalog, pr22bDummyResolve, @ptrCast(&ctx));
    try std.testing.expectError(error.RoleMapResolvesToNonStandard, result);
}

test "PR-22b: element with no RoleMap entry leaves resolved_role null" {
    const allocator = std.testing.allocator;
    var tree = try pr22bMakeTreeOneElement(allocator, "P");
    defer tree.deinit();

    // /RoleMap maps an unrelated key. The element's struct_type "P" is
    // not a key, so resolved_role must remain null.
    var entries = [_]ObjectDict.Entry{
        .{ .key = "CustomP", .value = .{ .name = "P" } },
    };
    const rolemap_dict: ObjectDict = .{ .entries = &entries };
    var catalog_entries = [_]ObjectDict.Entry{
        .{ .key = "RoleMap", .value = .{ .dict = rolemap_dict } },
    };
    const catalog: ObjectDict = .{ .entries = &catalog_entries };

    var ctx: u8 = 0;
    try parseRoleMap(&tree, catalog, pr22bDummyResolve, @ptrCast(&ctx));
    try std.testing.expect(tree.elements[0].resolved_role == null);
}

test "PR-22b: missing RoleMap is a no-op" {
    const allocator = std.testing.allocator;
    var tree = try pr22bMakeTreeOneElement(allocator, "P");
    defer tree.deinit();

    const empty_catalog: ObjectDict = .{ .entries = &.{} };
    var ctx: u8 = 0;
    try parseRoleMap(&tree, empty_catalog, pr22bDummyResolve, @ptrCast(&ctx));
    try std.testing.expect(tree.elements[0].resolved_role == null);
}

test "PR-22b: chain longer than MAX_ROLEMAP_CHAIN returns RoleMapCycle" {
    const allocator = std.testing.allocator;
    var tree = try pr22bMakeTreeOneElement(allocator, "K0");
    defer tree.deinit();

    // K0 → K1 → ... → K9 (10 hops, all to non-standard names so no
    // early terminal hit). MAX_ROLEMAP_CHAIN is 8 → must trip cycle.
    var entries = [_]ObjectDict.Entry{
        .{ .key = "K0", .value = .{ .name = "K1" } },
        .{ .key = "K1", .value = .{ .name = "K2" } },
        .{ .key = "K2", .value = .{ .name = "K3" } },
        .{ .key = "K3", .value = .{ .name = "K4" } },
        .{ .key = "K4", .value = .{ .name = "K5" } },
        .{ .key = "K5", .value = .{ .name = "K6" } },
        .{ .key = "K6", .value = .{ .name = "K7" } },
        .{ .key = "K7", .value = .{ .name = "K8" } },
        .{ .key = "K8", .value = .{ .name = "K9" } },
        .{ .key = "K9", .value = .{ .name = "K10" } },
    };
    const rolemap_dict: ObjectDict = .{ .entries = &entries };
    var catalog_entries = [_]ObjectDict.Entry{
        .{ .key = "RoleMap", .value = .{ .dict = rolemap_dict } },
    };
    const catalog: ObjectDict = .{ .entries = &catalog_entries };

    var ctx: u8 = 0;
    const result = parseRoleMap(&tree, catalog, pr22bDummyResolve, @ptrCast(&ctx));
    try std.testing.expectError(error.RoleMapCycle, result);
}

test "PR-22b: emitElementJson includes resolved_role when populated" {
    // Round-trip on the emitter: a populated `resolved_role` must
    // appear between `page_obj` and `mcid_refs`. Pairs the
    // SX1-byte-identical golden by exercising the new branch.
    const allocator = std.testing.allocator;
    const elem: StructElement = .{
        .struct_type = "CustomP",
        .resolved_role = "P",
        .children = &.{},
    };

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try emitElementJson(&elem, &aw.writer, 0);

    const expected =
        "{\"type\":\"CustomP\",\"resolved_role\":\"P\",\"mcid_refs\":[],\"children\":[]}";
    try std.testing.expectEqualStrings(expected, aw.written());
}

test "PR-22b: emitElementJson omits resolved_role when null" {
    // Negative-space: a null `resolved_role` must NOT serialize. Guards
    // the SX1 byte-identical golden against accidental drift.
    const allocator = std.testing.allocator;
    const elem: StructElement = .{
        .struct_type = "P",
        .children = &.{},
    };

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try emitElementJson(&elem, &aw.writer, 0);

    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "resolved_role") == null);
}

// =====================================================================
// PR-22e tests: alt-text validator unit coverage
// ---------------------------------------------------------------------
// These exercise validateAltText directly against synthetic trees so
// they don't depend on parser fidelity. Acceptance-gate fixtures live
// in `testpdf.zig` + `integration_test.zig` and exercise the full
// parse → validate path.
// =====================================================================

test "PR-22e: Figure with /Alt validates clean" {
    var fig: StructElement = .{
        .struct_type = "Figure",
        .alt_text = "A photograph of a sunset",
        .children = &.{},
    };
    var root: StructElement = .{
        .struct_type = "Document",
        .children = &[_]StructChild{.{ .element = &fig }},
    };
    const tree: StructTree = .{
        .root = &root,
        .elements = &.{},
        .allocator = std.testing.allocator,
    };
    try validateAltText(&tree);
}

test "PR-22e: Figure with /ActualText (no /Alt) validates clean" {
    // PDF/UA-1 §7.3 + ISO 32000-1 §14.9.4: /ActualText is an
    // acceptable substitute for /Alt.
    var fig: StructElement = .{
        .struct_type = "Figure",
        .actual_text = "Sunset over the ocean",
        .children = &.{},
    };
    var root: StructElement = .{
        .struct_type = "Document",
        .children = &[_]StructChild{.{ .element = &fig }},
    };
    const tree: StructTree = .{
        .root = &root,
        .elements = &.{},
        .allocator = std.testing.allocator,
    };
    try validateAltText(&tree);
}

test "PR-22e: Figure missing /Alt and /ActualText → MissingAltTextOnFigure" {
    var fig: StructElement = .{
        .struct_type = "Figure",
        .children = &.{},
    };
    var root: StructElement = .{
        .struct_type = "Document",
        .children = &[_]StructChild{.{ .element = &fig }},
    };
    const tree: StructTree = .{
        .root = &root,
        .elements = &.{},
        .allocator = std.testing.allocator,
    };
    try std.testing.expectError(error.MissingAltTextOnFigure, validateAltText(&tree));
}

test "PR-22e: Formula without alt → MissingAltTextOnFormula" {
    var fml: StructElement = .{ .struct_type = "Formula", .children = &.{} };
    const tree: StructTree = .{
        .root = &fml,
        .elements = &.{},
        .allocator = std.testing.allocator,
    };
    try std.testing.expectError(error.MissingAltTextOnFormula, validateAltText(&tree));
}

test "PR-22e: Form without alt → MissingAltTextOnForm" {
    var form: StructElement = .{ .struct_type = "Form", .children = &.{} };
    const tree: StructTree = .{
        .root = &form,
        .elements = &.{},
        .allocator = std.testing.allocator,
    };
    try std.testing.expectError(error.MissingAltTextOnForm, validateAltText(&tree));
}

test "PR-22e: P element without alt is fine (rule is type-gated)" {
    var p: StructElement = .{ .struct_type = "P", .children = &.{} };
    const tree: StructTree = .{
        .root = &p,
        .elements = &.{},
        .allocator = std.testing.allocator,
    };
    try validateAltText(&tree);
}

test "PR-22e: resolved_role overrides struct_type for the rule" {
    // /RoleMap mapping "MyFig" → "Figure" (PR-22b populates
    // resolved_role). The validator must catch the missing /Alt.
    var fig: StructElement = .{
        .struct_type = "MyFig",
        .resolved_role = "Figure",
        .children = &.{},
    };
    const tree: StructTree = .{
        .root = &fig,
        .elements = &.{},
        .allocator = std.testing.allocator,
    };
    try std.testing.expectError(error.MissingAltTextOnFigure, validateAltText(&tree));
}

test "PR-22e: empty tree validates clean" {
    const tree: StructTree = .{
        .root = null,
        .elements = &.{},
        .allocator = std.testing.allocator,
    };
    try validateAltText(&tree);
}

test "PR-22e: validateAll umbrella delegates to validateAltText today" {
    var fig: StructElement = .{ .struct_type = "Figure", .children = &.{} };
    const tree: StructTree = .{
        .root = &fig,
        .elements = &.{},
        .allocator = std.testing.allocator,
    };
    try std.testing.expectError(error.MissingAltTextOnFigure, validateAll(&tree));
}

test "PR-22e: deeply nested tree honours MAX_VALIDATE_DEPTH" {
    // Build a chain of 80 P elements with a Figure-without-Alt at the
    // bottom. The validator must NOT find it (depth-bounded), proving
    // the bound exists. A real document would never nest this deep.
    const allocator = std.testing.allocator;
    const N: usize = 80;
    var chain = try allocator.alloc(StructElement, N);
    defer allocator.free(chain);
    var children = try allocator.alloc(StructChild, N);
    defer allocator.free(children);

    var bad_fig: StructElement = .{ .struct_type = "Figure", .children = &.{} };

    // Build bottom-up: chain[N-1] holds the Figure; each parent holds
    // a single-element child slice pointing at the next.
    var i: usize = N;
    while (i > 0) {
        i -= 1;
        if (i == N - 1) {
            children[i] = .{ .element = &bad_fig };
        } else {
            children[i] = .{ .element = &chain[i + 1] };
        }
        chain[i] = .{
            .struct_type = "P",
            .children = children[i .. i + 1],
        };
    }
    const tree: StructTree = .{
        .root = &chain[0],
        .elements = &.{},
        .allocator = allocator,
    };
    // Depth 64 < N=80 → the Figure is past the cap, so no error.
    try validateAltText(&tree);
}
