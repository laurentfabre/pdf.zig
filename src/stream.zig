//! NDJSON streaming envelope for the pdf.zig CLI.
//!
//! Per `docs/streaming-layer-design.md` and `docs/architecture.md` §6:
//! every record is one JSON object per line, written to an injected writer.
//! The caller owns buffering + per-page flush; this module owns escaping +
//! envelope-field invariants (`kind`, `source`, `doc_id` always present).
//!
//! Signal discipline (architecture.md §6.4):
//!   - SIGPIPE → SIG_IGN; per-page write() returns error.BrokenPipe which
//!     the CLI translates to exit 0 (≥1 page emitted) or exit 141 (none).
//!   - SIGINT / SIGTERM → set an atomic flag; the page loop checks between
//!     iterations and emits an `interrupted` record before exiting.
//!   - No SIGABRT in release: every emit method returns errors normally.

const std = @import("std");
const builtin = @import("builtin");
const uuid = @import("uuid.zig");

pub const RecordKind = enum {
    meta,
    page,
    toc,
    summary,
    fatal,
    chunk,
    interrupted,

    pub fn asString(self: RecordKind) []const u8 {
        return switch (self) {
            .meta => "meta",
            .page => "page",
            .toc => "toc",
            .summary => "summary",
            .fatal => "fatal",
            .chunk => "chunk",
            .interrupted => "interrupted",
        };
    }
};

pub const FatalErrorKind = enum {
    not_a_pdf,
    encrypted,
    truncated,
    oom,
    unknown_filter,
    io,
    unknown,

    pub fn asString(self: FatalErrorKind) []const u8 {
        return switch (self) {
            .not_a_pdf => "not_a_pdf",
            .encrypted => "encrypted",
            .truncated => "truncated",
            .oom => "oom",
            .unknown_filter => "unknown_filter",
            .io => "io",
            .unknown => "unknown",
        };
    }
};

pub const FatalError = struct {
    kind: FatalErrorKind,
    message: []const u8,
    at_page: ?u32 = null,
    recoverable: bool = false,
};

pub const Warning = struct {
    code: []const u8,
    message: []const u8,
};

pub const TocItem = struct {
    title: []const u8,
    page: u32,
    depth: u8,
};

pub const DocumentInfo = struct {
    pages: u32,
    encrypted: bool,
    title: ?[]const u8 = null,
    author: ?[]const u8 = null,
    producer: ?[]const u8 = null,
};

pub const Totals = struct {
    pages_emitted: u32,
    bytes_emitted: u64,
    warnings_count: u32,
    elapsed_ms: u64,
};

pub const ChunkBreak = enum {
    section_heading,
    page_boundary,
    paragraph,
    sentence,

    pub fn asString(self: ChunkBreak) []const u8 {
        return switch (self) {
            .section_heading => "section_heading",
            .page_boundary => "page_boundary",
            .paragraph => "paragraph",
            .sentence => "sentence",
        };
    }
};

