//! pdf.zig CLI dispatch — LLM-streaming flavoured (NDJSON-by-default).
//!
//! Subcommands:
//!   extract <file>             default: NDJSON to stdout, per-page flush
//!   extract --output md        Markdown (per-page flush, --- separators)
//!   extract --output chunks --max-tokens N
//!   extract --output text      Plain text, no markdown structure
//!   info <file>                pretty metadata (text)
//!   info --json <file>         single `meta` NDJSON record
//!   chunk <file> --max-tokens N   alias for `extract --output chunks`
//!   --version / --help
//!
//! Hand-rolled arg parser per zlsx pattern (no clap dep). All errors → an
//! ArgError enum that maps to a one-line stderr diagnostic + exit 1.

const std = @import("std");
const builtin = @import("builtin");
const zpdf = @import("root.zig");

const stream = @import("stream.zig");
const chunk = @import("chunk.zig");
const tokenizer = @import("tokenizer.zig");

pub const ExitCode = enum(u8) {
    ok = 0,
    arg_error = 1,
    io_error = 2,
    not_a_pdf = 3,
    encrypted = 4,
    oom = 5,
    interrupted_int = 130,
    interrupted_term = 143,
    sigpipe_no_output = 141,
};

pub const OutputMode = enum { ndjson, md, chunks, text };

pub const ExtractArgs = struct {
    input: []const u8,
    output_path: ?[]const u8 = null,
    output_mode: OutputMode = .ndjson,
    pages: ?[]const u8 = null,
    max_tokens: u32 = 4000,
    no_toc: bool = false,
    no_warnings: bool = false,
    /// PR-11 [feat]: percentage [0,100] of low-text pages required
    /// to flag the document as scanned. Default 50 = ≥half the
    /// extracted pages are below 50 bytes of extracted text.
    scan_threshold: u8 = 50,
};

pub const InfoArgs = struct {
    input: []const u8,
    as_json: bool = false,
};

pub const Command = union(enum) {
    extract: ExtractArgs,
    info: InfoArgs,
    chunk: ExtractArgs, // alias for extract with output_mode = .chunks
    help,
    version,
};

pub const ArgError = error{
    NoSubcommand,
    UnknownSubcommand,
    MissingInput,
    UnknownFlag,
    MissingValue,
    InvalidMaxTokens,
    InvalidOutputMode,
    InvalidScanThreshold,
};

/// Parse argv (excluding argv[0]) into a Command.
pub fn parseArgs(args: []const []const u8) ArgError!Command {
    if (args.len == 0) return error.NoSubcommand;

    const sub = args[0];
    if (std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h") or std.mem.eql(u8, sub, "help")) {
        return .help;
    }
    if (std.mem.eql(u8, sub, "--version") or std.mem.eql(u8, sub, "-V")) {
        return .version;
    }
    if (std.mem.eql(u8, sub, "extract")) return .{ .extract = try parseExtract(args[1..]) };
    if (std.mem.eql(u8, sub, "chunk")) {
        var ea = try parseExtract(args[1..]);
        ea.output_mode = .chunks;
        return .{ .chunk = ea };
    }
    if (std.mem.eql(u8, sub, "info")) return .{ .info = try parseInfo(args[1..]) };

    return error.UnknownSubcommand;
}

fn parseExtract(args: []const []const u8) ArgError!ExtractArgs {
    var out = ExtractArgs{ .input = "" };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--output-file")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            out.output_path = args[i];
        } else if (std.mem.eql(u8, a, "-p") or std.mem.eql(u8, a, "--pages")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            out.pages = args[i];
        } else if (std.mem.eql(u8, a, "--output")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            out.output_mode = parseOutputMode(args[i]) catch return error.InvalidOutputMode;
        } else if (std.mem.eql(u8, a, "--max-tokens")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            out.max_tokens = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidMaxTokens;
            if (out.max_tokens == 0) return error.InvalidMaxTokens;
        } else if (std.mem.eql(u8, a, "--no-toc")) {
            out.no_toc = true;
        } else if (std.mem.eql(u8, a, "--no-warnings")) {
            out.no_warnings = true;
        } else if (std.mem.eql(u8, a, "--scan-threshold")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            const v = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidScanThreshold;
            if (v > 100) return error.InvalidScanThreshold;
            out.scan_threshold = @intCast(v);
        } else if (std.mem.eql(u8, a, "-")) {
            // Bare `-` is the stdin sentinel, not a flag.
            if (out.input.len != 0) return error.UnknownFlag;
            out.input = a;
        } else if (a.len > 1 and (std.mem.startsWith(u8, a, "--") or std.mem.startsWith(u8, a, "-"))) {
            return error.UnknownFlag;
        } else if (out.input.len == 0) {
            out.input = a;
        } else {
            return error.UnknownFlag;
        }
    }
    if (out.input.len == 0) return error.MissingInput;
    return out;
}

