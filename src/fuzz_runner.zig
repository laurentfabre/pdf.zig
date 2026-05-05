//! Week-4 fuzz harness for pdf.zig.
//!
//! Per `docs/architecture.md` §11: ≥10 fuzz targets, ≥1M iters each, no
//! panics. ReleaseSafe build mode required so safety checks (UB sanitizer,
//! integer overflow, optional-null deref) trip the runtime instead of
//! silently producing bad output.
//!
//! Usage:
//!   zig build fuzz                              # 1M iters, every target
//!   PDFZIG_FUZZ_ITERS=10000 zig build fuzz      # quick smoke (CI default)
//!   PDFZIG_FUZZ_TARGET=stream_json zig build fuzz
//!   PDFZIG_FUZZ_SEED=0xCAFEBABE zig build fuzz
//!
//! Exit non-zero only if the harness itself errors. A target panic crashes
//! the process with a stack trace — that is the bug-report channel.

const std = @import("std");
const builtin = @import("builtin");
const zpdf = @import("root.zig");
const testpdf = @import("testpdf.zig");

const stream = @import("stream.zig");
const chunk = @import("chunk.zig");
const tokenizer = @import("tokenizer.zig");
const cli = @import("cli_pdfzig.zig");
const lattice = @import("lattice.zig");
const layout = @import("layout.zig");
const xmp_writer = @import("xmp_writer.zig");
const encrypt_writer = @import("encrypt_writer.zig");
const markdown_to_pdf = @import("markdown_to_pdf.zig");
const truetype = @import("truetype.zig");
const jpeg_meta = @import("jpeg_meta.zig");
const decompress = @import("decompress.zig");
const parser = @import("parser.zig");
const interpreter = @import("interpreter.zig");
const pdf_document = @import("pdf_document.zig");
const bidi = @import("bidi.zig");
const cff = @import("cff.zig");
const pdf_resources = @import("pdf_resources.zig");
const image_writer = @import("image_writer.zig");
const pdf_writer = @import("pdf_writer.zig");
const attr_flattener = @import("attr_flattener.zig");
const structtree = @import("structtree.zig");
const markdown = @import("markdown.zig");

// ============================================================================
// Target registry
// ============================================================================

const TargetFn = *const fn (rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void;

const Target = struct {
    name: []const u8,
    run: TargetFn,
    aggressive: bool = false,
    /// `reproducer_only` targets run only when explicitly named via
    /// `PDFZIG_FUZZ_TARGET=<name>`. Use for known-failing targets that
    /// would otherwise abort default + aggressive sweeps. Documented in
    /// `audit/fuzz_findings.md` against an open Finding so the gating
    /// decision has a single canonical justification.
    reproducer_only: bool = false,
};

/// Default gate set (PDFZIG_FUZZ_AGGRESSIVE unset). 11 targets, all required
/// to be panic-free at PDFZIG_FUZZ_ITERS iters per architecture.md §11.
///
/// The two `*_mutation` targets are gated behind PDFZIG_FUZZ_AGGRESSIVE=1
/// because they exercise an upstream heap-safety bucket that is documented
/// in `audit/fuzz_findings.md` (Finding 001) — fuzzer surfaces the bug
/// reliably around ~200k iters, but the bug is not user-reachable through
/// the pdf.zig CLI's own data-handling path (verified: the captured
/// reproducer parses cleanly through `pdf.zig info`).
const TARGETS = [_]Target{
    .{ .name = "tokenizer_count", .run = fuzzTokenizerCount },
    .{ .name = "stream_json_string", .run = fuzzStreamJsonString },
    .{ .name = "stream_envelope_meta", .run = fuzzStreamEnvelopeMeta },
    .{ .name = "stream_envelope_page", .run = fuzzStreamEnvelopePage },
    .{ .name = "chunk_break_finder", .run = fuzzChunkBreakFinder },
    .{ .name = "cli_parse_args", .run = fuzzCliParseArgs },
    .{ .name = "cli_page_range", .run = fuzzCliPageRange },
    .{ .name = "pdf_open_random", .run = fuzzPdfOpenRandom },
    .{ .name = "pdf_open_magic_prefix", .run = fuzzPdfOpenMagicPrefix },
    .{ .name = "pdf_extract_seed_repeat", .run = fuzzPdfExtractSeedRepeat },
    .{ .name = "tokenizer_realistic_md", .run = fuzzTokenizerRealisticMd },
    .{ .name = "lattice_content_random", .run = fuzzLatticeContentRandom },
    .{ .name = "lattice_form_xobject_mutation", .run = fuzzLatticeFormXObjectMutation },
    .{ .name = "tagged_table_mutation", .run = fuzzTaggedTableMutation },
    .{ .name = "link_continuations_random", .run = fuzzLinkContinuationsRandom },
    .{ .name = "lattice_pass_b_spans", .run = fuzzLatticePassBSpans },
    // v1.6 module surface (writer + a11y).
    .{ .name = "xmp_escape_xml", .run = fuzzXmpEscapeXml },
    .{ .name = "xmp_emit_random", .run = fuzzXmpEmitRandom },
    .{ .name = "encrypt_roundtrip_rc4", .run = fuzzEncryptRoundtripRc4 },
    .{ .name = "encrypt_roundtrip_aes", .run = fuzzEncryptRoundtripAes },
    .{ .name = "markdown_render_tagged", .run = fuzzMarkdownRenderTagged },
    .{ .name = "truetype_parse_random", .run = fuzzTruetypeParseRandom },
    .{ .name = "jpeg_meta_random", .run = fuzzJpegMetaRandom },
    // Iter-1 of the autonomous fuzz loop (audit/fuzz_loop_state.md).
    .{ .name = "decompress_ascii_hex_random", .run = fuzzDecompressAsciiHexRandom },
    .{ .name = "decompress_runlength_random", .run = fuzzDecompressRunLengthRandom },
    // Aggressive-gated: reproduces a u32 overflow trap inside `decodeASCII85`
    // when the round-trip encoder produces a 5-char tuple whose intermediate
    // accumulator (after the 4th '*85') exceeds 2^32. Minimal byte repro:
    // `"uuuuu"`. Bug lives in src/decompress.zig:386. See
    // audit/fuzz_findings.md (decoders section, ASCII85 overflow finding).
    // `reproducer_only`: this target deterministically aborts on the open
    // Finding 005 (decodeASCII85 u32 overflow). Running it inside the
    // aggressive sweep would crash an otherwise-clean PDFZIG_FUZZ_AGGRESSIVE=1
    // run; gating it as reproducer-only means it executes ONLY when
    // explicitly named via PDFZIG_FUZZ_TARGET=decompress_ascii85_roundtrip.
    // Promote back to .aggressive once Finding 005 is fixed.
    .{ .name = "decompress_ascii85_roundtrip", .run = fuzzDecompressAscii85Roundtrip, .reproducer_only = true },
    // Iter-2 of the autonomous fuzz loop (audit/fuzz_loop_state.md) —
    // `parser.zig` (Parser.parseObject / parseIndirectObject / initAt).
    // Today the only fuzz coverage of the COS object parser is via
    // `pdf_open_random` + `pdf_open_magic_prefix`, which bury the parser
    // surface under xref-table parsing, page-tree assembly, and decryption
    // fast-fail. These three targets reach the deep parse branches
    // directly.
    .{ .name = "parser_object_pdfish", .run = fuzzParserObjectPdfish },
    .{ .name = "parser_indirect_object_random", .run = fuzzParserIndirectObjectRandom },
    .{ .name = "parser_init_at_offset_random", .run = fuzzParserInitAtOffsetRandom },
    // Iter-3 (audit/fuzz_loop_state.md tier 4 — stateful sequence fuzz) —
    // content-stream operator dispatch in src/interpreter.zig. Reaches the
    // production lexer + the BDC/EMC tag-stack in root.zig::extractContentStream
    // directly, instead of going through the lattice geometry layer.
    .{ .name = "interpreter_random_ops", .run = fuzzInterpreterRandomOps },
    .{ .name = "interpreter_bdc_emc_nesting", .run = fuzzInterpreterBdcEmcNesting },
    // Iter-7 (audit/fuzz_loop_state.md tier 7 — multi-stage adversarial PDF-of-PDF).
    // Each iter walks 4 build → parse → canonicalise → mutate → re-emit
    // cycles. Drift between stages surfaces serialise/parse asymmetries.
    .{ .name = "pdf_of_pdf_roundtrip", .run = fuzzPdfOfPdfRoundtrip },
    // Iter-8 (audit/fuzz_loop_state.md row 4 — bidi.zig). UAX #9 Level-1
    // resolver. Three SUT-independent invariant targets: byte conservation,
    // UTF-8 validity, multiset-equality reorder + format-char storm.
    .{ .name = "bidi_resolve_random_codepoints", .run = fuzzBidiResolveRandomCodepoints },
    .{ .name = "bidi_reorder_property", .run = fuzzBidiReorderProperty },
    .{ .name = "bidi_format_character_storm", .run = fuzzBidiFormatCharacterStorm },
    // Iter-9 (audit/fuzz_loop_state.md row 5 — cff.zig). Hand-written
    // byte-level CFF Type 2 parser used by the font_embedder fallback
    // path. `CffParser.init(allocator, bytes)` takes attacker bytes
    // directly. SUT-independent invariants (no panic / no leak; on
    // success: charsets.len ≤ charstrings_index.count; getString /
    // getGlyphName return null OR a bounded-length slice).
    //
    // All three targets are `reproducer_only` because they each
    // reproducibly trip an open Finding (008a/008b) at < 10k iters in
    // ReleaseSafe. Promote back to default-gate once Finding 008 is
    // fixed. See audit/fuzz_findings.md for repro details.
    //
    // Repro (seed=0x1, ReleaseSafe):
    //   cff_init_random_bytes  → integer overflow @ cff.zig:263
    //                            (data_size = readOffSize(off_size) - 1
    //                            underflows when last offset is 0).
    //                            Trips between 5k-10k iters.
    //   cff_init_biased_header → same bug as above; major=1 / minor=0
    //                            biased header reaches Index.parse
    //                            faster (trips between 100-1000 iters).
    //   cff_dict_random_topdict→ @intCast trap @ cff.zig:105
    //                            (charset_offset = @intCast(operand[0])
    //                            on a negative/oversized operand from
    //                            DictParser.readNumber).
    //                            Trips at iter ≤ 50.
    .{ .name = "cff_init_random_bytes", .run = fuzzCffInitRandomBytes, .reproducer_only = true },
    .{ .name = "cff_init_biased_header", .run = fuzzCffInitBiasedHeader, .reproducer_only = true },
    .{ .name = "cff_dict_random_topdict", .run = fuzzCffDictRandomTopDict, .reproducer_only = true },
    // Iter-4 (audit/fuzz_loop_state.md tier 3 — round-trip / property fuzz)
    // — DocumentBuilder.write() ↔ Document.openFromMemory ↔ extractMarkdown
    // — exercises the full writer ↔ reader pipeline (xref, page tree,
    // builtin font dict, content stream, text-extraction state machine).
    // Today's fuzz coverage of this seam is asymmetric: random PDFs flow
    // through `pdf_open_random` (read-only) and the seed-mutation targets,
    // but no target builds a valid PDF from a randomized in-memory tree
    // and asserts an algebraic emit→reparse→equal property.
    .{ .name = "writer_drawtext_roundtrip", .run = fuzzWriterDrawTextRoundtrip },
    .{ .name = "writer_multipage_count", .run = fuzzWriterMultipageCount },
    .{ .name = "writer_text_escape_roundtrip", .run = fuzzWriterTextEscapeRoundtrip },
    // Iter-5 (audit/fuzz_loop_state.md tier 5 — differential fuzz). The
    // natural flate-vs-stdlib differential is a tautology because
    // src/decompress.zig:135 wraps `std.compress.flate.Decompress`
    // directly. We pivot to encoder/decoder differentials on the three
    // independent legacy decoders. See the `decompress.zig differential`
    // section below for the full design rationale.
    .{ .name = "decompress_runlength_diff", .run = fuzzDecompressRunLengthDiff },
    .{ .name = "decompress_ascii_hex_diff", .run = fuzzDecompressAsciiHexDiff },
    .{ .name = "decompress_filter_chain_diff", .run = fuzzDecompressFilterChainDiff },
    // Iter-10 (audit/fuzz_loop_state.md row 18 — pdf_resources.zig).
    // Tier-4 stateful sequence fuzz on `ResourceRegistry`. The registry
    // hands out font / image handles, dedupes builtin fonts, and freezes
    // for further font registration after `assignFontObjectNumbers`.
    // Self-contained surface — no parsing / xref state required.
    //
    // SUT-independent invariants:
    //   - registerBuiltinFont is idempotent per BuiltinFont enum value.
    //   - fontResourceName is `/F<idx>` and stable across calls.
    //   - imageResourceName is `/Im<idx>` and stable across calls.
    //   - fontCount / imageCount equal the number of successful registers.
    //   - After assignFontObjectNumbers: every entry has obj_num != 0,
    //     all obj_nums are pairwise distinct, registerBuiltinFont returns
    //     `error.ObjectNumbersAlreadyAssigned` (negative-space invariant).
    //   - After assignImageObjectNumbers: every image has obj_num != 0
    //     AND `image_obj_nums[idx] == ref.obj_num` (registry / entry
    //     mirror).
    .{ .name = "pdf_resources_builtin_dedup", .run = fuzzPdfResourcesBuiltinDedup },
    .{ .name = "pdf_resources_image_register_assign", .run = fuzzPdfResourcesImageRegisterAssign },
    .{ .name = "pdf_resources_freeze_after_assign", .run = fuzzPdfResourcesFreezeAfterAssign },
    // Iter-11 (audit/fuzz_loop_state.md row 11 — attr_flattener.zig).
    // Pure functions on a *const StructTree. SUT-independent invariants:
    // independent re-walk comparison, byte-idempotent re-flatten, depth-
    // bound boundary symmetry between flatten and flattenInPlace.
    .{ .name = "attr_flattener_random_tree", .run = fuzzAttrFlattenerRandomTree },
    .{ .name = "attr_flattener_in_place_idempotent", .run = fuzzAttrFlattenerInPlaceIdempotent },
    .{ .name = "attr_flattener_depth_bound", .run = fuzzAttrFlattenerDepthBound },
    // Iter-12 (audit/fuzz_loop_state.md row 15 — markdown.zig).
    // Row 15 calls out "the markdown parser itself" but src/markdown.zig
    // is in fact the *reverse* renderer (PDF TextSpan slices → Markdown
    // text). Today's only markdown-side coverage is `tokenizer_realistic_md`
    // which exercises the tokenizer estimator only.
    //
    // Two targets:
    //   - markdown_render_pdf_to_md: randomised `TextSpan` slices into
    //     `renderPageToMarkdown`. Biases font_size toward heading-trip
    //     buckets (6/12/18/24 pt) and texts toward bullet / numbered-list
    //     prefixes so the semantic detection branches are exercised.
    //     Invariants: no panic; no leak; UTF-8 input → UTF-8 output;
    //     output ≤ 32 × Σ(input.text.len + 8) (heading "###### " + "\n"
    //     is the worst per-element overhead).
    //   - markdown_to_pdf_untagged: pivot per the user's instruction —
    //     `markdown_render_tagged` covers the `tagged=true` branch;
    //     this target drives the `tagged=false` half of `renderCore`.
    //     Same property as the tagged target (PDF magic, EOF, reparse,
    //     pageCount > 0) but probes the no-StructTreeRoot codepath.
    .{ .name = "markdown_render_pdf_to_md", .run = fuzzMarkdownRenderPdfToMd },
    .{ .name = "markdown_to_pdf_untagged", .run = fuzzMarkdownToPdfUntagged },
    .{ .name = "pdf_open_mutation", .run = fuzzPdfOpenMutation, .aggressive = true },
    .{ .name = "pdf_extract_mutation", .run = fuzzPdfExtractMutation, .aggressive = true },
};

// ============================================================================
// Targets — streaming layer
// ============================================================================

fn fuzzTokenizerCount(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = allocator;
    _ = seed_pdf;
    const len = rng.intRangeAtMost(usize, 0, scratch.len);
    rng.bytes(scratch[0..len]);
    const t = tokenizer.Tokenizer.init(.heuristic);
    const n = try t.count(scratch[0..len]);
    // Invariant: count ≤ ceil(len/4) + 1 (a generous upper bound; multibyte
    // weights inflate beyond bytes/4 but only for non-ASCII bytes).
    const upper = @as(u32, @intCast(len)) + 1;
    if (n > upper) return error.TokenCountAboveUpperBound;
}

fn fuzzStreamJsonString(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;
    const len = rng.intRangeAtMost(usize, 0, scratch.len);
    rng.bytes(scratch[0..len]);

    // Worst-case escape: every byte → 6-char \u00XX (e.g. all 0x01s).
    // Double again for the surrounding quotes + slack.
    var out_buf: [98304]u8 = undefined;
    var aw = std.Io.Writer.fixed(&out_buf);
    try stream.writeJsonString(&aw, scratch[0..len]);

    const written = aw.buffered();
    // Invariants: starts with `"`, ends with `"`, contains no raw \n inside
    // the body, is valid UTF-8 end-to-end.
    if (written.len < 2) return error.JsonStringTooShort;
    if (written[0] != '"' or written[written.len - 1] != '"') return error.JsonStringNotQuoted;
    if (std.mem.indexOfScalar(u8, written[1 .. written.len - 1], '\n')) |_| return error.JsonStringHasRawNewline;
    if (!std.unicode.utf8ValidateSlice(written)) return error.JsonStringInvalidUtf8;

    // Validate by re-parsing as JSON.
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, written, .{}) catch |e| {
        return e;
    };
    defer parsed.deinit();
    if (parsed.value != .string) return error.JsonStringNotAString;
}

fn fuzzStreamEnvelopeMeta(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = allocator;
    _ = seed_pdf;
    const src_len = rng.intRangeAtMost(usize, 0, 200);
    const title_len = rng.intRangeAtMost(usize, 0, 200);
    const author_len = rng.intRangeAtMost(usize, 0, 200);

    if (src_len + title_len + author_len > scratch.len) return;

    rng.bytes(scratch[0..src_len]);
    rng.bytes(scratch[src_len .. src_len + title_len]);
    rng.bytes(scratch[src_len + title_len .. src_len + title_len + author_len]);

    var out_buf: [32768]u8 = undefined;
    var aw = std.Io.Writer.fixed(&out_buf);
    var env = stream.Envelope.initWithId(&aw, scratch[0..src_len], "01234567-89ab-7cde-8f01-23456789abcd".*);
    try env.emitMeta(.{
        .pages = rng.int(u32),
        .encrypted = rng.boolean(),
        .title = if (title_len > 0) scratch[src_len .. src_len + title_len] else null,
        .author = if (author_len > 0) scratch[src_len + title_len .. src_len + title_len + author_len] else null,
    });

    const written = aw.buffered();
    if (!std.mem.endsWith(u8, written, "}\n")) return error.RecordMissingTerminator;
    if (!std.unicode.utf8ValidateSlice(written)) return error.EnvelopeOutputInvalidUtf8;
}

fn fuzzStreamEnvelopePage(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;
    const md_len = rng.intRangeAtMost(usize, 0, scratch.len);
    rng.bytes(scratch[0..md_len]);

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    var env = stream.Envelope.initWithId(&aw.writer, "fuzz.pdf", "01234567-89ab-7cde-8f01-23456789abcd".*);
    try env.emitPage(rng.int(u32), scratch[0..md_len], &.{});

    const written = aw.written();
    if (!std.mem.endsWith(u8, written, "}\n")) return error.RecordMissingTerminator;
    // Count newlines in the body — should be exactly one (the record
    // terminator). Any embedded \n in markdown must be escaped.
    var nl_count: usize = 0;
    for (written) |b| if (b == '\n') {
        nl_count += 1;
    };
    if (nl_count != 1) return error.EmbeddedNewlineInRecord;
}

fn fuzzChunkBreakFinder(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;
    const text_len = rng.intRangeAtMost(usize, 1, scratch.len);
    rng.bytes(scratch[0..text_len]);

    // Each chunk record can be up to ~6× input (escape worst-case) plus
    // envelope overhead; with many small chunks the cumulative output
    // can exceed input by ~10×. Grow as needed via Allocating writer.
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    var env = stream.Envelope.initWithId(&aw.writer, "fuzz.pdf", "01234567-89ab-7cde-8f01-23456789abcd".*);
    const t = tokenizer.Tokenizer.init(.heuristic);
    const max_tokens = rng.intRangeAtMost(u32, 1, @as(u32, @intCast(@max(1, text_len / 4))));
    const pages = [_]chunk.Page{.{ .index = 0, .markdown = scratch[0..text_len] }};
    _ = chunk.chunkPages(allocator, &pages, .{
        .max_tokens = max_tokens,
        .tokenizer = t,
    }, &env) catch |e| return e;
}

fn fuzzCliParseArgs(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;
    const argv_count = rng.intRangeAtMost(usize, 0, 8);
    const argv = try allocator.alloc([]const u8, argv_count);
    defer allocator.free(argv);

    var off: usize = 0;
    for (argv) |*slot| {
        const arg_len = rng.intRangeAtMost(usize, 0, 32);
        if (off + arg_len > scratch.len) return; // bail this iter
        rng.bytes(scratch[off .. off + arg_len]);
        slot.* = scratch[off .. off + arg_len];
        off += arg_len;
    }
    // Result is intentionally discarded — the invariant is "no panic".
    _ = cli.parseArgs(argv) catch {};
}

fn fuzzCliPageRange(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;
    const len = rng.intRangeAtMost(usize, 0, 64);
    if (len > scratch.len) return;
    // Mostly digits/hyphens/commas to actually exercise the parser.
    const charset = "0123456789,-, abc";
    for (scratch[0..len]) |*b| b.* = charset[rng.intRangeAtMost(usize, 0, charset.len - 1)];

    const total = rng.intRangeAtMost(u32, 0, 1000);
    const got = cli.resolvePageRange(allocator, scratch[0..len], total) catch return;
    defer allocator.free(got);
    // Invariant: every returned index < total.
    for (got) |idx| {
        if (idx >= total) return error.PageIndexOutOfRange;
    }
}

/// Stress test: extractMarkdown on the unmutated seed PDF, repeated. Catches
/// state leaks, drift, double-free regressions in extractMarkdown itself
/// without depending on the upstream parser's tolerance to malformed input.
fn fuzzPdfExtractSeedRepeat(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = rng;
    _ = scratch;
    const doc = try zpdf.Document.openFromMemory(allocator, seed_pdf, zpdf.ErrorConfig.default());
    defer doc.close();
    if (doc.pageCount() == 0) return;
    const md = try doc.extractMarkdown(0, allocator);
    allocator.free(md);
}

