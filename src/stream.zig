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
    links,
    form,
    table,
    /// PR-17 [feat]: long-PDF section checkpoint. Heuristic-extracted
    /// from `# ` markdown headers; downstream consumers (LLM
    /// chunkers, citation tools) use it to anchor references to
    /// logical document divisions.
    section,
    /// PR-20 [feat]: per-page non-/Link annotations (highlight,
    /// underline, strikeout, ink, text/sticky-note, freetext, …).
    /// Existing `kind:"links"` is unchanged; `/Link` and `/Widget`
    /// subtypes are filtered out of `kind:"annotations"`.
    annotations,
    /// PR-19 [feat]: per-image metadata record. One record per image
    /// XObject placed on a page. Carries page index, position bbox,
    /// and pixel dimensions. Image bytes / encoding / base64 / path
    /// modes are deferred to a PR-19 follow-up.
    image,
    /// PR-21 [feat]: per-document PDF/UA structure tree. Single
    /// record carrying the full /StructTreeRoot walk as a JSON tree.
    /// Off by default (records can be very large on long documents).
    struct_tree,
    /// PR-15 [feat]: standalone warning record. Used for document- /
    /// page-scope conditions that don't fit inside a `page` record's
    /// embedded `warnings:[]` array — currently
    /// `vertical_writing_unsupported` (§9 cases #10 + #12).
    warning,

    pub fn asString(self: RecordKind) []const u8 {
        return switch (self) {
            .meta => "meta",
            .page => "page",
            .toc => "toc",
            .summary => "summary",
            .fatal => "fatal",
            .chunk => "chunk",
            .interrupted => "interrupted",
            .links => "links",
            .form => "form",
            .table => "table",
            .section => "section",
            .annotations => "annotations",
            .image => "image",
            .struct_tree => "struct_tree",
            .warning => "warning",
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

pub const LinkItem = struct {
    /// PDF page rect: [x0, y0, x1, y1] in PDF user-space points (bottom-left origin).
    rect: [4]f64,
    /// External URI if present, or null for an internal/dest link.
    uri: ?[]const u8 = null,
    /// 1-based destination page if this is an internal link.
    dest_page: ?u32 = null,
};

/// PR-20 [feat]: non-/Link annotation payload. `subtype` is the
/// raw `/Subtype` name lower-cased (e.g. `"highlight"`, `"underline"`,
/// `"strikeout"`, `"ink"`, `"text"`, `"freetext"`). Emitted via
/// `Envelope.emitAnnotations` as one `kind:"annotations"` record per
/// page that has any non-link annotation.
pub const AnnotationItem = struct {
    subtype: []const u8,
    /// PDF page rect: [x0, y0, x1, y1] in user-space points.
    rect: [4]f64,
    /// `/Contents` entry — text content of the annotation.
    contents: ?[]const u8 = null,
    /// `/T` entry — annotation author / title.
    author: ?[]const u8 = null,
    /// `/M` entry — modification date as the raw PDF date string
    /// (e.g. `"D:20260430123045Z"`); not parsed.
    modified: ?[]const u8 = null,
};

/// PR-19 [feat]: per-image metadata for the `--images` mode.
/// Emitted as one `kind:"image"` record per image XObject placed on a
/// page.  Metadata fields are always present; the optional `payload_b64`
/// and `warnings` fields appear only in `--images=base64` mode.
pub const ImageItem = struct {
    /// PDF page bbox after CTM, in user-space points.
    bbox: [4]f64,
    /// Image XObject /Width.
    width_px: u32,
    /// Image XObject /Height.
    height_px: u32,
    /// First entry of the image XObject's /Filter (e.g. "DCTDecode",
    /// "FlateDecode", "JPXDecode", "CCITTFaxDecode"), or `null` for
    /// uncompressed sample data. Borrowed slice — caller does not own.
    encoding: ?[]const u8 = null,
    /// Base64-encoded raw stream bytes for passthrough-friendly filters
    /// (DCTDecode / JPXDecode / CCITTFaxDecode).  Set by the caller in
    /// `--images=base64` mode; `null` in metadata mode or when the
    /// filter is unsupported (see `warnings`).  Borrowed — caller owns.
    payload_b64: ?[]const u8 = null,
    /// Non-null in `--images=base64` / `--images=path` modes when the
    /// payload (or path) could not be populated (e.g.
    /// `["unsupported_filter:FlateDecode"]`).  Null in metadata mode.
    /// Borrowed slice of slices — caller owns.
    warnings: ?[]const []const u8 = null,
    /// Path to the extracted image file, set only by `--images=path`
    /// mode. The CLI writes the file before emitting the record;
    /// the path is relative to the user-supplied --images-dir (or cwd
    /// when omitted).  Null in other modes.  Borrowed slice — caller owns.
    path: ?[]const u8 = null,
};

/// PR-18 [feat]: per-span text + bbox payload for the `--bboxes`
/// citation-grade extraction mode. Emitted as a parallel
/// `spans:[{text, bbox:[x0,y0,x1,y1], font_size, font_name}]` array
/// on `kind:"page"` records when the flag is set.
pub const SpanInfo = struct {
    text: []const u8,
    /// PDF user-space bbox: [x0, y0, x1, y1], bottom-left origin.
    bbox: [4]f64,
    font_size: f64,
    /// Reserved for a future pass that threads font name through
    /// `SpanCollector`. v1 emits `null` (skipped from JSON).
    font_name: ?[]const u8 = null,
};

pub const FormFieldType = enum { text, button, choice, signature, unknown };

pub const FormFieldItem = struct {
    name: []const u8,
    value: ?[]const u8 = null,
    field_type: FormFieldType = .unknown,
    rect: ?[4]f64 = null,
};

pub const TableEngine = enum { tagged, lattice, stream };

pub const TableCell = struct {
    r: u32,
    c: u32,
    rowspan: u32 = 1,
    colspan: u32 = 1,
    is_header: bool = false,
    text: ?[]const u8 = null,
};

pub const TableContinuationLink = struct {
    page: u32,
    table_id: u32,
};

pub const TableRecord = struct {
    /// 1-based page number.
    page: u32,
    /// Per-page table id (0-based).
    table_id: u32,
    n_rows: u32,
    n_cols: u32,
    header_rows: u32,
    cells: []const TableCell,
    engine: TableEngine,
    confidence: f32,
    /// Optional [x0, y0, x1, y1] in PDF user-space (bottom-left origin).
    bbox: ?[4]f64 = null,
    /// Multi-page continuation links — null when this table doesn't
    /// continue across pages.
    continued_from: ?TableContinuationLink = null,
    continued_to: ?TableContinuationLink = null,
};

pub const DocumentInfo = struct {
    pages: u32,
    encrypted: bool,
    title: ?[]const u8 = null,
    author: ?[]const u8 = null,
    subject: ?[]const u8 = null,
    keywords: ?[]const u8 = null,
    creator: ?[]const u8 = null,
    producer: ?[]const u8 = null,
    creation_date: ?[]const u8 = null,
    mod_date: ?[]const u8 = null,
};

pub const Totals = struct {
    pages_emitted: u32,
    bytes_emitted: u64,
    warnings_count: u32,
    elapsed_ms: u64,
    /// PR-11 [feat]: optional NDJSON `quality_flag` field on summary
    /// records. Currently the only emitted value is `"scanned"`,
    /// triggered when ≥ scan_threshold of pages produced very little
    /// text (heuristic detection of image-only / scanned PDFs).
    /// `null` means the field is omitted entirely from the JSON
    /// (preserves the v1.x schema for born-digital PDFs).
    quality_flag: ?[]const u8 = null,
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
    writer: *std.Io.Writer,

    pub fn init(io: std.Io, writer: *std.Io.Writer, source: []const u8) Envelope {
        return .{
            .doc_id = uuid.v7(io),
            .source = source,
            .writer = writer,
        };
    }

    /// Override doc_id (used in tests for determinism).
    pub fn initWithId(writer: *std.Io.Writer, source: []const u8, doc_id: uuid.String) Envelope {
        return .{ .doc_id = doc_id, .source = source, .writer = writer };
    }

    pub fn emitMeta(self: *Envelope, info: DocumentInfo) !void {
        try self.beginRecord(.meta);
        try self.writer.print(",\"pages\":{d},\"encrypted\":{}", .{ info.pages, info.encrypted });
        if (info.title) |t| try self.writeStringField("title", t);
        if (info.author) |a| try self.writeStringField("author", a);
        if (info.subject) |s| try self.writeStringField("subject", s);
        if (info.keywords) |k| try self.writeStringField("keywords", k);
        if (info.creator) |c| try self.writeStringField("creator", c);
        if (info.producer) |p| try self.writeStringField("producer", p);
        if (info.creation_date) |d| try self.writeStringField("creation_date", d);
        if (info.mod_date) |d| try self.writeStringField("mod_date", d);
        try self.endRecord();
    }

    /// `page_number` is 1-based (PDF page numbering convention used by every
    /// LLM citation and human-facing tool). The caller must convert from
    /// 0-based internal indices.
    pub fn emitPage(
        self: *Envelope,
        page_number: u32,
        markdown: []const u8,
        warnings: []const Warning,
    ) !void {
        try self.beginRecord(.page);
        try self.writer.print(",\"page\":{d}", .{page_number});
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

    /// PR-18 [feat]: same as `emitPage`, plus a parallel
    /// `spans:[{text, bbox:[x0,y0,x1,y1], font_size, font_name}]`
    /// array. The array order matches the per-span emission order from
    /// `extractTextWithBounds` (PDF stream order). Used by the
    /// `--bboxes` flag in `runExtract` to surface citation-grade
    /// extraction.
    pub fn emitPageWithSpans(
        self: *Envelope,
        page_number: u32,
        markdown: []const u8,
        warnings: []const Warning,
        spans: []const SpanInfo,
    ) !void {
        try self.beginRecord(.page);
        try self.writer.print(",\"page\":{d}", .{page_number});
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
        try self.writer.writeAll("],\"spans\":[");
        for (spans, 0..) |s, i| {
            if (i > 0) try self.writer.writeAll(",");
            try self.writer.writeAll("{\"text\":");
            try writeJsonString(self.writer, s.text);
            try self.writer.print(
                ",\"bbox\":[{d:.2},{d:.2},{d:.2},{d:.2}],\"font_size\":{d:.2}",
                .{ s.bbox[0], s.bbox[1], s.bbox[2], s.bbox[3], s.font_size },
            );
            if (s.font_name) |fn_| {
                try self.writer.writeAll(",\"font_name\":");
                try writeJsonString(self.writer, fn_);
            }
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

    /// PR-17 [feat]: emit a section checkpoint record. `section_id`
    /// is 0-indexed; `start_page` and `end_page` are 1-indexed
    /// (matching the v1.x page-numbering convention used by other
    /// records). Title is the markdown heading text without the
    /// leading `# ` prefix.
    pub fn emitSection(
        self: *Envelope,
        section_id: u32,
        title: []const u8,
        start_page: u32,
        end_page: u32,
    ) !void {
        try self.beginRecord(.section);
        try self.writer.print(",\"section_id\":{d},\"title\":", .{section_id});
        try writeJsonString(self.writer, title);
        try self.writer.print(",\"start_page\":{d},\"end_page\":{d}", .{ start_page, end_page });
        try self.endRecord();
    }

    pub fn emitLinks(self: *Envelope, page_number: u32, items: []const LinkItem) !void {
        try self.beginRecord(.links);
        try self.writer.print(",\"page\":{d},\"items\":[", .{page_number});
        for (items, 0..) |item, i| {
            if (i > 0) try self.writer.writeAll(",");
            try self.writer.print(
                "{{\"rect\":[{d:.2},{d:.2},{d:.2},{d:.2}]",
                .{ item.rect[0], item.rect[1], item.rect[2], item.rect[3] },
            );
            if (item.uri) |u| {
                try self.writer.writeAll(",\"uri\":");
                try writeJsonString(self.writer, u);
            }
            if (item.dest_page) |p| try self.writer.print(",\"dest_page\":{d}", .{p});
            try self.writer.writeAll("}");
        }
        try self.writer.writeAll("]");
        try self.endRecord();
    }

    /// PR-21 [feat]: open a `kind:"struct_tree"` record. The caller
    /// is responsible for writing the body (the JSON tree); this
    /// helper writes the leading `,"root":` separator and closes the
    /// record on `endStructTreeRecord`. Layered like this so
    /// `stream.zig` doesn't need to know about `structtree`'s types.
    pub fn beginStructTreeRecord(self: *Envelope) !void {
        try self.beginRecord(.struct_tree);
        try self.writer.writeAll(",\"root\":");
    }

    pub fn endStructTreeRecord(self: *Envelope) !void {
        try self.endRecord();
    }

    /// Caller-side helper for the (rare) case of an empty struct tree.
    pub fn emitStructTreeEmpty(self: *Envelope) !void {
        try self.beginStructTreeRecord();
        try self.writer.writeAll("null");
        try self.endStructTreeRecord();
    }

    /// PR-19 [feat]: emit `kind:"image"` for one image. The caller
    /// loops per page and per image (one record per image, NOT one
    /// record per page like links/annotations) to keep records flat
    /// for embedding pipelines that batch on a per-image basis.
    ///
    /// `payload_b64` / `warnings` discipline (--images=base64 mode):
    ///   - `payload_b64` non-null  → emit `"payload_b64":"<b64>"`
    ///   - `payload_b64` null + `warnings` non-null → emit `"payload_b64":null`
    ///   - both null (metadata mode) → `payload_b64` field absent entirely
    pub fn emitImage(self: *Envelope, page_number: u32, item: ImageItem) !void {
        try self.beginRecord(.image);
        try self.writer.print(
            ",\"page\":{d},\"bbox\":[{d:.2},{d:.2},{d:.2},{d:.2}],\"width_px\":{d},\"height_px\":{d}",
            .{ page_number, item.bbox[0], item.bbox[1], item.bbox[2], item.bbox[3], item.width_px, item.height_px },
        );
        if (item.encoding) |enc| {
            try self.writer.writeAll(",\"encoding\":");
            try writeJsonString(self.writer, enc);
        }
        if (item.payload_b64) |b64| {
            try self.writer.writeAll(",\"payload_b64\":");
            try writeJsonString(self.writer, b64);
        } else if (item.warnings != null) {
            try self.writer.writeAll(",\"payload_b64\":null");
        }
        if (item.warnings) |ws| {
            try self.writer.writeAll(",\"warnings\":[");
            for (ws, 0..) |w, i| {
                if (i > 0) try self.writer.writeAll(",");
                try writeJsonString(self.writer, w);
            }
            try self.writer.writeAll("]");
        }
        if (item.path) |p| {
            try self.writer.writeAll(",\"path\":");
            try writeJsonString(self.writer, p);
        }
        try self.endRecord();
    }

    /// PR-20 [feat]: emit `kind:"annotations"` for non-/Link
    /// annotations on a page. Caller filters /Link upstream
    /// (`Document.getPageAnnotations` does this).
    pub fn emitAnnotations(self: *Envelope, page_number: u32, items: []const AnnotationItem) !void {
        try self.beginRecord(.annotations);
        try self.writer.print(",\"page\":{d},\"items\":[", .{page_number});
        for (items, 0..) |item, i| {
            if (i > 0) try self.writer.writeAll(",");
            try self.writer.writeAll("{\"type\":");
            try writeJsonString(self.writer, item.subtype);
            try self.writer.print(
                ",\"rect\":[{d:.2},{d:.2},{d:.2},{d:.2}]",
                .{ item.rect[0], item.rect[1], item.rect[2], item.rect[3] },
            );
            if (item.contents) |s| {
                try self.writer.writeAll(",\"contents\":");
                try writeJsonString(self.writer, s);
            }
            if (item.author) |s| {
                try self.writer.writeAll(",\"author\":");
                try writeJsonString(self.writer, s);
            }
            if (item.modified) |s| {
                try self.writer.writeAll(",\"modified\":");
                try writeJsonString(self.writer, s);
            }
            try self.writer.writeAll("}");
        }
        try self.writer.writeAll("]");
        try self.endRecord();
    }

    pub fn emitForm(self: *Envelope, fields: []const FormFieldItem) !void {
        try self.beginRecord(.form);
        try self.writer.writeAll(",\"fields\":[");
        for (fields, 0..) |f, i| {
            if (i > 0) try self.writer.writeAll(",");
            try self.writer.writeAll("{\"name\":");
            try writeJsonString(self.writer, f.name);
            try self.writer.writeAll(",\"type\":");
            try writeJsonString(self.writer, @tagName(f.field_type));
            if (f.value) |v| {
                try self.writer.writeAll(",\"value\":");
                try writeJsonString(self.writer, v);
            }
            if (f.rect) |r| {
                try self.writer.print(
                    ",\"rect\":[{d:.2},{d:.2},{d:.2},{d:.2}]",
                    .{ r[0], r[1], r[2], r[3] },
                );
            }
            try self.writer.writeAll("}");
        }
        try self.writer.writeAll("]");
        try self.endRecord();
    }

    pub fn emitTable(self: *Envelope, t: TableRecord) !void {
        try self.beginRecord(.table);
        try self.writer.print(
            ",\"page\":{d},\"table_id\":{d},\"engine\":",
            .{ t.page, t.table_id },
        );
        try writeJsonString(self.writer, switch (t.engine) {
            .tagged => "native_tagged",
            .lattice => "native_lattice",
            .stream => "native_stream",
        });
        try self.writer.print(
            ",\"confidence\":{d:.2},\"n_rows\":{d},\"n_cols\":{d},\"header_rows\":{d}",
            .{ t.confidence, t.n_rows, t.n_cols, t.header_rows },
        );
        if (t.bbox) |b| {
            try self.writer.print(
                ",\"bbox\":[{d:.2},{d:.2},{d:.2},{d:.2}]",
                .{ b[0], b[1], b[2], b[3] },
            );
        }
        if (t.continued_from) |link| {
            try self.writer.print(
                ",\"continued_from\":{{\"page\":{d},\"table_id\":{d}}}",
                .{ link.page, link.table_id },
            );
        }
        if (t.continued_to) |link| {
            try self.writer.print(
                ",\"continued_to\":{{\"page\":{d},\"table_id\":{d}}}",
                .{ link.page, link.table_id },
            );
        }
        try self.writer.writeAll(",\"cells\":[");
        for (t.cells, 0..) |cell, i| {
            if (i > 0) try self.writer.writeAll(",");
            try self.writer.print(
                "{{\"r\":{d},\"c\":{d},\"rowspan\":{d},\"colspan\":{d},\"is_header\":{}",
                .{ cell.r, cell.c, cell.rowspan, cell.colspan, cell.is_header },
            );
            if (cell.text) |txt| {
                try self.writer.writeAll(",\"text\":");
                try writeJsonString(self.writer, txt);
            }
            try self.writer.writeAll("}");
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
        // PR-11 [feat]: opt-in quality_flag field. Only emit when set
        // (null preserves the v1.x born-digital summary shape).
        if (totals.quality_flag) |flag| {
            try self.writer.writeAll(",\"quality_flag\":");
            try writeJsonString(self.writer, flag);
        }
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

    /// PR-15 [feat]: emit a standalone `kind:"warning"` record. Used
    /// for warnings that aren't tied to a single page's extraction
    /// (e.g. `vertical_writing_unsupported` — the page is still
    /// emitted, but the extracted text is known to be wrong-order).
    /// `at_page` is 1-based; pass `null` for document-scope warnings.
    pub fn emitWarning(
        self: *Envelope,
        code: []const u8,
        message: []const u8,
        at_page: ?u32,
    ) !void {
        try self.beginRecord(.warning);
        try self.writer.writeAll(",\"code\":");
        try writeJsonString(self.writer, code);
        try self.writeStringField("message", message);
        if (at_page) |p| try self.writer.print(",\"at_page\":{d}", .{p});
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
pub fn writeJsonString(writer: *std.Io.Writer, s: []const u8) !void {
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
                    const cp = std.unicode.utf8Decode(s[i .. i + seq_len]) catch {
                        try writer.writeAll("\\ufffd");
                        i += 1;
                        continue;
                    };
                    // U+0085 NEL, U+2028 LINE SEPARATOR, U+2029 PARAGRAPH
                    // SEPARATOR are valid in JSON strings per RFC 8259, but
                    // Python's `str.splitlines()`, jq, awk, and many other
                    // line-buffered readers treat them as record separators
                    // — which silently breaks the NDJSON contract. Escape.
                    switch (cp) {
                        0x0085 => try writer.writeAll("\\u0085"),
                        0x2028 => try writer.writeAll("\\u2028"),
                        0x2029 => try writer.writeAll("\\u2029"),
                        else => try writer.writeAll(s[i .. i + seq_len]),
                    }
                    i += seq_len;
                }
            },
        }
    }
    try writer.writeAll("\"");
}

// ---- Signal handling ----

pub var interrupted_flag = std.atomic.Value(c_int).init(0);

fn handleInterrupt(sig: std.posix.SIG) callconv(.c) void {
    interrupted_flag.store(@intCast(@intFromEnum(sig)), .seq_cst);
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
    var aw = std.Io.Writer.fixed(&buf);
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
    var aw = std.Io.Writer.fixed(&buf);
    try writeJsonString(&aw, "a\"b\\c\nd\te\x01f");
    const written = aw.buffered();
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\te\\u0001f\"", written);
}

test "string escape: valid UTF-8 passes through" {
    var buf: [256]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    try writeJsonString(&aw, "café 你好 €");
    const written = aw.buffered();
    try std.testing.expectEqualStrings("\"café 你好 €\"", written);
}

test "string escape: invalid UTF-8 → U+FFFD replacement" {
    var buf: [256]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    // \xfe\xff is a UTF-16BE BOM; bytes are not valid UTF-8 leading bytes.
    try writeJsonString(&aw, "abc\xfe\xff M\x00 i\x00");
    const written = aw.buffered();
    // Must remain valid JSON: replacement character + control-char escape.
    try std.testing.expect(std.mem.startsWith(u8, written, "\"abc"));
    try std.testing.expect(std.mem.indexOf(u8, written, "\\ufffd") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\\u0000") != null);
    try std.testing.expectEqual(@as(u8, '"'), written[written.len - 1]);
}

test "string escape: Unicode line separators (U+0085 / U+2028 / U+2029) are escaped" {
    var buf: [256]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    // U+0085 = C2 85, U+2028 = E2 80 A8, U+2029 = E2 80 A9 in UTF-8.
    try writeJsonString(&aw, "a\xc2\x85b\xe2\x80\xa8c\xe2\x80\xa9d");
    const written = aw.buffered();
    try std.testing.expectEqualStrings(
        "\"a\\u0085b\\u2028c\\u2029d\"",
        written,
    );
}

test "string escape: truncated UTF-8 sequence → U+FFFD" {
    var buf: [256]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    // \xc3 is a 2-byte UTF-8 leading byte but missing the continuation.
    try writeJsonString(&aw, "x\xc3");
    const written = aw.buffered();
    try std.testing.expectEqualStrings("\"x\\ufffd\"", written);
}

test "page record escapes embedded newlines in markdown" {
    var buf: [4096]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
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
    var aw = std.Io.Writer.fixed(&buf);
    var env = Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID);
    try env.emitPage(2, "ok", &.{
        .{ .code = "cmap_missing", .message = "font has no ToUnicode CMap" },
    });
    const written = aw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"page\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"code\":\"cmap_missing\"") != null);
}

test "PR-18: emitPageWithSpans appends spans:[] with bbox + font_size" {
    var buf: [4096]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    var env = Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID);
    try env.emitPageWithSpans(1, "Hello world", &.{}, &.{
        .{ .text = "Hello", .bbox = .{ 72, 720, 100, 732 }, .font_size = 12 },
        .{ .text = "world", .bbox = .{ 105, 720, 140, 732 }, .font_size = 12 },
    });
    const written = aw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"spans\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"text\":\"Hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"bbox\":[72.00,720.00,100.00,732.00]") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"font_size\":12.00") != null);
    // font_name is null by default; should NOT appear in the JSON.
    try std.testing.expect(std.mem.indexOf(u8, written, "\"font_name\"") == null);
}