fn parseInfo(args: []const []const u8) ArgError!InfoArgs {
    var out = InfoArgs{ .input = "" };
    for (args) |a| {
        if (std.mem.eql(u8, a, "--json")) {
            out.as_json = true;
        } else if (std.mem.eql(u8, a, "-")) {
            // Bare `-` is the stdin sentinel, not a flag.
            if (out.input.len != 0) return error.UnknownFlag;
            out.input = a;
        } else if (a.len > 1 and (std.mem.startsWith(u8, a, "--") or std.mem.startsWith(u8, a, "-"))) {
            return error.UnknownFlag;
        } else if (out.input.len == 0) {
            out.input = a;
        } else {
            return error.UnknownFlag;
        }
    }
    if (out.input.len == 0) return error.MissingInput;
    return out;
}

fn parseOutputMode(s: []const u8) !OutputMode {
    if (std.mem.eql(u8, s, "ndjson")) return .ndjson;
    if (std.mem.eql(u8, s, "md") or std.mem.eql(u8, s, "markdown")) return .md;
    if (std.mem.eql(u8, s, "chunks")) return .chunks;
    if (std.mem.eql(u8, s, "text")) return .text;
    return error.InvalidOutputMode;
}

/// PR-11 [feat]: scanned-PDF heuristic. Returns `"scanned"` when:
///   - pages_emitted ≥ 3 (avoids 1-2 page false positives — codex r1 F1)
///   - the document has at least one font
///   - scanned_pages * 100 / pages_emitted ≥ scan_threshold
/// Otherwise null (the field is omitted from the summary record).
const MIN_PAGES_FOR_SCAN_FLAG: u32 = 3;
fn computeScanFlag(pages_emitted: u32, scanned_pages: u32, has_fonts: bool, scan_threshold: u8) ?[]const u8 {
    if (pages_emitted < MIN_PAGES_FOR_SCAN_FLAG or !has_fonts) return null;
    const pct = scanned_pages * 100 / pages_emitted;
    if (pct >= scan_threshold) return "scanned";
    return null;
}

// ---- Run ----

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !ExitCode {
    const cmd = parseArgs(args) catch |err| {
        try writeArgError(err);
        return .arg_error;
    };

    return switch (cmd) {
        .help => blk: {
            try writeHelp();
            break :blk .ok;
        },
        .version => blk: {
            try writeVersion();
            break :blk .ok;
        },
        .extract => |ea| try runExtract(allocator, ea),
        .chunk => |ea| try runExtract(allocator, ea),
        .info => |ia| try runInfo(allocator, ia),
    };
}

