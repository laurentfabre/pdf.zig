# Streaming layer design — pdf.zig vs upstream Lulzx/zpdf

> The deliverable for Week 3 of `architecture.md` §14: the LLM-streaming output layer that distinguishes `pdf.zig` from upstream `zpdf`. Concrete module map, data flow, error handling. Design note pre-implementation.

---

## What's already in upstream

The upstream Lulzx/zpdf at SHA `5eba7ad` already provides:

- `Document.open(allocator, path)` — parse the PDF, return a handle
- `Document.pageCount() usize`
- `Document.extractText(page_idx: usize, writer: anytype) !void` — write extracted text to a `std.io.AnyWriter`
- `Document.close()` / `deinit()`
- `markdown.zig` — Markdown export (separate path from raw text extraction)
- CLI in `main.zig` with `extract` / `info` / `bench` subcommands; output is plain text or markdown
- Python bindings in `python/`

What's *missing* for our LLM-streaming use case:

- **Per-page flush** — the upstream `extract` writes all pages, then the writer is closed. No flush between pages → LLM downstream sees content in one batch at EOF, not progressively.
- **NDJSON envelope** — output is plain text/markdown, not the `kind`-tagged records architecture.md §6.1 specifies.
- **`source` + `doc_id` envelope fields** — not present.
- **Terminal `fatal` record** — parser death is silent or stack-trace; doesn't emit a final NDJSON record per architecture.md §6.4.
- **SIGPIPE-clean exit** — not verified; needs explicit signal handling.
- **Token-aware chunking** (`--output chunks --max-tokens N`) — not present.

These are additive — we keep the upstream API and add a streaming layer on top.

---

## Module map (additions / modifications)

```
upstream/src/                       (read-only after fork; we don't refactor upstream's internals)
├── root.zig                        # use as-is via @import("zpdf")
├── markdown.zig                    # use as-is for the Markdown formatter
├── parser.zig + xref.zig + …       # use as-is (where the actual parsing happens)
└── main.zig                        # KEEP for upstream-compat; add new pdf-zig CLI in parallel

OUR ADDITIONS in src/ of forked repo:
├── stream.zig                      # NEW (~300 LOC): NDJSON envelope + flush rules
├── chunk.zig                       # NEW (~150 LOC): token-aware chunking
├── tokenizer.zig                   # NEW (~250 LOC): embedded BPE for token estimates
├── uuid.zig                        # NEW (~80 LOC): UUIDv7 generator
├── cli_pdfzig.zig                  # NEW (~400 LOC): pdf.zig-flavored CLI dispatch
└── main_pdfzig.zig                 # NEW (~50 LOC): entry point that calls cli_pdfzig

build.zig changes:
- Add a second binary target `pdf.zig` (in parallel with upstream's `zpdf` binary, for now)
- After Week-5 stability: deprecate the upstream-compat binary, make `pdf.zig` canonical

Total NEW Zig code: ~1230 LOC (rough). Compares to zlsx's 22K — much smaller because
upstream's parser does the heavy lifting; we're just the I/O envelope + LLM ergonomics.
```

---

## Data flow (one invocation of `pdf.zig extract foo.pdf`)

```
┌─────────────────────────────────────────────────────────────────────┐
│ argv parse (cli_pdfzig.zig)                                         │
│   - extract source basename:  "foo.pdf"                             │
│   - extract output mode:      ndjson | md | chunks | text           │
│   - mint UUIDv7 doc_id:       "019f4a2b-7e9c-7c1a-…"                │
│   - register SIGPIPE/SIGINT/SIGTERM handlers (stream.zig)           │
└────────────┬────────────────────────────────────────────────────────┘
             ↓
┌─────────────────────────────────────────────────────────────────────┐
│ Document.open(allocator, path)                       [upstream]     │
│   - errdefer: emit fatal record + exit non-zero                     │
│   - on success: extract metadata (page_count, encrypted, producer)  │
└────────────┬────────────────────────────────────────────────────────┘
             ↓
┌─────────────────────────────────────────────────────────────────────┐
│ stream.emitMeta(writer, doc_id, source, doc.metadata)               │
│   {"kind":"meta","source":"foo.pdf","doc_id":"…","pages":13,…}      │
│   writer.flush()                                                    │
└────────────┬────────────────────────────────────────────────────────┘
             ↓
┌─────────────────────────────────────────────────────────────────────┐
│ for page_idx in 0..doc.pageCount():                                 │
│   ┌──────────────────────────────────────────────────────────────┐ │
│   │ per-page arena = ArenaAllocator.init(parent_alloc)            │ │
│   │ defer per-page arena.deinit()                                 │ │
│   │ doc.extractText(page_idx, page_buf_writer)   [upstream]       │ │
│   │ markdown.format(page_buf, md_buf)            [upstream]       │ │
│   │ stream.emitPage(writer, doc_id, source, page_idx, md_buf,    │ │
│   │                 warnings_for_this_page)                       │ │
│   │ writer.flush()  ← LLM sees this page now                     │ │
│   └──────────────────────────────────────────────────────────────┘ │
└────────────┬────────────────────────────────────────────────────────┘
             ↓
┌─────────────────────────────────────────────────────────────────────┐
│ stream.emitToc(writer, doc_id, source, doc.toc) if structure tree   │
│ stream.emitSummary(writer, doc_id, source, totals)                  │
│ exit(0)                                                             │
└─────────────────────────────────────────────────────────────────────┘
```

