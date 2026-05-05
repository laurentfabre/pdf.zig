//! PDF Page Tree Parser
//!
//! PDFs store pages in a tree structure for efficiency with large documents.
//! Structure: Catalog -> Pages (root) -> [Pages | Page] -> ...
//!
//! We flatten this to a simple array for O(1) page access.

const std = @import("std");
const parser = @import("parser.zig");
const xref_mod = @import("xref.zig");

const Object = parser.Object;
const ObjRef = parser.ObjRef;
const XRefTable = xref_mod.XRefTable;

pub const Page = struct {
    /// Object reference for this page
    ref: ObjRef,
    /// Page dictionary
    dict: Object.Dict,
    /// Inherited MediaBox [x0, y0, x1, y1]
    media_box: [4]f64,
    /// Inherited CropBox (defaults to MediaBox)
    crop_box: [4]f64,
    /// Rotation in degrees (0, 90, 180, 270)
    rotation: i32,
    /// Inherited Resources dictionary
    resources: ?Object.Dict,
};

pub const PageTreeError = error{
    CatalogNotFound,
    PagesNotFound,
    InvalidPageTree,
    InvalidPageObject,
    CircularReference,
    OutOfMemory,
};

/// Resolve object reference using XRef table.
///
/// `error.OutOfMemory` propagates so allocator pressure is observable
/// at the call site. Domain errors (corrupt object, malformed stream
/// header) collapse to `Object{ .null = {} }` so a single bad
/// reference can't poison the whole document walk.
///
/// Codex review v1.2-rc4 round 3 [P2]: previously every parser /
/// decompress error was masked via `catch return Object{ .null = {} }`,
/// including OOM. Lattice's `resolveRefSoft` boundary couldn't
/// preserve OOM if this primitive ate it first. Now bubble OOM here
/// and keep the soft-fail for domain failures.
pub fn resolveRef(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    ref: ObjRef,
    resolved_cache: *std.AutoHashMap(u32, Object),
) !Object {
    // Check cache first
    if (resolved_cache.get(ref.num)) |cached| {
        return cached;
    }

    const entry = xref.get(ref.num) orelse return Object{ .null = {} };

    switch (entry.entry_type) {
        .free => return Object{ .null = {} },
        .in_use => {
            if (entry.offset >= data.len) return Object{ .null = {} };

            var p = parser.Parser.initAt(allocator, data, @intCast(entry.offset));
            const indirect = p.parseIndirectObject() catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return Object{ .null = {} };
            };

            // PR-W9 [feat]: transparently decrypt strings + streams.
            // The hook walks the parsed object tree; on OOM we
            // bubble, on any other failure we fall back to the
            // raw object (lets corrupt /Encrypt dicts produce a
            // soft-degraded extract rather than abort the parse).
            var obj = indirect.obj;
            if (xref.decrypt_fn) |dec| {
                if (xref.decrypt_ctx) |ctx| {
                    dec(ctx, &obj, indirect.num, indirect.gen, allocator) catch |err| {
                        if (err == error.OutOfMemory) return error.OutOfMemory;
                        // Domain failures fall through with the raw obj.
                    };
                }
            }
            try resolved_cache.put(ref.num, obj);
            return obj;
        },
        .compressed => {
            // Object is inside an object stream
            return resolveCompressedObject(allocator, data, xref, entry, resolved_cache);
        },
    }
}