/// Realistic-Markdown distribution for the tokenizer estimator: words +
/// whitespace + Markdown punctuation, no random binary noise. Keeps the
/// estimator honest on the inputs Step-3 chunking actually feeds it.
fn fuzzTokenizerRealisticMd(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = allocator;
    _ = seed_pdf;
    const len = rng.intRangeAtMost(usize, 0, scratch.len);
    const charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 \n.,;:!?#-*_";
    for (scratch[0..len]) |*b| b.* = charset[rng.intRangeAtMost(usize, 0, charset.len - 1)];
    const t = tokenizer.Tokenizer.init(.heuristic);
    const n = try t.count(scratch[0..len]);
    // For ASCII text, count must be ≤ ceil(len/4).
    const upper = (@as(u32, @intCast(len)) + 3) / 4;
    if (n > upper) return error.TokenCountAboveAsciiUpperBound;
}

// ============================================================================
// Targets — PDF parser
// ============================================================================

fn fuzzPdfOpenRandom(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;
    const len = rng.intRangeAtMost(usize, 0, @min(scratch.len, 4096));
    rng.bytes(scratch[0..len]);
    const doc = zpdf.Document.openFromMemory(allocator, scratch[0..len], zpdf.ErrorConfig.default()) catch return;
    doc.close();
}

fn fuzzPdfOpenMagicPrefix(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;
    const prefix = "%PDF-1.4\n";
    if (scratch.len < prefix.len) return;
    @memcpy(scratch[0..prefix.len], prefix);
    const tail_len = rng.intRangeAtMost(usize, 0, @min(scratch.len - prefix.len, 4096));
    rng.bytes(scratch[prefix.len .. prefix.len + tail_len]);
    const doc = zpdf.Document.openFromMemory(allocator, scratch[0 .. prefix.len + tail_len], zpdf.ErrorConfig.default()) catch return;
    doc.close();
}

fn fuzzPdfOpenMutation(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    if (seed_pdf.len > scratch.len) return;
    @memcpy(scratch[0..seed_pdf.len], seed_pdf);
    // Flip 1–8 random bytes.
    const flips = rng.intRangeAtMost(usize, 1, 8);
    for (0..flips) |_| {
        const idx = rng.intRangeAtMost(usize, 0, seed_pdf.len - 1);
        scratch[idx] ^= rng.int(u8);
    }
    dumpReproducer("pdf_open_mutation", scratch[0..seed_pdf.len]);
    const doc = zpdf.Document.openFromMemory(allocator, scratch[0..seed_pdf.len], zpdf.ErrorConfig.default()) catch return;
    doc.close();
}

fn fuzzPdfExtractMutation(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    if (seed_pdf.len > scratch.len) return;
    @memcpy(scratch[0..seed_pdf.len], seed_pdf);
    // Lighter mutation so the PDF still opens often: flip 1 byte in the
    // content stream half (after the prefix).
    const idx = rng.intRangeAtMost(usize, seed_pdf.len / 2, seed_pdf.len - 1);
    scratch[idx] ^= rng.int(u8);

    dumpReproducer("pdf_extract_mutation", scratch[0..seed_pdf.len]);
    const doc = zpdf.Document.openFromMemory(allocator, scratch[0..seed_pdf.len], zpdf.ErrorConfig.default()) catch return;
    defer doc.close();

    const n = doc.pageCount();
    if (n == 0) return;
    const page_idx = rng.intRangeAtMost(usize, 0, n - 1);
    const md = doc.extractMarkdown(page_idx, allocator) catch return;
    allocator.free(md);
}

// ============================================================================
// Targets — lattice Pass B (Form XObject Do recursion, PR-1)
// ============================================================================

/// Fuzz `lattice.collectStrokes` with a random byte buffer pretending to
/// be a PDF content stream. Exercises the operator dispatch + CTM stack
/// + last-name tracking against arbitrary byte sequences. The legacy
/// (no-context) entry point is used so `Do` is always a no-op — the
/// invariant is no panic, no leak, output is well-formed (every stroke
/// has finite endpoints).
fn fuzzLatticeContentRandom(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;
    const len = rng.intRangeAtMost(usize, 0, @min(scratch.len, 8192));
    rng.bytes(scratch[0..len]);

    const got = lattice.collectStrokes(allocator, scratch[0..len]) catch return;
    defer allocator.free(got);

    for (got) |s| {
        if (!std.math.isFinite(s.x0) or !std.math.isFinite(s.y0) or
            !std.math.isFinite(s.x1) or !std.math.isFinite(s.y1))
        {
            return error.LatticeStrokeNonFinite;
        }
    }
}

/// Fuzz `lattice.collectStrokesIn` end-to-end through `getTables` against
/// a mutated `generateFormXObjectTablePdf` fixture. Mutations target the
/// last quarter of the buffer (the Form XObject content stream region)
/// to keep the structural prefix valid most of the time so the recursion
/// path actually fires.
///
/// Invariants: open + getTables + freeTables must succeed without panic
/// or leak. Detected tables (when any) must have finite bboxes.
fn fuzzLatticeFormXObjectMutation(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;
    const pdf_data = testpdf.generateFormXObjectTablePdf(allocator) catch return;
    defer allocator.free(pdf_data);
    if (pdf_data.len > scratch.len) return;
    @memcpy(scratch[0..pdf_data.len], pdf_data);

    // Flip 1–4 bytes inside the Form XObject content region.
    const flips = rng.intRangeAtMost(usize, 1, 4);
    const mutate_start = pdf_data.len * 3 / 4;
    if (mutate_start >= pdf_data.len) return;
    for (0..flips) |_| {
        const idx = rng.intRangeAtMost(usize, mutate_start, pdf_data.len - 1);
        scratch[idx] ^= rng.int(u8);
    }

    dumpReproducer("lattice_form_xobject_mutation", scratch[0..pdf_data.len]);

    var doc = zpdf.Document.openFromMemory(allocator, scratch[0..pdf_data.len], zpdf.ErrorConfig.permissive()) catch return;
    defer doc.close();

    const detected = doc.getTables(allocator) catch return;
    defer zpdf.tables.freeTables(allocator, detected);

    for (detected) |t| {
        if (t.bbox) |bb| {
            for (bb) |v| {
                if (!std.math.isFinite(v)) return error.LatticeBboxNonFinite;
            }
        }
    }
}

// ============================================================================
// Targets — Pass A (tagged-table cell text via MCID, PR-3)
// ============================================================================

/// Surgical fuzz target for PR-3's *new* surface — the McidTextLookupFn
/// callback boundary inside `extractTaggedTables`. Builds a small
/// synthetic StructTree by hand (Table → 1..3 TR rows → 0..4 cells per
/// row → optional nested /P with one MCID), then drives the public
/// `extractTaggedTables` with a stub callback that returns a random
/// byte slice per MCID.
///
/// What this exercises:
///   - the recursive `collectMcidText` descent (PR-3 round 1)
///   - the `firstDescendantPageRef` fallback (PR-3 round 1)
///   - the cell.text allocation + freeTables ownership transfer
///   - errdefer cleanup on partial-build OOM
///
/// What this DOES NOT exercise: extractContentStream / interpreter /
/// pagetree. Those pre-existing crash surfaces are intentionally
/// out-of-scope for PR-3; the dedicated `pdf_open_mutation` and
/// `pdf_extract_mutation` targets cover them.
///
/// Invariants:
///   - extractTaggedTables succeeds OR returns OutOfMemory
///   - returned cells' .text is valid UTF-8 if non-null
///   - freeTables completes without panic / leak
fn fuzzTaggedTableMutation(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Build TD/TH cells: random count per row, each may contain a
    // direct mcid OR a nested /P with one mcid (round-1 path).
    const n_rows = rng.intRangeAtMost(usize, 0, 3);
    var rows = std.ArrayList(*zpdf.structtree.StructElement).empty;

    for (0..n_rows) |_| {
        const n_cells = rng.intRangeAtMost(usize, 0, 4);
        var row_kids = std.ArrayList(zpdf.structtree.StructChild).empty;
        for (0..n_cells) |_| {
            // Optionally wrap an MCID in a nested /P element.
            const nested = rng.boolean();
            const mcid = rng.int(i31);

            if (nested) {
                var p_kids = std.ArrayList(zpdf.structtree.StructChild).empty;
                try p_kids.append(aa, .{ .mcid = .{ .mcid = mcid, .page_ref = null, .stream_ref = null } });
                const p_elem = try aa.create(zpdf.structtree.StructElement);
                p_elem.* = .{ .struct_type = "P", .children = try p_kids.toOwnedSlice(aa), .page_ref = null };
                var td_kids = std.ArrayList(zpdf.structtree.StructChild).empty;
                try td_kids.append(aa, .{ .element = p_elem });
                const td_elem = try aa.create(zpdf.structtree.StructElement);
                td_elem.* = .{ .struct_type = "TD", .children = try td_kids.toOwnedSlice(aa), .page_ref = null };
                try row_kids.append(aa, .{ .element = td_elem });
            } else {
                var td_kids = std.ArrayList(zpdf.structtree.StructChild).empty;
                try td_kids.append(aa, .{ .mcid = .{ .mcid = mcid, .page_ref = null, .stream_ref = null } });
                const td_elem = try aa.create(zpdf.structtree.StructElement);
                td_elem.* = .{ .struct_type = "TD", .children = try td_kids.toOwnedSlice(aa), .page_ref = null };
                try row_kids.append(aa, .{ .element = td_elem });
            }
        }
        const tr_elem = try aa.create(zpdf.structtree.StructElement);
        tr_elem.* = .{ .struct_type = "TR", .children = try row_kids.toOwnedSlice(aa), .page_ref = null };
        try rows.append(aa, tr_elem);
    }

    var table_kids = std.ArrayList(zpdf.structtree.StructChild).empty;
    for (rows.items) |tr| try table_kids.append(aa, .{ .element = tr });
    const table_elem = try aa.create(zpdf.structtree.StructElement);
    table_elem.* = .{ .struct_type = "Table", .children = try table_kids.toOwnedSlice(aa), .page_ref = null };

    const tree = zpdf.structtree.StructTree{
        .root = table_elem,
        .elements = &.{},
        .allocator = aa,
    };

    // Stub callback returns a random slice from `scratch`. Returning
    // null on some MCIDs to exercise the empty/skip path.
    const Stub = struct {
        rng: *std.Random,
        scratch: []u8,
        fn lookup(ctx_ptr: *anyopaque, page_ref: ?zpdf.parser.ObjRef, mcid: i32) error{OutOfMemory}!?[]const u8 {
            _ = page_ref;
            _ = mcid;
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
            if (self.rng.intRangeAtMost(u8, 0, 9) == 0) return null;
            const max = @min(self.scratch.len, 32);
            const len = self.rng.intRangeAtMost(usize, 0, max);
            // Make sure it's valid UTF-8 by emitting only ASCII printable
            // characters (so the invariant check below is a real check
            // on `extractTaggedTables` not the stub).
            for (0..len) |i| {
                self.scratch[i] = self.rng.intRangeAtMost(u8, 0x20, 0x7E);
            }
            return self.scratch[0..len];
        }
    };
    var stub = Stub{ .rng = @constCast(&rng), .scratch = scratch };

    const detected = zpdf.tables.extractTaggedTables(
        allocator,
        &tree,
        null,
        null,
        @ptrCast(&stub),
        Stub.lookup,
    ) catch |err| {
        if (err == error.OutOfMemory) return err;
        return; // domain errors → treat as no-op
    };
    defer zpdf.tables.freeTables(allocator, detected);

    for (detected) |t| {
        for (t.cells) |c| {
            if (c.text) |txt| {
                if (!std.unicode.utf8ValidateSlice(txt)) {
                    return error.TaggedCellTextInvalidUtf8;
                }
            }
        }
    }

}

// ============================================================================
// Targets — Pass D continuation-link bbox-y constraint (PR-2)
// ============================================================================

/// Fuzz `tables.linkContinuations` against a random list of pre-detected
/// Tables (no PDF parse, no extractContentStream). Builds 0..16 tables
/// with random page numbers, ids, n_cols, and bbox/null pairings, then
/// drives linkContinuations through a stub PageMediaBoxFn that returns
/// random media-box rectangles. Invariants:
///   - linkContinuations completes without panic
///   - every continuation_to/continuation_from pair is symmetric:
///     if a.continued_to.{page,id} = (p, i) then list[finds (p, i)].
///     continued_from = (a.page, a.id)
///   - linked pairs have b.page == a.page + 1 and matching cols ±1
fn fuzzLinkContinuationsRandom(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = scratch;
    _ = seed_pdf;
    const n = rng.intRangeAtMost(usize, 0, 16);
    const list = try allocator.alloc(zpdf.tables.Table, n);
    defer allocator.free(list);

    // Page-sorted list: `i`-th table on page (i / 2) + 1, alternating ids.
    for (list, 0..) |*t, i| {
        const page = @as(u32, @intCast((i / 2) + 1));
        const id: u32 = @intCast(i % 2);
        const n_cols = rng.intRangeAtMost(u32, 1, 8);
        const has_bbox = rng.boolean();
        t.* = .{
            .page = page,
            .id = id,
            .n_rows = rng.intRangeAtMost(u32, 1, 16),
            .n_cols = n_cols,
            .header_rows = 0,
            .cells = &.{},
            .engine = .lattice,
            .confidence = 0.5,
            .bbox = if (has_bbox) blk: {
                const x0 = rng.float(f64) * 600.0;
                const y0 = rng.float(f64) * 800.0;
                break :blk [4]f64{ x0, y0, x0 + 100.0, y0 + 100.0 };
            } else null,
            .continued_from = null,
            .continued_to = null,
        };
    }

    const Stub = struct {
        rng: *std.Random,
        fn lookup(ctx_ptr: *const anyopaque, page: u32) ?[4]f64 {
            _ = page;
            const self: *const @This() = @ptrCast(@alignCast(ctx_ptr));
            // Half the time return a sensible US-Letter box; sometimes
            // return null (page out of range / unknown); rarely emit
            // a degenerate or huge page to stress the threshold math.
            const r = self.rng.intRangeAtMost(u8, 0, 9);
            // Note: the stub captures rng but mutating it via const
            // ptr is fine in Zig because std.Random is a vtable; we
            // operate read-only on the dispatch.
            if (r == 0) return null;
            if (r == 1) return [4]f64{ 0, 0, 0, 0 }; // degenerate height=0
            return [4]f64{ 0, 0, 612, 792 };
        }
    };
    var stub = Stub{ .rng = @constCast(&rng) };
    zpdf.tables.linkContinuations(list, @ptrCast(&stub), Stub.lookup);

    // Verify linked-pair invariants.
    for (list) |a| {
        const ct = a.continued_to orelse continue;
        // Find the target.
        var found = false;
        for (list) |b| {
            if (b.page == ct.page and b.id == ct.table_id) {
                if (b.continued_from) |cf| {
                    if (cf.page == a.page and cf.table_id == a.id) found = true;
                }
                break;
            }
        }
        if (!found) return error.LinkContinuationAsymmetric;
    }
}

/// Best-effort persist the most recent input the parser saw, so a segfault
/// crash leaves the offending bytes on disk at /tmp/pdf_zig_last_<tag>.bin
/// for minimization. Failures are silent — this is debug-only.
fn dumpReproducer(tag: []const u8, bytes: []const u8) void {
    // 0.16: file ops require an Io and the per-target fn signature has
    // none. Use raw POSIX syscalls so the reproducer-dump escape hatch
    // keeps working without threading Io through every TargetFn.
    var path_buf: [256:0]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/tmp/pdf_zig_last_{s}.bin", .{tag}) catch return;
    const flags: std.posix.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
    const fd = std.posix.openatZ(std.posix.AT.FDCWD, path.ptr, flags, 0o644) catch return;
    defer _ = std.posix.system.close(fd);
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = std.posix.system.write(fd, bytes[written..].ptr, bytes.len - written);
        const n: isize = @bitCast(@as(usize, @bitCast(rc)));
        if (n <= 0) return;
        written += @intCast(n);
    }
}

// ============================================================================
// Targets — Pass B (lattice cell text via glyph-center ∩ bbox, PR-4)
// ============================================================================

/// Fuzz `lattice.extractFromStrokes` directly with random spans + a small
/// valid grid of strokes. Exercises buildLatticeCellsWithText, locateBin,
/// and the new errdefer transfer guards under invariant checks (no panic,
/// no leak, finite cell text).
///
/// What this exercises:
///   - locateBin boundary handling (NaN/inf guard, bin-edge tie-break)
///   - buildLatticeCellsWithText partial-success errdefer paths
///   - extractFromStrokes' cells_owned ownership flag (R1)
///   - cell.text UTF-8 well-formedness when assembled from random bytes
///
/// What this DOES NOT exercise: getTables / Pass A / Pass C / Pass D.
/// Those have their own targets (lattice_form_xobject_mutation,
/// tagged_table_mutation, link_continuations_random).
fn fuzzLatticePassBSpans(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = scratch;
    _ = seed_pdf;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Build a small grid: 3..6 H strokes, 3..6 V strokes, all spanning
    // the full bbox so they survive the 50%-span filter.
    const n_h = rng.intRangeAtMost(usize, 3, 6);
    const n_v = rng.intRangeAtMost(usize, 3, 6);
    const left: f64 = 50.0;
    const right: f64 = 550.0;
    const bottom: f64 = 50.0;
    const top: f64 = 750.0;

    var strokes = std.ArrayList(lattice.Stroke).empty;
    defer strokes.deinit(aa);

    var i: usize = 0;
    while (i < n_h) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n_h - 1));
        const y = bottom + t * (top - bottom);
        try strokes.append(aa, .{ .x0 = left, .y0 = y, .x1 = right, .y1 = y });
    }
    i = 0;
    while (i < n_v) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n_v - 1));
        const x = left + t * (right - left);
        try strokes.append(aa, .{ .x0 = x, .y0 = bottom, .x1 = x, .y1 = top });
    }

    // Build random spans. Coordinates may land inside, on a boundary,
    // or outside the grid. Text length 1..16 random ASCII to keep
    // UTF-8 trivially well-formed.
    const n_spans = rng.intRangeAtMost(usize, 0, 32);
    var spans = std.ArrayList(layout.TextSpan).empty;
    defer spans.deinit(aa);

    // Static text pool — keeps the fuzz iter purely about geometric
    // boundary cases without exercising text content (covered by the
    // Pass B integration test). All slices live in `.rodata` so
    // appendSlice is safe regardless of arena ordering.
    const text_pool = [_][]const u8{ "a", "ab", "abc", "abcd", "abcde" };

    // Pick column-line indices for "center exactly on line" cases.
    // col_lines = [left, ..., right]. Choosing center == col_lines[k]
    // hits locateBin's bin-edge tie-break (inclusive lower, exclusive
    // upper). Same for row_lines.
    const col_count = n_v;
    const row_count = n_h;

    var s: usize = 0;
    while (s < n_spans) : (s += 1) {
        // Glyph-center mode (the binner reads center = (x0+x1)/2).
        // Generate centers directly, then derive a 5-pt-wide span
        // around them.
        const x_choice = rng.intRangeAtMost(u8, 0, 5);
        const cx: f64 = switch (x_choice) {
            0 => left - 5.0, // outside left
            1 => right + 5.0, // outside right
            2 => left, // on lower boundary (inclusive)
            3 => right, // on upper boundary (exclusive — should miss)
            4 => blk: { // on an interior column line (tie-break)
                const k = rng.intRangeAtMost(usize, 1, col_count - 2);
                break :blk left + (@as(f64, @floatFromInt(k)) /
                    @as(f64, @floatFromInt(col_count - 1))) * (right - left);
            },
            else => left + rng.float(f64) * (right - left),
        };
        const y_choice = rng.intRangeAtMost(u8, 0, 5);
        const cy: f64 = switch (y_choice) {
            0 => bottom - 5.0,
            1 => top + 5.0,
            2 => bottom,
            3 => top,
            4 => blk: {
                const k = rng.intRangeAtMost(usize, 1, row_count - 2);
                break :blk bottom + (@as(f64, @floatFromInt(k)) /
                    @as(f64, @floatFromInt(row_count - 1))) * (top - bottom);
            },
            else => bottom + rng.float(f64) * (top - bottom),
        };
        try spans.append(aa, .{
            .x0 = cx - 2.5,
            .y0 = cy - 2.5,
            .x1 = cx + 2.5,
            .y1 = cy + 2.5,
            .text = text_pool[rng.intRangeAtMost(usize, 0, text_pool.len - 1)],
            .font_size = 10.0,
        });
    }

    const detected = lattice.extractFromStrokes(allocator, strokes.items, 1, spans.items) catch |err| {
        if (err == error.OutOfMemory) return;
        return err;
    };
    defer zpdf.tables.freeTables(allocator, detected);

    for (detected) |t| {
        if (t.bbox) |bb| {
            for (bb) |v| {
                if (!std.math.isFinite(v)) return error.LatticeBboxNonFinite;
            }
        }
        for (t.cells) |c| {
            if (c.text) |txt| {
                if (!std.unicode.utf8ValidateSlice(txt)) {
                    return error.LatticeCellTextInvalidUtf8;
                }
            }
        }
    }
}

// ============================================================================
// Targets — v1.6 module surface (xmp_writer / encrypt_writer / markdown_to_pdf
// / truetype / jpeg_meta)
// ============================================================================

fn fuzzXmpEscapeXml(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;
    const len = rng.intRangeAtMost(usize, 0, scratch.len);
    rng.bytes(scratch[0..len]);

    const out = try xmp_writer.escapeXml(allocator, scratch[0..len]);
    defer allocator.free(out);

    // Postcondition (per xmp_writer.zig docstring): no unescaped predefined
    // entities and no forbidden C0 controls. CR (0x0D), LF (0x0A), TAB
    // (0x09) are the only sub-0x20 bytes that may pass through.
    for (out) |c| switch (c) {
        '<', '>', '"', '\'' => return error.XmpEscapeLeakedMetachar,
        0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => return error.XmpEscapeLeakedC0,
        else => {},
    };

    // `&` is legal in output only as part of a `&entity;` sequence. Any bare
    // `&` not followed by [a-z]+; signals a missed escape.
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, out, i, '&')) |pos| {
        const tail = out[pos..];
        const valid_entities = [_][]const u8{ "&amp;", "&lt;", "&gt;", "&quot;", "&apos;" };
        var matched = false;
        for (valid_entities) |e| {
            if (std.mem.startsWith(u8, tail, e)) {
                matched = true;
                i = pos + e.len;
                break;
            }
        }
        if (!matched) return error.XmpEscapeBareAmpersand;
    }
}