**Error paths**:
- Pre-Document.open failure (file not found, permission, NotAPdf): emit `meta_failed` then `fatal` with no per-page records, exit 4
- Per-page extraction error (CMap missing, unknown content op): emit `page` record with empty markdown + populated warnings array, continue
- OOM mid-page: emit `fatal:oom` with `at_page:N`, exit 5
- SIGPIPE during page flush: exit 0 if ≥1 page already emitted, exit 141 otherwise
- SIGINT/SIGTERM between pages: emit `interrupted` record, exit 130/143

---

## stream.zig API (proposed)

```zig
//! NDJSON streaming envelope for pdf.zig CLI. Per-page flush; no-panic; SIGPIPE-clean.
//! Architecture: docs/architecture.md §6 (LLM-streaming output protocol).

const std = @import("std");

pub const RecordKind = enum {
    meta, page, toc, summary, fatal, chunk, interrupted,
};

pub const Envelope = struct {
    doc_id: [36]u8,           // UUIDv7 string form; minted at invocation start
    source: []const u8,        // basename of input or "-" for stdin
    writer: std.io.AnyWriter,
    flush_after_each: bool,    // true for per-page; false for batch modes

    pub fn init(writer: std.io.AnyWriter, source: []const u8) Envelope {
        return .{
            .doc_id = uuid.v7(),
            .source = source,
            .writer = writer,
            .flush_after_each = true,
        };
    }

    pub fn emitMeta(self: *Envelope, info: DocumentInfo) !void { … }
    pub fn emitPage(self: *Envelope, page: u32, markdown: []const u8, warnings: []const Warning) !void { … }
    pub fn emitToc(self: *Envelope, items: []const TocItem) !void { … }
    pub fn emitSummary(self: *Envelope, totals: Totals) !void { … }
    pub fn emitFatal(self: *Envelope, err: FatalError) !void { … }
    pub fn emitChunk(self: *Envelope, chunk_id: u32, pages: []const u32, markdown: []const u8, tokens_est: u32, breakpoint: ChunkBreak) !void { … }
    pub fn emitInterrupted(self: *Envelope, signal: c_int) !void { … }
};

pub fn registerSignalHandlers() !void {
    // SIGPIPE → swallow if any page emitted (clean stdout disconnect)
    // SIGINT/SIGTERM → emit `interrupted` record, exit 130/143
    // No SIGABRT in release (per architecture.md §6.4 cycle-1 P1 fix)
}

pub const FatalError = struct {
    error_kind: enum { not_a_pdf, encrypted, truncated, oom, unknown_filter, … },
    message: []const u8,
    at_page: ?u32 = null,
    recoverable: bool = false,
};
```

## uuid.zig API (proposed)

```zig
//! UUIDv7 (time-ordered) generator. ~80 LOC. Per architecture.md §6.1 cycle-2 P2 fix.
const std = @import("std");

pub fn v7() [36]u8 {
    // 48-bit unix-millis timestamp + 12-bit random + variant bits + 62-bit random
    const ts_ms: u64 = @intCast(std.time.milliTimestamp());
    var rand_bytes: [10]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    // ... compose per RFC 9562 ...
    return formatted_string;
}
```

## chunk.zig API (proposed)