fn resolveCompressedObject(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    entry: xref_mod.XRefEntry,
    resolved_cache: *std.AutoHashMap(u32, Object),
) !Object {
    const objstm_num: u32 = @intCast(entry.offset);
    const index = entry.gen_or_index;

    // Get the object stream
    const objstm_entry = xref.get(objstm_num) orelse return Object{ .null = {} };
    if (objstm_entry.entry_type != .in_use) return Object{ .null = {} };
    if (objstm_entry.offset >= data.len) return Object{ .null = {} };

    var p = parser.Parser.initAt(allocator, data, @intCast(objstm_entry.offset));
    const indirect = p.parseIndirectObject() catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return Object{ .null = {} };
    };

    // PR-W9 [feat]: decrypt the ObjStm wrapper. The inner objects
    // (extracted below from the decompressed body) are NOT
    // individually encrypted per PDF §7.6.2 — only the wrapping
    // ObjStm is.
    var indirect_obj = indirect.obj;
    if (xref.decrypt_fn) |dec| {
        if (xref.decrypt_ctx) |ctx| {
            dec(ctx, &indirect_obj, indirect.num, indirect.gen, allocator) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
            };
        }
    }

    const stream = switch (indirect_obj) {
        .stream => |s| s,
        else => return Object{ .null = {} },
    };

    // Decompress stream (arena-allocated, no need to free).
    // Codex review v1.2-rc4 round 13 [P2]: ObjStm /Filter and
    // /DecodeParms can also be indirect refs or arrays-with-indirect-
    // members. Apply the same normalization as `getStreamData` so a
    // legal `/Filter [12 0 R]` here doesn't silently desync the
    // object-stream header parse and make a Form XObject (or any
    // other indirect-ref target stored inside that ObjStm)
    // invisible to lattice.
    const decompress = @import("decompress.zig");
    const raw_filter = try resolveDictEntry(allocator, data, xref, stream.dict.get("Filter"), resolved_cache);
    const raw_params = try resolveDictEntry(allocator, data, xref, stream.dict.get("DecodeParms"), resolved_cache);
    const obj_filter = try normalizeFilterChain(allocator, allocator, data, xref, raw_filter, resolved_cache);
    const obj_params = try normalizeDecodeParms(allocator, allocator, data, xref, raw_params, resolved_cache);
    const decoded = decompress.decompressStream(
        allocator,
        stream.data,
        obj_filter,
        obj_params,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return Object{ .null = {} };
    };

    // Parse object stream header. Codex review v1.2-rc4 round 14 [P2]:
    // /N and /First may legally be indirect references. The previous
    // direct-only `getInt` call returned null and aborted the whole
    // ObjStm, making every object stored inside it (including page
    // contents, resource dicts, and Form XObjects) invisible.
    const n = (try resolveIntMaybeIndirect(allocator, data, xref, stream.dict.get("N"), resolved_cache)) orelse return Object{ .null = {} };
    const first = (try resolveIntMaybeIndirect(allocator, data, xref, stream.dict.get("First"), resolved_cache)) orelse return Object{ .null = {} };

    if (n <= 0 or first < 0) return Object{ .null = {} };

    // Parse offset pairs from header
    var header_parser = parser.Parser.init(allocator, decoded);
    var offsets: std.ArrayList(struct { num: u32, offset: u64 }) = .empty;
    defer offsets.deinit(allocator);

    var i: i64 = 0;
    while (i < n) : (i += 1) {
        // Codex review v1.2-rc4 round 7 [P2]: the round-3 OOM-bubble
        // fix covered the outer parser/decompress paths but missed
        // these inner header-loop parses. parseObject can allocate
        // (e.g. constructing a temp dict during recovery); on
        // allocator failure we must propagate, not silently truncate
        // the header walk to whatever pairs we have so far.
        const obj = header_parser.parseObject() catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            break;
        };
        const num: u32 = switch (obj) {
            .integer => |int| @intCast(int),
            else => break,
        };

        const offset_obj = header_parser.parseObject() catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            break;
        };
        const offset: u64 = switch (offset_obj) {
            .integer => |int| @intCast(int),
            else => break,
        };

        try offsets.append(allocator, .{ .num = num, .offset = offset });
    }

    // Find our object
    if (index >= offsets.items.len) return Object{ .null = {} };

    const obj_offset: usize = @intCast(first);
    const rel_offset = offsets.items[index].offset;

    if (obj_offset + rel_offset >= decoded.len) return Object{ .null = {} };

    var obj_parser = parser.Parser.initAt(allocator, decoded, obj_offset + @as(usize, @intCast(rel_offset)));
    const result = obj_parser.parseObject() catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return Object{ .null = {} };
    };

    try resolved_cache.put(offsets.items[index].num, result);
    return result;
}