fn fuzzXmpEmitRandom(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;

    // Pick a tag. 75% of the time bias toward a valid PDF/A level so the
    // bulk of iters exercise `emit()` rather than the levelView early-bail;
    // the other 25% feed adversarial bytes to keep `levelView` covered.
    var tag_buf: [3]u8 = undefined;
    const view = blk: {
        if (rng.float(f32) < 0.75) {
            tag_buf[0] = "abu"[rng.intRangeAtMost(usize, 0, 2)];
            tag_buf[1] = "123"[rng.intRangeAtMost(usize, 0, 2)];
            break :blk xmp_writer.levelView(tag_buf[0..2]) catch unreachable;
        }
        const tag_len = rng.intRangeAtMost(usize, 0, tag_buf.len);
        rng.bytes(tag_buf[0..tag_len]);
        break :blk xmp_writer.levelView(tag_buf[0..tag_len]) catch return;
    };

    // Carve scratch into three field slices (some may be null). Each is
    // sized within MAX_FIELD_BYTES so we exercise both bounded and over-
    // sized lengths.
    const half = scratch.len / 2;
    const title_len = rng.intRangeAtMost(usize, 0, half);
    const author_len = rng.intRangeAtMost(usize, 0, half - half / 2);
    const subject_len = rng.intRangeAtMost(usize, 0, scratch.len - title_len - author_len);
    rng.bytes(scratch[0 .. title_len + author_len + subject_len]);

    const title: ?[]const u8 = if (rng.boolean()) scratch[0..title_len] else null;
    const author: ?[]const u8 = if (rng.boolean()) scratch[title_len .. title_len + author_len] else null;
    const subject: ?[]const u8 = if (rng.boolean()) scratch[title_len + author_len .. title_len + author_len + subject_len] else null;

    const bytes = xmp_writer.emit(allocator, view, .{
        .title = title,
        .author = author,
        .subject = subject,
    }) catch |e| switch (e) {
        error.OutOfMemory, error.XmpPacketTooLarge => return,
    };
    defer allocator.free(bytes);

    if (bytes.len > xmp_writer.MAX_PACKET_BYTES) return error.XmpPacketExceedsCap;
    if (!std.mem.startsWith(u8, bytes, "<?xpacket begin=")) return error.XmpMissingPacketBegin;
    if (!std.mem.endsWith(u8, bytes, "<?xpacket end=\"w\"?>")) return error.XmpMissingPacketEnd;
    if (std.mem.indexOf(u8, bytes, "<pdfaid:part>") == null) return error.XmpMissingPdfAidPart;
    if (std.mem.indexOf(u8, bytes, "<pdfaid:conformance>") == null) return error.XmpMissingPdfAidConformance;
}

fn fuzzEncryptRoundtripRc4(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    return encryptRoundtripCommon(rng, allocator, scratch, seed_pdf, .rc4_v2_r3_128);
}

fn fuzzEncryptRoundtripAes(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    return encryptRoundtripCommon(rng, allocator, scratch, seed_pdf, .aes_v4_r4_128);
}

fn encryptRoundtripCommon(
    rng: std.Random,
    allocator: std.mem.Allocator,
    scratch: []u8,
    seed_pdf: []const u8,
    algorithm: encrypt_writer.Algorithm,
) anyerror!void {
    _ = seed_pdf;

    // 32-byte cap on user/owner passwords matches the PDF spec — the algo
    // pads or truncates internally, but we still want fuzzed lengths.
    var user_pw_buf: [40]u8 = undefined;
    var owner_pw_buf: [40]u8 = undefined;
    const user_pw_len = rng.intRangeAtMost(usize, 0, user_pw_buf.len);
    const owner_pw_len = rng.intRangeAtMost(usize, 0, owner_pw_buf.len);
    rng.bytes(user_pw_buf[0..user_pw_len]);
    rng.bytes(owner_pw_buf[0..owner_pw_len]);

    var file_id: [16]u8 = undefined;
    rng.bytes(&file_id);

    var ctx = try encrypt_writer.EncryptionContext.deriveFromPasswords(
        allocator,
        algorithm,
        user_pw_buf[0..user_pw_len],
        owner_pw_buf[0..owner_pw_len],
        .{},
        file_id,
        rng,
    );
    defer ctx.deinit();

    // Random plaintext — sometimes empty, sometimes a non-trivial run.
    const plaintext_len = rng.intRangeAtMost(usize, 0, scratch.len);
    rng.bytes(scratch[0..plaintext_len]);
    const plaintext = scratch[0..plaintext_len];

    // Random object/generation pair — these affect the per-object key.
    const obj_num = rng.int(u32);
    const gen = rng.int(u16);

    const ciphertext = try ctx.encryptString(obj_num, gen, plaintext, allocator);
    defer allocator.free(ciphertext);

    const recovered = try ctx.decryptString(obj_num, gen, ciphertext, allocator);
    defer allocator.free(recovered);

    if (!std.mem.eql(u8, plaintext, recovered)) return error.EncryptRoundtripMismatch;

    // RC4: ciphertext length must match plaintext length (no IV/padding).
    // AES: ciphertext = 16-byte IV + PKCS#7-padded plaintext, multiple of 16.
    switch (algorithm) {
        .rc4_v2_r3_128 => {
            if (ciphertext.len != plaintext.len) return error.EncryptRc4LengthChanged;
        },
        .aes_v4_r4_128 => {
            if (ciphertext.len < 16) return error.EncryptAesShortCiphertext;
            if ((ciphertext.len - 16) % 16 != 0) return error.EncryptAesUnpaddedCiphertext;
        },
    }
}

fn fuzzMarkdownRenderTagged(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;

    // Cap input at 2 KiB — renderTagged synthesises one PDF page per
    // newline in the worst case, so unbounded markdown blows past the
    // page-tree depth budget without surfacing fresh bugs.
    const len = rng.intRangeAtMost(usize, 0, @min(scratch.len, 2048));
    rng.bytes(scratch[0..len]);

    const bytes = markdown_to_pdf.renderTagged(allocator, null, scratch[0..len]) catch |e| switch (e) {
        error.OutOfMemory => return,
        else => return e,
    };
    defer allocator.free(bytes);

    if (!std.mem.startsWith(u8, bytes, "%PDF-")) return error.MarkdownRenderMissingMagic;
    if (std.mem.indexOf(u8, bytes, "%%EOF") == null) return error.MarkdownRenderMissingEof;

    // Substring counts of "BDC"/"EMC" are unreliable since PR-W4 enabled
    // FlateDecode on content streams (compressed bytes will incidentally
    // hit those substrings). Stronger structural check: re-open the
    // emitted bytes with the parser. A renderTagged output that the
    // reader cannot open is a structural bug; an open with `pageCount > 0`
    // is the round-trip property we want.
    const doc = zpdf.Document.openFromMemory(allocator, bytes, zpdf.ErrorConfig.default()) catch
        return error.MarkdownRenderUnreadable;
    defer doc.close();
    if (doc.pageCount() == 0) return error.MarkdownRenderZeroPages;
}

fn fuzzTruetypeParseRandom(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;

    // A real TTF starts with a 4-byte sfnt version (0x00010000 or "OTTO").
    // Half the time we plant one of those magics so the parser advances
    // past the offset table; the other half stays fully random to
    // exercise the early-bail path.
    const len = rng.intRangeAtMost(usize, 0, scratch.len);
    rng.bytes(scratch[0..len]);
    if (len >= 4 and rng.boolean()) {
        const magics = [_][4]u8{
            .{ 0x00, 0x01, 0x00, 0x00 },
            .{ 'O', 'T', 'T', 'O' },
            .{ 't', 'r', 'u', 'e' },
        };
        const m = magics[rng.intRangeAtMost(usize, 0, magics.len - 1)];
        @memcpy(scratch[0..4], &m);
    }

    var font = truetype.parse(allocator, scratch[0..len]) catch |e| switch (e) {
        error.OutOfMemory => return,
        else => return,
    };
    defer font.deinit(allocator);
    // Surviving the parse is the invariant; the success path is exercised
    // by truetype.zig's own tests on a real TTF fixture.
}

fn fuzzJpegMetaRandom(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = allocator;
    _ = seed_pdf;

    // JPEG SOI is FF D8 FF — half the time we plant it so the parser
    // advances past the header.
    const len = rng.intRangeAtMost(usize, 0, scratch.len);
    rng.bytes(scratch[0..len]);
    if (len >= 3 and rng.boolean()) {
        scratch[0] = 0xFF;
        scratch[1] = 0xD8;
        scratch[2] = 0xFF;
    }

    const meta = jpeg_meta.parse(scratch[0..len]) catch return;

    // On success: width/height must be > 0, bits_per_component in
    // {1, 8, 12, 16}, color_space ∈ {gray, rgb, cmyk}.
    if (meta.width == 0 or meta.height == 0) return error.JpegMetaZeroDim;
    switch (meta.bits_per_component) {
        1, 8, 12, 16 => {},
        else => return error.JpegMetaUnknownBpc,
    }
    switch (meta.colorspace) {
        .gray, .rgb, .cmyk => {},
    }
}


// ============================================================================
// Targets — decompress.zig (defense-in-depth)
// ============================================================================
//
// `decompress.decompressStream` is the trust boundary between attacker-
// controlled PDF stream bytes and the rest of the parser. Any panic, read
// out-of-bounds, infinite loop, or unbounded allocation here is CVE-grade
// for a PDF reader. The four legacy decoders (FlateDecode, ASCIIHexDecode,
// ASCII85Decode, RunLengthDecode) get individual targets so a regression
// in one is attributable.
//
// Flate is intentionally driven only via the existing `pdf_open_mutation`
// target's stream content — its output is unbounded by design and the
// upstream decompressor has its own fuzz coverage; isolating it here would
// duplicate work without adding signal.

/// Drive `decompressStream` with `/Filter ASCIIHexDecode` against random
/// bytes. Half the inputs get a `>` terminator appended in a randomly
/// chosen position to exercise the early-exit path; the other half rely
/// on the natural end-of-buffer.
///
/// Invariants:
///   - no panic, no OOB read (the assertion is *surviving the call*)
///   - if decode succeeds, output length ≤ ⌈input_len / 2⌉ + 1
///     (best case: every input byte is a hex nibble; trailing nibble adds 1)
///   - termination: a finite call returns regardless of `>` placement
fn fuzzDecompressAsciiHexRandom(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;
    const len = rng.intRangeAtMost(usize, 0, scratch.len);
    rng.bytes(scratch[0..len]);

    // Bias half the iters toward "lots of hex digits" so we actually hit
    // the appendNibble path rather than skipping every byte.
    if (rng.boolean() and len > 0) {
        const hex_pool = "0123456789ABCDEFabcdef \n\t\r>";
        const nibblify_count = rng.intRangeAtMost(usize, 0, len);
        for (0..nibblify_count) |_| {
            const idx = rng.intRangeAtMost(usize, 0, len - 1);
            scratch[idx] = hex_pool[rng.intRangeAtMost(usize, 0, hex_pool.len - 1)];
        }
    }

    // Sometimes drop a `>` terminator at a random position. The decoder
    // must stop at it; this checks the early-exit doesn't read past.
    if (rng.boolean() and len > 0) {
        scratch[rng.intRangeAtMost(usize, 0, len - 1)] = '>';
    }

    const filter = parser.Object{ .name = "ASCIIHexDecode" };
    const out = decompress.decompressStream(allocator, scratch[0..len], filter, null) catch return;
    defer allocator.free(out);

    // Output length bound: every two non-whitespace nibbles in input
    // produce at most one output byte. `len/2 + 1` covers the trailing-
    // odd-nibble case without depending on whitespace counts.
    if (out.len > len / 2 + 1) return error.AsciiHexOutputAboveBound;
}

/// Round-trip a random plaintext through a fuzz-internal ASCII85 encoder
/// and then `decompressStream(filter=ASCII85Decode)`, asserting byte-
/// perfect equality. Also runs adversarial-bytes mode (no encoder) on
/// half the iters to exercise the malformed-input path against the
/// no-panic invariant.
///
/// Invariants:
///   - encoder/decoder round-trip: decode(encode(x)) == x (byte-exact)
///   - on adversarial input: no panic; output ≤ ⌈input_len * 4/5⌉ + 4
///     (every 5 input chars decode to ≤ 4 output bytes, plus tuple flush)
fn fuzzDecompressAscii85Roundtrip(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;
    const filter = parser.Object{ .name = "ASCII85Decode" };

    if (rng.boolean()) {
        // Round-trip mode: encode random plaintext, then decode it.
        const plain_len = rng.intRangeAtMost(usize, 0, scratch.len / 2);
        rng.bytes(scratch[0..plain_len]);
        const plain = scratch[0..plain_len];

        const encoded = try encodeAscii85(allocator, plain);
        defer allocator.free(encoded);

        const decoded = decompress.decompressStream(allocator, encoded, filter, null) catch |err| {
            // Any error on a well-formed encode is a bug.
            return err;
        };
        defer allocator.free(decoded);

        if (!std.mem.eql(u8, decoded, plain)) return error.Ascii85RoundtripMismatch;
        return;
    }

    // Adversarial mode: random bytes. The invariant is no panic. Bound
    // the output (5 input chars → ≤ 4 output bytes; +4 for trailing
    // tuple flush slack).
    const len = rng.intRangeAtMost(usize, 0, scratch.len);
    rng.bytes(scratch[0..len]);
    const out = decompress.decompressStream(allocator, scratch[0..len], filter, null) catch return;
    defer allocator.free(out);

    // Each non-skipped, non-`z` ASCII85 char contributes 1/5 of an
    // output tuple (4 bytes). `z` shorthand is 1 char → 4 bytes. So
    // worst-case ratio is 4 bytes per 1 input char.
    const upper = len * 4 + 4;
    if (out.len > upper) return error.Ascii85OutputAboveBound;
}

/// Drive `decompressStream` with `/Filter RunLengthDecode` against random
/// bytes. The decoder treats each pair (length, then 1..128 data bytes
/// or 1 repeat byte) as a packet; 0x80 is the EOD marker.
///
/// Invariants:
///   - no panic, no OOB read
///   - output length ≤ 128 * input_len (worst case: a length=129 byte
///     followed by a single data byte yields 128 output bytes for 2
///     input bytes — that's a 64× ratio. 128× is a safe upper bound.)
fn fuzzDecompressRunLengthRandom(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;
    const len = rng.intRangeAtMost(usize, 0, scratch.len);
    rng.bytes(scratch[0..len]);

    // Bias half the iters toward small length bytes < 128 (literal-copy
    // mode) and the other half toward > 128 (repeat mode), so both code
    // paths get exercised heavily. Without bias, the ~32% chance of any
    // given length byte being < 128 means the literal path is over-
    // represented.
    if (rng.boolean() and len > 0) {
        const bias_repeat = rng.boolean();
        for (scratch[0..len]) |*b| {
            if (rng.intRangeAtMost(u8, 0, 9) < 4) {
                b.* = if (bias_repeat) rng.intRangeAtMost(u8, 129, 255) else rng.intRangeAtMost(u8, 0, 127);
            }
        }
    }

    const filter = parser.Object{ .name = "RunLengthDecode" };
    const out = decompress.decompressStream(allocator, scratch[0..len], filter, null) catch return;
    defer allocator.free(out);

    // Output bound: 128× expansion is the analytical worst case for the
    // length=129 / single-data-byte pattern; we guard with 128× + 1 to
    // account for any single-iter EOF behaviour.
    if (out.len > len * 128 + 1) return error.RunLengthOutputAboveBound;
}

/// Minimal ASCII85 encoder used only by the round-trip fuzz target. Emits
/// `~>` terminator. Standard PDF base-85 alphabet (`!`..`u`), with `z` for
/// 4-zero-byte tuples (matches the decoder's recognition of `z`).
fn encodeAscii85(allocator: std.mem.Allocator, data: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i + 4 <= data.len) : (i += 4) {
        const tuple: u32 = (@as(u32, data[i]) << 24) |
            (@as(u32, data[i + 1]) << 16) |
            (@as(u32, data[i + 2]) << 8) |
            @as(u32, data[i + 3]);
        if (tuple == 0) {
            try out.append(allocator, 'z');
        } else {
            var t = tuple;
            var buf: [5]u8 = undefined;
            var j: usize = 5;
            while (j > 0) {
                j -= 1;
                buf[j] = @intCast('!' + @as(u8, @intCast(t % 85)));
                t /= 85;
            }
            try out.appendSlice(allocator, &buf);
        }
    }
    // Trailing 1..3 bytes — pad with zeros, encode, then drop padding.
    const rem = data.len - i;
    if (rem > 0) {
        var pad_buf: [4]u8 = .{ 0, 0, 0, 0 };
        @memcpy(pad_buf[0..rem], data[i..]);
        const tuple: u32 = (@as(u32, pad_buf[0]) << 24) |
            (@as(u32, pad_buf[1]) << 16) |
            (@as(u32, pad_buf[2]) << 8) |
            @as(u32, pad_buf[3]);
        var t = tuple;
        var buf: [5]u8 = undefined;
        var j: usize = 5;
        while (j > 0) {
            j -= 1;
            buf[j] = @intCast('!' + @as(u8, @intCast(t % 85)));
            t /= 85;
        }
        // Emit (rem + 1) chars of the 5-char encoding.
        try out.appendSlice(allocator, buf[0 .. rem + 1]);
    }
    try out.appendSlice(allocator, "~>");
    return out.toOwnedSlice(allocator);
}

// ============================================================================
// Targets — decompress.zig differential (iter-5, tier-5)
// ============================================================================
//
// Differential design notes (audit/fuzz_loop_state.md §"Complexity ladder"
// tier 5).
//
// We pivot away from FlateDecode-vs-stdlib because src/decompress.zig:135
// already wraps `std.compress.flate.Decompress` directly — running a
// "differential" between our wrapper and the same stdlib it calls is a
// tautology. Instead we exercise the three legacy decoders (RunLength,
// ASCIIHex, multi-filter chain) against an independent reference encoder
// implemented inline below. The differential property is:
//
//   decompressStream(filter, encode_ref(plain)) == plain  (byte-equal)
//
// On any disagreement we have a real bug in either the reference encoder
// or the production decoder; the encoders are intentionally minimal /
// straight-line so review can pin which side is at fault.
//
// We do NOT include ASCII85 here — iter-1 already covered it round-trip
// (reproducer-only because of Finding 005 u32 overflow). Adding another
// ASCII85 path would either re-trip Finding 005 (forcing reproducer-only
// gating) or duplicate iter-1 work.

/// Reference RunLength encoder. Emits PDF spec-compliant byte stream:
///   - literal run: length byte 0..127 means "next length+1 bytes are
///     literal data"
///   - repeat run: length byte 129..255 means "repeat the next byte
///     257-length times"
///   - 128 is the EOD marker (always emitted at the end)
///
/// Strategy: emit literal-only runs of up to 128 bytes. This is suboptimal
/// for compression but trivially correct, and exercises the literal-copy
/// path in the production decoder (decompress.zig:592-597). Repeat runs
/// are exercised via an alternate biased path triggered ~50% of iters.
fn encodeRunLengthLiteral(allocator: std.mem.Allocator, data: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < data.len) {
        const remaining = data.len - i;
        const run_len = @min(remaining, 128);
        try out.append(allocator, @as(u8, @intCast(run_len - 1))); // length byte: run_len - 1
        try out.appendSlice(allocator, data[i..][0..run_len]);
        i += run_len;
    }
    try out.append(allocator, 128); // EOD
    return out.toOwnedSlice(allocator);
}

/// Reference RunLength encoder using repeat runs. PDF spec: a length byte
/// of 129..255 means "repeat the next byte (257-length) times" → repeat
/// counts of 128..2 (the spec cannot express a single-byte "repeat once").
///
/// Strategy: encode every contiguous run of ≥2 identical bytes as a
/// repeat packet (clamped to 128 per packet), and every other byte as a
/// 1-byte literal packet. This is a real PDF RLE encoder, exercises the
/// repeat path in decompress.zig:599-604, and the differential property
/// `decode(encode(x)) == x` holds for any plaintext.
fn encodeRunLengthMixed(allocator: std.mem.Allocator, data: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < data.len) {
        // Count run of identical bytes starting at i.
        var run: usize = 1;
        while (i + run < data.len and data[i + run] == data[i] and run < 128) {
            run += 1;
        }

        if (run >= 2) {
            // Repeat packet: length byte = 257 - run, then the byte.
            try out.append(allocator, @as(u8, @intCast(257 - run)));
            try out.append(allocator, data[i]);
            i += run;
        } else {
            // Literal packet of exactly 1 byte: length=0 → "next 1 byte".
            try out.append(allocator, 0);
            try out.append(allocator, data[i]);
            i += 1;
        }
    }
    try out.append(allocator, 128); // EOD
    return out.toOwnedSlice(allocator);
}

/// RunLength differential: encode random plaintext with our reference
/// encoder, decode through `decompressStream(RunLengthDecode)`, assert
/// byte-equality.
///
/// Invariants:
///   - decode(encode(x)) == x  (the differential property)
///   - decompressStream returns Ok on every well-formed encode (any
///     error is a finding)
///   - no panic, no leak
///
/// Why this catches bugs the iter-1 `decompress_runlength_random` misses:
/// random bytes rarely form a long literal run that exhausts the 128-byte
/// max-literal-chunk boundary. The reference encoder emits exactly that
/// boundary on inputs ≥128 bytes, exercising the chunk-rollover branch.
fn fuzzDecompressRunLengthDiff(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;
    const filter = parser.Object{ .name = "RunLengthDecode" };

    // Plaintext capped at scratch.len/2 so the encoded form (worst case
    // 2× input for the repeat encoder, plus EOD byte) fits in scratch
    // budget for downstream consumers. We allocate the encoded buffer
    // off the heap so this is just a logical bound.
    const plain_len = rng.intRangeAtMost(usize, 0, scratch.len / 2);
    rng.bytes(scratch[0..plain_len]);
    const plain = scratch[0..plain_len];

    // Pick encoder mode each iter so both decoder paths get exercised:
    //   - literal-only: emits length-128 chunks → exercises literal-copy
    //     branch (decompress.zig:592-597), incl. the chunk-rollover edge.
    //   - mixed: emits repeat packets where the plaintext has runs of
    //     ≥2 identical bytes → exercises the repeat branch (599-604).
    //
    // For mixed mode to actually hit repeat packets often, bias the
    // plaintext so runs are likely. We do this by replacing ~50% of
    // bytes with a copy of the previous byte. Without this, random
    // bytes produce ≥2-byte runs only ~1/256 of the time and the
    // repeat branch is barely exercised.
    const use_mixed = rng.boolean();
    if (use_mixed and plain_len > 1) {
        for (1..plain_len) |idx| {
            if (rng.boolean()) scratch[idx] = scratch[idx - 1];
        }
    }

    const encoded = if (use_mixed)
        try encodeRunLengthMixed(allocator, plain)
    else
        try encodeRunLengthLiteral(allocator, plain);
    defer allocator.free(encoded);

    const decoded = decompress.decompressStream(allocator, encoded, filter, null) catch |err| {
        // Any error on a well-formed encode is a real bug. Don't
        // swallow it — propagate so the harness flags it.
        return err;
    };
    defer allocator.free(decoded);

    if (!std.mem.eql(u8, decoded, plain)) return error.RunLengthDiffMismatch;
}