```zig
//! Token-aware chunking for `--output chunks --max-tokens N`. ~150 LOC.

pub fn chunk(
    pages: []const PageMd,
    max_tokens: u32,
    tokenizer: *Tokenizer,
    envelope: *Envelope,
) !void {
    // Greedy pack pages into chunks ≤ max_tokens.
    // Break preference: section heading > page boundary > paragraph > sentence.
    // Emit each chunk record via envelope.emitChunk()
}
```

## tokenizer.zig API (proposed)

```zig
//! Embedded GPT-style tokenizer for token-count estimation. ~250 LOC.
//! Embeds either o200k_base BPE table (~2 MB) or falls back to chars/4 heuristic
//! if compiled with -Dno-bpe.

pub const Tokenizer = struct {
    pub fn init(allocator: std.mem.Allocator, mode: enum { o200k, fallback }) !Tokenizer { … }
    pub fn count(self: *Tokenizer, text: []const u8) u32 { … }
};
```

---

## CLI surface (additions to upstream `main.zig` style)

Per `architecture.md` §7, the new pdf.zig CLI mirrors zlsx subcommand conventions:

```
pdf.zig extract <file>              # default: NDJSON to stdout, all pages, per-page flush
pdf.zig extract -p 1-10 <file>
pdf.zig extract -o out.md <file>    # detects .md / .ndjson / .jsonl by extension
pdf.zig extract --output md
pdf.zig extract --output ndjson     # default
pdf.zig extract --output chunks --max-tokens 4000
pdf.zig extract --output text       # plain text, no markdown structure
pdf.zig extract --no-toc
pdf.zig extract --no-warnings
pdf.zig extract --jobs 4            # ONLY for non-stdout output (architecture.md §7 cycle-1 P2)
pdf.zig info <file>                  # pretty metadata (text)
pdf.zig info --json <file>           # JSON metadata (one record only)
pdf.zig bench <file>                 # speed/throughput self-report
pdf.zig chunk <file> --max-tokens N  # alias for `extract --output chunks`
pdf.zig --version
pdf.zig --help
```

Implementation: hand-rolled arg parser (per zlsx pattern); no clap dep. Errors → `ArgError` enum → exit 1 with one-line stderr diagnostic.

---

## Quality gates specific to the streaming layer

(In addition to the architecture.md §11 quality matrix.)

- **First-byte latency** ≤ 50 ms on the smallest Alfred PDF (Aman NY menu, 6 pages, 180 KB)
- **Per-page latency** (between two consecutive `page` records on stdout) ≤ 200 ms median
- **SIGPIPE test**: `pdf.zig extract huge.pdf | head -1` exits 0
- **Multi-file test**: `xargs -P4 -n1 pdf.zig extract --output ndjson > corpus.jsonl` produces records that re-group cleanly by `doc_id`
- **OOM-mid-page test**: artificially constrain RSS, verify `fatal:oom` is emitted, no SIGABRT
- **Fuzz on the envelope**: pass garbage page text into `emitPage`; verify NDJSON output is always valid JSON Lines

---

## Open implementation questions for Week 3

1. **Should the embedded BPE be compiled in by default, or `-Dno-bpe` opt-out?** ~2 MB binary cost vs zero-Python tokenization ergonomics.
2. **`--output chunks` chunk break heuristics**: greedy-pack with section-heading-preferred, or smarter (semantic-similarity sentence-boundary)? Start greedy.
3. **Should `info --json` use the same envelope?** Codex cycle-2 wants envelope invariants; consistency says yes (emit `meta` only, exit 0).
4. **Does upstream's `extractText` ever silently drop content on the floor?** The Week-1 triage of 47 unexplained empties + 9 garbage cases will tell us. If yes, we need a `warnings` array contract from upstream — possibly via PR upstream.
5. **Per-page flush vs end-of-doc flush for `--output md`**: if md goes to a file, do we still flush per-page? Probably yes for `tail -f` compat; cheap.

---

## Status

**Implemented in Week 3 (2026-04-26)** on branch `week3/streaming-layer`. Total new Zig: ~1 100 LOC across 6 modules + 35 LOC build.zig wiring (a touch under the 1 230 LOC estimate). Both `zpdf` (upstream-compat) and `pdf.zig` (NDJSON-streaming) binaries now ship side-by-side; `pdf.zig` becomes canonical at Week 5 per the roadmap.

### What landed