/// Resolve a numeric Object (possibly via one level of indirect
/// reference) to i64. Returns null on missing / non-numeric / domain
/// failure; bubbles `error.OutOfMemory`.
///
/// Codex review v1.2-rc4 round 14 [P2]: ObjStm header keys `/N` and
/// `/First` may legally be indirect references. The direct-only
/// `Dict.getInt` returned null on `.reference`, aborting the entire
/// object-stream parse.
fn resolveIntMaybeIndirect(
    parse_allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    obj_opt: ?Object,
    cache: *std.AutoHashMap(u32, Object),
) error{OutOfMemory}!?i64 {
    const obj = obj_opt orelse return null;
    const concrete = switch (obj) {
        .integer, .real => obj,
        .reference => (try resolveDictEntry(parse_allocator, data, xref, obj, cache)) orelse return null,
        else => return null,
    };
    return switch (concrete) {
        .integer => |i| i,
        .real => |r| @intFromFloat(r),
        else => null,
    };
}

/// Resolve one level of indirect reference. Returns the input
/// unchanged when not a `.reference`, the resolved object on
/// success, or null on domain resolution failure (kept silent so
/// the caller can fall through to a soft default). Bubbles
/// `error.OutOfMemory`.
///
/// Codex review v1.2-rc4 round 12 [P2]: page-level `/Contents`
/// stream `/Filter` and `/DecodeParms` need the same indirect-ref
/// hygiene as the lattice Form XObject path.
/// Round 13 [P2]: bubble OOM here — the round-5/12 contract is
/// "OOM surfaces, domain errors soft-fail" and the original
/// `catch return null` masked OOM.
fn resolveDictEntry(
    parse_allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    obj_opt: ?Object,
    cache: *std.AutoHashMap(u32, Object),
) error{OutOfMemory}!?Object {
    const obj = obj_opt orelse return null;
    return switch (obj) {
        .reference => |ref| resolveRef(parse_allocator, data, xref, ref, cache) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return null;
        },
        else => obj,
    };
}

/// Walk a `/Filter` Object and resolve any `.reference` array members.
fn normalizeFilterChain(
    scratch_allocator: std.mem.Allocator,
    parse_allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    obj_opt: ?Object,
    cache: *std.AutoHashMap(u32, Object),
) error{OutOfMemory}!?Object {
    const obj = obj_opt orelse return null;
    return switch (obj) {
        .array => |arr| blk: {
            var needs_alloc = false;
            for (arr) |el| if (el == .reference) {
                needs_alloc = true;
                break;
            };
            if (!needs_alloc) break :blk obj;

            const out = try scratch_allocator.alloc(Object, arr.len);
            for (arr, 0..) |el, i| {
                out[i] = switch (el) {
                    .reference => |ref| ref_blk: {
                        const resolved = resolveRef(parse_allocator, data, xref, ref, cache) catch |err| {
                            if (err == error.OutOfMemory) return error.OutOfMemory;
                            break :ref_blk Object{ .null = {} };
                        };
                        break :ref_blk resolved;
                    },
                    else => el,
                };
            }
            break :blk Object{ .array = out };
        },
        else => obj,
    };
}

