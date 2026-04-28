---
title: "pdf.zig — Roadmap"
project: pdf.zig
status: active
current: v1.2-rc3
next: v1.2-rc4
default_branch: main
toolchain: zig 0.15.2
loop:
  pick: "/next-pr"
  review_fix: "/pr-cycle"
  review_only: "/repo-review for current PR"
tags:
  - project/pdf-zig
  - kind/roadmap
  - methodology/claude-codex-loop
aliases:
  - "pdf.zig roadmap"
created: 2026-04-27
updated: 2026-04-27
---

> [!abstract] What this file is
> The single source of truth for *future* PRs in pdf.zig. Every `- [ ]` checkbox below is one PR. `/next-pr` picks the first unchecked item in document order; `/pr-cycle` round-trips it through Codex review and fix.

> [!info]+ The Claude ↔ Codex loop this roadmap is sized for
> ```mermaid
> %%{init: {'theme': 'base', 'themeVariables': {'primaryColor': '#1a1a2e', 'primaryTextColor': '#e0e0e0', 'primaryBorderColor': '#00d4ff', 'lineColor': '#00d4ff', 'secondaryColor': '#16213e', 'tertiaryColor': '#0f3460', 'fontFamily': 'monospace'}}}%%
> sequenceDiagram
>   actor LF as Laurent
>   participant CC as Claude Code
>   participant GH as GitHub
>   participant CX as Codex CLI
>   LF->>CC: /next-pr
>   CC->>CC: parse this ROADMAP.md, pick first `[ ]`
>   CC->>GH: gh pr create --draft (after confirm)
>   CC-->>LF: PR URL
>   LF->>CC: implement the work
>   CC->>CC: edits + tests
>   LF->>CC: /pr-cycle
>   CC->>CX: codex review --base <base>
>   CX-->>CC: CODE_REVIEW.md (PR-scoped findings)
>   CC->>CC: filter to PR_FILES, plan, confirm, implement fixes
>   CC->>CC: zig build test gate after each fix
>   LF->>GH: gh pr merge (after final review)
>   LF->>CC: tick the box here, /next-pr
> ```

> [!tip]+ PR-shape contract (one per checkbox)
> Every `- [ ]` PR below is sized to be **a single Codex-reviewable diff against `main`**:
> - **One concrete deliverable** (not "improve X")
> - **Explicit acceptance gate** with file paths, test names, or metric thresholds
> - **Files-touched envelope** named so `/pr-cycle`'s scope filter is unambiguous
> - **Test strategy** named (existing test file + new tests added)
> - **Baseline measured** (current behaviour or current metric)
>
> A PR that fails the contract lives under `## Parking lot` until it's decomposed.

---

## v1.2-rc4 — closing Codex `[P2 deferred]` items

- [x] **PR-1 · feat: Form XObject `Do` recursion in lattice Pass B** (merged in `4e66f15`, 2026-04-28; 26 commits, 21 Codex review rounds, 23 P2 + 1 P3 findings folded)
  > [!info]- Details
  > **Why.** `[[PROJECT-LOG#v1.2-rc2]]` Codex finding #6 (deferred from rc1 review) — ruled tables drawn inside `Do`-referenced templates are currently invisible to lattice detection.
  > **Files-touched envelope.** `src/lattice.zig` (primary), `src/parser.zig` (resource lookup helper), `src/integration_test.zig` (new test).
  > **Acceptance gate.**
  > - Lattice detector recurses through `Do` operator into `XObject` resource streams; resource-aware path tracker keeps each XObject's CTM stack isolated.
  > - New fixture `audit/tables-gold/form-xobject-table.pdf` (synth: a ruled 3×3 table inside a Form XObject `Do`-referenced template) — Pass B detects it; bbox in user-space matches gold within ±2 pt.
  > - No regression on the 5-table seed gold set (TEDS-Struct ≥ 0.777, GriTS_Con ≥ 0.679).
  > - No new ReleaseSafe panics on `audit/week4_corpus_run.py` n=40 corpus.
  >
  > **Test strategy.** Add `integration_test.zig` case `lattice_pass_b_recurses_form_xobject`; rerun `audit/v1_2_eval.py`.
  > **Codex gate (`/pr-cycle`).** Findings expected on: CTM stacking correctness, infinite-recursion guard, Resources dictionary `null`-handling.