fn runExtract(allocator: std.mem.Allocator, args: ExtractArgs) !ExitCode {
    try stream.registerSignalHandlers();

    var out_buf: [8192]u8 = undefined;
    const out_file = if (args.output_path) |path|
        std.fs.cwd().createFile(path, .{}) catch |err| {
            var serr_buf: [256]u8 = undefined;
            var sbw = std.fs.File.stderr().writer(&serr_buf);
            const sw = &sbw.interface;
            sw.print("pdf.zig: cannot open output {s}: {s}\n", .{ path, @errorName(err) }) catch {};
            sw.flush() catch {};
            return .io_error;
        }
    else
        std.fs.File.stdout();
    defer if (args.output_path != null) out_file.close();

    var bw = out_file.writer(&out_buf);
    const writer = &bw.interface;
    defer writer.flush() catch {};

    const source = sourceBasename(args.input);
    var env = stream.Envelope.init(writer, source);

    const t_start = std.time.milliTimestamp();

    const stdin_data: ?[]u8 = if (std.mem.eql(u8, args.input, "-"))
        readStdinAlloc(allocator) catch |err| {
            return try fatalFromOpenError(&env, writer, err);
        }
    else
        null;
    defer if (stdin_data) |d| allocator.free(d);

    const doc = (if (stdin_data) |data|
        zpdf.Document.openFromMemory(allocator, data, zpdf.ErrorConfig.default())
    else
        zpdf.Document.open(allocator, args.input)) catch |err| {
        return try fatalFromOpenError(&env, writer, err);
    };
    defer doc.close();

    if (doc.isEncrypted()) {
        try env.emitFatal(.{
            .kind = .encrypted,
            .message = "PDF is encrypted; pdf.zig v1 does not decrypt",
            .recoverable = false,
        });
        try writer.flush();
        return .encrypted;
    }

    const meta = doc.metadata();
    const total_pages: u32 = @intCast(doc.pageCount());

    const want_pages = try resolvePageRange(allocator, args.pages, total_pages);
    defer allocator.free(want_pages);

    switch (args.output_mode) {
        .ndjson => {
            try env.emitMeta(.{
                .pages = total_pages,
                .encrypted = false,
                .title = meta.title,
                .author = meta.author,
                .subject = meta.subject,
                .keywords = meta.keywords,
                .creator = meta.creator,
                .producer = meta.producer,
                .creation_date = meta.creation_date,
                .mod_date = meta.mod_date,
            });
            // Form fields (v1.0.1): one kind:"form" record per document.
            if (doc.getFormFields(allocator)) |fields| {
                defer zpdf.Document.freeFormFields(allocator, fields);
                if (fields.len > 0) {
                    var items: std.ArrayList(stream.FormFieldItem) = .empty;
                    defer items.deinit(allocator);
                    for (fields) |f| {
                        try items.append(allocator, .{
                            .name = f.name,
                            .value = f.value,
                            .field_type = switch (f.field_type) {
                                .text => .text,
                                .button => .button,
                                .choice => .choice,
                                .signature => .signature,
                                .unknown => .unknown,
                            },
                            .rect = f.rect,
                        });
                    }
                    try env.emitForm(items.items);
                }
            } else |_| {}
            // v1.2 Pass A: tagged-path tables (Document.getTables walks
            // /StructTreeRoot for /Table → /TR → /TH/TD). Returns empty
            // for PDFs without a structure tree.
            if (doc.getTables(allocator)) |found| {
                defer zpdf.tables.freeTables(allocator, found);
                for (found) |t| {
                    if (t.page == 0) continue; // unresolved page → skip
                    var cells: std.ArrayList(stream.TableCell) = .empty;
                    defer cells.deinit(allocator);
                    for (t.cells) |c| {
                        try cells.append(allocator, .{
                            .r = c.r,
                            .c = c.c,
                            .rowspan = c.rowspan,
                            .colspan = c.colspan,
                            .is_header = c.is_header,
                            .text = c.text,
                        });
                    }
                    try env.emitTable(.{
                        .page = t.page,
                        .table_id = t.id,
                        .n_rows = t.n_rows,
                        .n_cols = t.n_cols,
                        .header_rows = t.header_rows,
                        .cells = cells.items,
                        .engine = switch (t.engine) {
                            .tagged => .tagged,
                            .lattice => .lattice,
                            .stream => .stream,
                        },
                        .confidence = t.confidence,
                        .bbox = t.bbox,
                        .continued_from = if (t.continued_from) |l| .{ .page = l.page, .table_id = l.table_id } else null,
                        .continued_to = if (t.continued_to) |l| .{ .page = l.page, .table_id = l.table_id } else null,
                    });
                }
            } else |_| {}
            if (!args.no_toc) {
                const items: []zpdf.Document.OutlineItem = doc.getOutline(allocator) catch &.{};
                defer if (items.len > 0) zpdf.outline.freeOutline(allocator, items);
                if (items.len > 0) {
                    var toc_items: std.ArrayList(stream.TocItem) = .empty;
                    defer toc_items.deinit(allocator);
                    for (items) |item| {
                        try toc_items.append(allocator, .{
                            .title = item.title,
                            .page = if (item.page) |p| @intCast(p) else 0,
                            .depth = std.math.lossyCast(u8, item.level),
                        });
                    }
                    try env.emitToc(toc_items.items);
                }
            }
            try writer.flush();
        },
        .md, .text, .chunks => {},
    }

    var pages_emitted: u32 = 0;
    var bytes_emitted: u64 = 0;
    var warnings_count: u32 = 0;
    // PR-11 [feat]: scanned-PDF heuristic. Count pages whose
    // extractMarkdown output is shorter than this threshold (50 B):
    // a born-digital page rendering even a single sentence will
    // produce well over 100 bytes of markdown, while a scanned page
    // (image-only with possibly an OCR text stub) typically yields
    // under 50. We only count when the document actually has fonts —
    // that's the differentiator between "this is a real PDF that
    // failed to extract" vs "fake / empty PDF that legitimately has
    // no text". Final flag is emitted iff
    // `scanned_pages * 100 / pages_emitted >= scan_threshold`.
    var scanned_pages: u32 = 0;
    const SCAN_LOW_BYTES: usize = 50;

    var collected = std.ArrayList(chunk.Page).empty;
    defer {
        for (collected.items) |p| allocator.free(p.markdown);
        collected.deinit(allocator);
    }

    for (want_pages) |page_idx| {
        if (stream.wasInterrupted()) |sig| {
            try env.emitInterrupted(sig);
            try writer.flush();
            return if (sig == std.posix.SIG.TERM) .interrupted_term else .interrupted_int;
        }

        // .text mode streams plain text via the upstream extractor — no
        // markdown rendering, no per-page allocation. The other modes share
        // the extractMarkdown path below.
        if (args.output_mode == .text) {
            doc.extractText(page_idx, writer) catch |err| {
                writer.print("\n<!-- pdf.zig: page {d} extraction failed: {s} -->\n", .{ page_idx + 1, @errorName(err) }) catch |e| return mapWriteErr(e);
            };
            writer.writeAll("\n") catch |e| return mapWriteErr(e);
            writer.flush() catch |e| return mapWriteErr(e);
            pages_emitted += 1;
            continue;
        }

        const md = doc.extractMarkdown(page_idx, allocator) catch |err| {
            // Non-fatal per-page failure: emit the page record with empty md
            // and a warnings entry, continue to next page.
            const w = pageWarningFromError(err);
            warnings_count += 1;
            // PR-11 codex r1 F2: count an extraction failure as a
            // scanned page. The page record is still emitted (with
            // empty markdown), so it must contribute to the totals.
            // An all-fail or mostly-fail document with fonts present
            // matches the "image-only / scanned" signal we want to
            // surface.
            pages_emitted += 1;
            scanned_pages += 1;
            switch (args.output_mode) {
                .ndjson => {
                    const warns = if (args.no_warnings) &.{} else &[_]stream.Warning{w};
                    env.emitPage(@intCast(page_idx + 1), "", warns) catch |e| return mapWriteErr(e);
                    writer.flush() catch |e| return mapWriteErr(e);
                },
                .md, .text => {
                    writer.print("\n<!-- pdf.zig: page {d} extraction failed: {s} -->\n", .{ page_idx, w.message }) catch |e| return mapWriteErr(e);
                    writer.flush() catch |e| return mapWriteErr(e);
                },
                .chunks => {
                    try collected.append(allocator, .{ .index = @intCast(page_idx + 1), .markdown = try allocator.dupe(u8, "") });
                },
            }
            continue;
        };

        bytes_emitted += md.len;
        pages_emitted += 1;
        if (md.len < SCAN_LOW_BYTES) scanned_pages += 1;

        switch (args.output_mode) {
            .ndjson => {
                env.emitPage(@intCast(page_idx + 1), md, &.{}) catch |e| {
                    allocator.free(md);
                    return mapWriteErr(e);
                };
                allocator.free(md);
                // Hyperlinks (v1.0.1): emit a kind:"links" record per page that has any.
                if (doc.getPageLinks(page_idx, allocator)) |links| {
                    defer zpdf.Document.freeLinks(allocator, links);
                    if (links.len > 0) {
                        var items: std.ArrayList(stream.LinkItem) = .empty;
                        defer items.deinit(allocator);
                        for (links) |lk| {
                            try items.append(allocator, .{
                                .rect = lk.rect,
                                .uri = lk.uri,
                                .dest_page = if (lk.dest_page) |p| @intCast(p + 1) else null,
                            });
                        }
                        env.emitLinks(@intCast(page_idx + 1), items.items) catch |e| return mapWriteErr(e);
                    }
                } else |_| {}
                writer.flush() catch |e| return mapWriteErr(e);
            },
            .md => {
                if (page_idx != want_pages[0]) writer.writeAll("\n\n---\n\n") catch |e| {
                    allocator.free(md);
                    return mapWriteErr(e);
                };
                writer.writeAll(md) catch |e| {
                    allocator.free(md);
                    return mapWriteErr(e);
                };
                writer.flush() catch |e| {
                    allocator.free(md);
                    return mapWriteErr(e);
                };
                allocator.free(md);
            },
            .text => unreachable, // handled at top of loop via doc.extractText
            .chunks => {
                try collected.append(allocator, .{
                    .index = @intCast(page_idx + 1),
                    .markdown = md, // ownership transferred to `collected`
                });
            },
        }
    }

    if (args.output_mode == .chunks) {
        _ = chunk.chunkPages(allocator, collected.items, .{
            .max_tokens = args.max_tokens,
            .tokenizer = tokenizer.Tokenizer.init(.heuristic),
        }, &env) catch |e| return mapWriteErr(e);
        try writer.flush();
    }

    if (args.output_mode == .ndjson) {
        const elapsed_ms: u64 = @intCast(std.time.milliTimestamp() - t_start);
        // PR-11 [feat]: scanned-PDF heuristic — flag the doc as
        // "scanned" when ≥ scan_threshold% of pages produced under
        // 50 B of markdown AND the document has at least one font
        // (filters out trivially-empty PDFs from legitimately-no-text
        // signal). Per the roadmap, this enables routing through
        // OCR shell-out paths in v1.3 (PR-12 / PR-13).
        const has_fonts = doc.font_cache.count() > 0 or doc.font_obj_cache.count() > 0;
        const flag = computeScanFlag(pages_emitted, scanned_pages, has_fonts, args.scan_threshold);
        try env.emitSummary(.{
            .pages_emitted = pages_emitted,
            .bytes_emitted = bytes_emitted,
            .warnings_count = warnings_count,
            .elapsed_ms = elapsed_ms,
            .quality_flag = flag,
        });
        try writer.flush();
    }

    return .ok;
}