/// Codex review v1.2-rc4 round 18 [P2]: `/DecodeParms` dict entries
/// (Predictor, Columns, Colors, BitsPerComponent) may legally be
/// indirect refs per ISO 32000-1 §7.3.10. The lattice path mirrors
/// this same logic; the page-content path needs the parallel fix.
fn normalizeDecodeParms(
    scratch_allocator: std.mem.Allocator,
    parse_allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    obj_opt: ?Object,
    cache: *std.AutoHashMap(u32, Object),
) error{OutOfMemory}!?Object {
    const obj = obj_opt orelse return null;
    return switch (obj) {
        .dict => |d| try normalizeParamsDict(d, scratch_allocator, parse_allocator, data, xref, cache),
        .array => |arr| blk: {
            var needs_alloc = false;
            for (arr) |el| {
                switch (el) {
                    .dict => |d| {
                        if (paramsDictNeedsAlloc(d)) {
                            needs_alloc = true;
                            break;
                        }
                    },
                    .reference => {
                        needs_alloc = true;
                        break;
                    },
                    else => {},
                }
            }
            if (!needs_alloc) break :blk obj;

            const out = try scratch_allocator.alloc(Object, arr.len);
            for (arr, 0..) |el, i| {
                out[i] = switch (el) {
                    .reference => |ref| ref_blk: {
                        // Round 19 [P2]: when an array member resolves
                        // to a dict, normalize THAT dict's entries too
                        // so inner /Predictor N 0 R etc. don't survive.
                        const resolved = resolveRef(parse_allocator, data, xref, ref, cache) catch |err| {
                            if (err == error.OutOfMemory) return error.OutOfMemory;
                            break :ref_blk Object{ .null = {} };
                        };
                        break :ref_blk switch (resolved) {
                            .dict => |d| try normalizeParamsDict(d, scratch_allocator, parse_allocator, data, xref, cache),
                            else => resolved,
                        };
                    },
                    .dict => |d| try normalizeParamsDict(d, scratch_allocator, parse_allocator, data, xref, cache),
                    else => el,
                };
            }
            break :blk Object{ .array = out };
        },
        else => obj,
    };
}

fn paramsDictNeedsAlloc(d: Object.Dict) bool {
    for (d.entries) |e| if (e.value == .reference) return true;
    return false;
}

fn normalizeParamsDict(
    d: Object.Dict,
    scratch_allocator: std.mem.Allocator,
    parse_allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    cache: *std.AutoHashMap(u32, Object),
) error{OutOfMemory}!Object {
    if (!paramsDictNeedsAlloc(d)) return Object{ .dict = d };

    const new_entries = try scratch_allocator.alloc(Object.Dict.Entry, d.entries.len);
    for (d.entries, 0..) |e, i| {
        new_entries[i] = .{
            .key = e.key,
            .value = switch (e.value) {
                .reference => |ref| ref_blk: {
                    const resolved = resolveRef(parse_allocator, data, xref, ref, cache) catch |err| {
                        if (err == error.OutOfMemory) return error.OutOfMemory;
                        break :ref_blk Object{ .null = {} };
                    };
                    break :ref_blk resolved;
                },
                else => e.value,
            },
        };
    }
    return Object{ .dict = .{ .entries = new_entries } };
}

/// Build page array from PDF document
pub fn buildPageTree(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
) PageTreeError![]Page {
    var resolved_cache = std.AutoHashMap(u32, Object).init(allocator);
    defer resolved_cache.deinit();

    // Get Root from trailer
    const root_ref = switch (xref.trailer.get("Root") orelse return PageTreeError.CatalogNotFound) {
        .reference => |r| r,
        else => return PageTreeError.CatalogNotFound,
    };

    // Resolve catalog. Codex round 20 [P2]: split OOM from domain
    // failure; previously OOM was masked as CatalogNotFound.
    const catalog = resolveRef(allocator, data, xref, root_ref, &resolved_cache) catch |err| {
        if (err == error.OutOfMemory) return PageTreeError.OutOfMemory;
        return PageTreeError.CatalogNotFound;
    };

    const catalog_dict = switch (catalog) {
        .dict => |d| d,
        else => return PageTreeError.CatalogNotFound,
    };

    // Get Pages reference
    const pages_ref = switch (catalog_dict.get("Pages") orelse return PageTreeError.PagesNotFound) {
        .reference => |r| r,
        else => return PageTreeError.PagesNotFound,
    };

    // Build page list
    var pages: std.ArrayList(Page) = .empty;
    errdefer pages.deinit(allocator);

    // Track visited nodes to detect cycles
    var visited = std.AutoHashMap(u32, void).init(allocator);
    defer visited.deinit();

    // Inherited attributes
    const default_mediabox = [4]f64{ 0, 0, 612, 792 }; // Letter size default

    try walkPageTree(
        allocator,
        data,
        xref,
        &resolved_cache,
        &visited,
        &pages,
        pages_ref,
        default_mediabox,
        null, // crop_box
        0, // rotation
        null, // resources
    );

    return pages.toOwnedSlice(allocator);
}