test "PR-18: emitPageWithSpans omits font_name when null but emits when set" {
    var buf: [4096]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    var env = Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID);
    try env.emitPageWithSpans(1, "x", &.{}, &.{
        .{ .text = "x", .bbox = .{ 0, 0, 10, 10 }, .font_size = 12, .font_name = "Helvetica" },
    });
    const written = aw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"font_name\":\"Helvetica\"") != null);
}

test "PR-18: emitPageWithSpans handles empty spans array as []" {
    var buf: [1024]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    var env = Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID);
    try env.emitPageWithSpans(1, "no text", &.{}, &.{});
    const written = aw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"spans\":[]") != null);
}

test "PR-20: emitAnnotations basic shape (subtype + rect)" {
    var buf: [4096]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    var env = Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID);
    try env.emitAnnotations(1, &.{
        .{ .subtype = "highlight", .rect = .{ 100, 200, 300, 220 } },
        .{ .subtype = "ink", .rect = .{ 50, 60, 70, 80 } },
    });
    const written = aw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"kind\":\"annotations\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"page\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"type\":\"highlight\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"type\":\"ink\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"rect\":[100.00,200.00,300.00,220.00]") != null);
    // Optional fields absent → not in JSON.
    try std.testing.expect(std.mem.indexOf(u8, written, "\"contents\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"author\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"modified\"") == null);
}