fn runInfo(allocator: std.mem.Allocator, args: InfoArgs) !ExitCode {
    try stream.registerSignalHandlers();

    var stdout_buf: [4096]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&stdout_buf);
    const writer = &bw.interface;
    defer writer.flush() catch {};

    const source = sourceBasename(args.input);

    const stdin_data: ?[]u8 = if (std.mem.eql(u8, args.input, "-"))
        readStdinAlloc(allocator) catch |err| {
            try writer.print("error: reading stdin: {s}\n", .{@errorName(err)});
            return .io_error;
        }
    else
        null;
    defer if (stdin_data) |d| allocator.free(d);

    if (args.as_json) {
        var env = stream.Envelope.init(writer, source);
        const doc = (if (stdin_data) |data|
            zpdf.Document.openFromMemory(allocator, data, zpdf.ErrorConfig.default())
        else
            zpdf.Document.open(allocator, args.input)) catch |err| {
            return try fatalFromOpenError(&env, writer, err);
        };
        defer doc.close();
        const meta = doc.metadata();
        try env.emitMeta(.{
            .pages = @intCast(doc.pageCount()),
            .encrypted = doc.isEncrypted(),
            .title = meta.title,
            .author = meta.author,
            .subject = meta.subject,
            .keywords = meta.keywords,
            .creator = meta.creator,
            .producer = meta.producer,
            .creation_date = meta.creation_date,
            .mod_date = meta.mod_date,
        });
        return .ok;
    }

    const doc = (if (stdin_data) |data|
        zpdf.Document.openFromMemory(allocator, data, zpdf.ErrorConfig.default())
    else
        zpdf.Document.open(allocator, args.input)) catch |err| {
        try writer.print("error: failed to open {s}: {s}\n", .{ args.input, @errorName(err) });
        return mapOpenErrorToExit(err);
    };
    defer doc.close();
    const meta = doc.metadata();
    try writer.print("source:    {s}\n", .{source});
    try writer.print("pages:     {d}\n", .{doc.pageCount()});
    try writer.print("encrypted: {}\n", .{doc.isEncrypted()});
    if (meta.title) |t| try writer.print("title:     {s}\n", .{t});
    if (meta.author) |a| try writer.print("author:    {s}\n", .{a});
    if (meta.producer) |p| try writer.print("producer:  {s}\n", .{p});
    return .ok;
}