fn walkPageTree(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    cache: *std.AutoHashMap(u32, Object),
    visited: *std.AutoHashMap(u32, void),
    pages: *std.ArrayList(Page),
    node_ref: ObjRef,
    inherited_mediabox: [4]f64,
    inherited_cropbox: ?[4]f64,
    inherited_rotation: i32,
    inherited_resources: ?Object.Dict,
) PageTreeError!void {
    // Cycle detection
    if (visited.contains(node_ref.num)) {
        return PageTreeError.CircularReference;
    }
    visited.put(node_ref.num, {}) catch return PageTreeError.OutOfMemory;
    defer _ = visited.remove(node_ref.num);

    // Resolve node. Codex round 20 [P2]: split OOM from
    // InvalidPageTree (the previous catch swallowed both).
    const node = resolveRef(allocator, data, xref, node_ref, cache) catch |err| {
        if (err == error.OutOfMemory) return PageTreeError.OutOfMemory;
        return PageTreeError.InvalidPageTree;
    };

    const dict = switch (node) {
        .dict => |d| d,
        else => return PageTreeError.InvalidPageTree,
    };

    // Check Type — some generators omit /Type; infer from structure
    const type_name = dict.getName("Type") orelse
        if (dict.get("Kids") != null) "Pages" else "Page";

    // Get inherited attributes at this level
    const mediabox = extractBox(dict, "MediaBox") orelse inherited_mediabox;
    const cropbox = extractBox(dict, "CropBox") orelse inherited_cropbox;
    const rotation = @as(i32, @intCast(dict.getInt("Rotate") orelse inherited_rotation));

    // Resources inheritance: per PDF spec §7.7.3.4, page-tree
    // attributes inherit from ancestors only when the key is ABSENT.
    // If the key is PRESENT but resolves to anything that isn't a
    // dict (null, malformed, unresolvable indirect ref), the page
    // has declared its own (broken) resource scope and must NOT
    // silently fall back to the parent's resources.
    //
    // Codex review v1.2-rc4 round 14 [P2]: the previous code wrote
    //   var resources = inherited_resources;
    //   if (dict.get("Resources")) |res_obj| {
    //       ... if (resolved == .dict) resources = resolved.dict;
    //   }
    // which meant a present-but-invalid /Resources silently kept
    // the inherited dict, allowing page-level Do operators to
    // resolve against ancestor /XObject maps the page itself can't
    // legally see.
    // Codex review v1.2-rc4 round 15 [P2]: the previous catch
    // collapsed every resolveRef error — including
    // error.OutOfMemory — into Object{ .null = {} }, downgrading
    // allocator pressure to a silent fail-closed. Bubble OOM
    // explicitly through PageTreeError.OutOfMemory; only domain
    // resolution errors collapse to null.
    // PDF 32000-1 §7.7.3.4 page attribute inheritance + §7.3.9
    // null-equivalence: inherit parent when /Resources is ABSENT
    // OR resolves to .null. Only present-and-non-null-and-non-dict
    // values fail closed.
    var resources = inherited_resources;
    if (dict.get("Resources")) |res_obj| {
        const resolved: Object = switch (res_obj) {
            .reference => |r| ref_blk: {
                break :ref_blk resolveRef(allocator, data, xref, r, cache) catch |err| {
                    if (err == error.OutOfMemory) return PageTreeError.OutOfMemory;
                    break :ref_blk Object{ .null = {} };
                };
            },
            else => res_obj,
        };
        resources = switch (resolved) {
            .dict => |d| d,
            .null => inherited_resources, // §7.3.9: null ≡ absent → inherit
            else => null, // present-and-non-null-and-non-dict → fail closed
        };
    }

    if (std.mem.eql(u8, type_name, "Pages")) {
        // Intermediate node - recurse into Kids
        const kids = dict.getArray("Kids") orelse return;

        for (kids) |kid| {
            const kid_ref = switch (kid) {
                .reference => |r| r,
                else => continue,
            };

            try walkPageTree(
                allocator,
                data,
                xref,
                cache,
                visited,
                pages,
                kid_ref,
                mediabox,
                cropbox,
                rotation,
                resources,
            );
        }
    } else if (std.mem.eql(u8, type_name, "Page")) {
        // Leaf node - add to pages list
        pages.append(allocator, .{
            .ref = node_ref,
            .dict = dict,
            .media_box = mediabox,
            .crop_box = cropbox orelse mediabox,
            .rotation = rotation,
            .resources = resources,
        }) catch return PageTreeError.OutOfMemory;
    }
    // Ignore unknown types
}