test "PR-20: emitAnnotations emits contents/author/modified when present" {
    var buf: [4096]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    var env = Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID);
    try env.emitAnnotations(2, &.{
        .{
            .subtype = "text",
            .rect = .{ 0, 0, 10, 10 },
            .contents = "Sticky note here",
            .author = "Reviewer A",
            .modified = "D:20260430123045Z",
        },
    });
    const written = aw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"contents\":\"Sticky note here\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"author\":\"Reviewer A\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"modified\":\"D:20260430123045Z\"") != null);
}

test "PR-20: emitAnnotations with empty list still emits the record" {
    var buf: [1024]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    var env = Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID);
    try env.emitAnnotations(1, &.{});
    const written = aw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"items\":[]") != null);
}

test "PR-19: emitImage emits page + bbox + pixel dims" {
    var buf: [2048]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    var env = Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID);
    try env.emitImage(3, .{ .bbox = .{ 100, 500, 300, 650 }, .width_px = 200, .height_px = 150 });
    const written = aw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"kind\":\"image\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"page\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"bbox\":[100.00,500.00,300.00,650.00]") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"width_px\":200") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"height_px\":150") != null);
    // No encoding → field should be omitted entirely from the record.
    try std.testing.expect(std.mem.indexOf(u8, written, "\"encoding\"") == null);
}