// ---- Helpers ----

fn sourceBasename(path: []const u8) []const u8 {
    if (std.mem.eql(u8, path, "-")) return "<stdin>";
    const idx = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[idx + 1 ..];
}

/// Read all of stdin into an owned slice. Cap at 256 MiB so a runaway
/// producer doesn't OOM us; that ceiling sits safely above the largest
/// expected hotel PDF (~50 MiB) and below the practical 32-bit limit.
const STDIN_MAX_BYTES: usize = 256 * 1024 * 1024;

fn readStdinAlloc(allocator: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const stdin = std.fs.File.stdin();
    var chunk_buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = stdin.read(&chunk_buf) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) break;
        if (buf.items.len + n > STDIN_MAX_BYTES) return error.StdinTooLarge;
        try buf.appendSlice(allocator, chunk_buf[0..n]);
    }
    return buf.toOwnedSlice(allocator);
}

fn mapWriteErr(err: anyerror) ExitCode {
    return switch (err) {
        error.BrokenPipe => .sigpipe_no_output,
        error.OutOfMemory => .oom,
        else => .io_error,
    };
}

fn mapOpenErrorToExit(err: anyerror) ExitCode {
    return switch (err) {
        error.OutOfMemory => .oom,
        error.FileNotFound, error.AccessDenied => .io_error,
        else => .not_a_pdf,
    };
}

