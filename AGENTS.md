# Claude Guide: pdf.zig (PDF reader CLI / Zig lib / Python binding / Markdown→PDF writer)

This document explains how to read and write PDFs via **pdf.zig** — a single-binary Zig CLI + library + Python binding — from a Claude Code session, with a `docling` fallback for cases pdf.zig deliberately doesn't cover.

**Shared agent practices**: see `@~/.claude/AGENT-PRACTICES.md` for the cross-project conventions (kickoff brief, RPI loop, 40% context dumb-zone, writer/reviewer split, TDD + TDAD). Read it once per session; this file documents only what is specific to pdf.zig.

The audience is an LLM agent loaded into a project directory and asked to extract content from a PDF or write a fresh one. **Every section is dense on purpose.** These are the rules that separate a 30-ms first-page flush into Claude's context from a 5-second `pymupdf4llm` boot that loads the entire document into RAM.

> **Scope.** pdf.zig is the **default** for PDF → text / Markdown / NDJSON extraction at LLM-streaming latency, AND for greenfield Markdown → PDF authoring of plain documents (Tier-1: paragraphs, headings, lists, page breaks, base-14 fonts, ASCII). It does **not** cover: layout-aware table extraction with reading-order recovery (the v1.2 tagged-table path handles tagged PDFs only), OCR on scanned/image-only PDFs, encrypted PDFs (parser does not decrypt), or full PDF authoring (charts / images / forms / TrueType subsetting not in scope yet). Fall back to **docling** for layout/OCR/CJK and to **qpdf / pypdf** for encryption — see *Fallback to docling* below.

---

## Architecture Overview

pdf.zig ships in three loosely-coupled layers, and the layers split into **reader** and **writer** sublayers (the writer is newer — v1.5 series). Knowing which layer you're touching avoids the most common failure mode (assuming the local `zig-out/bin/pdf.zig` is on `$PATH` when it isn't, or trying to mutate a parsed `Document` when you actually need `DocumentBuilder`).

### 1. The `pdf.zig` CLI (the Stream Layer)
**Purpose**: Per-page-flushed Markdown / NDJSON for LLM ingestion + Markdown → PDF rendering for fresh-document authoring