pub const Envelope = struct {
    doc_id: uuid.String,
    source: []const u8,
    writer: *std.io.Writer,

    pub fn init(writer: *std.io.Writer, source: []const u8) Envelope {
        return .{
            .doc_id = uuid.v7(),
            .source = source,
            .writer = writer,
        };
    }

    /// Override doc_id (used in tests for determinism).
    pub fn initWithId(writer: *std.io.Writer, source: []const u8, doc_id: uuid.String) Envelope {
        return .{ .doc_id = doc_id, .source = source, .writer = writer };
    }

    pub fn emitMeta(self: *Envelope, info: DocumentInfo) !void {
        try self.beginRecord(.meta);
        try self.writer.print(",\"pages\":{d},\"encrypted\":{}", .{ info.pages, info.encrypted });
        if (info.title) |t| try self.writeStringField("title", t);
        if (info.author) |a| try self.writeStringField("author", a);
        if (info.producer) |p| try self.writeStringField("producer", p);
        try self.endRecord();
    }

    pub fn emitPage(
        self: *Envelope,
        page_idx: u32,
        markdown: []const u8,
        warnings: []const Warning,
    ) !void {
        try self.beginRecord(.page);
        try self.writer.print(",\"page\":{d}", .{page_idx});
        try self.writeStringField("markdown", markdown);
        try self.writer.writeAll(",\"warnings\":[");
        for (warnings, 0..) |w, i| {
            if (i > 0) try self.writer.writeAll(",");
            try self.writer.writeAll("{\"code\":");
            try writeJsonString(self.writer, w.code);
            try self.writer.writeAll(",\"message\":");
            try writeJsonString(self.writer, w.message);
            try self.writer.writeAll("}");
        }
        try self.writer.writeAll("]");
        try self.endRecord();
    }

    pub fn emitToc(self: *Envelope, items: []const TocItem) !void {
        try self.beginRecord(.toc);
        try self.writer.writeAll(",\"items\":[");
        for (items, 0..) |item, i| {
            if (i > 0) try self.writer.writeAll(",");
            try self.writer.writeAll("{\"title\":");
            try writeJsonString(self.writer, item.title);
            try self.writer.print(",\"page\":{d},\"depth\":{d}}}", .{ item.page, item.depth });
        }
        try self.writer.writeAll("]");
        try self.endRecord();
    }

    pub fn emitSummary(self: *Envelope, totals: Totals) !void {
        try self.beginRecord(.summary);
        try self.writer.print(
            ",\"pages_emitted\":{d},\"bytes_emitted\":{d},\"warnings_count\":{d},\"elapsed_ms\":{d}",
            .{ totals.pages_emitted, totals.bytes_emitted, totals.warnings_count, totals.elapsed_ms },
        );
        try self.endRecord();
    }

    pub fn emitFatal(self: *Envelope, err: FatalError) !void {
        try self.beginRecord(.fatal);
        try self.writer.writeAll(",\"error\":");
        try writeJsonString(self.writer, err.kind.asString());
        try self.writeStringField("message", err.message);
        if (err.at_page) |p| try self.writer.print(",\"at_page\":{d}", .{p});
        try self.writer.print(",\"recoverable\":{}", .{err.recoverable});
        try self.endRecord();
    }

    pub fn emitChunk(
        self: *Envelope,
        chunk_id: u32,
        pages: []const u32,
        markdown: []const u8,
        tokens_est: u32,
        breakpoint: ChunkBreak,
    ) !void {
        try self.beginRecord(.chunk);
        try self.writer.print(",\"chunk_id\":{d},\"pages\":[", .{chunk_id});
        for (pages, 0..) |p, i| {
            if (i > 0) try self.writer.writeAll(",");
            try self.writer.print("{d}", .{p});
        }
        try self.writer.print("],\"tokens_est\":{d},\"break\":", .{tokens_est});
        try writeJsonString(self.writer, breakpoint.asString());
        try self.writeStringField("markdown", markdown);
        try self.endRecord();
    }

    pub fn emitInterrupted(self: *Envelope, signal_num: c_int) !void {
        try self.beginRecord(.interrupted);
        try self.writer.print(",\"signal\":{d}", .{signal_num});
        try self.endRecord();
    }

    fn beginRecord(self: *Envelope, kind: RecordKind) !void {
        try self.writer.writeAll("{\"kind\":\"");
        try self.writer.writeAll(kind.asString());
        try self.writer.writeAll("\",\"doc_id\":\"");
        try self.writer.writeAll(&self.doc_id);
        try self.writer.writeAll("\",\"source\":");
        try writeJsonString(self.writer, self.source);
    }

    fn endRecord(self: *Envelope) !void {
        try self.writer.writeAll("}\n");
    }

    fn writeStringField(self: *Envelope, name: []const u8, value: []const u8) !void {
        try self.writer.writeAll(",\"");
        try self.writer.writeAll(name);
        try self.writer.writeAll("\":");
        try writeJsonString(self.writer, value);
    }
};