| Module | LOC | Status |
|---|---|---|
| `src/uuid.zig` | ~95 | ✅ RFC 9562 UUIDv7, 4 unit tests |
| `src/tokenizer.zig` | ~110 | ✅ chars/4 heuristic with multibyte+whitespace adjustments, 6 unit tests. **`o200k_base` BPE backend reserved for v1.x** (decision below). |
| `src/stream.zig` | ~370 | ✅ Envelope + 7 record kinds + signal handlers + UTF-8-robust JSON escaping (invalid bytes → `�`), 12 unit tests |
| `src/chunk.zig` | ~210 | ✅ Greedy page packing + giant-page split with section-heading > paragraph > sentence preference, 5 unit tests |
| `src/cli_pdfzig.zig` | ~440 | ✅ Hand-rolled arg parser, `extract` / `chunk` / `info` / `--version` / `--help`, 11 unit tests |
| `src/main_pdfzig.zig` | ~30 | ✅ Entry point on `std.heap.smp_allocator` |

**Test totals**: 38 unit tests across the new modules, all green. Existing upstream test suite untouched.

### Resolved open questions

1. **BPE compiled in by default?** → **No, opt-in for v1.x.** v1 ships the chars/4 heuristic only (`Backend.heuristic`). The `Backend.o200k_base` enum slot is reserved and returns `error.NotImplemented` so call sites are stable when the BPE table swaps in. Trade rationale: the binary is currently 647 KB; embedding o200k_base would push it past 2.5 MB before any real-world demand for sub-3% chunk-budget accuracy. (`src/tokenizer.zig:16-22`)
2. **Chunk break heuristics** → **Greedy with priority order section_heading > paragraph (`\n\n`) > sentence (`. ` / `\n`).** No semantic-similarity sentence boundary work in v1. (`src/chunk.zig:findBreakBefore`)
3. **`info --json` use the same envelope?** → **Yes, single `meta` record.** Keeps envelope invariants and lets downstream consumers run the same parser as for `extract`. (`src/cli_pdfzig.zig:runInfo`)
4. **Does upstream silently drop content?** → **Per Week-2 finding (`docs/week2-status.md`), no.** The 41 / 48 anomalies in the Week-0 audit are image-text PDFs (NG4), correctly detected; the streaming layer surfaces them as `page` records with empty `markdown` plus a `quality_flag:scanned` warning (warning-emission deferred to v1.x once the upstream quality flag exists; v1 emits the empty `markdown` and a per-extraction warning if the call returns an error).
5. **Per-page flush for `--output md`** → **Yes, flush after every page** (cheap, `tail -f` compatible). (`src/cli_pdfzig.zig:runExtract`)

### Quality-gate measurements

Run on `milaidhoo-island-maldives/SpaMenuwebCOMPRESS.pdf` (27 pages, ReleaseSafe build):

| Gate | Target | Actual |
|---|---|---|
| First-byte latency | ≤ 50 ms | < 8 ms (full extract finished in 8 ms) |
| Per-page latency (median) | ≤ 200 ms | ~0.3 ms |
| SIGPIPE: `extract \| head -1` | exit 0 | ✅ exit 0 |
| Per-file kind sequence | meta → page* → summary | ✅ on 4 / 4 sampled PDFs |
| JSON-Lines validity | always valid JSON, always valid UTF-8 | ✅ — `writeJsonString` validates per-sequence and substitutes `�` for invalid bytes (covers upstream's UTF-16BE-leaking metadata) |
| Multi-process shared stdout | groupable by doc_id | ⚠️ Known design-doc limitation: records past `PIPE_BUF` (4 KB) tear under parallel writes. Use `-o per-file.jsonl` or a single-process pipeline. |
| OOM-mid-page → `fatal:oom` | no SIGABRT | ⏸️ Deferred to Week 4 fuzz suite (`checkAllAllocationFailures`) |

### Caveats / known follow-ups for Week 3.x

- **Memory leaks reported by `DebugAllocator`** when running tests against real PDFs come from upstream `Document.close()` not freeing every parse-time allocation. Production binary uses `std.heap.smp_allocator` so leaks are reclaimed at exit, but the upstream cleanup is a real defect worth a separate PR (or a test-run-only ArenaAllocator wrapper). Out of scope for the streaming layer itself.
- **TOC emission** (`emitToc`) and the `--no-toc` / `--no-warnings` flags are wired through the parser but not yet populated by the extract path — the upstream `outline` integration adds in Week 3.x.
- **`bench` subcommand** stays on the upstream `zpdf` binary in v1 — no need to duplicate.