- [ ] **PR-2 · feat: continuation-link bbox-y constraint**
  > [!info]- Details
  > **Why.** `[[PROJECT-LOG#v1.2-rc3]]` follow-up — current ±1 col rule has false positives (two unrelated price tables on consecutive pages).
  > **Files-touched envelope.** `src/tables.zig::linkContinuations` (primary), `src/integration_test.zig`.
  > **Acceptance gate.**
  > - Add "table_a near bottom of page (`bbox.y1 > media_box.y - 0.20·height`) AND table_b near top of next page (`bbox.y0 < media_box.y0 + 0.20·height`)" via `Document.pages.items[i].media_box`.
  > - False-positive case fixture `audit/tables-gold/two-unrelated-tables.pdf`: no link.
  > - True-positive case fixture (existing 4-page Anantara spa price list): link end-to-end preserved.
  > - No regression on 5-table seed gold set.
  >
  > **Test strategy.** Two new integration_test cases; rerun `audit/v1_2_eval.py`.
  > **Codex gate.** `media_box` access on pages without explicit `/MediaBox`; threshold not over-tuned to one fixture.

- [x] **PR-3 · feat: Pass A cell text via MCID-to-bbox lookup** (merged in `483fda0`, 2026-04-28; 10 commits, 7 Codex review rounds, 1 P1 + 6 P2 findings folded; switched from bbox-intersection to direct text-by-MCID lookup)
  > [!info]- Details
  > **Files-touched envelope.** `src/structtree.zig` (expose per-MCID bbox), `src/tables.zig` (consume), `src/integration_test.zig`.
  > **Acceptance gate.**
  > - Upstream `MarkedContentExtractor` exposes a `getMcidBoundingBox(page_idx, mcid) ?Rect` API.
  > - `tables.zig` Pass A `extractCellText(td)` walks `td.MCIDs` → bbox lookup → glyph spans intersecting bbox → text concatenation.
  > - On synthetic tagged PDF with 2×3 table, every cell text matches gold exactly.
  > - 35 existing `src/tables.zig` unit tests still pass.
  >
  > **Test strategy.** New integration_test `tagged_table_extracts_cell_text`. Add fixture `audit/tables-gold/tagged-2x3.pdf`.
  > **Codex gate.** Allocator threading through new API; behaviour when MCID maps to multiple non-contiguous bboxes (legal per PDF/UA).

- [ ] **PR-4 · feat: Pass B cell text via glyph-center ∩ cell-bbox**
  > [!info]- Details
  > **Files-touched envelope.** `src/lattice.zig::buildCellsWithText` (new, mirrors `stream_table.zig`), `src/integration_test.zig`.
  > **Acceptance gate.**
  > - Pass B emits per-cell `text` field (or `null` when empty) using `extractTextWithBounds` spans whose glyph centers fall inside the cell bbox.
  > - On `audit/tables-gold/anantara-spa-page-2.pdf` ruled 4×3 table, all 12 cells match gold text within edit-distance ≤ 2.
  > - NDJSON `kind:"table"` schema unchanged (cells already optional).
  >
  > **Test strategy.** Reuse the rc3 `buildCellsWithText` test pattern.
  > **Codex gate.** Glyph-center vs glyph-bbox-overlap policy consistent with Pass C.