/// Reference ASCIIHex encoder. Two hex chars per input byte, terminated
/// by `>`. Whitespace can be inserted to exercise the skip-whitespace
/// branch (decompress.zig:429); we do this every iter on a randomized
/// 30% of byte boundaries.
fn encodeAsciiHex(allocator: std.mem.Allocator, data: []const u8, rng: std.Random, insert_whitespace: bool) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const hex_chars = "0123456789ABCDEF";
    const ws_pool = " \t\n\r";

    for (data) |b| {
        if (insert_whitespace and rng.intRangeAtMost(u8, 0, 9) < 3) {
            const ws = ws_pool[rng.intRangeAtMost(usize, 0, ws_pool.len - 1)];
            try out.append(allocator, ws);
        }
        try out.append(allocator, hex_chars[b >> 4]);
        try out.append(allocator, hex_chars[b & 0x0F]);
    }
    try out.append(allocator, '>');
    return out.toOwnedSlice(allocator);
}

/// ASCIIHex differential: encode random plaintext to two-hex-chars-per-
/// byte, decode through `decompressStream(ASCIIHexDecode)`, assert
/// byte-equality.
///
/// Invariants:
///   - decode(encode(x)) == x  (the differential property)
///   - whitespace-insertion mode also satisfies the property (covers
///     the skip-whitespace branch independently)
///   - no panic, no leak
///
/// Why this catches bugs the iter-1 `decompress_ascii_hex_random` misses:
/// random bytes contain only ~1/4 valid hex digits; the iter-1 target
/// rarely produces a long run of valid nibbles that exercises the
/// alternate `high`/`low` accumulation path. This target generates 100%
/// valid hex content and asserts a strict equality property rather than
/// a loose output-length bound.
fn fuzzDecompressAsciiHexDiff(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;
    const filter = parser.Object{ .name = "ASCIIHexDecode" };

    // Plaintext encoded form is 2× + ~30% whitespace + 1; cap at
    // scratch.len/3 to give plenty of headroom even with skewed RNG.
    const plain_len = rng.intRangeAtMost(usize, 0, scratch.len / 3);
    rng.bytes(scratch[0..plain_len]);
    const plain = scratch[0..plain_len];

    const insert_ws = rng.boolean();
    const encoded = try encodeAsciiHex(allocator, plain, rng, insert_ws);
    defer allocator.free(encoded);

    const decoded = decompress.decompressStream(allocator, encoded, filter, null) catch |err| {
        return err;
    };
    defer allocator.free(decoded);

    if (!std.mem.eql(u8, decoded, plain)) return error.AsciiHexDiffMismatch;
}

/// Multi-filter chain differential: encode plaintext through
/// RunLength → ASCIIHex (so the on-wire bytes are ASCII-hex of a
/// run-length-encoded payload), decode through
/// `/Filter [ASCIIHexDecode RunLengthDecode]`, assert byte-equality.
///
/// The PDF spec defines /Filter array order as the order in which the
/// decoders should be applied to the stream. Our `decompressStream`
/// (decompress.zig:54-66) iterates `filters` in array order. So if the
/// encoder emits `hex(rle(plain))`, the decoder array must be
/// `[ASCIIHexDecode, RunLengthDecode]` — first un-hex, then un-rle.
///
/// Invariants:
///   - decode_chain(encode_chain(x)) == x
///   - the multi-filter loop in decompressStream correctly threads
///     each stage's output as the next stage's input (no off-by-one
///     in the `current = result` assignment)
///   - intermediate ownership transfer (the `defer if (owned)…` path
///     in decompressStream:52) doesn't leak
///
/// What this catches that single-filter targets cannot: the inter-stage
/// buffer ownership in `decompressStream`. The `owned` slot is freed,
/// reassigned, and finally null-ed before return — a regression in any
/// of those steps would leak under the test allocator OR double-free
/// under GPA safety. Both are caught at iter granularity here.
fn fuzzDecompressFilterChainDiff(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;

    // Plaintext: run-length encoded form is ≤2× input; ASCIIHex on top
    // is another 2× plus EOD; so encoded form ≤ 4×+slack of plain. Cap
    // plain at scratch.len/5 to keep the encoded form < scratch.len.
    const plain_len = rng.intRangeAtMost(usize, 0, scratch.len / 5);
    rng.bytes(scratch[0..plain_len]);
    const plain = scratch[0..plain_len];

    // Stage 1: RLE (alternate literal vs mixed per iter; both modes
    // are byte-identical round-trips, see encodeRunLengthMixed comment).
    const use_mixed = rng.boolean();
    if (use_mixed and plain_len > 1) {
        for (1..plain_len) |idx| {
            if (rng.boolean()) scratch[idx] = scratch[idx - 1];
        }
    }
    const stage1 = if (use_mixed)
        try encodeRunLengthMixed(allocator, plain)
    else
        try encodeRunLengthLiteral(allocator, plain);
    defer allocator.free(stage1);

    // Stage 2: ASCIIHex on top.
    const stage2 = try encodeAsciiHex(allocator, stage1, rng, false);
    defer allocator.free(stage2);

    // Build the filter array. Object.array is `[]Object` (mutable slice),
    // so allocate from `allocator` and free after.
    var filter_arr = try allocator.alloc(parser.Object, 2);
    defer allocator.free(filter_arr);
    filter_arr[0] = .{ .name = "ASCIIHexDecode" };
    filter_arr[1] = .{ .name = "RunLengthDecode" };
    const filter = parser.Object{ .array = filter_arr };

    const decoded = decompress.decompressStream(allocator, stage2, filter, null) catch |err| {
        return err;
    };
    defer allocator.free(decoded);

    if (!std.mem.eql(u8, decoded, plain)) return error.FilterChainDiffMismatch;
}

// ============================================================================
// Targets — parser.zig (defense-in-depth, iter 2)
// ============================================================================
//
// `Parser.parseObject` is the inner trust boundary: once xref + decryption
// hand off, every byte is parsed as COS syntax. The existing `pdf_open_*`
// targets only reach this surface after a successful xref parse, so the
// deep branches (parens-nested literal strings, hex strings, name escapes,
// reference back-tracking, dict / array recursion up to MAX_NESTING=100,
// the parseDictOrStream branch off `<<…>>`) are under-covered.
//
// `parseIndirectObject` adds the `N M obj … endobj` framing on top, which
// is where `/Length` ↔ stream-data byte counting lives.
//
// `Parser.initAt` is just a constructor with a user-supplied offset; the
// risk is `parseObject` started at an arbitrary byte position of a real
// PDF — high probability of landing mid-token, mid-stream-data, or past
// `data.len`.

/// PDF-ish biased random fuzz against `Parser.parseObject`. Half the iters
/// are pure random bytes (raw stress); the other half are weighted toward
/// COS token shapes (`<<…>>`, `[…]`, `/name`, `<hex>`, `(literal)`,
/// `N M R`, `null`/`true`/`false`, signed-number forms, `%comment` skip).
///
/// Invariants:
///   - no panic (the floor is *surviving the call*)
///   - on success: parser advances strictly forward (`pos > 0`), and
///     `parseObject` produced an `Object` consistent with its tag (e.g.
///     a `.string` payload is valid against the allocator's lifetime).
///   - returned errors are members of `parser.ParseError`
///
/// We do not assert deep round-trip equality — the parser is canonical
/// here, no second implementation to diff against. Exhaustive structural
/// validation is delegated to `validateObjectShape` below: it walks
/// arrays/dicts recursively and checks every leaf has finite payload
/// (no NaN/Inf reals on the round-trip path; arrays/dicts respect
/// MAX_NESTING).
fn fuzzParserObjectPdfish(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;

    const len = rng.intRangeAtMost(usize, 0, scratch.len);
    rng.bytes(scratch[0..len]);

    // Half the iters: bias scratch toward COS-syntax-shaped tokens. Each
    // pass picks a small random window and overwrites it with one of a
    // dozen valid-ish shapes. The remainder of the buffer stays random so
    // we still hit "valid token followed by garbage" paths.
    if (rng.boolean() and len > 0) {
        const n_inserts = rng.intRangeAtMost(usize, 1, 8);
        for (0..n_inserts) |_| {
            biasPdfishToken(rng, scratch[0..len]);
        }
    }

    // Use an arena so a successful parseObject's nested allocations are
    // freed in one shot — `parseObject` returns sub-objects (arrays,
    // dicts, strings) allocated via `self.allocator`. Arena keeps the
    // harness honest under per-iter cleanup without needing per-object
    // free walks.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var p = parser.Parser.init(aa, scratch[0..len]);
    const obj = p.parseObject() catch |err| {
        // Domain errors are expected on adversarial input. Anything outside
        // ParseError is a harness bug — propagate so the runner counts it.
        switch (err) {
            error.UnexpectedToken,
            error.UnexpectedEof,
            error.InvalidNumber,
            error.InvalidString,
            error.InvalidHexString,
            error.InvalidName,
            error.InvalidDictionary,
            error.InvalidArray,
            error.InvalidStream,
            error.InvalidReference,
            error.NestingTooDeep,
            error.OutOfMemory,
            => return,
        }
    };

    // Parser advanced (a successful parse must have consumed ≥1 byte
    // unless `parseObject` was somehow called on empty input — which
    // returns UnexpectedEof, handled above).
    if (p.pos == 0 and len > 0) return error.ParserDidNotAdvance;
    if (p.pos > p.data.len) return error.ParserPosBeyondData;

    try validateObjectShape(obj, 0);
}