test "PR-19: emitImage surfaces /Filter as encoding when set" {
    var buf: [2048]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    var env = Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID);
    try env.emitImage(1, .{
        .bbox = .{ 0, 0, 100, 100 },
        .width_px = 32,
        .height_px = 32,
        .encoding = "DCTDecode",
    });
    const written = aw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"encoding\":\"DCTDecode\"") != null);
}

test "PR-19 base64: emitImage emits payload_b64 when set" {
    var buf: [4096]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    var env = Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID);
    try env.emitImage(2, .{
        .bbox = .{ 0, 0, 100, 100 },
        .width_px = 10,
        .height_px = 10,
        .encoding = "DCTDecode",
        .payload_b64 = "/w==",
    });
    const written = aw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"payload_b64\":\"/w==\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"warnings\"") == null);
}

test "PR-19 base64: emitImage emits null payload_b64 + warnings for unsupported filter" {
    var buf: [4096]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    var env = Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID);
    const ws: []const []const u8 = &.{"unsupported_filter:FlateDecode"};
    try env.emitImage(1, .{
        .bbox = .{ 0, 0, 100, 100 },
        .width_px = 10,
        .height_px = 10,
        .encoding = "FlateDecode",
        .warnings = ws,
    });
    const written = aw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"payload_b64\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"warnings\":[\"unsupported_filter:FlateDecode\"]") != null);
}