/// Write a JSON string literal: surrounded by double quotes, with the minimum
/// set of escapes required by RFC 8259. Valid UTF-8 sequences pass through;
/// invalid bytes are replaced with `�` per Unicode Standard §3.9 so the
/// output is always well-formed JSON regardless of upstream encoding bugs.
pub fn writeJsonString(writer: *std.io.Writer, s: []const u8) !void {
    try writer.writeAll("\"");
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        switch (b) {
            '"' => {
                try writer.writeAll("\\\"");
                i += 1;
            },
            '\\' => {
                try writer.writeAll("\\\\");
                i += 1;
            },
            '\n' => {
                try writer.writeAll("\\n");
                i += 1;
            },
            '\r' => {
                try writer.writeAll("\\r");
                i += 1;
            },
            '\t' => {
                try writer.writeAll("\\t");
                i += 1;
            },
            0x08 => {
                try writer.writeAll("\\b");
                i += 1;
            },
            0x0c => {
                try writer.writeAll("\\f");
                i += 1;
            },
            0...0x07, 0x0b, 0x0e...0x1f => {
                try writer.print("\\u{x:0>4}", .{b});
                i += 1;
            },
            else => {
                if (b < 0x80) {
                    try writer.writeAll(&.{b});
                    i += 1;
                } else {
                    const seq_len = std.unicode.utf8ByteSequenceLength(b) catch {
                        try writer.writeAll("\\ufffd");
                        i += 1;
                        continue;
                    };
                    if (i + seq_len > s.len) {
                        try writer.writeAll("\\ufffd");
                        i += 1;
                        continue;
                    }
                    _ = std.unicode.utf8Decode(s[i .. i + seq_len]) catch {
                        try writer.writeAll("\\ufffd");
                        i += 1;
                        continue;
                    };
                    try writer.writeAll(s[i .. i + seq_len]);
                    i += seq_len;
                }
            },
        }
    }
    try writer.writeAll("\"");
}

// ---- Signal handling ----

pub var interrupted_flag = std.atomic.Value(c_int).init(0);

fn handleInterrupt(sig: c_int) callconv(.c) void {
    interrupted_flag.store(sig, .seq_cst);
}

/// Install signal handlers per architecture.md §6.4.
/// Idempotent — safe to call multiple times.
pub fn registerSignalHandlers() !void {
    if (builtin.os.tag == .windows) return;

    const ignore_act = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &ignore_act, null);

    const interrupt_act = std.posix.Sigaction{
        .handler = .{ .handler = handleInterrupt },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &interrupt_act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &interrupt_act, null);
}

pub fn wasInterrupted() ?c_int {
    const v = interrupted_flag.load(.seq_cst);
    return if (v == 0) null else v;
}

pub fn clearInterrupted() void {
    interrupted_flag.store(0, .seq_cst);
}

// ---- tests ----

const FIXED_DOC_ID: uuid.String = "01234567-89ab-7cde-8f01-23456789abcd".*;

test "envelope record contains kind, doc_id, source" {
    var buf: [4096]u8 = undefined;
    var aw = std.io.Writer.fixed(&buf);
    var env = Envelope.initWithId(&aw, "test.pdf", FIXED_DOC_ID);
    try env.emitMeta(.{ .pages = 5, .encrypted = false });
    const written = aw.buffered();

    try std.testing.expect(std.mem.indexOf(u8, written, "\"kind\":\"meta\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"doc_id\":\"01234567-89ab-7cde-8f01-23456789abcd\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"source\":\"test.pdf\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, written, "}\n"));
}

test "string escape: quotes, backslash, control chars" {
    var buf: [256]u8 = undefined;
    var aw = std.io.Writer.fixed(&buf);
    try writeJsonString(&aw, "a\"b\\c\nd\te\x01f");
    const written = aw.buffered();
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\te\\u0001f\"", written);
}

test "string escape: valid UTF-8 passes through" {
    var buf: [256]u8 = undefined;
    var aw = std.io.Writer.fixed(&buf);
    try writeJsonString(&aw, "café 你好 €");
    const written = aw.buffered();
    try std.testing.expectEqualStrings("\"café 你好 €\"", written);
}