fn extractBox(dict: Object.Dict, key: []const u8) ?[4]f64 {
    const array = dict.getArray(key) orelse return null;
    if (array.len != 4) return null;

    var box: [4]f64 = undefined;
    for (array, 0..) |elem, i| {
        box[i] = switch (elem) {
            .integer => |n| @floatFromInt(n),
            .real => |n| n,
            else => return null,
        };
    }
    return box;
}

/// Get page content stream(s)
pub fn getPageContents(
    parse_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    page: Page,
    cache: *std.AutoHashMap(u32, Object),
) ![]const u8 {
    const contents = page.dict.get("Contents") orelse return &[_]u8{};

    return getStreamData(parse_allocator, scratch_allocator, data, xref, contents, cache);
}

fn getStreamData(
    parse_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    obj: Object,
    cache: *std.AutoHashMap(u32, Object),
) ![]const u8 {
    switch (obj) {
        .reference => |ref| {
            const resolved = try resolveRef(parse_allocator, data, xref, ref, cache);
            return getStreamData(parse_allocator, scratch_allocator, data, xref, resolved, cache);
        },
        .stream => |s| {
            const decompress = @import("decompress.zig");
            // Codex review v1.2-rc4 round 6 [P2]: bubble OOM, keep
            // soft fallback to raw bytes for domain errors.
            // Codex round 12 [P2]: also normalize indirect array
            // members in /Filter and /DecodeParms — `decompressStream`
            // only consumes direct `.name` array entries, so a legal
            // `/Filter [12 0 R]` would silently collapse the chain to
            // "no filters" and a Pass B caller would scan compressed
            // bytes as content.
            const raw_filter = try resolveDictEntry(parse_allocator, data, xref, s.dict.get("Filter"), cache);
            const raw_params = try resolveDictEntry(parse_allocator, data, xref, s.dict.get("DecodeParms"), cache);
            const filter = try normalizeFilterChain(scratch_allocator, parse_allocator, data, xref, raw_filter, cache);
            const params = try normalizeDecodeParms(scratch_allocator, parse_allocator, data, xref, raw_params, cache);
            return decompress.decompressStream(
                scratch_allocator,
                s.data,
                filter,
                params,
            ) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return s.data;
            };
        },
        .array => |arr| {
            // Concatenate multiple content streams
            var result: std.ArrayList(u8) = .empty;
            errdefer result.deinit(scratch_allocator);

            for (arr) |item| {
                const stream_data = try getStreamData(parse_allocator, scratch_allocator, data, xref, item, cache);
                // stream_data is arena-allocated, no need to free
                try result.appendSlice(scratch_allocator, stream_data);
                try result.append(scratch_allocator, '\n'); // Separate streams
            }

            return result.toOwnedSlice(scratch_allocator);
        },
        else => return &[_]u8{},
    }
}

// ============================================================================
// TESTS
// ============================================================================

test "extractBox" {
    const allocator = std.testing.allocator;

    // Create a simple dict with MediaBox
    var entries = [_]Object.Dict.Entry{
        .{
            .key = "MediaBox",
            .value = Object{
                .array = @constCast(&[_]Object{
                    .{ .integer = 0 },
                    .{ .integer = 0 },
                    .{ .integer = 612 },
                    .{ .integer = 792 },
                }),
            },
        },
    };

    const dict = Object.Dict{ .entries = &entries };

    const box = extractBox(dict, "MediaBox");
    try std.testing.expect(box != null);
    try std.testing.expectApproxEqRel(@as(f64, 0), box.?[0], 0.001);
    try std.testing.expectApproxEqRel(@as(f64, 612), box.?[2], 0.001);

    _ = allocator;
}