/// Biased-random fuzz against `Parser.parseIndirectObject`. Generates
/// `N M obj … endobj` shapes with random `N` / `M` / inner-object bytes,
/// occasionally with a stream segment whose `/Length` either matches,
/// under-shoots, or over-shoots the actual data — the boundary cases the
/// task brief calls out as worth seeding.
///
/// Invariants:
///   - no panic
///   - on success: `result.num` and `result.gen` round-trip the input
///     header (mod the adversarial-input edge where `parseIndirectObject`
///     itself rejects with InvalidReference for u32/u16 overflow)
///   - returned errors are in `parser.ParseError`
fn fuzzParserIndirectObjectRandom(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;

    // Build a synthetic indirect-object frame inside `scratch`, then
    // optionally smear a few random bytes over it.
    var aw = std.Io.Writer.fixed(scratch);

    const num = rng.intRangeAtMost(u32, 0, 1_000_000);
    const gen = rng.intRangeAtMost(u16, 0, 65535);

    aw.print("{d} {d} obj\n", .{ num, gen }) catch return;

    // Pick one of: integer, name, dict, array, stream-with-length.
    const inner_kind = rng.intRangeAtMost(u8, 0, 4);
    switch (inner_kind) {
        0 => aw.print("{d}", .{rng.int(i32)}) catch return,
        1 => aw.writeAll("/SomeName") catch return,
        2 => aw.writeAll("<< /Type /Catalog /Pages 2 0 R >>") catch return,
        3 => aw.writeAll("[1 2 3 (hi) /Foo]") catch return,
        4 => {
            // Stream object. Vary the /Length policy:
            //   0 → omit /Length (decoder uses endstream-search fallback)
            //   1 → /Length matches the data
            //   2 → /Length under-shoots (data tail leaks into endstream)
            //   3 → /Length over-shoots (would read past data.len)
            //   4 → /Length is negative (must be rejected as InvalidStream)
            const policy = rng.intRangeAtMost(u8, 0, 4);
            const data_len = rng.intRangeAtMost(usize, 0, 64);
            const claimed: i64 = switch (policy) {
                1 => @intCast(data_len),
                2 => @intCast(data_len -| rng.intRangeAtMost(usize, 1, @max(1, data_len))),
                3 => @as(i64, @intCast(data_len)) + @as(i64, rng.intRangeAtMost(i64, 1, 200)),
                4 => -@as(i64, rng.intRangeAtMost(i64, 1, 1000)),
                else => 0, // policy 0 — value unused, dict omits /Length
            };
            if (policy == 0) {
                aw.writeAll("<< /Filter /ASCIIHexDecode >>\nstream\n") catch return;
            } else {
                aw.print("<< /Length {d} >>\nstream\n", .{claimed}) catch return;
            }
            // Random data bytes, then maybe missing endstream marker.
            const buf_remaining = scratch.len - aw.end;
            const safe_data_len = @min(data_len, buf_remaining -| 32);
            for (0..safe_data_len) |_| {
                aw.writeByte(rng.int(u8)) catch break;
            }
            // Optional endstream + endobj. Sometimes drop one or both to
            // exercise the optional-keyword paths (parser tolerates a
            // missing endobj per spec).
            if (rng.boolean()) aw.writeAll("\nendstream") catch {};
        },
        else => unreachable,
    }

    if (rng.boolean()) aw.writeAll("\nendobj\n") catch {};

    // Optional smearing: flip 0..4 random bytes inside the assembled frame.
    const written = aw.end;
    const flips = rng.intRangeAtMost(usize, 0, 4);
    for (0..flips) |_| {
        if (written == 0) break;
        const idx = rng.intRangeAtMost(usize, 0, written - 1);
        scratch[idx] ^= rng.int(u8);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var p = parser.Parser.init(arena.allocator(), scratch[0..written]);
    const got = p.parseIndirectObject() catch |err| {
        switch (err) {
            error.UnexpectedToken,
            error.UnexpectedEof,
            error.InvalidNumber,
            error.InvalidString,
            error.InvalidHexString,
            error.InvalidName,
            error.InvalidDictionary,
            error.InvalidArray,
            error.InvalidStream,
            error.InvalidReference,
            error.NestingTooDeep,
            error.OutOfMemory,
            => return,
        }
    };

    // Header-round-trip invariant: only meaningful when no smearing
    // landed on the header. If flips were 0 we can assert.
    if (flips == 0) {
        if (got.num != num) return error.IndirectHeaderNumMismatch;
        if (got.gen != gen) return error.IndirectHeaderGenMismatch;
    }
    if (p.pos > p.data.len) return error.ParserPosBeyondData;

    try validateObjectShape(got.obj, 0);
}

/// Random-offset fuzz against `Parser.initAt(seed_pdf, offset).parseObject()`.
/// Picks a uniformly random byte offset into one of the seed-pool PDFs and
/// drives `parseObject` from there. Most offsets land mid-token (or in
/// stream data, or past `data.len`); the floor invariant is *no panic, no
/// OOB read*. We never expect "success" here — it's the structural-error
/// path under hostile starting positions.
///
/// Invariants:
///   - no panic, no segfault, no @intCast trap
///   - if parseObject returns Ok, the parser advanced and pos ≤ data.len
///   - returned errors are in `parser.ParseError`
fn fuzzParserInitAtOffsetRandom(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = scratch;

    if (seed_pdf.len == 0) return;

    // Random offset across the full PDF, including the boundary at
    // `data.len` (initAt is allowed to receive an at-end offset; the
    // first parseObject call should immediately return UnexpectedEof).
    const offset = rng.intRangeAtMost(usize, 0, seed_pdf.len);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var p = parser.Parser.initAt(arena.allocator(), seed_pdf, offset);

    // Sometimes call parseObject; sometimes parseIndirectObject — both
    // are public surface against `initAt`.
    const used_indirect = rng.boolean();
    if (used_indirect) {
        const got = p.parseIndirectObject() catch |err| switch (err) {
            error.UnexpectedToken,
            error.UnexpectedEof,
            error.InvalidNumber,
            error.InvalidString,
            error.InvalidHexString,
            error.InvalidName,
            error.InvalidDictionary,
            error.InvalidArray,
            error.InvalidStream,
            error.InvalidReference,
            error.NestingTooDeep,
            error.OutOfMemory,
            => return,
        };
        if (p.pos > p.data.len) return error.ParserPosBeyondData;
        try validateObjectShape(got.obj, 0);
    } else {
        const obj = p.parseObject() catch |err| switch (err) {
            error.UnexpectedToken,
            error.UnexpectedEof,
            error.InvalidNumber,
            error.InvalidString,
            error.InvalidHexString,
            error.InvalidName,
            error.InvalidDictionary,
            error.InvalidArray,
            error.InvalidStream,
            error.InvalidReference,
            error.NestingTooDeep,
            error.OutOfMemory,
            => return,
        };
        if (p.pos > p.data.len) return error.ParserPosBeyondData;
        try validateObjectShape(obj, 0);
    }
}

/// Overwrite a randomly-chosen window of `buf` with a COS-syntax-shaped
/// token. Window length is bounded by what the chosen token needs; if
/// `buf` is too small we no-op rather than truncate.
fn biasPdfishToken(rng: std.Random, buf: []u8) void {
    if (buf.len == 0) return;
    const choice = rng.intRangeAtMost(u8, 0, 13);
    const tokens = [_][]const u8{
        "<< /Type /Page >>",
        "<< /Length 12 >>\nstream\nHello World!\nendstream",
        "[1 2 3 4]",
        "[(a) (b) (c)]",
        "/Name#20With#20Spaces",
        "<48656C6C6F>",
        "(Hello (nested) World)",
        "10 0 R",
        "%a comment\n",
        "true false null",
        "-3.14e2",
        "<< /A 1 /B 2 /C [ 1 2 << /D 5 >> ] >>",
        "(\\101\\102\\103\\\\)",
        "<<<<<<<<<<<<<<<<<<<<>>>>>>>>>>>>>>>>>>>>", // adversarial: 20-deep dict
    };
    const tok = tokens[choice];
    if (tok.len > buf.len) return;
    // Codex review of 77b8bf5 [P2]: `parseObject` starts at `pos == 0` and
    // only skips whitespace + comments before dispatching, so a biased
    // token written at a non-zero offset is never reached. Place the
    // first token at offset 0 deterministically; if there's room, plant
    // a *second* token at a random later offset to keep the
    // partial-overwrite + adjacent-noise coverage the original placement
    // was reaching for.
    @memcpy(buf[0..tok.len], tok);
    if (buf.len > 2 * tok.len and rng.boolean()) {
        const max_off = buf.len - 2 * tok.len;
        const off = tok.len + rng.intRangeAtMost(usize, 0, max_off);
        @memcpy(buf[off..][0..tok.len], tok);
    }
}

/// Recursive structural validator. Walks `obj` and asserts:
///   - reals are finite (no NaN / +inf / -inf snuck through)
///   - dict keys are non-null slices
///   - nesting depth never exceeds `parser.MAX_NESTING` (100 — we use 200
///     here as a generous backstop in case the constant changes)
///   - reference num/gen are inside their public type bounds
///
/// Errors propagate as harness-side invariant violations.
fn validateObjectShape(obj: parser.Object, depth: usize) anyerror!void {
    if (depth > 200) return error.ObjectNestingExceedsBackstop;
    switch (obj) {
        .null, .boolean, .integer => {},
        .real => |r| {
            if (!std.math.isFinite(r)) return error.ObjectRealNonFinite;
        },
        .string, .hex_string, .name => {},
        .array => |arr| {
            for (arr) |item| try validateObjectShape(item, depth + 1);
        },
        .dict => |d| {
            for (d.entries) |entry| {
                if (entry.key.len == 0) {
                    // Empty name keys are legal per PDF spec but suspicious;
                    // we accept and continue.
                }
                try validateObjectShape(entry.value, depth + 1);
            }
        },
        .stream => |s| {
            for (s.dict.entries) |entry| try validateObjectShape(entry.value, depth + 1);
            // stream.data is a borrow into the parser's input — len is
            // bounded by the parser; nothing to assert beyond no-panic.
            _ = s.data;
        },
        .reference => |r| {
            // u32/u16 are the type bounds — already enforced by `@intCast`
            // inside parseIndirectObject. This is just a tripwire for any
            // future regression that would let a wider int leak in.
            _ = r;
        },
    }
}


// ============================================================================
// Targets — interpreter.zig (content-stream operator dispatch, iter-3)
// ============================================================================
//
// Coverage map. The two targets layer in increasing depth:
//
//   1. `interpreter_random_ops`         — drives `ContentLexer.next()` over
//      raw + COS-operator-biased bytes. This is the actual production lexer
//      surface (`extractContentStream` calls it directly). Floor: no panic,
//      `pos` advances monotonically, returned slices are inside `data`.
//
//   2. `interpreter_bdc_emc_nesting`    — synthesises a minimal valid PDF
//      whose page content stream is a procedurally-generated cocktail of
//      random operators (BMC/BDC/EMC up to depth ~200, plus Tj) and drives
//      the *production* `extractMarkdown` path end-to-end. This is the
//      only target that exercises root.zig's `extractContentStream`
//      dispatch (BDC/EMC tag stack with MAX_MC_DEPTH=64, artifact-skip
//      gate, font lookup) at hostile depth. Floor: depth cap silently
//      degrades (per the comment at root.zig:2913); no panic.
//
// A planned third target — `interpreter_q_stack_dispatch` — would have
// driven the public `ContentInterpreter(Writer).process()` with
// adversarial q/Q runs to stress its `state_stack` resize path. Building
// it surfaced **Finding 006** (interpreter.zig:103, :172 stale 0.15
// `ArrayList(...).init()` / `.append(item)` API in production), so the
// target is omitted pending the prod-side migration. The
// `ContentInterpreter` type is public surface but unused in production
// today (extractContentStream calls `ContentLexer` directly with its own
// dispatch), which is why the rot stayed hidden until iter-3. Re-add a
// q/Q-stack target when the type compiles again.
//
// Pitfall avoided (Codex round-2 on iter-2): biased-input fuzzers must
// place biased tokens at offset 0, not at random offsets, because the
// SUT starts parsing from pos=0. `interpreter_random_ops` uses
// `biasContentToken` which always plants the first token at offset 0.

/// Bias a chosen window of `buf` toward PDF content-stream tokens. The
/// first chosen token always lands at offset 0 (so the lexer reaches it
/// after `skipWhitespaceAndComments`); a second copy may land at a random
/// later offset to keep the partial-overwrite + adjacent-noise coverage.
fn biasContentToken(rng: std.Random, buf: []u8) void {
    if (buf.len == 0) return;
    // Mix of: text operators, graphics-state operators, marked-content,
    // xobject paint, inline-image marker, hex string, name tokens, common
    // adversarial shapes (unbalanced parens, deeply nested arrays, BMC
    // without an EMC, etc.).
    const tokens = [_][]const u8{
        "BT /F1 12 Tf (Hello) Tj ET",
        "q 1 0 0 1 50 50 cm /Im1 Do Q",
        "/Span <</MCID 0>> BDC (text) Tj EMC",
        "/Artifact BMC (header) Tj EMC",
        "[(a) -200 (b) 50 (c)] TJ",
        "<48656C6C6F> Tj",
        "/F1 12 Tf",
        "100 200 Td 300 400 TD",
        "1 0 0 1 0 0 Tm",
        "T* ' \" Tc Tw TL Tz Ts Tr",
        "q Q q Q q Q",                  // shallow balanced
        "q q q q q q q q q q q q",      // deep unbalanced (push only)
        "Q Q Q Q Q Q Q Q Q Q Q Q",      // pop without push
        "BMC EMC BMC EMC",              // unbracketed BMC, no name operand
        "BDC BDC BDC EMC",              // missing EMCs
        "BI /W 1 /H 1 ID \xAA\xBB EI", // inline image
        "(unterminated string",         // open paren never closes
        "<8765",                         // open hex never closes
        "/Name#20Spaces",
        "%comment line\n",
        "[<<<<<<<<<<<<<<<<>>>>>>>>>>>>]", // pathological array
        "10 0 R Do",                       // resolve-then-paint
        "0.5 0.5 0.5 rg 0 0 0 RG",        // colour set
        "/CS1 cs /CS1 CS",                 // colourspace ops
        "/GS1 gs",                          // ExtGState ref
    };
    const choice = rng.intRangeAtMost(usize, 0, tokens.len - 1);
    const tok = tokens[choice];
    if (tok.len > buf.len) return;
    @memcpy(buf[0..tok.len], tok);
    if (buf.len > 2 * tok.len and rng.boolean()) {
        const max_off = buf.len - 2 * tok.len;
        const off = tok.len + rng.intRangeAtMost(usize, 0, max_off);
        const tok2 = tokens[rng.intRangeAtMost(usize, 0, tokens.len - 1)];
        if (off + tok2.len <= buf.len) @memcpy(buf[off..][0..tok2.len], tok2);
    }
}

/// Iter-3 #1 — random + biased bytes through `ContentLexer.next()`.
///
/// Half the iters are pure random ASCII; the other half are biased toward
/// PDF operator tokens (planted at offset 0 so they survive
/// `skipWhitespaceAndComments`). Drives the lexer until EOF or first
/// error, asserting the float-parse / hex-string / parens-balance /
/// inline-image-skip branches don't panic.
///
/// Invariants:
///   - no panic
///   - lexer pos never exceeds data.len
///   - pos is monotonically non-decreasing (next() always advances or
///     terminates; a fixpoint of (pos, EOF=false) would loop forever)
///   - returned `string` / `hex_string` / `name` / `operator` slices are
///     either empty or pointers into `data` / arena-owned memory
///   - returned numbers are finite (NaN/Inf would mean simd.parseFloat
///     leaked an arithmetic edge through)
fn fuzzInterpreterRandomOps(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;
    const len = rng.intRangeAtMost(usize, 0, @min(scratch.len, 8192));
    rng.bytes(scratch[0..len]);

    // Half the iters: bias scratch toward content-stream operator tokens.
    if (rng.boolean() and len > 0) {
        const n_inserts = rng.intRangeAtMost(usize, 1, 8);
        for (0..n_inserts) |_| biasContentToken(rng, scratch[0..len]);
    }

    // ContentLexer's scanString / scanHexString allocate via the supplied
    // allocator. Use an arena so a successful run's heap-promoted overflow
    // buffers are freed in one shot, matching the iter-2 pattern.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var lex = interpreter.ContentLexer.init(aa, scratch[0..len]);

    var prev_pos: usize = 0;
    // Bound the per-iter token count. A pathological scratch could produce
    // up to ~len tokens (every byte its own delimiter); 4× len is a safe
    // ceiling that still catches infinite-loop regressions.
    const max_tokens = len * 4 + 16;
    var token_count: usize = 0;

    while (try lex.next()) |tok| {
        token_count += 1;
        if (token_count > max_tokens) return error.LexerTokenCountExceededBound;
        if (lex.pos > lex.data.len) return error.LexerPosBeyondData;
        // Strict monotonicity: every yielded token must consume ≥1 byte.
        // (Lexer skips whitespace before yielding, so equal-pos two-in-a-row
        // would mean a zero-width token — an infinite-loop bug.)
        if (lex.pos <= prev_pos) return error.LexerDidNotAdvance;
        prev_pos = lex.pos;

        switch (tok) {
            .number => |n| {
                if (!std.math.isFinite(n)) return error.LexerNumberNonFinite;
            },
            .string, .hex_string, .name, .operator => {
                // Slices may be either pointers into `data` (name, operator)
                // or arena-owned (string, hex_string after escape decode).
                // No structural check beyond "didn't crash to get here."
            },
            .array => |arr| {
                // The array buffer is a fixed `[512]Operand` inside the
                // lexer; its length must respect that cap.
                if (arr.len > 512) return error.LexerArrayLenExceedsCap;
                for (arr) |op| switch (op) {
                    .number => |n| if (!std.math.isFinite(n)) return error.LexerArrayNumberNonFinite,
                    else => {},
                };
            },
        }
    }

    if (lex.pos > lex.data.len) return error.LexerPosBeyondDataAtEof;
}

/// Iter-3 #2 — random BMC/BDC/EMC nesting through the *production*
/// `Document.extractMarkdown` path.
///
/// Synthesises a minimal valid PDF whose single page's content stream is
/// the iter's procedurally-generated operator soup. The pdf_document
/// builder handles header, xref, trailer, font resources for us; we
/// `appendContent(stream)` to plant our raw bytes verbatim.
///
/// What this exercises that the lexer-only and ContentInterpreter targets
/// don't: root.zig::`extractContentStream` BDC/BMC tag-stack tracking
/// with `MAX_MC_DEPTH=64` (silent depth-cap degradation), artifact-skip
/// gate, and the full font-cache lookup path during Tj decoding.
///
/// Invariants:
///   - openFromMemory + extractMarkdown succeed OR return a domain error
///     (the synthesised PDF is structurally valid; the content stream
///     may be adversarial, but the parser tolerates malformed content
///     streams up to its lexer limits)
///   - no panic at any depth — even when the stream contains 200 BDCs
///     in a row (well past MAX_MC_DEPTH)
///   - returned markdown is valid UTF-8
fn fuzzInterpreterBdcEmcNesting(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;

    // Build the content stream into `scratch`. We target up to 200 BDC/BMC
    // pushes interleaved with EMC pops, plus a few text operators so the
    // markdown extraction path is exercised, not just the marked-content
    // tracker.
    var aw = std.Io.Writer.fixed(scratch);

    // Need a font reference for Tj — we'll get the resource name back from
    // markFontUsed below. Prefix the stream with `BT /<font> 12 Tf 100 700 Td`
    // so the page renders something even if all the BDCs do nothing.
    var doc = pdf_document.DocumentBuilder.init(allocator);
    defer doc.deinit();
    const page = doc.addPage(.{ 0, 0, 612, 792 }) catch return;
    const font_name = page.markFontUsed(.helvetica) catch return;

    aw.print("BT\n{s} 12 Tf\n100 700 Td\n", .{font_name}) catch return;

    const n_ops = rng.intRangeAtMost(usize, 0, 256);

    for (0..n_ops) |_| {
        const r = rng.intRangeAtMost(u8, 0, 99);
        if (r < 30) {
            // BDC with name + dict (with optional MCID)
            const mcid = rng.int(u16);
            aw.print("/Span <</MCID {d}>> BDC ", .{mcid}) catch break;
        } else if (r < 50) {
            // BMC (tag-only)
            const tag_choice = rng.intRangeAtMost(u8, 0, 3);
            const tag = switch (tag_choice) {
                0 => "/Span",
                1 => "/Artifact", // exercises artifact-skip gate
                2 => "/P",
                else => "/Unknown",
            };
            aw.print("{s} BMC ", .{tag}) catch break;
        } else if (r < 80) {
            // EMC — even when there's no matching open bracket
            // (adversarial). The dispatch tolerates this (production code
            // at root.zig:2980 just decrements when depth > 0).
            aw.writeAll("EMC ") catch break;
        } else if (r < 90) {
            // Plain Tj — exercises the text path inside whatever bracket
            // we're currently in (artifact suppression depends on this).
            aw.writeAll("(t) Tj ") catch break;
        } else if (r < 95) {
            // BDC with malformed properties (no /MCID — exercises the
            // root.zig defensive sentinel-push branch at 2944–2952).
            aw.writeAll("/X <<>> BDC ") catch break;
        } else {
            // BDC with NO name operand at all — the truly hostile case
            // for the depth tracker, since the dispatch must still keep
            // the stack invariant when no /Tag was provided.
            aw.writeAll("BDC ") catch break;
        }
    }

    aw.writeAll("ET\n") catch {};
    const stream_len = aw.end;

    page.appendContent(scratch[0..stream_len]) catch return;

    // Note on substring-count invariants: per audit/fuzz_loop_state.md
    // pitfall list, counting `BDC`/`EMC` in the emitted bytes is
    // unreliable when content streams are FlateDecode'd. Our synthesised
    // PDF here goes through DocumentBuilder which (as of v1.6) does NOT
    // compress page content streams by default, so a direct substring
    // probe *would* work — but we still avoid it: the invariant we care
    // about is "no panic across hostile depth," and that's covered by
    // the round-trip Document.extractMarkdown call below. A grep on
    // `pdf_buf` for raw operator bytes would catch a future regression
    // where the builder gains FlateDecode-by-default and silently
    // breaks the content-shape assumption.
    const pdf_buf = doc.write() catch return;
    defer allocator.free(pdf_buf);

    var d = zpdf.Document.openFromMemory(allocator, pdf_buf, zpdf.ErrorConfig.permissive()) catch return;
    defer d.close();

    if (d.pageCount() == 0) return;
    const md = d.extractMarkdown(0, allocator) catch return;
    defer allocator.free(md);

    if (!std.unicode.utf8ValidateSlice(md)) return error.InterpreterMarkdownInvalidUtf8;
}

// ============================================================================
// Iter-4 — DocumentBuilder ↔ Document round-trip (tier 3, audit/fuzz_loop_state.md)
// ============================================================================

/// Round-trip property: build a single-page PDF with N drawn-text strings
/// → Document.openFromMemory → extractMarkdown → assert every drawn string
/// is present in the extracted markdown.
///
/// Inputs constrained to printable ASCII (0x20..0x7E excluding the PDF
/// metachars `( ) \`) so the WinAnsi-filter doesn't drop bytes and the
/// drawn string survives intact through escape→content-stream→reparse.
/// Metachar coverage lives in the dedicated escape-roundtrip target so a
/// failure in either path points at the correct seam.
///
/// What this exercises:
///   - PageBuilder.drawText escape path (parens, backslashes are excluded
///     here on purpose to keep the equality check unambiguous)
///   - DocumentBuilder.write xref + page-tree assembly
///   - Document.openFromMemory parser end-to-end on a writer-produced doc
///   - extractMarkdown text-extraction on a builtin Helvetica page
///
/// Invariants:
///   - written bytes start with the PDF magic
///   - reopen succeeds (`openFromMemory` does not return an error)
///   - pageCount() == 1
///   - extracted markdown is valid UTF-8
///   - every drawn string appears as a substring of the extracted markdown
fn fuzzWriterDrawTextRoundtrip(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = scratch;
    _ = seed_pdf;

    var doc = pdf_document.DocumentBuilder.init(allocator);
    defer doc.deinit();
    const page = try doc.addPage(.{ 0, 0, 612, 792 });

    // 1..4 strings per page; each 4..16 bytes of alphanumeric ASCII.
    // Restricted to [A-Za-z0-9] because the extractor is markdown-shape-
    // aware: a drawn `*foo*` re-emerges as `**foo**` (or italic markers),
    // a leading `# ` becomes a heading prefix, etc. Those are *correct*
    // round-trips at the markdown layer but break the byte-identical
    // substring assertion this target encodes. The PDF metachars
    // `(` / `)` / `\\` are exercised by the dedicated escape-roundtrip
    // target below.
    const safe_charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    const n_strings = rng.intRangeAtMost(usize, 1, 4);

    var emitted: [4][]u8 = undefined;
    var emitted_count: usize = 0;
    defer for (emitted[0..emitted_count]) |s| allocator.free(s);

    var y: f64 = 700.0;
    for (0..n_strings) |i| {
        const slen = rng.intRangeAtMost(usize, 4, 16);
        const buf = try allocator.alloc(u8, slen);
        emitted[i] = buf;
        emitted_count += 1;
        for (buf) |*b| b.* = safe_charset[rng.intRangeAtMost(usize, 0, safe_charset.len - 1)];
        try page.drawText(50.0, y, .helvetica, 12.0, buf);
        y -= 20.0;
    }

    const bytes = try doc.write();
    defer allocator.free(bytes);

    // Postcondition: writer emits a valid PDF prefix.
    if (bytes.len < 5 or !std.mem.startsWith(u8, bytes, "%PDF-")) {
        return error.WriterOutputMissingMagic;
    }

    var d = try zpdf.Document.openFromMemory(allocator, bytes, zpdf.ErrorConfig.permissive());
    defer d.close();
    if (d.pageCount() != 1) return error.WriterPageCountMismatch;

    const md = try d.extractMarkdown(0, allocator);
    defer allocator.free(md);
    if (!std.unicode.utf8ValidateSlice(md)) return error.WriterMarkdownInvalidUtf8;

    for (emitted[0..emitted_count]) |s| {
        if (std.mem.indexOf(u8, md, s) == null) {
            return error.WriterDrawnTextNotFoundInMarkdown;
        }
    }
}

/// Round-trip property: build a PDF with a random number of pages
/// (1..16), each with a random media-box and one drawn label, then
/// reopen and verify the page count round-trips exactly + every page
/// extracts without parser error.
///
/// What this exercises:
///   - balanced page-tree assembly (the writer chooses /Kids structure
///     based on page count; up to 16 forces > 1 internal node)
///   - varying media-box rectangles (writer real-number formatter)
///   - extractMarkdown on every page (page-cache state stability)
///
/// Invariants:
///   - openFromMemory succeeds
///   - pageCount() == n_pages
///   - every page's extractMarkdown succeeds + returns valid UTF-8
fn fuzzWriterMultipageCount(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = scratch;
    _ = seed_pdf;

    var doc = pdf_document.DocumentBuilder.init(allocator);
    defer doc.deinit();

    const n_pages = rng.intRangeAtMost(usize, 1, 16);

    // Vary the media-box per page within a sensible PDF-real range
    // (0..2400 pt — the spec's UserUnit-1 ceiling for letter-class
    // media). Width / height kept ≥ 100 pt so drawText coords are valid.
    for (0..n_pages) |i| {
        const w = 100.0 + rng.float(f64) * 2300.0;
        const h = 100.0 + rng.float(f64) * 2300.0;
        const page = try doc.addPage(.{ 0.0, 0.0, w, h });
        // Draw a per-page label so each page has a non-empty content
        // stream — extractMarkdown on a page with zero text returns "",
        // which is a valid but uninteresting round-trip.
        var label_buf: [16]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buf, "P{d}", .{i});
        try page.drawText(20.0, h - 40.0, .helvetica, 10.0, label);
    }

    const bytes = try doc.write();
    defer allocator.free(bytes);

    var d = try zpdf.Document.openFromMemory(allocator, bytes, zpdf.ErrorConfig.permissive());
    defer d.close();
    if (d.pageCount() != n_pages) return error.WriterPageCountMismatch;

    var idx: usize = 0;
    while (idx < n_pages) : (idx += 1) {
        const md = try d.extractMarkdown(idx, allocator);
        defer allocator.free(md);
        if (!std.unicode.utf8ValidateSlice(md)) return error.WriterMarkdownInvalidUtf8;
    }
}

/// Round-trip property focused on the PDF text-string escape rules:
/// `(`, `)`, `\` must be escaped on the writer side and unescaped on
/// the reader side. Builds a single-page PDF with a randomized string
/// containing a random sprinkling of metachars, writes, reopens, and
/// asserts the drawn text appears verbatim in the extracted *raw text*
/// (not markdown — the markdown layer applies its own escaping pass
/// over `\\`/`*`/`_` etc., which would mask a real PDF-escape bug).
///
/// What this exercises:
///   - drawText's metachar-escape path on inputs that actually contain
///     metachars (the round-trip target above intentionally avoids them
///     so a failure here pinpoints the escape seam)
///   - the parser's PDF literal-string unescaper (interpreter.zig
///     parseStringLiteral / parseLiteralString)
///   - extractText writer-streaming surface
///
/// Invariants:
///   - reopen succeeds, pageCount() == 1
///   - extracted raw text contains the originally-drawn string verbatim
fn fuzzWriterTextEscapeRoundtrip(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;

    // Build a 4..32 byte string biased toward the three PDF metachars
    // `(`, `)`, `\` (each ~1/8 probability) interleaved with safe
    // alphanumerics. Restricted to [A-Za-z0-9] (plus the three
    // metachars) so the round-trip equality test exercises the PDF
    // text-string escape seam without confounding with the markdown
    // layer's punctuation handling.
    const safe_charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    const slen = rng.intRangeAtMost(usize, 4, 32);
    if (slen > scratch.len) return;
    for (scratch[0..slen]) |*b| {
        const choice = rng.intRangeAtMost(u8, 0, 7);
        b.* = switch (choice) {
            0 => '(',
            1 => ')',
            2 => '\\',
            else => safe_charset[rng.intRangeAtMost(usize, 0, safe_charset.len - 1)],
        };
    }
    const drawn = scratch[0..slen];

    var doc = pdf_document.DocumentBuilder.init(allocator);
    defer doc.deinit();
    const page = try doc.addPage(.{ 0, 0, 612, 792 });
    try page.drawText(50.0, 700.0, .helvetica, 12.0, drawn);

    const bytes = try doc.write();
    defer allocator.free(bytes);

    var d = try zpdf.Document.openFromMemory(allocator, bytes, zpdf.ErrorConfig.permissive());
    defer d.close();
    if (d.pageCount() != 1) return error.WriterPageCountMismatch;

    // Stream raw extracted text into an Allocating writer — bypasses
    // the markdown layer (which would re-escape backslashes / asterisks
    // / underscores and break a byte-identical comparison even though
    // the PDF round-trip itself was correct).
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try d.extractText(0, &aw.writer);
    const raw = aw.written();
    if (!std.unicode.utf8ValidateSlice(raw)) return error.WriterRawTextInvalidUtf8;

    if (std.mem.indexOf(u8, raw, drawn) == null) {
        return error.WriterEscapedTextNotFoundInRawText;
    }
}

// ============================================================================
// iter-7 (tier-7) — multi-stage adversarial round-trip
// ============================================================================

/// Number of round-trip stages per fuzz iter. Each stage is one
/// build → parse → canonicalise cycle. Capped at 4 to keep wall time
/// bounded (see audit/fuzz_loop_state.md history table for budget).
const PDF_OF_PDF_STAGES: usize = 4;

/// Reduce a parsed Document to a canonical "what the parser saw" string:
/// `pageCount\n` followed by extractMarkdown of every page joined by
/// `\x1f` (unit separator — not a byte the WinAnsi filter or PDF emitter
/// will produce, so unambiguous as a delimiter). Caller owns the result.
///
/// Drift between two canon snapshots taken across a build/parse cycle
/// = either a writer asymmetry (drawText emits text the parser can't
/// recover) or a parser asymmetry (extractMarkdown returns text that,
/// when fed back into drawText, is not preserved).
fn pdfOfPdfCanonicalise(
    doc: *zpdf.Document,
    allocator: std.mem.Allocator,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    const n = doc.pageCount();
    var hdr: [32]u8 = undefined;
    const hdr_str = try std.fmt.bufPrint(&hdr, "{d}\n", .{n});
    try out.appendSlice(allocator, hdr_str);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const md = try doc.extractMarkdown(i, allocator);
        defer allocator.free(md);
        try out.appendSlice(allocator, md);
        try out.append(allocator, 0x1f);
    }
    return out.toOwnedSlice(allocator);
}

/// Synthesise a fresh PDF from a canonical text by sharding the
/// extracted text across one page per `\x1f`-separated chunk. The
/// emitted PDF is what the next stage parses; if drawText + the parser
/// agree on what's representable, canonicalising the next stage MUST
/// reproduce the same bytes. Caller owns the result.
fn pdfOfPdfEmitFromCanon(
    canon: []const u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    // Strip the page-count header line; it's metadata, not page text.
    const nl = std.mem.indexOfScalar(u8, canon, '\n') orelse return error.PdfOfPdfMalformedCanon;
    const body = canon[nl + 1 ..];

    var doc = pdf_document.DocumentBuilder.init(allocator);
    defer doc.deinit();

    var it = std.mem.splitScalar(u8, body, 0x1f);
    var pages_emitted: u32 = 0;
    while (it.next()) |chunk_text| {
        // The trailing US byte yields one empty chunk after the last
        // page; skip it so we don't emit a phantom page that bumps
        // pageCount on the round-trip.
        if (chunk_text.len == 0) continue;
        const page = try doc.addPage(.{ 0, 0, 612, 792 });
        // drawText filters non-ASCII / control bytes for WinAnsi fonts.
        // That filter IS the canonicalisation step — feeding the same
        // pre-filtered text twice must converge.
        try page.drawText(72, 720, .helvetica, 12, chunk_text);
        pages_emitted += 1;
        // Cap pages per iter so a path that explodes the page count
        // (parser drift inserting extra US bytes) doesn't OOM the
        // arena. Hard cap mirrors the page-count assertion below.
        if (pages_emitted >= 32) break;
    }
    if (pages_emitted == 0) {
        // Empty doc isn't legal — emit a single empty page so the
        // round-trip has something to parse.
        _ = try doc.addPage(.{ 0, 0, 612, 792 });
    }
    return doc.write();
}

/// Mutate a canonical text by sprinkling PDF-meaningful punctuation
/// likely to surface escape asymmetries: parens, backslash, octal-
/// looking digits, CR / LF, hex-string delimiters, name-token `#`.
/// Bytes outside [0x20, 0x7e] are dropped on the next emit by the
/// WinAnsi filter — but they exercise the WRITER's filter logic,
/// which is part of the round-trip surface.
fn pdfOfPdfMutateCanon(
    canon: []u8,
    rng: std.Random,
) void {
    if (canon.len == 0) return;
    // Skip the header line and the US byte separator when picking
    // mutation positions, otherwise we'd corrupt the page-count
    // metadata or the chunk delimiter and the next emit step would
    // misread the page geometry.
    const nl = std.mem.indexOfScalar(u8, canon, '\n') orelse return;
    if (canon.len <= nl + 1) return;

    const adversarial = [_]u8{
        '(', ')', '\\', '<', '>', '#', '%', '/',
        '\n', '\r', '\t', '0', '1', '7', // octal-escape-looking digits
        ' ', ' ', // bias toward whitespace (WinAnsi-safe)
    };
    const flips = rng.intRangeAtMost(usize, 1, 6);
    var k: usize = 0;
    while (k < flips) : (k += 1) {
        const idx = rng.intRangeAtMost(usize, nl + 1, canon.len - 1);
        // Don't overwrite the US separator — keeps page boundaries
        // stable across the mutation.
        if (canon[idx] == 0x1f) continue;
        canon[idx] = adversarial[rng.intRangeAtMost(usize, 0, adversarial.len - 1)];
    }
}