fn fatalFromOpenError(env: *stream.Envelope, writer: *std.io.Writer, err: anyerror) !ExitCode {
    const fk: stream.FatalErrorKind = switch (err) {
        error.OutOfMemory => .oom,
        error.FileNotFound, error.AccessDenied => .io,
        else => .not_a_pdf,
    };
    env.emitFatal(.{
        .kind = fk,
        .message = @errorName(err),
        .recoverable = false,
    }) catch {};
    writer.flush() catch {};
    return mapOpenErrorToExit(err);
}

fn pageWarningFromError(err: anyerror) stream.Warning {
    return switch (err) {
        error.PageNotFound => .{ .code = "page_not_found", .message = "page index out of range" },
        error.OutOfMemory => .{ .code = "oom", .message = "allocation failed during page extraction" },
        else => .{ .code = "extraction_failed", .message = @errorName(err) },
    };
}

/// Parse a page-range spec ("1-10", "1,3,5", "1-3,7,9-11") into 0-indexed
/// page numbers. Returns an owned slice. `null` spec → all pages.
pub fn resolvePageRange(allocator: std.mem.Allocator, spec: ?[]const u8, total: u32) ![]usize {
    if (spec == null or spec.?.len == 0) {
        const out = try allocator.alloc(usize, total);
        for (0..total) |i| out[i] = i;
        return out;
    }

    var list = std.ArrayList(usize).empty;
    defer list.deinit(allocator);
    var part_iter = std.mem.splitScalar(u8, spec.?, ',');
    while (part_iter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        if (std.mem.indexOfScalar(u8, trimmed, '-')) |dash| {
            const a = try std.fmt.parseInt(u32, trimmed[0..dash], 10);
            const b = try std.fmt.parseInt(u32, trimmed[dash + 1 ..], 10);
            if (a < 1 or b < a) return error.InvalidPageRange;
            var p: u32 = a;
            while (p <= b and p <= total) : (p += 1) try list.append(allocator, p - 1);
        } else {
            const p = try std.fmt.parseInt(u32, trimmed, 10);
            if (p < 1 or p > total) continue;
            try list.append(allocator, p - 1);
        }
    }
    return try list.toOwnedSlice(allocator);
}