test "string escape: invalid UTF-8 → U+FFFD replacement" {
    var buf: [256]u8 = undefined;
    var aw = std.io.Writer.fixed(&buf);
    // \xfe\xff is a UTF-16BE BOM; bytes are not valid UTF-8 leading bytes.
    try writeJsonString(&aw, "abc\xfe\xff M\x00 i\x00");
    const written = aw.buffered();
    // Must remain valid JSON: replacement character + control-char escape.
    try std.testing.expect(std.mem.startsWith(u8, written, "\"abc"));
    try std.testing.expect(std.mem.indexOf(u8, written, "\\ufffd") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\\u0000") != null);
    try std.testing.expectEqual(@as(u8, '"'), written[written.len - 1]);
}

test "string escape: truncated UTF-8 sequence → U+FFFD" {
    var buf: [256]u8 = undefined;
    var aw = std.io.Writer.fixed(&buf);
    // \xc3 is a 2-byte UTF-8 leading byte but missing the continuation.
    try writeJsonString(&aw, "x\xc3");
    const written = aw.buffered();
    try std.testing.expectEqualStrings("\"x\\ufffd\"", written);
}

test "page record escapes embedded newlines in markdown" {
    var buf: [4096]u8 = undefined;
    var aw = std.io.Writer.fixed(&buf);
    var env = Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID);
    try env.emitPage(0, "line1\nline2\nline3", &.{});
    const written = aw.buffered();
    // Exactly one record-terminating newline; markdown newlines are escaped.
    var newline_count: usize = 0;
    for (written) |b| if (b == '\n') {
        newline_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), newline_count);
    try std.testing.expect(std.mem.indexOf(u8, written, "line1\\nline2\\nline3") != null);
}

test "page record with warnings array" {
    var buf: [4096]u8 = undefined;
    var aw = std.io.Writer.fixed(&buf);
    var env = Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID);
    try env.emitPage(2, "ok", &.{
        .{ .code = "cmap_missing", .message = "font has no ToUnicode CMap" },
    });
    const written = aw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"page\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"code\":\"cmap_missing\"") != null);
}

test "fatal record carries error kind + recoverable" {
    var buf: [1024]u8 = undefined;
    var aw = std.io.Writer.fixed(&buf);
    var env = Envelope.initWithId(&aw, "bad.pdf", FIXED_DOC_ID);
    try env.emitFatal(.{
        .kind = .encrypted,
        .message = "PDF is encrypted",
        .recoverable = false,
    });
    const written = aw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"error\":\"encrypted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"recoverable\":false") != null);
}

test "chunk record emits pages array + tokens_est + break" {
    var buf: [1024]u8 = undefined;
    var aw = std.io.Writer.fixed(&buf);
    var env = Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID);
    try env.emitChunk(0, &.{ 0, 1, 2 }, "## Heading\n\ntext", 12, .section_heading);
    const written = aw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"chunk_id\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"pages\":[0,1,2]") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"tokens_est\":12") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"break\":\"section_heading\"") != null);
}

test "interrupted record carries signal number" {
    var buf: [1024]u8 = undefined;
    var aw = std.io.Writer.fixed(&buf);
    var env = Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID);
    try env.emitInterrupted(2);
    const written = aw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"kind\":\"interrupted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"signal\":2") != null);
}

test "every record is valid JSON Lines (one trailing newline, no embedded newlines)" {
    var buf: [4096]u8 = undefined;
    var aw = std.io.Writer.fixed(&buf);
    var env = Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID);
    try env.emitMeta(.{ .pages = 3, .encrypted = false });
    try env.emitPage(0, "hello\nworld", &.{});
    try env.emitSummary(.{ .pages_emitted = 1, .bytes_emitted = 11, .warnings_count = 0, .elapsed_ms = 5 });

    var lines: usize = 0;
    var iter = std.mem.splitScalar(u8, aw.buffered(), '\n');
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        lines += 1;
        // Each non-empty line should start with `{` and end with `}`.
        try std.testing.expectEqual(@as(u8, '{'), line[0]);
        try std.testing.expectEqual(@as(u8, '}'), line[line.len - 1]);
    }
    try std.testing.expectEqual(@as(usize, 3), lines);
}

test "registerSignalHandlers is idempotent" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try registerSignalHandlers();
    try registerSignalHandlers();
}