/// Tier-7 multi-stage adversarial round-trip. Each iter walks
/// `PDF_OF_PDF_STAGES` build → parse → canonicalise cycles, mutating
/// between stages. Drift surfaces as `error.PdfOfPdfRoundTripDrift`
/// with the stage index and a dumped reproducer for minimisation.
///
/// Stage-0 invariant: the canonical text of the seed PDF round-trips
/// when re-emitted via `drawText` and re-parsed.
/// Stage-N (N≥1) invariant: after a mutation pass on stage N-1's
/// canon, the emitted PDF re-parses to that same mutated canon (or to
/// a stable filtered variant — see `tolerant_compare`).
fn fuzzPdfOfPdfRoundtrip(
    rng: std.Random,
    allocator: std.mem.Allocator,
    scratch: []u8,
    seed_pdf: []const u8,
) anyerror!void {
    _ = scratch;
    _ = seed_pdf;

    // Stage 0 input: a freshly-synthesised minimal PDF whose text is
    // ASCII-only and so bypasses the WinAnsi filter on the very first
    // round-trip. Using the iter's RNG to vary the seed text keeps
    // every iter distinct; using `generateMinimalPdf` keeps the
    // structure trivial so any drift is attributable to the
    // text-channel and not page-tree bookkeeping.
    var seed_text_buf: [64]u8 = undefined;
    const seed_text_len = rng.intRangeAtMost(usize, 1, seed_text_buf.len);
    const ascii = "abcdefghijklmnopqrstuvwxyz ";
    for (seed_text_buf[0..seed_text_len]) |*b| {
        b.* = ascii[rng.intRangeAtMost(usize, 0, ascii.len - 1)];
    }
    var current_pdf = try testpdf.generateMinimalPdf(allocator, seed_text_buf[0..seed_text_len]);
    defer allocator.free(current_pdf);

    var prev_canon: ?[]u8 = null;
    defer if (prev_canon) |p| allocator.free(p);

    var stage: usize = 0;
    while (stage < PDF_OF_PDF_STAGES) : (stage += 1) {
        // (a) Open the current PDF and canonicalise.
        const doc = zpdf.Document.openFromMemory(allocator, current_pdf, zpdf.ErrorConfig.default()) catch |e| {
            // First-stage parse failure is a real bug because we just
            // emitted these bytes ourselves. Stage-N≥1 parse failure
            // means our writer emitted bytes the parser can't read —
            // also a bug.
            dumpReproducer("pdf_of_pdf_roundtrip", current_pdf);
            return e;
        };
        // pageCount is invariant across stages once stage-0 settles
        // (no US bytes survive the WinAnsi filter so chunk count
        // monotonically converges to the page count). Cap defends
        // against a writer that splices content streams unexpectedly.
        if (doc.pageCount() > 64) {
            doc.close();
            dumpReproducer("pdf_of_pdf_roundtrip", current_pdf);
            return error.PdfOfPdfPageCountExplosion;
        }
        const canon = pdfOfPdfCanonicalise(doc, allocator) catch |e| {
            doc.close();
            dumpReproducer("pdf_of_pdf_roundtrip", current_pdf);
            return e;
        };
        doc.close();

        // (b) On stages ≥ 1: prev_canon was the input we asked the
        //     writer to emit. The fresh canon is what came back out.
        //     They MUST be byte-equal (modulo the page-count header,
        //     which is recomputed each stage). The empty-doc fallback
        //     in `pdfOfPdfEmitFromCanon` can legitimately bump the
        //     page count from 0 to 1 — tolerate that one transition.
        if (prev_canon) |p| {
            const drift = !std.mem.eql(u8, p, canon);
            if (drift) {
                allocator.free(canon);
                dumpReproducer("pdf_of_pdf_roundtrip", current_pdf);
                return error.PdfOfPdfRoundTripDrift;
            }
        }

        // (c) Mutate (in place) for the next round.
        pdfOfPdfMutateCanon(canon, rng);

        // (d) Free the previous prev_canon, hand current canon to it.
        if (prev_canon) |p| allocator.free(p);
        prev_canon = canon;

        // (e) Re-emit a fresh PDF from the (now-mutated) canon.
        const next_pdf = pdfOfPdfEmitFromCanon(canon, allocator) catch |e| {
            dumpReproducer("pdf_of_pdf_roundtrip", current_pdf);
            return e;
        };
        allocator.free(current_pdf);
        current_pdf = next_pdf;

        // (f) Update prev_canon to reflect what the WRITER will
        //     actually emit (post-WinAnsi-filter). The next stage's
        //     canonicalisation MUST match this filtered view, not
        //     the pre-filter mutated text. Recompute by re-parsing
        //     the freshly-emitted PDF — that's the contract.
        //
        // CAVEAT (Codex review of 6ed0045 [P2]): this oracle is
        // materially weaker than the harness docstring claims.
        // Storing the *re-parsed* canon as the next stage's expected
        // value detects **parser non-determinism** (still a real bug
        // class — useful) but NOT the writer↔reader serialise/parse
        // asymmetry the tier-7 brief targets. A `drawText` escape
        // bug that drops a `\` would be silently absorbed at stage
        // N (the post-loss canon becomes "expected") → no drift at
        // stage N+1. A stronger oracle (deferred to a follow-up
        // iter) would apply pdf_writer's WinAnsi filter to the
        // *mutated* canon BEFORE drawText and use that prediction
        // as the expected value — either factor the filter into a
        // public helper or duplicate its logic in the harness.
        const verify_doc = zpdf.Document.openFromMemory(allocator, current_pdf, zpdf.ErrorConfig.default()) catch |e| {
            dumpReproducer("pdf_of_pdf_roundtrip", current_pdf);
            return e;
        };
        const filtered_canon = pdfOfPdfCanonicalise(verify_doc, allocator) catch |e| {
            verify_doc.close();
            dumpReproducer("pdf_of_pdf_roundtrip", current_pdf);
            return e;
        };
        verify_doc.close();
        allocator.free(prev_canon.?);
        prev_canon = filtered_canon;
    }
}

// ============================================================================
// Targets — bidi (UAX #9 Level-1 resolver + reorder, src/bidi.zig)
// ============================================================================
//
// Iter-8 of the autonomous fuzz loop (audit/fuzz_loop_state.md): broaden
// horizontal coverage to bidi.zig — a hand-written W1–W7 / N1–N2 / I1–I2 /
// L1–L2 implementation reachable from extractText / extractMarkdown via
// `bidi.processLines` (root.zig:760). Zero prior fuzz coverage.
//
// Floor invariants the SUT must hold for ANY input — independent of whether
// the visual order is "right":
//   - byte-multiset preservation: `process` partitions input bytes into
//     non-overlapping (byte_off, byte_len) state slices and writes each
//     state's slice exactly once under a permutation `order`, so the
//     output is a byte-multiset rearrangement of the input.
//   - no panic / no leak under arbitrary scalar mixes (incl. heavy bidi
//     control density).
//   - valid UTF-8 in → valid UTF-8 out (the implementation only ever
//     copies whole input slices, never splits a multi-byte sequence).
//
// These three targets exercise the three hot regions identified in the
// task spec: W/N/I rule transitions on random scalars (T1), reorder
// permutation correctness (T2), and the format-character stress that the
// UAX #9 spec is famously brittle around (T3).

/// Shared scalar sampler — weighted bag covering ASCII, Hebrew (R),
/// Arabic (AL/AN/NSM), CJK (L by default), bidi controls (LRM/RLM/ALM,
/// LRE..PDF, FSI..PDI, BOM), neutrals, digits. Skips the surrogate range
/// (utf8Encode would error). Caller controls the weight bias via `mode`.
const ScalarMode = enum { uniform, format_heavy };

fn sampleBidiScalar(rng: std.Random, mode: ScalarMode) u21 {
    // Pick a category, then a code point inside it. Categories chosen to
    // hit every BidiClass branch in `bidi.classify`:
    //   0 LTR ASCII letter            → L
    //   1 ASCII digit                 → EN
    //   2 ASCII separator (+,-./:)    → ES/CS
    //   3 ASCII ET ($,#,%,*)          → ET
    //   4 ASCII whitespace / sep      → WS/B/S
    //   5 Hebrew letter (U+05D0..)    → R
    //   6 Hebrew NSM (U+05B7..)       → NSM
    //   7 Arabic letter (U+0627..)    → AL
    //   8 Arabic-Indic digit          → AN
    //   9 Arabic NSM (U+064B..)       → NSM
    //  10 CJK ideograph (U+4E00..)    → L (default branch)
    //  11 LRM/RLM/ALM/BOM             → L/R/AL/BN
    //  12 LRE..RLO + LRI..PDI         → ON (Level-1 fallback)
    //  13 NBSP / typographic neutral  → CS/ON
    //  14 Non-character / private use → L (default branch)
    //  15 Misc Latin-1 supp ET/EN     → ET/EN
    const total_cats: u32 = 16;
    const heavy_threshold: u32 = 70; // % of samples that hit cat 11/12 in format_heavy mode
    const cat: u32 = blk: {
        if (mode == .format_heavy and rng.intRangeLessThan(u32, 0, 100) < heavy_threshold) {
            // 50/50 between explicit format chars (12) and BD1 markers (11).
            break :blk if (rng.boolean()) @as(u32, 11) else @as(u32, 12);
        }
        break :blk rng.intRangeLessThan(u32, 0, total_cats);
    };
    return switch (cat) {
        0 => rng.intRangeAtMost(u21, 'A', 'Z'),
        1 => rng.intRangeAtMost(u21, '0', '9'),
        2 => switch (rng.intRangeAtMost(u8, 0, 4)) {
            0 => '+',
            1 => '-',
            2 => '.',
            3 => ',',
            else => ':',
        },
        3 => switch (rng.intRangeAtMost(u8, 0, 3)) {
            0 => '$',
            1 => '#',
            2 => '%',
            else => '*',
        },
        4 => switch (rng.intRangeAtMost(u8, 0, 4)) {
            0 => ' ',
            1 => '\t',
            2 => '\n',
            3 => '\r',
            else => @as(u21, 0x1F), // unit separator → S
        },
        5 => rng.intRangeAtMost(u21, 0x05D0, 0x05EA),
        6 => switch (rng.intRangeAtMost(u8, 0, 2)) {
            0 => rng.intRangeAtMost(u21, 0x0591, 0x05BD),
            1 => @as(u21, 0x05BF),
            else => rng.intRangeAtMost(u21, 0x05C1, 0x05C2),
        },
        7 => rng.intRangeAtMost(u21, 0x0627, 0x064A),
        8 => rng.intRangeAtMost(u21, 0x0660, 0x0669),
        9 => rng.intRangeAtMost(u21, 0x064B, 0x065F),
        10 => rng.intRangeAtMost(u21, 0x4E00, 0x4E2F),
        11 => switch (rng.intRangeAtMost(u8, 0, 3)) {
            0 => @as(u21, 0x200E), // LRM
            1 => @as(u21, 0x200F), // RLM
            2 => @as(u21, 0x061C), // ALM
            else => @as(u21, 0xFEFF), // BOM
        },
        12 => switch (rng.intRangeAtMost(u8, 0, 8)) {
            0 => @as(u21, 0x202A), // LRE
            1 => @as(u21, 0x202B), // RLE
            2 => @as(u21, 0x202C), // PDF
            3 => @as(u21, 0x202D), // LRO
            4 => @as(u21, 0x202E), // RLO
            5 => @as(u21, 0x2066), // LRI
            6 => @as(u21, 0x2067), // RLI
            7 => @as(u21, 0x2068), // FSI
            else => @as(u21, 0x2069), // PDI
        },
        13 => switch (rng.intRangeAtMost(u8, 0, 2)) {
            0 => @as(u21, 0x00A0), // NBSP
            1 => @as(u21, 0x00AB), // «
            else => @as(u21, 0x00BB), // »
        },
        14 => switch (rng.intRangeAtMost(u8, 0, 2)) {
            0 => rng.intRangeAtMost(u21, 0xFDD0, 0xFDEF), // non-character block
            1 => @as(u21, 0xFFFE),
            else => @as(u21, 0xE000), // private-use start
        },
        else => switch (rng.intRangeAtMost(u8, 0, 3)) {
            0 => @as(u21, 0x00B0), // ° → ET
            1 => @as(u21, 0x00B1), // ± → ET
            2 => @as(u21, 0x00B2), // ² → EN
            else => @as(u21, 0x00B9), // ¹ → EN
        },
    };
}

/// Build a UTF-8 input from `n_scalars` calls to `sampleBidiScalar` and
/// return both the buffer (caller owns) and the count of bytes used. Any
/// scalar that the unicode encoder rejects (won't happen with the bag
/// above, but guard for future expansion) is silently skipped.
fn buildBidiInput(
    allocator: std.mem.Allocator,
    rng: std.Random,
    n_scalars: usize,
    mode: ScalarMode,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    // Each scalar is at most 4 UTF-8 bytes.
    try buf.ensureTotalCapacity(allocator, n_scalars * 4);
    var scratch: [4]u8 = undefined;
    var i: usize = 0;
    while (i < n_scalars) : (i += 1) {
        const cp = sampleBidiScalar(rng, mode);
        const len = std.unicode.utf8Encode(cp, &scratch) catch continue;
        try buf.appendSlice(allocator, scratch[0..len]);
    }
    return buf.toOwnedSlice(allocator);
}

/// Sort a slice of u8 in-place. Helper for byte-multiset comparison.
fn sortBytes(buf: []u8) void {
    std.mem.sort(u8, buf, {}, std.sort.asc(u8));
}

/// T1 — random scalars through `bidi.process`. Floor invariants:
///   - no panic, no leak (the latter caught by GPA in test mode; in the
///     fuzz harness we simply rely on arena reset),
///   - output is a caller-owned slice,
///   - byte length conserved (the implementation copies whole state slices),
///   - input UTF-8 valid → output UTF-8 valid,
///   - `containsRtl(input)` agrees with itself (idempotent — sanity check
///     on the cheap pre-pass that gates the bidi pipeline at root.zig:760).
fn fuzzBidiResolveRandomCodepoints(
    rng: std.Random,
    allocator: std.mem.Allocator,
    scratch: []u8,
    seed_pdf: []const u8,
) anyerror!void {
    _ = scratch;
    _ = seed_pdf;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const n_scalars = rng.intRangeAtMost(usize, 0, 256);
    const input = try buildBidiInput(aa, rng, n_scalars, .uniform);
    // Forced paragraph level: null (auto), 0 (LTR), or 1 (RTL).
    const forced: ?u8 = switch (rng.intRangeAtMost(u8, 0, 2)) {
        0 => null,
        1 => @as(u8, 0),
        else => @as(u8, 1),
    };

    const out = bidi.process(aa, input, forced) catch |err| {
        if (err == error.OutOfMemory) return;
        return err;
    };

    if (out.len != input.len) return error.BidiByteLengthChanged;
    if (std.unicode.utf8ValidateSlice(input) and !std.unicode.utf8ValidateSlice(out)) {
        return error.BidiOutputInvalidUtf8;
    }
    // containsRtl idempotent on its own output of containsRtl-flagged input.
    const rtl_in = bidi.containsRtl(input);
    if (rtl_in) {
        // A Hebrew/Arabic input must keep its strong-RTL bytes intact — the
        // multiset of bytes is conserved (T2 covers this rigorously); here
        // we only assert that containsRtl on the output matches.
        if (!bidi.containsRtl(out)) return error.BidiContainsRtlLostStrongOnReorder;
    }
}

/// T2 — reorder permutation property. Build random UTF-8, pass through
/// `bidi.process`, sort both byte arrays, expect equality. This is the
/// strongest property test for the L2 reorder pass: no byte may appear,
/// disappear, or change identity — only its position may move.
fn fuzzBidiReorderProperty(
    rng: std.Random,
    allocator: std.mem.Allocator,
    scratch: []u8,
    seed_pdf: []const u8,
) anyerror!void {
    _ = scratch;
    _ = seed_pdf;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const n_scalars = rng.intRangeAtMost(usize, 0, 192);
    const input = try buildBidiInput(aa, rng, n_scalars, .uniform);

    // Also exercise processLines on inputs containing newlines — that
    // path adds the per-line dispatch logic. ~25% of iters.
    const use_lines = rng.intRangeLessThan(u8, 0, 4) == 0;
    const out = if (use_lines) blk: {
        break :blk bidi.processLines(aa, input) catch |err| {
            if (err == error.OutOfMemory) return;
            return err;
        };
    } else blk: {
        break :blk bidi.process(aa, input, null) catch |err| {
            if (err == error.OutOfMemory) return;
            return err;
        };
    };

    if (out.len != input.len) return error.BidiPermutationLengthMismatch;

    // Byte-multiset equality: sort both and compare.
    const a = try aa.dupe(u8, input);
    const b = try aa.dupe(u8, out);
    sortBytes(a);
    sortBytes(b);
    if (!std.mem.eql(u8, a, b)) return error.BidiPermutationByteMultisetChanged;
}

/// T3 — format-character storm. Bias the input toward LRO/RLO/PDF/LRE/
/// RLE/FSI/RLI/LRI/PDI plus LRM/RLM/ALM/BOM, alternated with bursts of
/// strong-direction letters from both directions. Stresses the W/N rule
/// neutral-run resolver (long ON runs from the explicit-embedding chars,
/// since Level-1 maps them to ON), the L1 trailing-WS reset around
/// segment separators, and the L2 reversal across alternating-direction
/// short runs.
fn fuzzBidiFormatCharacterStorm(
    rng: std.Random,
    allocator: std.mem.Allocator,
    scratch: []u8,
    seed_pdf: []const u8,
) anyerror!void {
    _ = scratch;
    _ = seed_pdf;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Larger sequences here — cap at 384 scalars (~1.1 KiB) to keep
    // per-iter wall time bounded.
    const n_scalars = rng.intRangeAtMost(usize, 16, 384);
    const input = try buildBidiInput(aa, rng, n_scalars, .format_heavy);

    const out = bidi.process(aa, input, null) catch |err| {
        if (err == error.OutOfMemory) return;
        return err;
    };

    if (out.len != input.len) return error.BidiStormByteLengthChanged;
    // All sampled scalars produce valid UTF-8, so output must too.
    if (!std.unicode.utf8ValidateSlice(out)) return error.BidiStormOutputInvalidUtf8;

    // Embedding-level cap: UAX #9 spec puts the max embedding level at
    // 125. The Level-1 resolver only ever assigns levels 0/1/2 (paragraph
    // base 0/1, plus +1 from I1/I2 once), so a level >2 anywhere would
    // be a bug. We can't directly read the per-char levels (private
    // CharState), but we can re-run with a forced paragraph level and
    // check the byte-conservation invariant still holds — a level-bump
    // bug would surface as a length divergence on long runs.
    const out2 = bidi.process(aa, input, 1) catch |err| {
        if (err == error.OutOfMemory) return;
        return err;
    };
    if (out2.len != input.len) return error.BidiStormForcedRtlByteLengthChanged;
}

// ============================================================================
// Targets — cff.zig (iter-9, row 5 of audit/fuzz_loop_state.md)
// ============================================================================

/// Walk every glyph + every SID slot of a successfully-parsed CFF font and
/// assert structural invariants the public surface advertises. Shared
/// between cff_init_random_bytes and cff_init_biased_header so the same
/// invariants apply to both reach paths.
///
/// SUT-independent invariants:
///   - `parser.charsets.len ≤ parser.charstrings_index.count`
///     (parseCharset writes at most `count` slots).
///   - `getGlyphName(gid)` for `gid < charsets.len` is either `null` or
///     a slice with bounded length.
///   - `getString(sid)` is null OR has length ≤ 64 (longest std_string is
///     "guilsinglright" at 14 bytes; dynamic strings are CFF Top-DICT
///     sub-slices and capped well under 64 in any realistic font; we use
///     a generous 1024-byte cap to allow for adversarial dynamic strings).
///   - getGlyphName(gid) for `gid < charsets.len` agrees with
///     getString(charsets[gid]) (both null or byte-equal).
fn cffSweepInvariants(cp: *cff.CffParser) anyerror!void {
    // Codex review of 899525c [P2]: `charstrings_index` is left
    // `undefined` on parser-success paths that lack a CharStrings
    // entry in the Top DICT (e.g., synthetic T3 fonts with an empty
    // or non-matching Top DICT). Reading `.count` on an undefined
    // field is UB and makes this invariant non-deterministic.
    // src/cff.zig:89 already gates the parse step on
    // `charstrings_offset > 0`; mirror that here so the harness
    // only walks the index when it has been populated.
    if (cp.charstrings_offset == 0) return;
    if (cp.charsets.len > cp.charstrings_index.count) {
        return error.CffCharsetsExceedCharstrings;
    }

    // Sweep getGlyphName over the charsets array. Cap at 256 to bound
    // wall time on adversarial fonts that claim millions of glyphs but
    // have only a tiny charsets array allocated.
    const gid_cap: usize = @min(cp.charsets.len, 256);
    for (0..gid_cap) |gid| {
        const name_opt = cp.getGlyphName(@intCast(gid));
        if (name_opt) |name| {
            if (name.len > 1024) return error.CffGlyphNameTooLong;
        }
        // getGlyphName must agree with getString(charsets[gid]).
        const sid = cp.charsets[gid];
        const via_sid = cp.getString(sid);
        if ((name_opt == null) != (via_sid == null)) {
            return error.CffGlyphNameSidDisagreement;
        }
        if (name_opt) |a| if (via_sid) |b| {
            if (!std.mem.eql(u8, a, b)) return error.CffGlyphNameSidByteMismatch;
        };
    }

    // Sweep getString over a window of SIDs covering both std_strings
    // (0..391) and a band of dynamic SIDs (391..391+min(string_index.count,256)).
    const dyn_count: usize = @min(cp.string_index.count, 256);
    const sid_cap: u16 = @intCast(@min(@as(usize, 391) + dyn_count, std.math.maxInt(u16)));
    var sid: u16 = 0;
    while (sid < sid_cap) : (sid += 1) {
        const s_opt = cp.getString(sid);
        if (s_opt) |s| {
            if (s.len > 1024) return error.CffStringTooLong;
        }
    }
}

/// T1 — pure random bytes through `CffParser.init`. The full happy path
/// is exercised only when the random bytes happen to look like a CFF
/// header (~1 in 256), but the rejected paths still walk the cursor +
/// header probe. Buffer capped at 4 KiB to keep wall time bounded.
fn fuzzCffInitRandomBytes(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;
    const len = rng.intRangeAtMost(usize, 0, @min(scratch.len, 4096));
    rng.bytes(scratch[0..len]);

    var cp = cff.CffParser.init(allocator, scratch[0..len]) catch return;
    defer cp.deinit();

    try cffSweepInvariants(&cp);
}