fn writeArgError(err: ArgError) !void {
    var buf: [256]u8 = undefined;
    var bw = std.fs.File.stderr().writer(&buf);
    const w = &bw.interface;
    defer w.flush() catch {};
    const msg = switch (err) {
        error.NoSubcommand => "pdf.zig: missing subcommand (try `pdf.zig --help`)",
        error.UnknownSubcommand => "pdf.zig: unknown subcommand",
        error.MissingInput => "pdf.zig: missing input file",
        error.UnknownFlag => "pdf.zig: unknown flag",
        error.MissingValue => "pdf.zig: flag requires a value",
        error.InvalidMaxTokens => "pdf.zig: --max-tokens must be a positive integer",
        error.InvalidOutputMode => "pdf.zig: --output must be one of ndjson|md|chunks|text",
        error.InvalidScanThreshold => "pdf.zig: --scan-threshold must be an integer in [0, 100]",
    };
    try w.print("{s}\n", .{msg});
}

fn writeHelp() !void {
    var buf: [4096]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&buf);
    const w = &bw.interface;
    defer w.flush() catch {};
    try w.writeAll(
        \\pdf.zig — PDF → Markdown extraction with NDJSON streaming
        \\
        \\Usage: pdf.zig <command> [options] <file>
        \\
        \\Commands:
        \\  extract <file>              extract content (NDJSON to stdout, default)
        \\  chunk <file> --max-tokens N alias for `extract --output chunks`
        \\  info <file>                 print pretty metadata
        \\  info --json <file>          single `meta` NDJSON record
        \\  --version                   print version and exit
        \\  --help                      this message
        \\
        \\Extract options:
        \\  -o, --output-file FILE      write to FILE instead of stdout
        \\  -p, --pages SPEC            page subset, e.g. "1-10" or "1,3,5"
        \\  --output ndjson|md|chunks|text   default: ndjson
        \\  --max-tokens N              chunk budget (default 4000)
        \\  --no-toc                    suppress `toc` record (NDJSON only)
        \\  --no-warnings               suppress `warnings` array on page records
        \\  --scan-threshold PCT        flag doc as "scanned" when ≥PCT% of pages have <50B text (default 50)
        \\
        \\Examples:
        \\  pdf.zig extract hotel.pdf
        \\  pdf.zig extract --output md hotel.pdf > hotel.md
        \\  pdf.zig extract --output chunks --max-tokens 2000 hotel.pdf
        \\  pdf.zig info --json hotel.pdf
        \\
    );
}

fn writeVersion() !void {
    var buf: [128]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&buf);
    const w = &bw.interface;
    defer w.flush() catch {};
    try w.writeAll("pdf.zig 0.1.0-dev\n");
}

// ---- tests ----

test "parse extract: defaults" {
    const cmd = try parseArgs(&.{ "extract", "foo.pdf" });
    try std.testing.expect(cmd == .extract);
    try std.testing.expectEqualStrings("foo.pdf", cmd.extract.input);
    try std.testing.expectEqual(OutputMode.ndjson, cmd.extract.output_mode);
}

test "parse extract: --output md + -p range" {
    const cmd = try parseArgs(&.{ "extract", "--output", "md", "-p", "1-3", "foo.pdf" });
    try std.testing.expectEqual(OutputMode.md, cmd.extract.output_mode);
    try std.testing.expectEqualStrings("1-3", cmd.extract.pages.?);
}

test "parse chunk subcommand sets output_mode = chunks" {
    const cmd = try parseArgs(&.{ "chunk", "--max-tokens", "2000", "foo.pdf" });
    try std.testing.expect(cmd == .chunk);
    try std.testing.expectEqual(OutputMode.chunks, cmd.chunk.output_mode);
    try std.testing.expectEqual(@as(u32, 2000), cmd.chunk.max_tokens);
}

test "parse info --json" {
    const cmd = try parseArgs(&.{ "info", "--json", "foo.pdf" });
    try std.testing.expect(cmd == .info);
    try std.testing.expect(cmd.info.as_json);
}

test "parse rejects missing input" {
    try std.testing.expectError(error.MissingInput, parseArgs(&.{"extract"}));
}

test "parse rejects unknown subcommand" {
    try std.testing.expectError(error.UnknownSubcommand, parseArgs(&.{ "zap", "foo.pdf" }));
}

test "parse extract: --scan-threshold accepted" {
    const cmd = try parseArgs(&.{ "extract", "--scan-threshold", "30", "foo.pdf" });
    try std.testing.expectEqual(@as(u8, 30), cmd.extract.scan_threshold);
}