test "PR-19 metadata: emitImage omits payload_b64 field entirely" {
    var buf: [2048]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    var env = Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID);
    try env.emitImage(1, .{
        .bbox = .{ 0, 0, 100, 100 },
        .width_px = 10,
        .height_px = 10,
        .encoding = "FlateDecode",
    });
    const written = aw.buffered();
    // Metadata mode: no payload_b64 or warnings fields at all.
    try std.testing.expect(std.mem.indexOf(u8, written, "\"payload_b64\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"warnings\"") == null);
}

test "PR-21: emitStructTreeEmpty produces null root" {
    var buf: [1024]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    var env = Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID);
    try env.emitStructTreeEmpty();
    const written = aw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"kind\":\"struct_tree\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"root\":null") != null);
}

test "PR-21: beginStructTreeRecord + write body + end emits well-formed JSON" {
    var buf: [2048]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    var env = Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID);
    try env.beginStructTreeRecord();
    // Caller-controlled body — minimal hand-written tree.
    try env.writer.writeAll("{\"type\":\"Document\",\"mcid_refs\":[],\"children\":[]}");
    try env.endStructTreeRecord();
    const written = aw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"kind\":\"struct_tree\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"root\":{\"type\":\"Document\"") != null);
}

test "fatal record carries error kind + recoverable" {
    var buf: [1024]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
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
    var aw = std.Io.Writer.fixed(&buf);
    var env = Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID);
    try env.emitChunk(0, &.{ 0, 1, 2 }, "## Heading\n\ntext", 12, .section_heading);
    const written = aw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"chunk_id\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"pages\":[0,1,2]") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"tokens_est\":12") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"break\":\"section_heading\"") != null);
}