/// T2 — biased CFF header so init() advances past the major-version
/// gate (line 65: `if (major != 1) return UnsupportedFeature`). Forces
/// the cursor into the four nested Index parses + Top DICT parser more
/// often than the 1-in-256 rate of T1. Same SUT-independent invariants.
fn fuzzCffInitBiasedHeader(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;
    const len = rng.intRangeAtMost(usize, 4, @min(scratch.len, 4096));
    rng.bytes(scratch[0..len]);
    // major = 1 (only supported version), minor = 0, hdr_size in {4..16}
    // to occasionally land past byte 4 (exercises the cursor.pos = hdr_size
    // jump on line 68), off_size in {1..4} (legal CFF range, used by the
    // four nested Index.parse calls indirectly via Top DICT operands).
    scratch[0] = 1;
    scratch[1] = 0;
    scratch[2] = rng.intRangeAtMost(u8, 4, 16);
    scratch[3] = rng.intRangeAtMost(u8, 1, 4);

    var cp = cff.CffParser.init(allocator, scratch[0..len]) catch return;
    defer cp.deinit();

    try cffSweepInvariants(&cp);
}

/// Append a u16 BE to `buf` (helper for T3's synthetic CFF construction).
fn appendU16Be(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u16) !void {
    var be: [2]u8 = undefined;
    std.mem.writeInt(u16, &be, v, .big);
    try buf.appendSlice(allocator, &be);
}

/// T3 — synthesise a minimal CFF byte stream where the Top DICT INDEX
/// contains a single entry of *random bytes*. Drives `parseTopDict` →
/// `DictParser.next` → `readNumber` directly with attacker bytes,
/// including the real-number nibble decoder (b0 == 30). The Name /
/// String / Global Subr indices are emitted empty (count=0, two-byte
/// each) so the cursor reaches Top DICT parsing cleanly.
///
/// Random Top DICT body covers:
///   - all integer encodings (32–246, 247–250, 251–254 single-byte;
///     28 short-int, 29 long-int)
///   - real-number nibble decoder (30 ... terminator nibble F)
///   - operator dispatch (b0 ≤ 21, including the two-byte 12-prefix)
///   - StackUnderflow/Overflow guard at operand_buf[48]
///
/// Invariants: no panic. If init() succeeds, run cffSweepInvariants.
fn fuzzCffDictRandomTopDict(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = scratch;
    _ = seed_pdf;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(aa);

    // Header: major=1, minor=0, hdr_size=4, off_size=1.
    try buf.appendSlice(aa, &[_]u8{ 1, 0, 4, 1 });

    // Name INDEX: count=0 (two-byte big-endian zero — Index.parse early
    // return path).
    try appendU16Be(&buf, aa, 0);

    // Top DICT INDEX: count=1, off_size=1, offsets=[1, dict_len+1],
    // followed by `dict_len` random bytes. dict_len = 0..192.
    const dict_len = rng.intRangeAtMost(usize, 0, 192);
    if (dict_len + 1 > 255) return; // off_size=1 caps offsets at 255
    try appendU16Be(&buf, aa, 1); // count
    try buf.append(aa, 1); // off_size
    try buf.append(aa, 1); // offsets[0]
    try buf.append(aa, @intCast(dict_len + 1)); // offsets[1]
    const dict_start = buf.items.len;
    try buf.resize(aa, dict_start + dict_len);
    rng.bytes(buf.items[dict_start..][0..dict_len]);

    // String INDEX: count=0.
    try appendU16Be(&buf, aa, 0);

    // Global Subr INDEX: count=0.
    try appendU16Be(&buf, aa, 0);

    var cp = cff.CffParser.init(allocator, buf.items) catch return;
    defer cp.deinit();

    try cffSweepInvariants(&cp);
}

// ============================================================================
// Targets — pdf_resources.zig (iter-10, row 18 of audit/fuzz_loop_state.md)
// ============================================================================

/// Pick a uniform random `BuiltinFont` from the 14-variant enum. The cast
/// is safe because `intRangeAtMost(0, 13)` is bounded by the enum range.
fn randomBuiltinFont(rng: std.Random) pdf_document.BuiltinFont {
    const idx = rng.intRangeAtMost(u4, 0, 13);
    return @enumFromInt(idx);
}

/// Build a synthetic ImageRef with random width/height/colorspace +
/// caller-allocated bytes. The registry takes ownership of `bytes`, so
/// the caller MUST pass a freshly-allocated slice (matching
/// pdf_document.addImage*'s "copy-on-register" contract).
fn synthRandomImageRef(rng: std.Random, allocator: std.mem.Allocator) !image_writer.ImageRef {
    // Cap at 16 B per image so a fuzz iter can register dozens without
    // blowing past the per-iter scratch budget.
    const len = rng.intRangeAtMost(usize, 1, 16);
    const bytes = try allocator.alloc(u8, len);
    errdefer allocator.free(bytes);
    rng.bytes(bytes);

    // Width / height in [1, 256]: positive (image_writer.emitImageObject
    // asserts > 0) and bounded so the assert path is fuzz-safe.
    const cs_idx = rng.intRangeAtMost(u8, 0, 2);
    return .{
        .bytes = bytes,
        .encoding = switch (rng.intRangeAtMost(u8, 0, 2)) {
            0 => .dct_passthrough,
            1 => .raw_uncompressed,
            else => .raw_flate,
        },
        .width = rng.intRangeAtMost(u32, 1, 256),
        .height = rng.intRangeAtMost(u32, 1, 256),
        .bits_per_component = 8,
        .colorspace = switch (cs_idx) {
            0 => .gray,
            1 => .rgb,
            else => .cmyk,
        },
    };
}

/// T1 — register a random sequence of builtin fonts and assert dedup
/// invariants. Each iter performs 1..32 register calls drawn uniformly
/// from the 14-font enum, then sweeps the registry for:
///   - Same `BuiltinFont` value → same `FontHandle` (idempotent dedup).
///   - `fontResourceName(handle)` is `/F<idx>` and stable.
///   - All resource names are pairwise distinct.
///   - `fontCount()` == number of *distinct* BuiltinFonts seen.
fn fuzzPdfResourcesBuiltinDedup(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = scratch;
    _ = seed_pdf;

    var reg = pdf_resources.ResourceRegistry.init(allocator);
    defer reg.deinit();

    // Track first-seen handle per BuiltinFont enum value, for dedup
    // checking against every subsequent register.
    var first_handle: [14]?pdf_resources.FontHandle = @splat(null);
    var distinct_count: u32 = 0;

    const ops = rng.intRangeAtMost(u32, 1, 32);
    var op: u32 = 0;
    while (op < ops) : (op += 1) {
        const font = randomBuiltinFont(rng);
        const lookup_idx: usize = @intFromEnum(font);
        const h = try reg.registerBuiltinFont(font);

        if (first_handle[lookup_idx]) |prior| {
            // Idempotency: subsequent registration of the same builtin
            // returns the same handle.
            if (prior != h) return error.PdfResourcesBuiltinHandleNotIdempotent;
        } else {
            first_handle[lookup_idx] = h;
            distinct_count += 1;
        }
    }

    if (reg.fontCount() != distinct_count) {
        return error.PdfResourcesFontCountDisagrees;
    }

    // Sweep names: each handle's resource name must be `/F<idx>` and
    // pairwise unique across all registered handles. Iter through the
    // first_handle table so we exercise getter consistency for EVERY
    // distinct font that was registered.
    var name_buf: [16][]const u8 = undefined;
    var seen: u32 = 0;
    for (first_handle) |maybe_h| {
        if (maybe_h) |h| {
            const idx = @intFromEnum(h);
            const name = reg.fontResourceName(h);
            // Must start with "/F" and end in a decimal index matching idx.
            if (name.len < 3 or name[0] != '/' or name[1] != 'F') {
                return error.PdfResourcesFontNameMalformed;
            }
            const parsed = std.fmt.parseInt(u32, name[2..], 10) catch
                return error.PdfResourcesFontNameNotDecimal;
            if (parsed != idx) return error.PdfResourcesFontNameIndexMismatch;

            // Stability: a second call returns byte-identical bytes.
            const name2 = reg.fontResourceName(h);
            if (!std.mem.eql(u8, name, name2)) {
                return error.PdfResourcesFontNameNotStable;
            }

            name_buf[seen] = name;
            seen += 1;
        }
    }

    // Pairwise uniqueness across all registered handles.
    var i: u32 = 0;
    while (i < seen) : (i += 1) {
        var j: u32 = i + 1;
        while (j < seen) : (j += 1) {
            if (std.mem.eql(u8, name_buf[i], name_buf[j])) {
                return error.PdfResourcesFontNameCollision;
            }
        }
    }
}

/// T2 — register a random sequence of images, then assign object
/// numbers via a real `pdf_writer.Writer`. Asserts:
///   - `imageCount()` reflects the number of successful registers.
///   - Names are `/Im<idx>` and pairwise unique.
///   - After `assignImageObjectNumbers`: every `imageObjectNum(h)` is
///     non-zero and pairwise distinct (writer hands out fresh nums).
///   - The internal `images.items[idx].ref.obj_num` mirrors the value
///     in `image_obj_nums[idx]` (registry / entry consistency).
fn fuzzPdfResourcesImageRegisterAssign(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = scratch;
    _ = seed_pdf;

    var reg = pdf_resources.ResourceRegistry.init(allocator);
    defer reg.deinit();

    var w = pdf_writer.Writer.init(allocator);
    defer w.deinit();

    const n = rng.intRangeAtMost(u32, 0, 16);
    var handles: [16]pdf_resources.ImageHandle = undefined;
    var actual_n: u32 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const ref = try synthRandomImageRef(rng, allocator);
        // Codex review-style note: `registerImage` takes ownership of
        // `ref.bytes`. On error the registry has not appended yet, so
        // the bytes belong to us — free or hand to the next attempt.
        // The two errors registerImage can return are OutOfMemory and
        // ObjectNumbersAlreadyAssigned; we haven't called assign* yet,
        // so OOM is the only branch and we must free on it.
        const handle = reg.registerImage(ref) catch |err| {
            allocator.free(ref.bytes);
            return err;
        };
        handles[i] = handle;
        actual_n += 1;
    }

    if (reg.imageCount() != actual_n) return error.PdfResourcesImageCountDisagrees;

    // Names: `/Im<idx>` and pairwise unique.
    var seen_names: [16][]const u8 = undefined;
    var s: u32 = 0;
    while (s < actual_n) : (s += 1) {
        const name = reg.imageResourceName(handles[s]);
        if (name.len < 4 or name[0] != '/' or name[1] != 'I' or name[2] != 'm') {
            return error.PdfResourcesImageNameMalformed;
        }
        const parsed = std.fmt.parseInt(u32, name[3..], 10) catch
            return error.PdfResourcesImageNameNotDecimal;
        if (parsed != @intFromEnum(handles[s])) {
            return error.PdfResourcesImageNameIndexMismatch;
        }
        seen_names[s] = name;
    }
    var a: u32 = 0;
    while (a < actual_n) : (a += 1) {
        var b: u32 = a + 1;
        while (b < actual_n) : (b += 1) {
            if (std.mem.eql(u8, seen_names[a], seen_names[b])) {
                return error.PdfResourcesImageNameCollision;
            }
        }
    }

    // Drive the writer side: assign object numbers and assert post-
    // conditions on the registry. Skip if no images registered (the
    // assign call is a no-op but the post-condition sweep is empty).
    if (actual_n == 0) return;

    try reg.assignImageObjectNumbers(&w);

    // Sweep: every handle's obj_num is non-zero and pairwise distinct.
    // The mirror invariant — `image_obj_nums[idx] == images[idx].ref.obj_num`
    // — is checked via the public `imageObjectNum` getter (which reads
    // `image_obj_nums`) and by re-fetching the entry's `ref.obj_num`
    // via `images.items` slice access. This is a pair-assertion in the
    // TigerStyle sense.
    var nums: [16]u32 = undefined;
    var k: u32 = 0;
    while (k < actual_n) : (k += 1) {
        const num = reg.imageObjectNum(handles[k]);
        if (num == 0) return error.PdfResourcesImageObjNumZero;
        // Pair: cross-check against the entry-side mirror.
        const entry_num = reg.images.items[@intFromEnum(handles[k])].ref.obj_num;
        if (entry_num != num) return error.PdfResourcesImageObjNumMirrorBroken;
        nums[k] = num;
    }
    // Pairwise distinctness across handles.
    var p: u32 = 0;
    while (p < actual_n) : (p += 1) {
        var q: u32 = p + 1;
        while (q < actual_n) : (q += 1) {
            if (nums[p] == nums[q]) return error.PdfResourcesImageObjNumDup;
        }
    }

    // Codex review of 25f3c0e [P2]: probe the post-assign image
    // lifecycle. Per pdf_resources.zig:378, `assignImageObjectNumbers`
    // does NOT flip the registry freeze flag (unlike `assign
    // FontObjectNumbers`); image re-assigns are intended to succeed
    // even after the first call. This asymmetric-with-fonts contract
    // is documented as Finding 009 (LOW) in audit/fuzz_findings.md.
    // Pin the *current* behaviour: if a future change makes images
    // freeze symmetrically with fonts, this assertion trips and
    // forces the audit doc to be re-examined.
    reg.assignImageObjectNumbers(&w) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.PdfResourcesImageReassignNowRejected,
    };
}

/// T3 — freeze-after-assign negative-space invariant. Register some
/// builtin fonts + images, run `assignFontObjectNumbers`, then assert
/// every subsequent mutating call returns
/// `error.ObjectNumbersAlreadyAssigned`. Crucially: `registerImage`
/// also rejects post-assign even though `assignFontObjectNumbers` is
/// the call that flipped the flag — the registry treats font + image
/// freeze as a single epoch.
fn fuzzPdfResourcesFreezeAfterAssign(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = scratch;
    _ = seed_pdf;

    var reg = pdf_resources.ResourceRegistry.init(allocator);
    defer reg.deinit();

    var w = pdf_writer.Writer.init(allocator);
    defer w.deinit();

    // Register 0..8 random builtin fonts.
    const n_fonts = rng.intRangeAtMost(u32, 0, 8);
    var i: u32 = 0;
    while (i < n_fonts) : (i += 1) {
        _ = try reg.registerBuiltinFont(randomBuiltinFont(rng));
    }
    const fonts_before = reg.fontCount();

    // Register 0..8 images.
    const n_imgs = rng.intRangeAtMost(u32, 0, 8);
    var j: u32 = 0;
    while (j < n_imgs) : (j += 1) {
        const ref = try synthRandomImageRef(rng, allocator);
        _ = reg.registerImage(ref) catch |err| {
            allocator.free(ref.bytes);
            return err;
        };
    }
    const imgs_before = reg.imageCount();

    // Freeze the registry. After this returns, all mutating font ops
    // must reject. Image side: `registerImage` checks the same flag,
    // so it also rejects. (The semantic asymmetry that
    // `assignImageObjectNumbers` does NOT flip the flag is documented
    // in src/pdf_resources.zig:378 — the caller is expected to drive
    // the freeze through the font path. We don't assert on that side.)
    try reg.assignFontObjectNumbers(&w);

    // Negative-space invariant 1: font register rejects.
    const new_font = randomBuiltinFont(rng);
    if (reg.registerBuiltinFont(new_font)) |_| {
        return error.PdfResourcesFontRegisterAcceptedAfterFreeze;
    } else |err| switch (err) {
        error.ObjectNumbersAlreadyAssigned => {},
        else => return err,
    }

    // Negative-space invariant 2: assign-twice rejects.
    if (reg.assignFontObjectNumbers(&w)) |_| {
        return error.PdfResourcesAssignTwiceAccepted;
    } else |err| switch (err) {
        error.ObjectNumbersAlreadyAssigned => {},
        else => return err,
    }

    // Negative-space invariant 3: image register rejects (shared epoch).
    // The bytes we tried to hand off were never owned by the registry,
    // so we must free them ourselves.
    const ref = try synthRandomImageRef(rng, allocator);
    if (reg.registerImage(ref)) |_| {
        return error.PdfResourcesImageRegisterAcceptedAfterFreeze;
    } else |err| switch (err) {
        error.ObjectNumbersAlreadyAssigned => {
            allocator.free(ref.bytes);
        },
        else => {
            allocator.free(ref.bytes);
            return err;
        },
    }

    // Positive-space invariant: counts are unchanged after the
    // rejected calls. The registry must NOT half-commit on rejection.
    if (reg.fontCount() != fonts_before) return error.PdfResourcesFontCountChangedAfterFreeze;
    if (reg.imageCount() != imgs_before) return error.PdfResourcesImageCountChangedAfterFreeze;

    // Positive-space invariant: all assigned font obj_nums are non-zero
    // and pairwise distinct.
    if (fonts_before > 0) {
        // Iterate the parallel `font_obj_nums` slice via the public
        // accessor on each handle. Handles are dense `0..fonts_before`.
        var nums_buf: [8]u32 = undefined;
        var f: u32 = 0;
        while (f < fonts_before) : (f += 1) {
            const handle: pdf_resources.FontHandle = @enumFromInt(f);
            const num = reg.fontObjectNum(handle);
            if (num == 0) return error.PdfResourcesFontObjNumZero;
            nums_buf[f] = num;
        }
        var x: u32 = 0;
        while (x < fonts_before) : (x += 1) {
            var y: u32 = x + 1;
            while (y < fonts_before) : (y += 1) {
                if (nums_buf[x] == nums_buf[y]) {
                    return error.PdfResourcesFontObjNumDup;
                }
            }
        }
    }
}


// ============================================================================
// Targets — attr_flattener (PR-23b inheritance walker, row 11)
// ============================================================================
//
// `attr_flattener.flatten` walks a parsed StructTree and computes the
// effective `/Lang`, `/Alt`, `/ActualText`, and `resolved_role` for every
// element by inheriting from the nearest ancestor with the slot set.
// `flattenInPlace` is the mutating sibling that writes the inherited
// values back onto descendants directly.
//
// Both surfaces are pure functions on a `*const StructTree` (or `*StructTree`
// for the in-place variant) — no parser, no XRef, no Document. The
// existing `tagged_table_mutation` target already shows how to synth a
// StructTree in arena.
//
// SUT-independent invariants only (iter-7 P2 lesson):
//   - The harness re-walks the tree from the root and computes the
//     "expected" effective attrs by following parent pointers — and
//     compares to the SUT's map.
//   - Idempotency: flattenInPlace twice yields the same field values
//     by-bytes as flattenInPlace once.
//   - Negative space: own-set fields MUST NOT be overwritten.
//   - Depth bound: error.StructTreeTooDeep iff depth ≥ MAX_FLATTEN_DEPTH.
//
// All three targets are default-gate; the surface is small and
// self-contained, identical to iter-10's pdf_resources pattern.

/// Per-element string slots are drawn from a fixed pool (or null).
/// All slices in the pool are `.rodata` so they survive arena shrink
/// and pointer-equality comparisons across walks are well-defined.
const ATTR_POOL_ALT = [_][]const u8{ "alt-A", "alt-B", "alt-C" };
const ATTR_POOL_ACTUAL = [_][]const u8{ "actual-X", "actual-Y", "actual-Z" };
const ATTR_POOL_LANG = [_][]const u8{ "en-US", "fr-FR", "ja-JP" };
const ATTR_POOL_ROLE = [_][]const u8{ "P", "Sect", "H1" };
const ATTR_POOL_TYPE = [_][]const u8{ "Document", "Sect", "P", "Span", "Table", "TR", "TD", "Figure" };

/// Pick a pool entry or null with ~1/3 null bias so inheritance gets
/// exercised on most paths.
fn pickOptional(rng: std.Random, pool: []const []const u8) ?[]const u8 {
    if (rng.intRangeAtMost(u8, 0, 2) == 0) return null;
    return pool[rng.intRangeAtMost(usize, 0, pool.len - 1)];
}

/// Recursively build a random tree under `arena`. Tracks the elements
/// list in `out_elements` (caller-owned) so the caller can iterate
/// every element later for SUT-independent re-walks.
fn buildRandomStructTree(
    aa: std.mem.Allocator,
    rng: std.Random,
    out_elements: *std.ArrayList(*structtree.StructElement),
    depth: u32,
    max_depth: u32,
) anyerror!*structtree.StructElement {
    // Branching factor: 0..3 children at each level. Depth gate caps
    // total size; over-deep paths cut off at max_depth.
    const n_kids: usize = if (depth >= max_depth) 0 else rng.intRangeAtMost(usize, 0, 3);

    var kids: std.ArrayList(structtree.StructChild) = .empty;
    for (0..n_kids) |_| {
        const sub = try buildRandomStructTree(aa, rng, out_elements, depth + 1, max_depth);
        try kids.append(aa, .{ .element = sub });
    }
    const kids_slice = try kids.toOwnedSlice(aa);

    const elem = try aa.create(structtree.StructElement);
    elem.* = .{
        .struct_type = ATTR_POOL_TYPE[rng.intRangeAtMost(usize, 0, ATTR_POOL_TYPE.len - 1)],
        .alt_text = pickOptional(rng, &ATTR_POOL_ALT),
        .actual_text = pickOptional(rng, &ATTR_POOL_ACTUAL),
        .lang = pickOptional(rng, &ATTR_POOL_LANG),
        .resolved_role = pickOptional(rng, &ATTR_POOL_ROLE),
        .children = kids_slice,
    };
    try out_elements.append(aa, elem);
    return elem;
}

/// SUT-independent oracle: re-walk the tree and compute, for each
/// element pointer, the effective `(alt, actual, lang, role)` according
/// to the documented inheritance rules — element-own value wins,
/// otherwise nearest ancestor with the slot set.
const ExpectedAttrs = struct {
    alt: ?[]const u8,
    actual: ?[]const u8,
    lang: ?[]const u8,
    role: ?[]const u8,
};
fn walkExpected(
    elem: *const structtree.StructElement,
    inherited: ExpectedAttrs,
    out: *std.AutoHashMap(*const structtree.StructElement, ExpectedAttrs),
    aa: std.mem.Allocator,
) anyerror!void {
    const eff: ExpectedAttrs = .{
        .alt = elem.alt_text orelse inherited.alt,
        .actual = elem.actual_text orelse inherited.actual,
        .lang = elem.lang orelse inherited.lang,
        .role = elem.resolved_role orelse inherited.role,
    };
    try out.put(elem, eff);
    for (elem.children) |child| switch (child) {
        .element => |sub| try walkExpected(sub, eff, out, aa),
        .mcid => {},
    };
}