- [ ] **PR-5 · data: gold-set fill 5 → 120 tables / 50 PDFs**
  > [!info]- Details
  > **Why.** v1.2 dataset infrastructure (already scaffolded in v1.0.1) needs population for v1.2 GA gating.
  > **Files-touched envelope.** `audit/tables-gold/*.json` (annotations only), `audit/tables-gold/INDEX.md` (new index). No code change in `src/`.
  > **Acceptance gate.**
  > - 50 PDFs annotated via `audit/v1_2_annotate.py` (TUI), distributed across 6 strata (ruled-price / unruled-menu / dining-list / spa-price / factsheet / mixed).
  > - ≥ 120 unique table annotations total (avg 2.4 per PDF).
  > - `audit/v1_2_eval.py` runs against the new gold set and produces a per-stratum TEDS-Struct + GriTS_Con report.
  >
  > **Test strategy.** Data-only PR. `audit/v1_2_eval.py --gold-set audit/tables-gold/` smoke run validates JSON schema.
  > **Codex gate.** Annotation schema consistency; sample-check 10/50 PDFs for annotator drift (Codex reads gold + PDF text, flags disagreements).

---

## v1.2 GA — corpus regression + perf + strict alloc

- [ ] **PR-6 · feat: PubTables-1M sanity subset materialised**
  > [!info]- Details
  > **Files-touched envelope.** `audit/v1_2_pubtables_subset.py` (existing), `audit/pubtables_subset/` (data dir, `.gitignore`'d), `audit/v1_2_pubtables_run.py` (new harness), `.github/workflows/pubtables-weekly.yml` (manual trigger only).
  > **Acceptance gate.**
  > - Stratified subset of 200 PDFs from PubTables-1M (HF `datasets` streaming, ~70 GB → 200 sampled PDFs ≈ 50 MB).
  > - `audit/v1_2_pubtables_run.py` emits `audit/pubtables_results.tsv` with TEDS-Struct ≥ 0.70 mean.
  > - Run completes in ≤ 5 min on aarch64-macos.
  >
  > **Test strategy.** New harness; no `src/` changes.
  > **Codex gate.** HF auth handling; partial-download resume; subset stratification reproducibility (seeded).

- [ ] **PR-7 · feat: FinTabNet numeric / currency subset materialised**
  > [!info]- Details
  > **Files-touched envelope.** `audit/v1_2_fintabnet_subset.py` (existing), `audit/fintabnet_subset/`, `audit/v1_2_fintabnet_run.py`, `src/stream_table.zig` (1 unit test).
  > **Acceptance gate.**
  > - 100 PDFs sampled from IBM mirror (~700 MB total).
  > - Extraction TEDS-Struct ≥ 0.65 mean (lower than PubTables — financial tables have heavy currency / negative-number formatting).
  > - Currency-formatting regression test: cells matching `^[€$£¥]?\s*-?\d+([.,]\d+)*$` extracted byte-identical.
  >
  > **Test strategy.** New harness + 5-cell currency-format unit test in `src/stream_table.zig`.
  > **Codex gate.** Regex isn't over-permissive; IBM mirror URL freshness.

- [ ] **PR-8 · perf: Pass B+C early-out for table-free pages**
  > [!info]- Details
  > **Why.** `[[PROJECT-LOG#🗺️ Roadmap]]` v1.2 GA performance regression — pdf.zig 2.2 s vs upstream zpdf 1.3 s on n=40.
  > **Files-touched envelope.** `src/tables.zig::getTables` (dispatcher), `src/lattice.zig::collectStrokes` (early-out), `src/stream_table.zig::collectAnchors` (early-out), `bench/bench.zig`.
  > **Acceptance gate.**
  > - Pass B early-out when `collectStrokes` yields 0 horizontal *and* 0 vertical strokes.
  > - Pass C early-out when histogram has < 3 bins with ≥ 50 % row coverage.
  > - On `audit/week4_corpus_run.py` n=40 corpus: pdf.zig wall-clock ≤ 1.5 s (vs 2.2 s baseline) — within 15 % of upstream zpdf.
  > - No regression on 5-table seed gold set.
  >
  > **Test strategy.** `bench/bench.zig` regression check + corpus run + gold-set re-eval.
  > **Codex gate.** Early-out doesn't trigger on edge cases (single-row tables, 2-column tables); no perf regression on PDFs with strokes-but-no-table.

- [ ] **PR-9 · refactor: strict-mode `checkAllAllocationFailures`**
  > [!info]- Details
  > **Why.** `[[PROJECT-LOG#🛡️ Defensive-programming alignment]]` §3.4 (currently shape-level — leak-shape asserted, not fixed).
  > **Files-touched envelope.** `src/alloc_failure_test.zig` (primary), `audit/fuzz_findings.md` (close findings 001–003), upstream `src/parser.zig` / `src/root.zig` (`errdefer` fixes — IF needed).
  > **Acceptance gate.**
  > - `zig build alloc-failure-test` no longer asserts the leak shape — flips to "must NOT leak".
  > - Findings 001–003 in `audit/fuzz_findings.md` marked `RESOLVED` with the fix commit SHA.
  > - n=40 corpus run under `DebugAllocator`'s leak checker: 0 leaks reported.
  > - All 162 unit tests green.
  >
  > **Test strategy.** Existing `alloc_failure_test.zig` + new "n=40 corpus under DebugAllocator" smoke run.
  > **Codex gate.** `errdefer` placement on every new `try` site; no double-free (paired `errdefer` + `defer`); leak fixed not masked.

- [ ] **PR-10 · release: cycle-11 bake-off rerun + v1.2 GA tag**
  > [!info]- Details
  > **Files-touched envelope.** `audit/week11_bakeoff.py` (new harness, copy of `week6_5`), `docs/v1.2-ga-audit.md` (new), `docs/PROJECT-LOG.md` (add v1.2 GA section).
  > **Acceptance gate.**
  > - Bake-off vs `pymupdf4llm` AND Docling on Alfred table-rich subset (≥ 30 PDFs with ≥ 1 ground-truth table each).
  > - pdf.zig TEDS-Struct mean ≥ docling within ±0.05 (or document the gap as a known v1.3 item).
  > - Speedup vs `pymupdf4llm` ≥ 50× on table-rich subset.
  > - All v1.2-rc4 + v1.2 GA PRs merged.
  > - `git tag v1.2` + GH release built via existing `release.yml`.
  > - Brew tap auto-bump fires (existing `brew-tap-bump.yml`).
  >
  > **Test strategy.** Bake-off harness + manual release verification.
  > **Codex gate.** Final whole-repo `/repo-review` *before* tagging — last chance to catch GA-blockers like the U+0085 incident in v1.0.

---

## v1.3 — OCR shell-out (closes NG4 image-text bucket)

- [ ] **PR-11 · feat: scanned-PDF detection (`quality_flag:"scanned"`)**
  > [!info]- Details
  > **Files-touched envelope.** `src/cli_pdfzig.zig` (heuristic + summary record), `src/stream.zig` (new `quality_flag` field on `summary`), `src/integration_test.zig`.
  > **Acceptance gate.**
  > - Heuristic: page where `Document.extractText` produces < 50 bytes AND `Document.info().fonts.len > 0` AND `pageCount() > 0` ⇒ flag scanned.
  > - `kind:"summary"` NDJSON record gains `"quality_flag":"scanned"` when ≥ 50 % of pages flagged.
  > - Test fixture `audit/scanned-pdfs/scanned-1.pdf` (Babylonstoren breakfast NG4 case) → flag emitted.
  > - Born-digital fixture `audit/sample/born-digital.pdf` → no flag.
  >
  > **Test strategy.** New integration_test case + 2 fixtures.
  > **Codex gate.** Heuristic doesn't false-flag PDFs with very-short pages (cover pages with 1 word); threshold tunable via `--scan-threshold`.

- [ ] **PR-12 · feat: `ocrmypdf` shell-out path**
  > [!info]- Details
  > **Files-touched envelope.** `src/cli_pdfzig.zig` (`--ocr=auto|on|off` flag, `std.process.Child.run`), `src/integration_test.zig`, README.md.
  > **Acceptance gate.**
  > - When `quality_flag:"scanned"` AND `--ocr=auto` (default), shell out to `ocrmypdf` if on `$PATH`.
  > - Invocation: `ocrmypdf --skip-text --output-type pdf --quiet <input> -` (path or stdin → stdout searchable PDF).
  > - pdf.zig re-opens the OCR'd output and re-emits NDJSON page records.
  > - If `ocrmypdf` not installed, emit `kind:"warning"` `"ocr_unavailable: ocrmypdf not on PATH"` and continue.
  > - `--ocr=off` short-circuits the heuristic.
  >
  > **Test strategy.** Tag CI test `requires_ocrmypdf`; skip on lanes without it.
  > **Codex gate.** Shell-out args use `argv[]` (no injection); timeout on long OCR jobs; stderr capture.

- [ ] **PR-13 · feat: `tesseract`-only fallback when `ocrmypdf` missing**
  > [!info]- Details
  > **Files-touched envelope.** `src/cli_pdfzig.zig` (fallback branch).
  > **Acceptance gate.**
  > - When `ocrmypdf` not on `$PATH` but `tesseract` is, render each scanned page (`mutool draw` if available, else built-in min-render) and pipe to `tesseract -`.
  > - Quality is degraded vs `ocrmypdf` (no OSD, no language detection); README documents this.
  > - When NEITHER tool is available, emit `quality_flag:"scanned_unprocessed"` and skip OCR.
  >
  > **Test strategy.** Two CI lanes: one with both tools, one with neither.
  > **Codex gate.** Rendering path doesn't introduce a heavy dep footprint; fallback is honestly worse (otherwise `ocrmypdf` is moot).

---

## v1.4 — incremental quality

- [ ] **PR-14 · feat: encrypted-with-empty-password retry**
  > [!info]- Details
  > **Files-touched envelope.** `src/cli_pdfzig.zig` (retry path), upstream `src/main.zig` (probe API), `src/integration_test.zig`.
  > **Acceptance gate.**
  > - On `error.PasswordRequired` from `Document.open`, retry once with empty password `""`.
  > - On 2nd failure, emit `kind:"fatal"` with `"error":"encrypted: password required"` (existing v1.0 behaviour preserved).
  > - Test fixture `audit/encrypted-empty-password.pdf` → extraction succeeds.
  > - Test fixture `audit/encrypted-real-password.pdf` → fatal record emitted.
  >
  > **Test strategy.** Two fixtures + integration test.
  > **Codex gate.** No infinite-loop cascade; correct error-code propagation.

- [ ] **PR-15 · feat: CJK extraction quality + corpus test**
  > [!info]- Details
  > **Files-touched envelope.** Audit-only PR — `audit/cjk_subset.py`, `audit/cjk-pdfs/`, `audit/v1_4_cjk_run.py`, possibly `src/encoding.zig` regressions.
  > **Acceptance gate.**
  > - 30-PDF CJK corpus materialised (10 ja, 10 zh, 10 ko).
  > - ≥ 95 % byte-identical text vs `pymupdf4llm` reference for non-vertical writing.
  > - Vertical-writing CJK extraction known-broken — emit `kind:"warning"` `"vertical_writing_unsupported"`.
  > - Document gap in [[architecture]] §9 case #10 update.
  >
  > **Test strategy.** New corpus harness; if encoding regressions surface, scope follow-up `v1.4.1` PR.
  > **Codex gate.** 95 % threshold honest (not gamed by stripping); CJK-specific edge cases (full-width punctuation, ruby annotations).

- [ ] **PR-16 · feat: Bidi (Arabic / Hebrew) — proper logical-order pass**
  > [!info]- Details
  > **Why.** Architecture §9 case #10 (currently emit-as-is + warn).
  > **Files-touched envelope.** `src/encoding.zig` or new `src/bidi.zig`, `src/integration_test.zig`.
  > **Acceptance gate.**
  > - Implement Unicode Bidirectional Algorithm (UAX #9) Level 1 (no embeddings).
  > - Test fixtures: 1 Arabic PDF (Banyan-Tree-Mayakoba MICE Arabic page), 1 Hebrew PDF (synthetic).
  > - Extracted text matches `pymupdf4llm` output character-for-character on test fixtures (post-bidi reorder).
  > - `bidi-untreated` warning replaced with `bidi-applied` info record.
  >
  > **Test strategy.** Two fixtures, integration test, char-level diff vs pymupdf4llm reference.
  > **Codex gate.** UAX #9 conformance against public test suite (`BidiTest.txt`); digit handling (Arabic-Indic vs European). **Highest-complexity PR in the roadmap.**

- [ ] **PR-17 · feat: `kind:"section"` long-PDF checkpoint records**
  > [!info]- Details
  > **Why.** Codex minor #9 in `[[week7-ga-audit]]`.
  > **Files-touched envelope.** `src/stream.zig` (new record kind), `src/cli_pdfzig.zig` (emission), `src/integration_test.zig`.
  > **Acceptance gate.**
  > - New `"section"` record `{section_id, title, start_page, end_page}` emitted at section boundaries (heuristic: `# ` markdown headers in extracted text).
  > - On `audit/tables-gold/lvmh-rse-162-page.pdf`, ≥ 5 `section` records emitted.
  > - No regression on existing record kinds.
  >
  > **Test strategy.** Existing fixture + new test.
  > **Codex gate.** No false-trigger on inline `# ` characters in PDF text; ordering vs page records.

- [ ] **PR-18 · feat: citation-grade `--bboxes` flag (`spans:[]` per page)**
  > [!info]- Details
  > **Files-touched envelope.** `src/cli_pdfzig.zig` (flag + emission), `src/stream.zig` (extend `page` record schema), `src/integration_test.zig`, README.
  > **Acceptance gate.**
  > - `--bboxes` flag adds parallel `spans:[{text, bbox:[x0,y0,x1,y1], font_size, font_name}]` array on `kind:"page"` record.
  > - Bbox in PDF user-space (1/72 inch); origin bottom-left.
  > - Round-trip: `Document.extractText` between `bbox` produces same text byte-for-byte.
  > - Off by default (~30 % record-size hit when on).
  >
  > **Test strategy.** New integration_test `bboxes_round_trip`.
  > **Codex gate.** Schema is consumer-friendly (parallel array, not nested); flag-off keeps zero overhead.

- [ ] **PR-19 · feat: image extraction (`kind:"image"`)**
  > [!info]- Details
  > **Files-touched envelope.** `src/cli_pdfzig.zig` (flag + emission), `src/stream.zig` (new record kind), `src/integration_test.zig`, upstream `src/parser.zig` (image XObject access).
  > **Acceptance gate.**
  > - `--images` flag emits `kind:"image"` `{page, bbox, width_px, height_px, encoding}` (no payload by default).
  > - `--images=base64` adds `payload_b64`.
  > - `--images=path` extracts to `<output_dir>/<doc_id>-<page>-<image_id>.png` and emits `path` field.
  > - On `audit/sample/with-images.pdf`, all images detected.
  >
  > **Test strategy.** Three integration tests (one per mode).
  > **Codex gate.** Base64 payload doesn't break NDJSON line-buffering on multi-MB images (cap or stream-as-array); path-mode doesn't escape the output dir.

- [ ] **PR-20 · feat: annotation extraction (non-link)**
  > [!info]- Details
  > **Files-touched envelope.** `src/cli_pdfzig.zig`, `src/stream.zig` (new `annotations` kind), upstream parser glue.
  > **Acceptance gate.**
  > - `kind:"annotations"` per-page record `[{type:"text|highlight|underline|strikeout|ink", rect, contents, author?, modified?}]`.
  > - Test fixture `audit/sample/annotated.pdf` → 4 annotations of different types extracted.
  > - Existing `kind:"links"` record unchanged.
  >
  > **Test strategy.** Single fixture, single integration test.
  > **Codex gate.** Schema covers PDF spec annotation types correctly; timestamps ISO-8601 (PDF dates are not).

- [ ] **PR-21 · feat: PDF/UA structure-tree NDJSON output**
  > [!info]- Details
  > **Files-touched envelope.** `src/structtree.zig` (new emission helper), `src/cli_pdfzig.zig` (`--struct-tree` flag), `src/integration_test.zig`.
  > **Acceptance gate.**
  > - `--struct-tree` emits `kind:"struct_tree"` per-document record with the full `/StructTreeRoot` walk as a JSON tree (`type`, `children[]`, `mcid_refs[]`, optional `lang`, `alt`).
  > - On a tagged PDF/UA-conformant fixture (e.g. LVMH RSE), tree depth and node count match `qpdf --json-output --json-key=structtree` reference within ±5 %.
  > - Off by default (large records).
  >
  > **Test strategy.** Reference comparison against `qpdf` output.
  > **Codex gate.** Tree serialization uses bounded recursion (no stack blow-up on adversarial trees); `lang`/`alt` escaped.

---

## v2.0 — full PDF/UA conformance (placeholders, decompose before use)

> [!warning] These two are intentionally too large for `/next-pr`
> Listed without checkboxes so the picker skips them. Decompose into ≤ 1-day sub-PRs (each with its own `- [ ]`) once v1.4 closes.

- **PR-22 · placeholder: full PDF/UA-1 conformance (validator pass)** — needs decomposition into ≥ 5 sub-PRs (role mapping, marked-content fixes, lang propagation, alt-text validation, `qpdf --check` pass).
- **PR-23 · placeholder: accessibility-tree output (`kind:"a11y_tree"`)** — depends on PR-21 + PR-22 sub-PRs.

---

## Parking lot

> [!fail]+ NOT eligible for `/next-pr`
> These violate the PR-shape contract (too vague, too cross-cutting, or missing measurable acceptance gates). Decompose before promoting above the divider.

- DOCX / EPUB output formats — design needed; `--output {ndjson,md,docx,epub}` matrix interaction with chunking/streaming
- Real-time streaming over WebSocket — protocol design needed; not aligned with current pipe-first model
- WASM target re-validation post-v1.0 — upstream `src/wapi.zig` exists but hasn't been exercised since the fork; needs a sample bundle
- Cloud-native deployment (Lambda layer / Docker image) — packaging exercise, low-novelty
- GUI — explicitly out of scope; pdf.zig is a CLI

---

## How to add a new PR here

1. Add `- [ ] **PR-N · kind: title**` under the right milestone heading (kind ∈ `feat`/`fix`/`perf`/`refactor`/`docs`/`test`/`chore`/`data`/`release`).
2. Inside that bullet, add a `> [!info]- Details` callout with: **Why**, **Files-touched envelope**, **Acceptance gate**, **Test strategy**, **Codex gate**.
3. Run `/next-pr` — picks the first `[ ]` checkbox in document order. The branch prefix (`feat/`, `fix/`, etc.) is auto-inferred from your title.
4. After merge, change `[ ]` → `[x]` and append `(merged in <SHA>, <date>)` at the end of the bullet line.
5. If a PR spawns a follow-up, add a new entry below — never extend the original past its `merged` line.

> [!quote] The contract restated
> Every checkbox above the **v2.0 placeholders** divider is reachable via `/next-pr → /pr-cycle → tag`. If a PR isn't reviewable in one Codex pass against `main`, it doesn't belong here yet — park it.

---

## Tags
#project/pdf-zig #kind/roadmap #methodology/claude-codex-loop