- Single static binary; expected location after install: `/opt/homebrew/bin/pdf.zig` (brew tap) or `~/.local/bin/pdf.zig` (release tarball). On dev machines an in-tree build at `/Users/lf/Projects/Pro/pdf.zig/zig-out/bin/pdf.zig` is the authoritative source.
- **Source repo**: `/Users/lf/Projects/Pro/pdf.zig` (fork of [Lulzx/zpdf](https://github.com/Lulzx/zpdf), CC0). README headline reads `v1.0-rc2`; Git tags include `v1.2-rc3` plus 100+ post-tag commits in the v1.5 greenfield writer series. The CLI's `--version` reports `pdf.zig 0.1.0-dev` — the build version literal lags the README/tag (cosmetic backlog item; trust `git describe --tags` for the canonical version).
- **No `build.zig.zon`** — pdf.zig is consumed as a binary (brew tap / release tarball / source build), not as a Zig package dependency. Don't try to `.dependencies = .{ .pdfzig = ... }` from another `build.zig.zon`.
- **Reader subcommands** (the 90% case):
  - `extract <file>` — content extraction (default).
  - `chunk <file> --max-tokens N` — alias for `extract --output chunks`.
  - `info <file>` — pretty metadata.
  - `info --json <file>` — single `meta` NDJSON record.
- **Writer subcommand** (PR-W5, v1.5):
  - `new -o FILE [INPUT.md|-]` — render Markdown into a fresh PDF. Tier-1 only (ASCII, Helvetica, paragraphs/headings/lists/`---` page breaks). Compose-only; non-ASCII bytes are silently dropped per `drawText`'s WinAnsi filter.
- **Output formats** (extract): `ndjson` (default), `md`, `chunks`, `text`. Slice + filter: `--pages "1-10"` or `--pages "1,3,5"`, `--max-tokens N` chunk budget, `--no-toc`, `--no-warnings`, `--scan-threshold PCT` for "is this scanned" heuristic.
- **Streaming protocol**: NDJSON envelope with `kind` + `source` + `doc_id` (UUIDv7 minted at invocation start); per-page flush; SIGPIPE-clean; terminal `{"kind":"fatal"}` record on parser death (no SIGABRT in release).
- **Error model**: per-page parse errors emit inline `{"kind":"warning",…}` records on the page; workbook-open failures emit a terminal `{"kind":"fatal"}` and exit non-zero.

### 2. The Zig Library (the Native Layer)
**Purpose**: In-process PDF read AND fresh write for Zig consumers — same parser/writer, no NDJSON marshalling overhead

- Built as part of `zig build` from `/Users/lf/Projects/Pro/pdf.zig`. Upstream's `src/` tree is preserved; pdf.zig's additions layer alongside (`docs/`, `audit/`, `bake-off/`, `scripts/`).
- **Toolchain**: Zig 0.16.0 (`zig`). The codebase was migrated from 0.15.2 in the `chore/zig-0.16-migration` PR: `std.io` → `std.Io`, `ArrayList.writer()` → `ArrayList.print()`/`Io.Writer.Allocating`, `std.fs` → `std.Io.Dir`, signal handler type `c_int` → `std.posix.SIG`, `std.crypto.random` → `std.os.linux.getrandom`.
- **Build mode**: **ReleaseSafe**, not ReleaseFast — quality bar is "zero panics on the Alfred 1,776-PDF corpus", not raw throughput.
- **Reader API** (entry: `src/root.zig`): `Document.openFromMemory(allocator, bytes, ErrorConfig)`, `doc.pageCount()`, `doc.metadata()`, `doc.extractMarkdown(page_num, allocator)`, `doc.getOutline(allocator)`, `doc.getFormFields(allocator)`. All allocator-explicit; deinit pairs symmetric.
- **Writer API** (PR-W1+W2+W3+W6, `src/pdf_writer.zig` + `src/pdf_document.zig`):
  - Low level: `pdf_writer.Writer` — header, indirect objects (`allocObjectNum`/`beginObject`/`endObject`), name + literal/hex strings (with `(` `\` octal escapes), real numbers (NaN/inf rejected), int, ref, stream, xref, trailer.
  - High level: `pdf_document.DocumentBuilder` — single-use builder with balanced `/Pages` tree (fan-out 10), `addPage` returning a `*PageBuilder`, `addAuxiliaryObject` / `reserveAuxiliaryObject` + `setAuxiliaryPayload` (cyclic graphs like /Outlines ↔ items), `setInfoDict`, `setCatalogExtras`. Writes `/Info` ref into the trailer automatically when set. After `write()` the builder is consumed (`written = true`); subsequent mutations return `error.DocumentAlreadyWritten`.
  - Page level: `PageBuilder.drawText(x, y, font, size, text)` — typed `BT … Tj ET` op composer with auto-resource emission; `appendContent` for raw content streams (TJ kerning, Tm matrices, etc.); `setResourcesRaw` to override the auto `/Resources/Font` dict; `setPageExtras` for `/Annots`/`/Group`/`/StructParents`. `markFontUsed(font)` returns the resource name (`/F0`..`/F13`) for `Tf` operators in raw streams.
  - Fonts: 14 standard PDF Type 1 base-14 fonts via `BuiltinFont` enum; WinAnsiEncoding for the 12 ASCII-friendly ones, native encoding for Symbol/ZapfDingbats.
- **What the writer does NOT do**: TrueType subsetting / UTF-8 outside WinAnsi; charts; images; encryption; signatures; linearization. Tier-1 = readable, valid PDFs with text-only content. FlateDecode content-stream compression is available (PR-W4, `compress_content_streams: bool` on `DocumentBuilder`) but opt-in.
- **Quality evidence** (per README *Status* + audit):
  - 0 crashes on Alfred's 1,776-PDF corpus.
  - 11 fuzz targets × 1M iters each (`zig build fuzz`).
  - 11/11 xref-repair fixtures green.
  - 4 NaN/inf upstream panic sites fixed.
  - **1133/1133 unit tests pass** as of the v1.5 series merge (was 474 before PR-W6 — PR-W6 wired up 376 previously-orphaned writer-stack tests + added foundational escape hatches).

### 3. The Python Binding (the Polyglot Layer)
**Purpose**: Call pdf.zig from a Python process without subprocess overhead

- Package: `py-pdf-zig`. `pip install py-pdf-zig`. **Not currently installed** by default; verify with `python3 -c "from zpdf import Document"`.
- **Import name preserves upstream identity**: `from zpdf import Document` (NOT `import pdfzig`).
- Reader-only at present; the v1.5 writer surface is Zig-library + CLI only. To author from Python, use the CLI: `subprocess.run(["pdf.zig", "new", "-o", out, "-i", in_md])`.

---

## Understanding `pdf.zig` Targets

Unlike a build system, pdf.zig has no compilation targets at the user level — but it does have **subcommand**, **output mode**, **page subset**, and **chunk budget** that determine what lands in the consumer's context.

| Concept | What it is | How to discover |
|---|---|---|
| Subcommand | Verb that determines emission shape | `pdf.zig --help` (extract / chunk / info / new) |
| Output mode (extract) | NDJSON / Markdown / chunks / plain text | `--output ndjson\|md\|chunks\|text` (default ndjson) |
| Page subset | Range or list (1-based) | `--pages "1-10"` or `--pages "1,3,5"` |
| Chunk budget | Max tokens per chunk record | `--max-tokens N` (default 4000) |
| TOC suppression | Drop the `toc` NDJSON record | `--no-toc` |
| Warnings suppression | Drop the per-page `warnings` array | `--no-warnings` |
| Scan-detection threshold | Flag a doc "scanned" by ≥PCT% empty-text pages | `--scan-threshold PCT` (default 50) |
| Doc ID | UUIDv7 minted at invocation start | Surfaced as `doc_id` in every NDJSON record |
| Writer input | Markdown source | `pdf.zig new -o out.pdf doc.md` (positional) or `-i FILE` / stdin via `-` |

**Key insights**:

1. **NDJSON streams page-by-page.** The LLM consumer sees content as it parses, not after EOF. This is the load-bearing reason to prefer pdf.zig over `pymupdf4llm` for piped consumption: a doc that takes 300 ms total starts emitting at ~30 ms.
2. **`chunks` mode is for embedding pipelines.** Default budget 4000 tokens; tune `--max-tokens` to your embedder's context. Chunker respects logical boundaries (paragraph / section); when a paragraph alone exceeds the budget, it ships oversized rather than mid-sentence cut.
3. **`md` mode loses the NDJSON envelope.** When you want a clean Markdown file (`> hotel.md`), use `--output md`. When you want streaming envelope + NDJSON, default.
4. **The `new` subcommand is Tier-1 only.** Headings (`# `/`## `/`### `), paragraphs (word-wrap), bullet/numbered lists, `---` page break. ASCII inputs only — non-ASCII bytes are silently dropped per `drawText`'s WinAnsi filter. No inline `**bold**`/`_italic_`/`` `code` `` (preserved as raw chars). No code fences, tables, links, images, multi-font.
5. **Out-of-scope for the reader: image-only PDFs and CJK char parity.** Two documented quality buckets per Week 5 bake-off.
6. **Static binary, no Python startup.** ~300 ms savings per invocation vs `pymupdf4llm`.

---

## Code Organization Patterns

### Standard layout (pdf.zig user / contributor)

```
/Users/lf/Projects/Pro/pdf.zig/                  # The source repo (Zig)
  build.zig                                       # canonical build entry (no build.zig.zon — not a Zig dep)
  src/
    root.zig                                      # reader entry (Document, ErrorConfig, extractMarkdown, …)
    cli_pdfzig.zig                                # CLI dispatcher (parseArgs / runExtract / runInfo / runNew)
    pdf_writer.zig                                # PR-W1: low-level object emitter (header, xref, trailer)
    pdf_document.zig                              # PR-W2/W3/W6: DocumentBuilder + PageBuilder + base-14 fonts
    markdown_to_pdf.zig                           # PR-W5: heuristic Markdown → PDF renderer
    testpdf.zig                                   # Test-fixture generators (most via writer API after W6.1-5)
  docs/
    architecture.md                               # design doc (~800 lines, v3)
    streaming-layer-design.md                     # NDJSON envelope spec
    alfred-bakeoff-report.md                      # quality evidence (Week 5)
    ROADMAP.md                                    # PR plan / status
    decisions.md                                  # high-level decisions log
  bake-off/                                       # comparative test outputs
  audit/                                          # per-week status / audits
  python/zpdf/                                    # Python binding source
  scripts/Formula/pdf-zig.rb                      # Homebrew tap formula
  zig-out/bin/pdf.zig                             # built binary (not on $PATH by default)

# Brew-tap install (preferred for v1.0+):
# /opt/homebrew/bin/pdf.zig                       # via `brew tap laurentfabre/pdf.zig && brew install pdf.zig`

# Pre-built release binary (alternative):
# ~/.local/bin/pdf.zig                            # via curl + tar from github.com/laurentfabre/pdf.zig/releases
```

### Pattern to follow when working with PDF data

1. **Identify the operation**: read (extract / chunk / info), write (Markdown → fresh PDF via `new`), or contribute to the parser/writer (Zig library).
2. **Pick the right surface**:
   - Shell pipeline → `pdf.zig` CLI → NDJSON | jq | sqlite3 / duckdb / claude.
   - Python script that already runs → `py-pdf-zig` (no subprocess overhead) for reads; `subprocess.run([...])` for writes.
   - Zig project → import the library directly via `@import("root.zig")` (after vendoring; pdf.zig is not a Zig dep).
3. **Stream, don't materialize**: per-page flush keeps memory flat even on 200-page docs. Buffering `pdf.zig extract big.pdf > /tmp/all.ndjson && cat /tmp/all.ndjson | jq …` defeats the architecture.
4. **NDJSON over Markdown** unless the consumer is a human or markdown-only pipeline. NDJSON preserves per-page metadata (warnings, page index, doc_id), which Markdown drops.

### What NOT to do

- **Don't subprocess `pymupdf4llm` for new pipelines** — pdf.zig was specifically built to replace it. The bake-off shows 121× faster aggregate at 78.9% char parity (per README *Week 5*).
- **Don't mutate a parsed `Document`** — it's read-only. To produce a modified PDF, parse + extract, then build fresh via `DocumentBuilder` (or `pdf.zig new`).
- **Don't run `pdf.zig` as root** — there's no daemon mode, no installer privilege story; running as root just means anything that exploits a parser bug runs as root.
- **Don't ignore the terminal `{"kind":"fatal"}` record** — it's the contract for parser death. SIGABRT is suppressed in release; if your pipeline doesn't surface fatal records, you'll see "exit 1, no error message".
- **Don't load the entire NDJSON output into a buffer before parsing** — the per-page flush is meaningless if you re-buffer.
- **Don't pass `**bold**` / fenced code / tables to `pdf.zig new`** — it preserves them as raw chars (no inline formatting in Tier-1). For richer output, fall back to `pandoc` + a real Markdown→PDF engine.
- **Don't expect compressed output from `pdf.zig new` by default** — the CLI doesn't expose a compression flag; use `DocumentBuilder.compress_content_streams = true` from Zig code (PR-W4). Tier-1 `pdf.zig new` stays uncompressed; file sizes are 4-5× typical.

---

## Common Task: Extracting a PDF for an LLM

### Steps

1. **Probe the document**:
   ```bash
   pdf.zig info hotel.pdf                    # human-readable metadata
   pdf.zig info --json hotel.pdf             # NDJSON `meta` record
   ```
2. **Stream into the LLM** (default ndjson):
   ```bash
   pdf.zig extract hotel.pdf | claude -p "Summarize this hotel"
   ```
3. **Write Markdown for offline review**:
   ```bash
   pdf.zig extract --output md hotel.pdf > hotel.md
   ```
4. **Chunk for embedding**:
   ```bash
   pdf.zig extract --output chunks --max-tokens 2000 hotel.pdf > chunks.ndjson
   ```

### Deciding output mode

- **Single LLM ingestion** → `ndjson` (default). Smallest first-token latency, type-tagged.
- **Markdown file for humans** → `md`. Loses NDJSON envelope; clean for reading.
- **Embedding pipeline** → `chunks`. Logical-boundary-aware splitting; tune `--max-tokens` to embedder.
- **`grep`-able plain text** → `text`. No structure; lowest fidelity.

### When to slice pages

- **Quick visual probe** → `--pages 1-3` (saves the per-page work).
- **Known section of interest** → `--pages "5-12,40-45"` (single flag, multiple ranges).
- **Tail (appendix only)** → `--pages "100-"` (open-ended ranges supported).

### When to use the Python binding instead of the CLI

- The pipeline already lives in Python; subprocess overhead matters at high call rates.
- You need typed access to pages (Python's `Document.extract_page(i)` returns a string per page).
- You're walking a corpus and want loop-friendly errors over CLI's NDJSON `kind: "fatal"` records.

---

## Common Task: Writing a Markdown → PDF (v1.5)

### Steps

1. **Render via the CLI** (simplest):
   ```bash
   pdf.zig new -o out.pdf doc.md                       # positional input file
   echo "# Hello\n\nWorld" | pdf.zig new -o out.pdf -i -   # from stdin
   ```
2. **Programmatic in Zig**:
   ```zig
   const std = @import("std");
   const document = @import("pdf_document.zig");

   var doc = document.DocumentBuilder.init(allocator);
   defer doc.deinit();
   _ = try doc.setInfoDict("<< /Title (Hello) /Author (Tester) >>");
   const page = try doc.addPage(.{ 0, 0, 612, 792 });
   try page.drawText(72, 720, .helvetica, 12, "Body text here");
   const bytes = try doc.write();
   defer allocator.free(bytes);
   try std.fs.cwd().writeFile(.{ .sub_path = "out.pdf", .data = bytes });
   ```
3. **Cyclic aux objects (e.g. /Outlines)** — reserve numbers up-front, then fill payloads:
   ```zig
   const outlines = try doc.reserveAuxiliaryObject();
   const item = try doc.reserveAuxiliaryObject();
   try doc.setAuxiliaryPayload(outlines, "<< /Type /Outlines /First 3 0 R /Last 3 0 R /Count 1 >>");
   try doc.setAuxiliaryPayload(item, "<< /Title (Top) /Parent 2 0 R /Dest [4 0 R /Fit] >>");
   try doc.setCatalogExtras("/Outlines 2 0 R");
   ```

### Tier-1 limits the writer respects

- ASCII-only (WinAnsi printable subset, 0x20..0x7e). Bytes outside drop silently.
- One font family (Helvetica family by default). 14 base-14 fonts available; no embedding.
- No inline formatting, no code fences, no tables, no links, no images.
- Page break on a `---` line by itself (mirrors the extractor's page separator).
- Letter pages (612×792), 1-inch margins.

### When to fall back to a real markdown engine

If you need bold/italic, code blocks, tables, links, images, custom fonts, or non-ASCII — use `pandoc` + `wkhtmltopdf` or `weasyprint`. pdf.zig's writer is **not** trying to be a full Markdown→PDF engine; it's the seed of a greenfield authoring stack. Tier 2/3 will add styling + Unicode; until then, `pandoc` is the right tool for rich documents.

---

## Fallback to docling

pdf.zig is the default for ~90% of PDF → text work but **deliberately doesn't cover** layout-aware extraction, scanned/image-only PDFs, and figure/caption / reading-order document understanding. Fall back to **docling** (IBM Research's Granite-based layout-aware PDF/document parser) for these.

| Need | Fallback | Why |
|---|---|---|
| Scanned / image-only PDF (no text layer) | `docling` (with OCR) or `tesseract` direct | pdf.zig extracts from the PDF text layer; image-only docs have none |
| CJK-heavy PDF where char parity matters | `docling` or LibreOffice convert + reparse | per Week 5 bake-off, CJK is a documented out-of-scope bucket |
| Layout-aware table extraction (rows × cols) on **untagged** PDFs | `docling` (Granite layout) or `unstructured` | pdf.zig's v1.2 tagged-table path handles tagged PDFs only; layout-recovery on untagged tables is out of scope |
| Reading order across multi-column / sidebars | `docling` | pdf.zig follows the PDF stream order |
| Figures, captions, document understanding | `docling` | full document-AI pipeline |
| Form field extraction | `pypdf` / `pdfplumber` | pdf.zig's reader exposes /AcroForm fields (PR-17) but does not validate / fill them |
| Encrypted PDF (password protected) | `qpdf --decrypt` then re-run pdf.zig, or `pypdf` | parser does not implement password-decrypt |
| FlateDecode compression on emitted PDFs | pdf.zig `DocumentBuilder` with `compress_content_streams: true` | PR-W4 shipped; opt-in per-document |

### Fallback recipe (CLI)

```bash
# Default: pdf.zig
pdf.zig extract hotel.pdf | claude -p "Summarize"

# Fallback: docling for layout-aware + OCR
pip install docling                     # ~2 GB; install only when needed
docling convert scanned.pdf -o scanned.md
cat scanned.md | claude -p "Summarize"

# Fallback: qpdf for encrypted input (then back to pdf.zig)
qpdf --password=PWD --decrypt encrypted.pdf decrypted.pdf
pdf.zig extract decrypted.pdf
```

### Fallback recipe (Python)

```python
# Default: pdf.zig via py-pdf-zig
from zpdf import Document
with Document("hotel.pdf") as doc:
    for i in range(doc.page_count):
        print(doc.extract_page(i))

# Fallback: docling for layout-aware extraction
from docling.document_converter import DocumentConverter
result = DocumentConverter().convert("scanned.pdf")
print(result.document.export_to_markdown())
```

> **Don't fall back too eagerly.** pdf.zig handles the vast majority of text-bearing PDFs at 121× the throughput of `pymupdf4llm`. Only fall back when the document is genuinely image-only, CJK-dominant with a strict char-parity bar, encrypted, or you need layout / table / reading-order understanding. A 2 GB Granite model and ~10× the latency is real cost.

> **Install docling on demand, not by default.** It's not currently on this machine. `pip install docling` adds ~2 GB; only install when a fallback case actually surfaces.

---

## Verification Workflow

Three layers — install correctness, version state, and end-to-end NDJSON sanity.

### Layer 1: Install sanity

```bash
which pdf.zig                                                          # ideally /opt/homebrew/bin/pdf.zig
ls /Users/lf/Projects/Pro/pdf.zig/zig-out/bin/pdf.zig                  # in-tree build (always present after `zig build`)
/Users/lf/Projects/Pro/pdf.zig/zig-out/bin/pdf.zig --version           # → pdf.zig 0.1.0-dev (NB: README markets v1.0+; binary string lags)
git -C /Users/lf/Projects/Pro/pdf.zig describe --tags                  # canonical version
python3 -c "from zpdf import Document"                                 # py-pdf-zig (may not be installed)
```

### Layer 2: End-to-end NDJSON

```bash
pdf.zig info --json hotel.pdf                       # one `meta` record
pdf.zig extract --pages 1 hotel.pdf | head -20      # first page; per-record flush observable
pdf.zig extract --pages 1 --output md hotel.pdf     # Markdown for visual sanity
echo '# Hello' | pdf.zig new -o /tmp/h.pdf -i -     # writer round-trip (PR-W5)
pdf.zig extract /tmp/h.pdf --output text            # confirm "Hello" survives the round-trip
```

### Layer 3: Performance smoke

```bash
# pdf.zig vs pymupdf4llm on the same fixture (per Week 5 bake-off methodology)
time pdf.zig extract corpus/sample.pdf --output md > /tmp/pdfzig.md
pip install pymupdf4llm 2>/dev/null
time python3 -c "import pymupdf4llm; print(pymupdf4llm.to_markdown('corpus/sample.pdf'))" > /tmp/pymupdf.md
diff <(wc -c < /tmp/pdfzig.md) <(wc -c < /tmp/pymupdf.md)
```

If pdf.zig output is < 50% of pymupdf4llm's char count on a non-trivial doc, suspect a CJK or image-text case (fall back to docling).

### Test suite

```bash
cd /Users/lf/Projects/Pro/pdf.zig
zig build test --summary all      # 1133/1133 expected (post-W6 series)
zig build alloc-failure-test       # FailingAllocator stress over parse paths
zig build fuzz                     # 11 targets × 1M iters (slow)
```

### Known cache trap

pdf.zig has no on-disk cache; each invocation re-parses the document. If repeated invocations are slow on the same file, parallelize at the shell level (`parallel -j 4 pdf.zig extract ::: *.pdf`) rather than expecting incremental speedups.

---

## Fragile Areas & Gotchas

### 1. Binary not on `$PATH`
- **Symptom**: `pdf.zig --version` errors with "command not found".
- **Cause**: pdf.zig may not be installed globally on every dev machine. The in-tree build lives at `/Users/lf/Projects/Pro/pdf.zig/zig-out/bin/pdf.zig`; nothing has been linked to `~/.local/bin` or `/usr/local/bin` by default.
- **Fix**: choose one:
  - **Brew tap (recommended for v1.0+)**: `brew tap laurentfabre/pdf.zig && brew install pdf.zig`.
  - **Pre-built release**: download from `github.com/laurentfabre/pdf.zig/releases`, extract, copy `bin/pdf.zig` to `~/.local/bin/`.
  - **Symlink the in-tree build**: `ln -s /Users/lf/Projects/Pro/pdf.zig/zig-out/bin/pdf.zig ~/.local/bin/pdf.zig` — quick-and-dirty; updates as you rebuild.

### 2. Zig version mismatch breaks the build
- **Symptom**: `zig build` errors with API drift or missing members.
- **Cause**: pdf.zig requires Zig 0.16.0; older versions (0.15.x) had `std.io`, `ArrayList.writer()`, `std.fs.cwd()`, and other APIs that have since moved.
- **Fix**: install Zig 0.16.0 and ensure `zig` on PATH resolves to it.

### 3. Version string lag
- **Symptom**: `pdf.zig --version` says `0.1.0-dev`; README and Git tag say `v1.0-rc2` / `v1.2-rc3+`.
- **Cause**: the build version literal hasn't been bumped to track the README + tags. The CLI is correct; the version literal is stale.
- **Fix**: cosmetic backlog. For now, `git -C /Users/lf/Projects/Pro/pdf.zig describe --tags` is the canonical version source.

### 4. NDJSON envelope mistaken for plain JSON
- **Symptom**: `jq .` over `pdf.zig extract` output fails with "trailing garbage".
- **Cause**: NDJSON is one JSON object per line, not a JSON array.
- **Fix**: `jq -c .`, or `jq --slurp .`, or stream with `jq -R 'fromjson?'`. Standard pattern: `pdf.zig extract foo.pdf | jq -c 'select(.kind == "page")'`.

### 5. Image-only PDF returns empty pages
- **Symptom**: `pdf.zig extract scan.pdf` returns `{"kind":"page","text":""}` for every page.
- **Cause**: PDF has no text layer, only embedded images. pdf.zig doesn't OCR.
- **Fix**: confirm with `pdftotext scan.pdf /dev/stdout | wc -c` (near-zero → image-only); fall back to `docling convert scan.pdf` (does layout + OCR via Granite).

### 6. CJK char parity gap
- **Symptom**: pdf.zig loses ~20% of CJK characters vs `pymupdf4llm` on the same doc.
- **Cause**: documented out-of-scope bucket per Week 5 bake-off (encoding edge cases in CMap parsing).
- **Fix**: for CJK-dominant docs where char parity matters, fall back to docling or `pymupdf4llm`.

### 7. Encrypted PDFs not supported
- **Symptom**: `pdf.zig extract encrypted.pdf` returns a fatal record with "encrypted: not supported".
- **Cause**: parser doesn't implement password-decrypt yet.
- **Fix**: `qpdf --password=PWD --decrypt encrypted.pdf decrypted.pdf`, then re-run `pdf.zig`. Or fall back to `pypdf` / `pdfplumber` (both support encryption).

### 8. SIGPIPE handling on truncated downstream
- **Symptom**: `pdf.zig extract huge.pdf | head -10` exits cleanly with no error — but the receiver only sees N records, not the expected pretty close.
- **Cause**: pdf.zig is **SIGPIPE-clean by design** — exits silently when the downstream closes the pipe. This is correct streaming behavior; no terminal record is emitted.
- **Fix**: don't expect a "stream closed cleanly" sentinel. If your pipeline needs to know the stream was complete (vs truncated), check the exit code or read all records.

### 9. `--max-tokens` is a chunker hint, not a cap on records
- **Symptom**: With `chunk --max-tokens 2000`, individual chunks occasionally exceed 2000 tokens.
- **Cause**: chunker respects logical boundaries (paragraph / section). When a paragraph alone exceeds the budget, it's emitted as a single oversized chunk rather than mid-sentence cut.
- **Fix**: post-process if your embedder has a hard cap; or accept the slight overflow.

### 10. `pdf.zig new` drops bytes outside printable ASCII
- **Symptom**: `echo "Café — résumé" | pdf.zig new -o out.pdf -i -`; the output has `Caf  rsum` (the `é` and em-dash bytes are gone).
- **Cause**: `drawText`'s WinAnsi filter accepts only `[0x20, 0x7e]` for Tier-1; non-ASCII bytes drop silently.
- **Fix**: pre-transliterate to ASCII (`iconv -f utf-8 -t ascii//TRANSLIT`), or fall back to `pandoc` for richer documents. Tier 2 (TrueType + UTF-8) is on the v2 roadmap.

### 11. `DocumentBuilder` is single-use after `write()`
- **Symptom**: Calling `addPage` / `setInfoDict` / etc. on a builder after `write()` returns `error.DocumentAlreadyWritten`.
- **Cause**: `write()` consumes the underlying `Writer` (resets object metadata via `finalize()`); the `written` flag prevents partial mutation that would emit a malformed PDF.
- **Fix**: build a fresh `DocumentBuilder` per output document. The single-use contract is explicit; don't try to reuse.

### 12. Writer aux-object failure-atomicity
- **Symptom**: An `addPage` / `addAuxiliaryObject` / `setInfoDict` call returns OOM mid-allocation; subsequent `write()` then fails with `error.DanglingObjectAllocation`.
- **Cause**: object numbers are reserved eagerly via `writer.allocObjectNum()`; if a later allocation in the same call fails, the writer holds a reservation but no payload. The contract is **discard the builder after any non-`DocumentAlreadyWritten` error**.
- **Fix**: on error, call `deinit` and start over. Don't retry the failed call on the poisoned builder.

### 13. Fork drift from upstream Lulzx/zpdf
- **Symptom**: A patch in upstream `Lulzx/zpdf` doesn't appear in pdf.zig.
- **Cause**: pdf.zig is a fork; upstream tracking is manual. Per README, pdf.zig's additions layer in `docs/`, `audit/`, `bake-off/`, `scripts/`, plus the v1.5 writer modules (`pdf_writer.zig`, `pdf_document.zig`, `markdown_to_pdf.zig`); upstream `src/` parser preserved as-is — but rebases don't happen automatically.
- **Fix**: check `git log -- src/` against upstream HEAD; cherry-pick or merge per `docs/decisions.md` policy.

### 14. py-pdf-zig import succeeds but C ABI mismatch crashes
- **Symptom**: `from zpdf import Document` works, but the first `Document(...)` constructor call segfaults.
- **Cause**: py-pdf-zig was compiled against a different C ABI than the currently-loaded shared library.
- **Fix**: `pip install --force-reinstall py-pdf-zig`, OR rebuild from `/Users/lf/Projects/Pro/pdf.zig/python/` against the local `pdf.zig` source.

---

## Defensive Programming Patterns

### Stream, never buffer the whole document
The architecture's value is per-page flush. Materializing all pages defeats it and brings memory back to `pymupdf4llm`-grade RAM use.

### Always handle `kind:"fatal"` terminal records
Production pipelines must filter for `{"kind":"fatal"}` records and surface them. They're the contract for parser death (no SIGABRT in release). Standard guard:
```bash
pdf.zig extract f.pdf | jq -c 'if .kind == "fatal" then halt_error(2) else . end'
```

### Type-tag NDJSON carries truth
Every record has a `kind` discriminator (`meta`, `page`, `chunk`, `toc`, `warning`, `fatal`, …). Pipelines that care should `jq 'select(.kind == "page")'` rather than assume.

### Use ReleaseSafe binaries, not ReleaseFast
Repo policy: ReleaseSafe in production, ReleaseFast for benchmarking only. Don't run a ReleaseFast binary against untrusted PDFs — fuzz-found edge cases assume safety checks.

### Pin to a known-good tag
The CLI's `--version` lags the README tag. Use `git describe --tags` in CI to track the canonical version. Don't deploy an unpinned `main`.

### Allocator discipline (Zig consumers)
Single GPA in `main()`, allocators passed down explicitly. `try` + `errdefer` for cleanup; `catch` blocks either recover meaningfully or re-raise. The repo's `defensive-programming conventions` (see `/Users/lf/Projects/Pro/CLAUDE.md`) are TigerStyle-shaped.

### Discard a `DocumentBuilder` after any error
The single-use contract + failure-atomicity contract together mean: after a non-`DocumentAlreadyWritten` error, call `deinit` and start over. Don't reattempt on the poisoned builder.

### Don't pipe OCR output back into pdf.zig
If you OCR an image-only PDF (via docling or tesseract), the output is text or Markdown, not a PDF. Don't try to re-encode and feed back; the OCR tool's output IS the extraction.

### Test against the Alfred corpus before claiming improvement
"0 crashes on Alfred's 1,776-PDF corpus" is the safety bar. Any change to the parser must re-validate against that corpus before merging.

### Check fork drift periodically
Upstream `Lulzx/zpdf` ships weekly. pdf.zig's `src/` mirrors upstream; quarterly `git log` comparisons catch drift before it accumulates.

---

## Working with Claude: Process to Follow

### When asked to read content from a PDF

1. **Probe first**: `pdf.zig info <file>` (or `info --json` for machine-readable). Confirms the PDF is parseable and gives page count.
2. **Default to NDJSON streaming** for LLM ingestion: `pdf.zig extract <file>`.
3. **Subset pages early** when only a section matters: `--pages "1-5"`.
4. **Switch to Markdown** for human review: `--output md`.
5. **If empty or near-empty pages**: probe whether it's image-only (`pdftotext <file> /dev/stdout | wc -c`); if yes, fall back to docling.
6. **If CJK char parity matters**: bake-off pdf.zig vs docling vs pymupdf4llm on a representative page; pick the tool that hits your char-parity bar.

### When asked to write a PDF from Markdown

1. **Default to the CLI**: `pdf.zig new -o out.pdf doc.md`. Tier-1 only — confirm the input is plain ASCII paragraphs/headings/lists.
2. **Programmatic in Zig** → `DocumentBuilder` + `PageBuilder` from `pdf_document.zig`. Use `setInfoDict`, `setCatalogExtras`, `addPage`, `drawText` for the standard surface. For aux objects with cyclic refs, use `reserveAuxiliaryObject` + `setAuxiliaryPayload`.
3. **Need bold/italic/code/tables/images** → fall back to `pandoc` + `wkhtmltopdf` / `weasyprint`. pdf.zig's writer is Tier-1 by design.
4. **Need compressed output** → set `compress_content_streams = true` on `DocumentBuilder` (PR-W4, Zig API only — the CLI doesn't expose a flag yet). Only streams > 256 bytes are compressed.

### When asked "is pdf.zig installed?"

```bash
which pdf.zig                                            # global install
ls /Users/lf/Projects/Pro/pdf.zig/zig-out/bin/pdf.zig   # in-tree build
git -C /Users/lf/Projects/Pro/pdf.zig describe --tags   # canonical version
```

### Discovery before action

```bash
# Confirm parseability + metadata
pdf.zig info <file>

# Smallest possible probe (page 1 only)
pdf.zig extract --pages 1 <file>

# Identify image-only docs (zero text layer)
pdftotext <file> /dev/stdout | wc -c     # near-zero → image-only → docling
```

---

## Quick Reference Commands

### Read (the 80% case)
```bash
pdf.zig extract hotel.pdf                                   # default ndjson
pdf.zig extract --output md hotel.pdf > hotel.md            # Markdown
pdf.zig extract --output text hotel.pdf                     # plain text
pdf.zig extract --output chunks --max-tokens 2000 hotel.pdf # embedding chunks
pdf.zig extract --pages 1-10 hotel.pdf                      # subset
pdf.zig chunk hotel.pdf --max-tokens 2000                   # alias
pdf.zig info hotel.pdf                                      # human-readable metadata
pdf.zig info --json hotel.pdf                               # NDJSON meta
```

### Write (Markdown → PDF, Tier-1)
```bash
pdf.zig new -o out.pdf doc.md                               # positional input
pdf.zig new -o out.pdf -i doc.md                            # explicit -i flag
echo "# Hello" | pdf.zig new -o out.pdf -i -                # stdin
```

### Inspect / version
```bash
pdf.zig --help
pdf.zig --version                                           # 0.1.0-dev (lags README tag)
git -C /Users/lf/Projects/Pro/pdf.zig describe --tags
```

### Python
```python
from zpdf import Document
doc = Document("hotel.pdf")
for i in range(doc.page_count):
    print(doc.extract_page(i))
```

### Build / upgrade
```bash
brew tap laurentfabre/pdf.zig && brew install pdf.zig       # recommended
brew upgrade pdf.zig
# Or build from source:
cd /Users/lf/Projects/Pro/pdf.zig && zig build -Doptimize=ReleaseSafe
sudo install -m 755 zig-out/bin/pdf.zig /usr/local/bin/
```

### Run the test suite
```bash
cd /Users/lf/Projects/Pro/pdf.zig
zig build test --summary all  # 1133/1133
zig build alloc-failure-test
zig build fuzz                # 11 targets × 1M iters
```

### Fallback (docling)
```bash
pip install docling                                         # ~2 GB; install only when needed
docling convert scanned.pdf -o scanned.md                   # layout + OCR
```

### Fallback (qpdf for encrypted)
```bash
qpdf --password=PWD --decrypt encrypted.pdf decrypted.pdf
pdf.zig extract decrypted.pdf
```

---

## Questions to Ask When Starting Work

1. **Read or write?** Reads are pdf.zig by default. Writes (Markdown → PDF) are Tier-1 only via `pdf.zig new` or `DocumentBuilder`.
2. **Does this PDF have a text layer?** `pdftotext` returns near-zero bytes → image-only → docling.
3. **Is it CJK-dominant?** Char parity bake-off; fall back if needed.
4. **Need layout / tables / reading order on an untagged PDF?** Out of scope; docling.
5. **Is it encrypted?** `qpdf --decrypt` first, or use `pypdf`.
6. **What's the consumer?** LLM stream → ndjson; human → md; embedder → chunks; grep → text.
7. **For writes: ASCII only?** If no, fall back to pandoc; pdf.zig's writer is Tier-1.
8. **Is pdf.zig actually on `$PATH`?** Verify with `which pdf.zig`; if not, the in-tree build at `/Users/lf/Projects/Pro/pdf.zig/zig-out/bin/pdf.zig` is the authority.

---

## Anti-patterns (don't do these)

- **Default to `pymupdf4llm` for reads** — pdf.zig replaces it for new pipelines per the Alfred bake-off (121× faster, 78.9% char parity).
- **Buffer the entire NDJSON output** before parsing — defeats the streaming architecture.
- **Run a ReleaseFast binary against untrusted PDFs** — quality bar assumes ReleaseSafe.
- **Forget that `--version` lags the README tag** — use `git describe`.
- **Install docling preemptively** — ~2 GB; install only when a fallback case surfaces.
- **Ignore terminal `kind:"fatal"` records** — they're how parser death is reported in release.
- **Use a pre-0.16.0 `zig` binary for the build** — pdf.zig requires Zig 0.16.0; older stdlib APIs (`std.io`, `ArrayList.writer()`, `std.fs.cwd()`) were removed.
- **Mutate a parsed `Document`** — it's read-only; build a fresh one via `DocumentBuilder`.
- **Reuse a `DocumentBuilder` after `write()`** — single-use; build fresh per output.
- **Pass non-ASCII to `pdf.zig new`** — bytes drop silently; transliterate first or use pandoc.
- **Expect compressed output from `pdf.zig new` by default** — compression is opt-in via `compress_content_streams: true` on `DocumentBuilder` (PR-W4); the CLI does not yet expose a flag.
- **Pipe `pdf.zig extract` into `pdf.zig new`** — the modes don't roundtrip; extract gives Markdown, new takes Markdown, but the writer is Tier-1 only and would lose all formatting/structure.

---

## Closing rule

When in doubt, run `pdf.zig --help`, then `pdf.zig info <file>`. The first tells you what's possible; the second tells you whether the document is parseable. If `info` succeeds but `extract` returns empty pages, it's image-only — fall back to docling. If `info` itself fails, the PDF is malformed beyond xref repair; try `qpdf --linearize` first, then re-run. For writes, if Tier-1 (ASCII paragraphs/headings/lists) doesn't fit, reach for pandoc — pdf.zig's writer is the seed of a greenfield stack, not yet a full Markdown→PDF engine.