test "table cell with text is emitted with `text` field" {
    var buf: [2048]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    var env = Envelope.initWithId(&aw, "menu.pdf", FIXED_DOC_ID);
    try env.emitTable(.{
        .page = 2,
        .table_id = 0,
        .n_rows = 1,
        .n_cols = 2,
        .header_rows = 0,
        .engine = .stream,
        .confidence = 0.8,
        .cells = &.{
            .{ .r = 0, .c = 0, .text = "Soupe à l'oignon" },
            .{ .r = 0, .c = 1, .text = "20" },
        },
    });
    const written = aw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"text\":\"Soupe à l'oignon\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"text\":\"20\"") != null);
}

test "table record emits page + engine + cell grid + confidence" {
    var buf: [4096]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    var env = Envelope.initWithId(&aw, "menu.pdf", FIXED_DOC_ID);
    try env.emitTable(.{
        .page = 3,
        .table_id = 0,
        .n_rows = 2,
        .n_cols = 2,
        .header_rows = 1,
        .engine = .tagged,
        .confidence = 1.0,
        .cells = &.{
            .{ .r = 0, .c = 0, .is_header = true },
            .{ .r = 0, .c = 1, .is_header = true },
            .{ .r = 1, .c = 0 },
            .{ .r = 1, .c = 1 },
        },
    });
    const written = aw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"kind\":\"table\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"page\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"engine\":\"native_tagged\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"n_rows\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"header_rows\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"is_header\":true") != null);
    try std.testing.expect(std.mem.endsWith(u8, written, "}\n"));
}