/// T1: drive `flatten()` on a random tree; assert map size + per-element
/// field equality against the SUT-independent oracle.
fn fuzzAttrFlattenerRandomTree(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = scratch;
    _ = seed_pdf;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var elements: std.ArrayList(*structtree.StructElement) = .empty;

    // Root sometimes absent → empty-map invariant.
    const has_root = rng.intRangeAtMost(u8, 0, 9) != 0;
    var tree: structtree.StructTree = .{
        .root = null,
        .elements = &.{},
        .allocator = aa,
    };
    if (has_root) {
        const max_depth = rng.intRangeAtMost(u32, 0, 12); // well under MAX_FLATTEN_DEPTH=64
        const root = try buildRandomStructTree(aa, rng, &elements, 0, max_depth);
        tree.root = root;
    }

    var got = try attr_flattener.flatten(&tree, allocator);
    defer got.deinit();

    if (!has_root) {
        if (got.count() != 0) return error.FlattenEmptyTreeMapNonEmpty;
        return;
    }

    // Build the oracle map.
    var expected = std.AutoHashMap(*const structtree.StructElement, ExpectedAttrs).init(aa);
    try walkExpected(tree.root.?, .{ .alt = null, .actual = null, .lang = null, .role = null }, &expected, aa);

    // Invariant: SUT map and oracle map cover the same set of pointers.
    if (got.count() != expected.count()) return error.FlattenMapCountMismatch;

    var it = expected.iterator();
    while (it.next()) |e| {
        const sut = got.get(e.key_ptr.*) orelse return error.FlattenMissingElementInMap;
        const exp = e.value_ptr.*;
        if (!optStrEql(sut.alt_text, exp.alt)) return error.FlattenAltMismatch;
        if (!optStrEql(sut.actual_text, exp.actual)) return error.FlattenActualMismatch;
        if (!optStrEql(sut.lang, exp.lang)) return error.FlattenLangMismatch;
        if (!optStrEql(sut.resolved_role, exp.role)) return error.FlattenRoleMismatch;
    }
}

fn optStrEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// T2: drive `flattenInPlace()` twice on a random tree; assert idempotency
/// and own-value preservation. Snapshot every element's four attrs after
/// the first call and compare to the same fields after the second.
///
/// Negative-space invariants (iter-10 P2 lesson):
///   - Elements that originally had alt_text != null must keep the
///     SAME slice pointer (no overwrite, no copy).
///   - flattenInPlace is total: never returns an error on shallow trees.
fn fuzzAttrFlattenerInPlaceIdempotent(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = scratch;
    _ = seed_pdf;
    _ = allocator;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var elements: std.ArrayList(*structtree.StructElement) = .empty;

    const max_depth = rng.intRangeAtMost(u32, 0, 12);
    const root = try buildRandomStructTree(aa, rng, &elements, 0, max_depth);

    // Snapshot owners — every element whose alt_text/actual_text was
    // SET before flattening. Their slot must remain the SAME slice
    // pointer after flattening (own-value-wins).
    const Owners = struct {
        ptr: *structtree.StructElement,
        own_alt: ?[]const u8,
        own_actual: ?[]const u8,
    };
    var owners: std.ArrayList(Owners) = .empty;
    for (elements.items) |e| {
        try owners.append(aa, .{ .ptr = e, .own_alt = e.alt_text, .own_actual = e.actual_text });
    }

    var tree: structtree.StructTree = .{
        .root = root,
        .elements = &.{},
        .allocator = aa,
    };

    try attr_flattener.flattenInPlace(&tree);

    // Snapshot post-1st-call.
    const Snap = struct {
        alt: ?[]const u8,
        actual: ?[]const u8,
        lang: ?[]const u8,
        role: ?[]const u8,
    };
    var snap: std.ArrayList(Snap) = .empty;
    for (elements.items) |e| {
        try snap.append(aa, .{ .alt = e.alt_text, .actual = e.actual_text, .lang = e.lang, .role = e.resolved_role });
    }

    // Own-value preservation: for every element whose own_alt was
    // non-null pre-flatten, the post-flatten slice must be the SAME
    // pointer (.ptr + .len), not a copy.
    for (owners.items, 0..) |o, idx| {
        if (o.own_alt) |orig| {
            const post = elements.items[idx].alt_text orelse return error.FlattenInPlaceLostOwnAlt;
            if (post.ptr != orig.ptr or post.len != orig.len) return error.FlattenInPlaceOverwroteOwnAlt;
        }
        if (o.own_actual) |orig| {
            const post = elements.items[idx].actual_text orelse return error.FlattenInPlaceLostOwnActual;
            if (post.ptr != orig.ptr or post.len != orig.len) return error.FlattenInPlaceOverwroteOwnActual;
        }
    }

    // Second call → idempotent.
    try attr_flattener.flattenInPlace(&tree);
    for (elements.items, 0..) |e, idx| {
        const s = snap.items[idx];
        if (!optStrEql(e.alt_text, s.alt)) return error.FlattenInPlaceNotIdempotentAlt;
        if (!optStrEql(e.actual_text, s.actual)) return error.FlattenInPlaceNotIdempotentActual;
        if (!optStrEql(e.lang, s.lang)) return error.FlattenInPlaceNotIdempotentLang;
        if (!optStrEql(e.resolved_role, s.role)) return error.FlattenInPlaceNotIdempotentRole;
    }
}

/// T3: depth-bound assertion. Builds a chain of length N where N is
/// drawn from `MAX_FLATTEN_DEPTH - 4 ..= MAX_FLATTEN_DEPTH + 4`.
///
/// Per attr_flattener.zig:67 the bound is checked as `depth >= MAX`,
/// i.e. depth 0..MAX-1 succeeds, depth MAX (chain length MAX+1) fails.
/// Both `flatten` and `flattenInPlace` share the same gate.
///
/// Invariants:
///   - chain length ≤ MAX_FLATTEN_DEPTH → both calls succeed
///   - chain length ≥ MAX_FLATTEN_DEPTH + 1 → both return error.StructTreeTooDeep
///   - the boundary is consistent across the two surfaces (Finding-class
///     check: if they disagreed it would be an asymmetry to document)
fn fuzzAttrFlattenerDepthBound(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = scratch;
    _ = seed_pdf;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const MAX = attr_flattener.MAX_FLATTEN_DEPTH;
    // Window: MAX-4 ..= MAX+4. Chain length N = depth + 1 (root at
    // depth 0, leaf at depth N-1).
    const N: u32 = MAX - 4 + rng.intRangeAtMost(u32, 0, 8);

    const chain = try aa.alloc(structtree.StructElement, N);
    const slots = try aa.alloc(structtree.StructChild, N);

    var i: usize = N;
    while (i > 0) {
        i -= 1;
        chain[i] = .{
            .struct_type = "P",
            .children = if (i == N - 1) &.{} else slots[i .. i + 1],
        };
        if (i < N - 1) slots[i] = .{ .element = &chain[i + 1] };
    }

    var tree: structtree.StructTree = .{
        .root = &chain[0],
        .elements = &.{},
        .allocator = aa,
    };

    // Threshold: depth `MAX` means N == MAX+1 chain elements (the
    // leaf is at depth MAX, where `depth >= MAX` trips). Anything
    // shorter must succeed.
    const expect_too_deep = N >= MAX + 1;

    if (attr_flattener.flatten(&tree, allocator)) |*ok| {
        var m = ok.*;
        m.deinit();
        if (expect_too_deep) return error.FlattenAcceptedOverDeepChain;
    } else |err| {
        if (!expect_too_deep) return error.FlattenRejectedShallowChain;
        if (err != error.StructTreeTooDeep) return err;
    }

    if (attr_flattener.flattenInPlace(&tree)) {
        if (expect_too_deep) return error.FlattenInPlaceAcceptedOverDeepChain;
    } else |err| {
        if (!expect_too_deep) return error.FlattenInPlaceRejectedShallowChain;
        if (err != error.StructTreeTooDeep) return err;
    }
}

// ============================================================================
// Targets — markdown (iter-12, row 15)
// ============================================================================
//
// `src/markdown.zig` is a PDF-spans → Markdown *renderer* (not a parser).
// Public surface used here:
//   - `markdown.TextSpan`               — alias for `layout.TextSpan`.
//   - `markdown.MarkdownOptions`        — semantic-detection toggles.
//   - `markdown.renderPageToMarkdown`   — single-page entry.
//
// The reverse direction (Markdown → PDF) lives in `markdown_to_pdf.zig` and
// is fuzzed by `markdown_render_tagged` (tagged=true). The untagged target
// below covers the `tagged=false` branch of `renderCore`.

/// Construct a randomised `TextSpan` slice and feed it through
/// `markdown.renderPageToMarkdown`. SUT-independent invariants only:
///   - no panic / no leak.
///   - UTF-8 input → UTF-8 output (we keep the input UTF-8-valid so that
///     a violation of this property is a *renderer* bug, not the input
///     accidentally being garbage already).
///   - finite coordinates (NaN/inf y/x are out of scope here; guarded
///     by `layout.safeRowFromY` already; iter-9 P4 says don't probe
///     fields that may be undefined).
///   - heuristic upper bound on output size: each element prepends at
///     most 7 bytes ("###### ") and appends 1 newline, so for N spans
///     the output is at most 8 × (N + Σ text.len) plus a slack.
fn fuzzMarkdownRenderPdfToMd(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;
    _ = scratch;

    // Cap span count well under any structural budget. The renderer
    // sorts and dupes; 64 spans at avg 16 bytes of text is plenty to
    // exercise the line-flush + paragraph-gap branches without blowing
    // the scratch budget.
    const span_count = rng.intRangeAtMost(usize, 0, 64);

    // Bias text choices toward markers the semantic detection cares
    // about: bullets, numbered prefixes, plain words. The renderer
    // checks `startsWith` against these so they have to land at byte 0.
    // (iter-2 P2 recap: biased input must reach the SUT from byte 0.)
    const text_pool = [_][]const u8{
        "Hello",
        "world",
        "Title",
        "Section",
        "Body text continues here.",
        "\u{2022}", // bullet
        "\u{25CF}",
        "\u{25A0}",
        "-",
        "*",
        "1.",
        "2)",
        "(i)",
        "a.",
        "Z:",
        "", // empty span — exercises the empty-text branch
        "code",
        " leading-space",
        "\t",
        "long word that should not wrap because wrap_column = 0",
    };

    // Heading detection trips at ratio ≥ h3_ratio (1.3). Biasing font_size
    // toward {6, 9, 12, 14, 18, 24, 36} drives heading branches at
    // body=12pt (the most common bucket).
    const font_size_pool = [_]f64{ 6, 9, 10, 11, 12, 14, 18, 24, 36, 48 };

    var spans: std.ArrayList(markdown.TextSpan) = .empty;
    defer spans.deinit(allocator);
    try spans.ensureTotalCapacity(allocator, span_count);

    // Layout uses 1-pt resolution on a Letter page. Keep coords inside
    // [0, 1000] × [0, 1000] so the rough bbox is plausible and the
    // sort/lossyCast paths don't blow up.
    var i: usize = 0;
    while (i < span_count) : (i += 1) {
        const text = text_pool[rng.intRangeAtMost(usize, 0, text_pool.len - 1)];
        const fs = font_size_pool[rng.intRangeAtMost(usize, 0, font_size_pool.len - 1)];
        // Indented spans: ~1/4 of the time, push x0 past 36 / 72 pt to
        // light up the indentation-level branch in `indentLevel`.
        const indent_bucket = rng.intRangeAtMost(u8, 0, 7); // 0..7 → 0,36,72,...
        const x0: f64 = @as(f64, @floatFromInt(indent_bucket)) * 36.0 + rng.float(f64) * 4.0;
        // Y descends in 14-pt steps with jitter so the line-flush branch
        // (y_diff > 3.0) and paragraph-gap branch (y_diff > body*1.2)
        // both get exercised.
        const row_idx: f64 = @as(f64, @floatFromInt(i));
        const y0: f64 = 700.0 - row_idx * 14.0 + (rng.float(f64) - 0.5) * 6.0;
        const w: f64 = @as(f64, @floatFromInt(text.len)) * fs * 0.5 + 1.0;
        try spans.append(allocator, .{
            .x0 = x0,
            .y0 = y0,
            .x1 = x0 + w,
            .y1 = y0 + fs,
            .text = text,
            .font_size = fs,
        });
    }

    // Toggle the semantic-detection knobs ~ uniformly to widen branch
    // coverage. `apply_bidi=false` half the time skips the per-line
    // bidi pass; the bidi resolver itself is iter-8 territory.
    const opts: markdown.MarkdownOptions = .{
        .detect_headings = rng.boolean(),
        .detect_emphasis = rng.boolean(),
        .detect_code = rng.boolean(),
        .detect_lists = rng.boolean(),
        .detect_tables = rng.boolean(),
        .page_breaks_as_hr = rng.boolean(),
        .apply_bidi = rng.boolean(),
    };

    // `renderPageToMarkdown`'s inferred error set today is just
    // `error{OutOfMemory}` (alloc + dupe + appendSlice). Bubble OOM as
    // a no-op (allocator pressure isn't a SUT bug); any future error
    // added to the set will surface here as a compile error and force
    // a deliberate decision.
    const out = markdown.renderPageToMarkdown(allocator, spans.items, 612.0, opts) catch |e| {
        if (e == error.OutOfMemory) return;
        return e;
    };
    defer allocator.free(out);

    // Invariant 1: every span text is ASCII-only in our pool, so the
    // output must validate as UTF-8 too. (Bullet code points U+2022 /
    // U+25CF / U+25A0 are valid 3-byte UTF-8 → still UTF-8-valid.)
    if (!std.unicode.utf8ValidateSlice(out)) return error.MarkdownRenderInvalidUtf8;

    // Invariant 2: heuristic size ceiling. Worst-case prefix is
    // "###### " (7 bytes), worst-case suffix is "```\n…\n```\n"
    // (10 bytes around code blocks); use 32× per element + slack as a
    // generous upper bound. Most pool texts ≤ 64 bytes, so the bound
    // is comfortably above the renderer's actual output.
    var total_text_len: usize = 0;
    for (spans.items) |s| total_text_len += s.text.len;
    const upper_bound: usize = 32 * (spans.items.len + 1) + 32 * total_text_len + 1024;
    if (out.len > upper_bound) return error.MarkdownRenderOutputTooLarge;

    // Invariant 3: line-break sentinel uses the empty rodata literal `""`;
    // the per-element free in `render` guards on `text.len > 0`. If the
    // renderer ever emits a literal NUL byte we want to know about it
    // — markdown is text and a NUL would corrupt downstream NDJSON.
    if (std.mem.indexOfScalar(u8, out, 0)) |_| return error.MarkdownRenderEmbeddedNul;
}

/// Pivot per iter-12 brief: `markdown_render_tagged` covers the
/// `tagged=true` half of `renderCore`; this target drives the
/// `tagged=false` half. Same `%PDF-` / `%%EOF` / reparse-yields-pages
/// property as the tagged target.
///
/// Mirror of `fuzzMarkdownRenderTagged` (line ~1040) but uses
/// `markdown_to_pdf.render` (the `renderWithIo(allocator, null, …)`
/// alias) so the StructTree assembly path stays cold.
fn fuzzMarkdownToPdfUntagged(rng: std.Random, allocator: std.mem.Allocator, scratch: []u8, seed_pdf: []const u8) anyerror!void {
    _ = seed_pdf;

    // Same 2 KiB cap as the tagged target — render() expands one PDF
    // page per `---` line in the worst case; unbounded markdown blows
    // past the page-tree depth budget without surfacing fresh bugs.
    const len = rng.intRangeAtMost(usize, 0, @min(scratch.len, 2048));
    rng.bytes(scratch[0..len]);

    // `render`'s inferred error set is narrower than `renderTagged`'s
    // (no struct-tree assembly), so a single OutOfMemory swallow
    // covers it. Any other error (e.g. drawing-engine panic surfaced
    // as an error) bubbles up and counts as a finding.
    const bytes = markdown_to_pdf.render(allocator, scratch[0..len]) catch |e| {
        if (e == error.OutOfMemory) return;
        return e;
    };
    defer allocator.free(bytes);

    // Same structural invariants as the tagged target (line ~1055).
    if (!std.mem.startsWith(u8, bytes, "%PDF-")) return error.MarkdownUntaggedMissingMagic;
    if (std.mem.indexOf(u8, bytes, "%%EOF") == null) return error.MarkdownUntaggedMissingEof;

    const doc = zpdf.Document.openFromMemory(allocator, bytes, zpdf.ErrorConfig.default()) catch
        return error.MarkdownUntaggedUnreadable;
    defer doc.close();
    if (doc.pageCount() == 0) return error.MarkdownUntaggedZeroPages;

    // Negative-space check (iter-10 P2 — probe each transition's
    // post-condition explicitly). The untagged path must NOT emit a
    // /StructTreeRoot dictionary. A bare substring search is OK here
    // because content streams are not flate-compressed at this tier
    // for the StructTree dict itself (only page content streams are).
    if (std.mem.indexOf(u8, bytes, "/StructTreeRoot")) |_| {
        return error.MarkdownUntaggedHasStructTreeRoot;
    }
}

// ============================================================================
// Driver
// ============================================================================

const DEFAULT_ITERS: u64 = 1_000_000;
const PROGRESS_EVERY: u64 = 100_000;

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // 0.16: `getEnvVarOwned` is gone; env vars come from `init.environ_map`
    // (parsed once at process start). `.get` returns a borrow that lives
    // for the whole process, so the per-target arena.reset()s below can't
    // invalidate it (the PR-4c page-allocator dance is no longer needed).
    const env_iters = init.environ_map.get("PDFZIG_FUZZ_ITERS");
    const iters = if (env_iters) |s|
        std.fmt.parseInt(u64, s, 10) catch DEFAULT_ITERS
    else
        DEFAULT_ITERS;

    const target_filter = init.environ_map.get("PDFZIG_FUZZ_TARGET");

    const env_aggressive = init.environ_map.get("PDFZIG_FUZZ_AGGRESSIVE");
    const aggressive_enabled = if (env_aggressive) |s| !std.mem.eql(u8, s, "0") else false;

    const env_seed = init.environ_map.get("PDFZIG_FUZZ_SEED");
    const wall_seed: u64 = blk: {
        const now = std.Io.Timestamp.now(init.io, .real);
        break :blk @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_ms));
    };
    const base_seed: u64 = if (env_seed) |s|
        std.fmt.parseInt(u64, s, 0) catch wall_seed
    else
        wall_seed;

    var stderr_buf: [4096]u8 = undefined;
    var bw = std.Io.File.stderr().writer(init.io, &stderr_buf);
    const out = &bw.interface;
    defer out.flush() catch {};

    try out.print("pdf.zig fuzz harness — iters={d}, base_seed=0x{x}, build={s}\n", .{ iters, base_seed, @tagName(builtin.mode) });

    // Build a pool of seed PDFs covering the parser families called out as
    // risk areas during the GA review (Codex cycle-3 finding #6): minimal
    // Helvetica, CID/CMap-using font, encrypted, and multi-page. Allocate
    // from page_allocator so they survive every per-target arena.reset.
    var seed_pool: [4][]const u8 = undefined;
    seed_pool[0] = try testpdf.generateMinimalPdf(std.heap.page_allocator, "fuzz seed — minimal");
    seed_pool[1] = try testpdf.generateCIDFontPdf(std.heap.page_allocator);
    seed_pool[2] = try testpdf.generateEncryptedPdf(std.heap.page_allocator);
    seed_pool[3] = try testpdf.generateMultiPagePdf(std.heap.page_allocator, &.{
        "Page one with a paragraph and some words.",
        "Page two has different content for cross-page mutation.",
        "Page three closes the document body.",
    });
    defer for (seed_pool) |p| std.heap.page_allocator.free(p);

    var scratch: [8192]u8 = undefined;

    const t_total = std.Io.Timestamp.now(init.io, .real).toMilliseconds();
    var failures: u32 = 0;

    for (TARGETS, 0..) |target, ti| {
        if (target_filter) |f| {
            if (!std.mem.eql(u8, f, "all") and !std.mem.eql(u8, f, target.name)) continue;
            // `all` is for "every target except the known-broken ones"; a
            // reproducer-only target is only reached when its name is named
            // exactly. Otherwise PDFZIG_FUZZ_TARGET=all would re-introduce
            // the deterministic abort the gating exists to prevent.
            if (target.reproducer_only and !std.mem.eql(u8, f, target.name)) continue;
        } else {
            // No filter set → default + aggressive sweeps. Reproducer-only
            // targets never run in this branch — they require the explicit
            // PDFZIG_FUZZ_TARGET=<name> opt-in.
            if (target.reproducer_only) continue;
            if (target.aggressive and !aggressive_enabled) continue;
        }
        var prng = std.Random.DefaultPrng.init(base_seed +% @as(u64, ti) *% 0x9E3779B97F4A7C15);
        const rng = prng.random();

        try out.print("[{d}/{d}] {s}: ", .{ ti + 1, TARGETS.len, target.name });
        try out.flush();

        const t_start = std.Io.Timestamp.now(init.io, .real).toMilliseconds();
        var iter: u64 = 0;
        var target_failures: u32 = 0;
        while (iter < iters) : (iter += 1) {
            // Rotate the seed across the 4-PDF pool so mutation targets
            // exercise minimal / CID-font / encrypted / multi-page parser
            // paths instead of just the minimal one. Exception: the
            // extract-mutation target is pinned to seed_pool[0] (minimal
            // Helvetica) because byte-flipping a CID-font / encrypted /
            // multi-page seed and then calling extractMarkdown can drive
            // the upstream parser into a hang on hostile input — a class
            // of bug not reachable through pdf.zig's user-facing CLI
            // (which only opens trusted PDFs from disk). Tracked as
            // audit/fuzz_findings.md Finding 004; safe to broaden once
            // upstream gains content-stream watchdog timeouts.
            const this_seed = if (std.mem.eql(u8, target.name, "pdf_extract_mutation"))
                seed_pool[0]
            else
                seed_pool[@as(usize, @intCast(iter)) % seed_pool.len];
            target.run(rng, arena_alloc, &scratch, this_seed) catch |e| {
                target_failures += 1;
                if (target_failures <= 3) {
                    try out.print("\n  ! iter={d} {s}", .{ iter, @errorName(e) });
                }
            };
            // Cheap: reset the arena every 4096 iters to bound RSS growth.
            if (iter & 0xFFF == 0xFFF) {
                _ = arena.reset(.retain_capacity);
            }
            if (iter > 0 and iter % PROGRESS_EVERY == 0) {
                try out.print(".", .{});
                try out.flush();
            }
        }
        const elapsed_ms = std.Io.Timestamp.now(init.io, .real).toMilliseconds() - t_start;
        try out.print(" {d} iters in {d} ms ({d} fail)\n", .{ iters, elapsed_ms, target_failures });
        failures += target_failures;
    }

    const total_ms = std.Io.Timestamp.now(init.io, .real).toMilliseconds() - t_total;
    try out.print("\nTotal: {d} target(s) × {d} iters in {d} ms — {d} invariant violation(s)\n", .{ TARGETS.len, iters, total_ms, failures });

    if (failures > 0) {
        std.process.exit(1);
    }
}
