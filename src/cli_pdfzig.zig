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
        } else if (std.mem.startsWith(u8, a, "--") or std.mem.startsWith(u8, a, "-")) {
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
        } else if (std.mem.startsWith(u8, a, "--") or std.mem.startsWith(u8, a, "-")) {
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

    var stdout_buf: [8192]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&stdout_buf);
    const writer = &bw.interface;
    defer writer.flush() catch {};

    const source = sourceBasename(args.input);
    var env = stream.Envelope.init(writer, source);

    const t_start = std.time.milliTimestamp();

    const doc = zpdf.Document.open(allocator, args.input) catch |err| {
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
                .producer = meta.producer,
            });
            try writer.flush();
        },
        .md, .text, .chunks => {},
    }

    var pages_emitted: u32 = 0;
    var bytes_emitted: u64 = 0;
    var warnings_count: u32 = 0;

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

        const md = doc.extractMarkdown(page_idx, allocator) catch |err| {
            // Non-fatal per-page failure: emit the page record with empty md
            // and a warnings entry, continue to next page.
            const w = pageWarningFromError(err);
            warnings_count += 1;
            switch (args.output_mode) {
                .ndjson => {
                    const warns = if (args.no_warnings) &.{} else &[_]stream.Warning{w};
                    env.emitPage(@intCast(page_idx), "", warns) catch |e| return mapWriteErr(e);
                    writer.flush() catch |e| return mapWriteErr(e);
                },
                .md, .text => {
                    writer.print("\n<!-- pdf.zig: page {d} extraction failed: {s} -->\n", .{ page_idx, w.message }) catch |e| return mapWriteErr(e);
                    writer.flush() catch |e| return mapWriteErr(e);
                },
                .chunks => {
                    try collected.append(allocator, .{ .index = @intCast(page_idx), .markdown = try allocator.dupe(u8, "") });
                },
            }
            continue;
        };

        bytes_emitted += md.len;
        pages_emitted += 1;

        switch (args.output_mode) {
            .ndjson => {
                env.emitPage(@intCast(page_idx), md, &.{}) catch |e| {
                    allocator.free(md);
                    return mapWriteErr(e);
                };
                writer.flush() catch |e| {
                    allocator.free(md);
                    return mapWriteErr(e);
                };
                allocator.free(md);
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
            .text => {
                writer.writeAll(md) catch |e| {
                    allocator.free(md);
                    return mapWriteErr(e);
                };
                writer.writeAll("\n") catch {};
                writer.flush() catch |e| {
                    allocator.free(md);
                    return mapWriteErr(e);
                };
                allocator.free(md);
            },
            .chunks => {
                try collected.append(allocator, .{
                    .index = @intCast(page_idx),
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
        try env.emitSummary(.{
            .pages_emitted = pages_emitted,
            .bytes_emitted = bytes_emitted,
            .warnings_count = warnings_count,
            .elapsed_ms = elapsed_ms,
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

    if (args.as_json) {
        var env = stream.Envelope.init(writer, source);
        const doc = zpdf.Document.open(allocator, args.input) catch |err| {
            return try fatalFromOpenError(&env, writer, err);
        };
        defer doc.close();
        const meta = doc.metadata();
        try env.emitMeta(.{
            .pages = @intCast(doc.pageCount()),
            .encrypted = doc.isEncrypted(),
            .title = meta.title,
            .author = meta.author,
            .producer = meta.producer,
        });
        return .ok;
    }

    const doc = zpdf.Document.open(allocator, args.input) catch |err| {
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
    const idx = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[idx + 1 ..];
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
fn resolvePageRange(allocator: std.mem.Allocator, spec: ?[]const u8, total: u32) ![]usize {
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
}