test "form record emits fields array with name, type, value, rect" {
    var buf: [2048]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    var env = Envelope.initWithId(&aw, "form.pdf", FIXED_DOC_ID);
    try env.emitForm(&.{
        .{ .name = "guest_name", .value = "L. Fabre", .field_type = .text, .rect = .{ 100, 700, 300, 720 } },
        .{ .name = "agree_terms", .value = "Yes", .field_type = .button },
    });
    const written = aw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"kind\":\"form\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"name\":\"guest_name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"type\":\"text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"value\":\"L. Fabre\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"rect\":[100.00,700.00,300.00,720.00]") != null);
    try std.testing.expect(std.mem.endsWith(u8, written, "}\n"));
}

test "links record emits per-page items with rect + uri/dest_page" {
    var buf: [2048]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    var env = Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID);
    try env.emitLinks(3, &.{
        .{ .rect = .{ 12.0, 200.0, 88.5, 215.5 }, .uri = "https://example.com/" },
        .{ .rect = .{ 100.0, 100.0, 200.0, 120.0 }, .dest_page = 7 },
    });
    const written = aw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"kind\":\"links\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"page\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"uri\":\"https://example.com/\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"dest_page\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "[12.00,200.00,88.50,215.50]") != null);
    try std.testing.expect(std.mem.endsWith(u8, written, "}\n"));
}