test "parse extract: --scan-threshold default is 50" {
    const cmd = try parseArgs(&.{ "extract", "foo.pdf" });
    try std.testing.expectEqual(@as(u8, 50), cmd.extract.scan_threshold);
}

test "parse extract: --scan-threshold rejects > 100" {
    try std.testing.expectError(
        error.InvalidScanThreshold,
        parseArgs(&.{ "extract", "--scan-threshold", "150", "foo.pdf" }),
    );
}

test "parse extract: --scan-threshold rejects non-numeric" {
    try std.testing.expectError(
        error.InvalidScanThreshold,
        parseArgs(&.{ "extract", "--scan-threshold", "fifty", "foo.pdf" }),
    );
}

// PR-11 codex r1 F3: integration coverage for the heuristic helper.
// Each case names the scenario it pins down.
test "computeScanFlag — 1-page low-text never flags (codex r1 F1)" {
    // Single-page doc with 1 low-text page. Default threshold 50.
    try std.testing.expectEqual(@as(?[]const u8, null), computeScanFlag(1, 1, true, 50));
}

test "computeScanFlag — 2-page mixed never flags at default 50% threshold" {
    // 2-page doc, 1 low-text + 1 normal. pct=50, but pages_emitted < 3.
    try std.testing.expectEqual(@as(?[]const u8, null), computeScanFlag(2, 1, true, 50));
}

test "computeScanFlag — 3-page all-low-text doc with fonts flags" {
    const got = computeScanFlag(3, 3, true, 50);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("scanned", got.?);
}

test "computeScanFlag — 3-page mixed below threshold doesn't flag" {
    // 3 pages, 1 low-text → pct=33 < 50.
    try std.testing.expectEqual(@as(?[]const u8, null), computeScanFlag(3, 1, true, 50));
}

test "computeScanFlag — no-fonts never flags (filters fake/empty PDFs)" {
    try std.testing.expectEqual(@as(?[]const u8, null), computeScanFlag(10, 10, false, 50));
}

test "computeScanFlag — custom threshold of 30 flags 33% scanned" {
    const got = computeScanFlag(3, 1, true, 30);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("scanned", got.?);
}

test "computeScanFlag — pages_emitted = 0 never flags" {
    try std.testing.expectEqual(@as(?[]const u8, null), computeScanFlag(0, 0, true, 50));
}

test "parse rejects --max-tokens 0" {
    try std.testing.expectError(error.InvalidMaxTokens, parseArgs(&.{ "extract", "--max-tokens", "0", "foo.pdf" }));
}

test "parse rejects unknown --output value" {
    try std.testing.expectError(error.InvalidOutputMode, parseArgs(&.{ "extract", "--output", "bogus", "foo.pdf" }));
}

test "page range: null spec → all pages" {
    const got = try resolvePageRange(std.testing.allocator, null, 3);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, got);
}

test "page range: range + list" {
    const got = try resolvePageRange(std.testing.allocator, "1-3,5", 10);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 4 }, got);
}

test "sourceBasename strips directory" {
    try std.testing.expectEqualStrings("foo.pdf", sourceBasename("/var/tmp/foo.pdf"));
    try std.testing.expectEqualStrings("foo.pdf", sourceBasename("foo.pdf"));
    try std.testing.expectEqualStrings("<stdin>", sourceBasename("-"));
}

test "parse extract: bare `-` is the stdin sentinel" {
    const cmd = try parseArgs(&.{ "extract", "-" });
    try std.testing.expect(cmd == .extract);
    try std.testing.expectEqualStrings("-", cmd.extract.input);
}

test "parse extract: `-` with --output md still works" {
    const cmd = try parseArgs(&.{ "extract", "--output", "md", "-" });
    try std.testing.expectEqualStrings("-", cmd.extract.input);
    try std.testing.expectEqual(OutputMode.md, cmd.extract.output_mode);
}

test "parse info: bare `-` is the stdin sentinel" {
    const cmd = try parseArgs(&.{ "info", "-" });
    try std.testing.expect(cmd == .info);
    try std.testing.expectEqualStrings("-", cmd.info.input);
}

test "parse info: `--json -` works" {
    const cmd = try parseArgs(&.{ "info", "--json", "-" });
    try std.testing.expect(cmd.info.as_json);
    try std.testing.expectEqualStrings("-", cmd.info.input);
}