test "interrupted record carries signal number" {
    var buf: [1024]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    var env = Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID);
    try env.emitInterrupted(2);
    const written = aw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"kind\":\"interrupted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"signal\":2") != null);
}

test "PR-15: emitWarning emits kind, code, message, optional at_page" {
    var buf: [1024]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    var env = Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID);
    try env.emitWarning("vertical_writing_unsupported", "page uses /Identity-V", 7);
    const written = aw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"kind\":\"warning\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"code\":\"vertical_writing_unsupported\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"message\":\"page uses /Identity-V\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"at_page\":7") != null);
}

test "PR-15: emitWarning omits at_page when null" {
    var buf: [1024]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    var env = Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID);
    try env.emitWarning("doc_scope_warning", "applies to whole doc", null);
    const written = aw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"kind\":\"warning\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"at_page\":") == null);
}

test "emitSummary omits quality_flag when null (PR-11 default)" {
    var buf: [512]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    var env = Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID);
    try env.emitSummary(.{ .pages_emitted = 1, .bytes_emitted = 11, .warnings_count = 0, .elapsed_ms = 5 });
    const written = aw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"quality_flag\"") == null);
}

test "emitSummary emits quality_flag when set (PR-11 scanned)" {
    var buf: [512]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    var env = Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID);
    try env.emitSummary(.{
        .pages_emitted = 4,
        .bytes_emitted = 80,
        .warnings_count = 0,
        .elapsed_ms = 12,
        .quality_flag = "scanned",
    });
    const written = aw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"quality_flag\":\"scanned\"") != null);
}

// PR-17 [feat]: section record schema test.
test "emitSection writes section_id, title, start_page, end_page" {
    var buf: [512]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    var env = Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID);
    try env.emitSection(0, "Introduction", 1, 4);
    const written = aw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"kind\":\"section\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"section_id\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"title\":\"Introduction\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"start_page\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"end_page\":4") != null);
}

test "emitSection escapes title with quotes and newlines" {
    var buf: [512]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    var env = Envelope.initWithId(&aw, "x.pdf", FIXED_DOC_ID);
    try env.emitSection(7, "Tab\there\nand \"quotes\"", 5, 7);
    const written = aw.buffered();
    // Title bytes must be escaped — no literal newline or unescaped quote inside the JSON.
    var nl_count: usize = 0;
    for (written) |c| {
        if (c == '\n') nl_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), nl_count); // only the trailing newline
}

test "every record is valid JSON Lines (one trailing newline, no embedded newlines)" {
    var buf: [4096]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
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
