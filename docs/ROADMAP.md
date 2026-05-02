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

- [x] **PR-2 · feat: continuation-link bbox-y constraint** (merged in `97c53bd`, 2026-04-28; 3 commits, Codex converged round 1, 0 findings; ROADMAP entry's bbox.y inversion fixed in implementation)
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

- [x] **PR-4 · feat: Pass B cell text via glyph-center ∩ cell-bbox**
  > [!info]- Details
  > **Files-touched envelope.** `src/lattice.zig::buildCellsWithText` (new, mirrors `stream_table.zig`), `src/integration_test.zig`.
  > **Acceptance gate.**
  > - Pass B emits per-cell `text` field (or `null` when empty) using `extractTextWithBounds` spans whose glyph centers fall inside the cell bbox.
  > - On `audit/tables-gold/anantara-spa-page-2.pdf` ruled 4×3 table, all 12 cells match gold text within edit-distance ≤ 2.
  > - NDJSON `kind:"table"` schema unchanged (cells already optional).
  >
  > **Test strategy.** Reuse the rc3 `buildCellsWithText` test pattern.
  > **Codex gate.** Glyph-center vs glyph-bbox-overlap policy consistent with Pass C.

- [x] **PR-4b · fix: stream_table.zig leak/double-free shapes mirroring PR-4 lattice fixes**
  > [!info]- Details
  > **Why.** Codex review on PR-4 round 2 [P2] flagged that `stream_table.extractFromSpans` carries the same three leak/double-free shapes that PR-4 fixed in `lattice.zig`: outer errdefer frees only `t.cells` (not per-cell `text`); `buildCellsWithText` has the partial-success `toOwnedSlice` leak shape; `try out.append` can fail after `cells` has been built but before ownership reaches `out`. Out of PR-4's diff scope.
  > **Files-touched envelope.** `src/stream_table.zig` (errdefer + ownership-flag mirror of PR-4).
  > **Acceptance gate.**
  > - `extractFromSpans` outer errdefer frees per-cell `text` before `t.cells`.
  > - `buildCellsWithText` has `cells_initialised` errdefer cleanup.
  > - `cells_owned` flag guards `out.append`.
  > - New FailingAllocator unit test for `extractFromSpans` covers the early alloc-failure indices (0..15) for all five fixed surfaces. The full 0..127 sweep is gated on PR-4d (separate `buildCellsWithText` `bufs.deinit` issue) — see PR-4d entry.
  >
  > **Test strategy.** Mirror `lattice.zig` "extractFromStrokes survives every allocation failure index".
  > **Codex gate.** Verify R5 P2 finding from PR-4 round-2 review is fully resolved.

- [x] **PR-4d · fix: stream_table.zig late-fail allocation paths (buildCellsWithText bufs)**
  > [!info]- Details
  > **Why.** PR-4b fixed the three R5 leak shapes (extractFromSpans outer errdefer, buildCellsWithText cells_initialised, cells_owned around out.append) plus uncovered pre-existing fixes in groupIntoRows (span_slice ownership, sorted_owned) and findColumnAnchors (peaks_owned). The new FailingAllocator stress passes indices 0..15 cleanly, but indices ≥16 still trigger an integer-overflow panic from inside `buildCellsWithText`'s `bufs.deinit` errdefer when `bufs[idx].appendSlice` fails after some bufs grew. Suspected ArrayList / DebugAllocator interaction or an additional ownership transfer that needs guarding.
  > **Files-touched envelope.** `src/stream_table.zig` (buildCellsWithText) + `src/lattice.zig` (parallel latent fix in buildLatticeCellsWithText), test bound bumped from 16 → 128.
  > **Acceptance gate.**
  > - `test "extractFromSpans survives every allocation failure index"` passes for `fail_index < 128`.
  > - No regression in current 405/405 tests.
  >
  > **Test strategy.** Bump bound + observe no panic + no leak.

- [x] **PR-9b · fix: ContentLexer OOM swallowing in scanString/scanHexString**
  > [!info]- Details
  > **Why.** Codex review on PR-9 round 1 [P2] flagged that `ContentLexer.next` calls non-erroring `scanString` / `scanHexString` which themselves use `appendByte` / `finalizeBuf` that swallow OOM with `catch {}` and `catch &.{}`. Leak-clean under the scratch arena, but silently drops text on allocator pressure — a correctness concern, not a leak.
  > **Files-touched envelope.** `src/interpreter.zig` (ContentLexer + helpers + scan* signature change).
  > **Acceptance gate.**
  > - `appendByte` / `finalizeBuf` propagate OOM instead of swallowing.
  > - `scanString` / `scanHexString` change return type to `![]const u8`.
  > - `ContentLexer.next` propagates lexer OOM up its caller chain.
  > - 407/407 tests stay green.

- [x] **PR-4c · fix: fuzz harness target_filter UAF + check arena reset/seed lifetimes**
  > [!info]- Details
  > **Why.** Discovered while extending the fuzz harness for PR-4: `target_filter` is allocated from `arena_alloc` but the in-target loop calls `arena.reset(.retain_capacity)` every 4096 iters, leaving `target_filter` dangling. Crashes the harness at `mem.eql(u8, f, target.name)` when `PDFZIG_FUZZ_TARGET` is set and the target is fast enough that reset fires inside its iter loop.
  > **Files-touched envelope.** `src/fuzz_runner.zig` (allocate `env_target` from `page_allocator`).
  > **Acceptance gate.**
  > - `PDFZIG_FUZZ_ITERS=1500000 PDFZIG_FUZZ_TARGET=lattice_pass_b_spans zig build fuzz` no longer segfaults.
  > - All other env-var derived strings audited for arena_alloc lifetime issues.
  >
  > **Test strategy.** Manual repro before/after.

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

- [x] **PR-8 · perf: Pass B+C early-out for table-free pages**
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

- [x] **PR-9 · refactor: strict-mode `checkAllAllocationFailures`**
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

- [x] **PR-11 · feat: scanned-PDF detection (`quality_flag:"scanned"`)**
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

- [x] **PR-17 · feat: `kind:"section"` long-PDF checkpoint records**
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

- [x] **PR-18 · feat: citation-grade `--bboxes` flag (`spans:[]` per page)** (#30)
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

- [x] **PR-19 · feat: image extraction (`kind:"image"`)** — _shipped: `--images` (#35), `encoding` field (#38), `--images=base64` (#39), `--images=path` (#41)_
  > [!info]- Details
  > **Files-touched envelope.** `src/cli_pdfzig.zig` (flag + emission), `src/stream.zig` (new record kind), `src/integration_test.zig`, upstream `src/parser.zig` (image XObject access).
  > **Acceptance gate.**
  > - [x] `--images` flag emits `kind:"image"` `{page, bbox, width_px, height_px, encoding}` (no payload by default). _(#35 + #38)_
  > - [x] `--images=base64` adds `payload_b64` for DCT/JPX/CCITTFax passthrough; `warnings` array for unsupported filters. _(#39)_
  > - [x] `--images=path` extracts DCT/JPX images to `<--images-dir>/<doc_id>-page<N>-img<idx>.<ext>` and emits `path` field. _(#41)_
  > - [x] On the `generateImagePdfWithFilter` fixture, images detected with correct encoding + base64 round-trip + on-disk file.
  >
  > **Test strategy.** Three integration tests (one per mode).
  > **Codex gate.** Base64 payload doesn't break NDJSON line-buffering on multi-MB images (cap or stream-as-array); path-mode doesn't escape the output dir.

- [x] **PR-20 · feat: annotation extraction (non-link)** (#33)
  > [!info]- Details
  > **Files-touched envelope.** `src/cli_pdfzig.zig`, `src/stream.zig` (new `annotations` kind), upstream parser glue.
  > **Acceptance gate.**
  > - `kind:"annotations"` per-page record `[{type:"text|highlight|underline|strikeout|ink", rect, contents, author?, modified?}]`.
  > - Test fixture `audit/sample/annotated.pdf` → 4 annotations of different types extracted.
  > - Existing `kind:"links"` record unchanged.
  >
  > **Test strategy.** Single fixture, single integration test.
  > **Codex gate.** Schema covers PDF spec annotation types correctly; timestamps ISO-8601 (PDF dates are not).

- [x] **PR-21 · feat: PDF/UA structure-tree NDJSON output** _(shipped via #36)_
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

## v1.5 — greenfield PDF authoring (Tier 1: minimum viable writer)

> [!info] Why
> pdf.zig is currently read-only. Tier 1 adds a clean writer module: hello-world PDFs with plain ASCII text on white pages using Type 1 base-14 fonts (no font file embedding). Sufficient for round-trip workflows (extract → modify markdown → re-render), test-fixture generation (replace `testpdf.zig`'s hand-rolled byte concat), and NDJSON-to-PDF assembly.
>
> **Use-case constraint.** Target documents are **multi-hundred pages** (not just hello-world). PR-W2 therefore implements a balanced page tree from day one (~10-fan-out per `/Pages` node), not a flat single-level tree. This is the only Tier-1 gate that materially diverges from "minimum viable" — every other PR keeps the minimal-scope discipline.
>
> **Scope boundary.** No font embedding (no non-ASCII), no images, no encryption, no PDF/A. Those are Tier 2 (PR-W7+) — listed separately under v1.6 once Tier 1 ships.

- [x] **PR-W1 · feat: PDF writer core (`src/pdf_writer.zig`)**
  > [!info]- Details
  > **Why.** Foundation for every authoring PR. Current `testpdf.zig` is ~50 hand-rolled byte-level fixtures (literal string concat); a real writer module unifies that and unblocks tier-1.
  > **Files-touched envelope.** `src/pdf_writer.zig` (new, ~500 LOC), `src/integration_test.zig`.
  > **Acceptance gate.**
  > - Emit low-level PDF object types: name, string (literal + hex), integer, real, array, dict, stream, indirect ref, indirect object.
  > - Track byte offsets per indirect object; emit valid xref table at end.
  > - Emit `trailer << /Size N /Root R >>` + `startxref` + `%%EOF`.
  > - Round-trip test: write a 1-page minimal PDF, parse with `Document.openFromMemory`, assert pageCount == 1.
  > - Allocator-failure test (FailingAllocator over every alloc index) — must not leak.
  >
  > **Test strategy.** New unit tests for object serialization + round-trip integration test.
  > **Codex gate.** xref byte-offset accuracy under stream lengths that span chunk boundaries; deferred-reference resolution before `endobj`; FlateDecode boundary not assumed (Tier-1 content streams uncompressed).

- [x] **PR-W2 · feat: Document/Page/Resources builders with balanced page tree (`src/pdf_document.zig`)**
  > [!info]- Details
  > **Why.** High-level API on top of PR-W1 so callers don't write objects directly. Page tree is **balanced from day one** — see the v1.5 section header for the use-case constraint (multi-hundred-page authoring).
  > **Files-touched envelope.** `src/pdf_document.zig` (new, ~600 LOC including the page-tree builder), `src/integration_test.zig`.
  > **Acceptance gate.**
  > - `DocumentBuilder.init(allocator) -> *DocumentBuilder` returns a builder with empty catalog.
  > - `addPage(media_box: [4]f64) -> *PageBuilder` allocates a page; pages are buffered until `write()` so the final tree shape can be balanced (fan-out target ≈ 10 children per `/Pages` node).
  > - `PageBuilder.appendContent(bytes)` appends to the page's content stream.
  > - `DocumentBuilder.write(allocator) -> []u8` flushes catalog + balanced page tree + pages + content streams + xref + trailer. Tree depth = `⌈log₁₀(N)⌉`; every leaf `/Page` carries the correct `/Parent` ref; every internal `/Pages` node has correct `/Count` (subtree page count) and `/Kids`.
  > - **Stress test**: 1000-page synthetic PDF round-trips through `Document.openFromMemory` with `pageCount() == 1000`. Random-access page reads pick the right page (e.g. `pages.items[500]` resolves to the page added 500th).
  > - 3-page baseline still produces a flat-ish tree (single `/Pages` parent — no unnecessary nesting under the threshold).
  >
  > **Test strategy.** Two integration tests: 3-page (flat) + 1000-page (deep tree). Round-trip via the existing reader.
  > **Codex gate.** `/Count` correctness at every internal node (subtree page count, NOT direct-children count); `/Parent` chain on every leaf; tree fan-out is uniform (not pathological — last node may be partial); resources dict ownership (per-page; tier-2 may add shared resources via `/Parent` inheritance).

- [x] **PR-W3 · feat: Type 1 base-14 fonts + `drawText` content op encoder**
  > [!info]- Details
  > **Why.** Tier-1 minimum text rendering without font-file embedding. The 14 standard fonts (Helvetica, Helvetica-Bold, Times-Roman, Times-Bold, Courier, …) are guaranteed available in every PDF reader.
  > **Files-touched envelope.** `src/pdf_document.zig` (extend), `src/encoding.zig` (WinAnsi escape helpers — new file or extend existing), `src/integration_test.zig`.
  > **Acceptance gate.**
  > - `BuiltinFont` enum with 14 entries; `PageBuilder.drawText(x, y, font, size, text)` emits `BT /Fk size Tf x y Td (escaped-text) Tj ET`.
  > - Text accepts `[]const u8` ASCII + WinAnsiEncoding subset; non-encodable bytes are dropped with a warning (Tier-2 will handle UTF-8 via embedded fonts).
  > - Round-trip: build a PDF with `drawText("Hello World")`, extract via `Document.extractText`, assert byte-identical match.
  > - Special-char escapes: `(`, `)`, `\` properly escaped in literal strings.
  >
  > **Test strategy.** 14 unit tests (one per BuiltinFont) + round-trip integration test.
  > **Codex gate.** WinAnsi encoding completeness vs the standard; backslash-escape edge cases; empty-text drawText is a no-op (not malformed BT/ET).

- [ ] **PR-W4 · feat: FlateDecode content-stream compression** (deferred — Zig 0.15.2 stdlib gap)
  > [!warning] Blocked on Zig stdlib
  > Both `std.compress.flate.Compress` (high-level) and `std.compress.flate.Compress.Simple` are non-functional in Zig 0.15.2. `Compress.drain` calls `@panic("TODO")` and `Simple.finish` has a compile-time error in `hasher.container()` (Container is an enum, not callable). Until upstream Zig completes the deflate encoder, this PR can't ship without either (a) writing a hand-rolled deflate encoder (~500 LOC, scope creep), (b) shelling out to `zlib` (breaks the no-deps story), or (c) waiting for Zig 0.16+.
  > **Files-touched envelope.** `src/pdf_writer.zig`, `src/pdf_document.zig`, `src/integration_test.zig`.
  > **Acceptance gate.**
  > - Streams >256 B compress with `/Filter /FlateDecode`; smaller stay raw.
  > - Compressed output round-trips through the existing reader (which already handles FlateDecode).
  > - Compression ratio ≥ 50% on a 3-page text PDF.
  >
  > **Test strategy.** Compression-ratio assertion + round-trip extract.
  > **Codex gate.** No off-by-one in length-after-compression; `/Length` reflects compressed bytes; `/DL` field if predictor used (tier-1: no predictor).
  > **Workaround.** Tier-1 emits raw uncompressed content streams. Files are 4-5× larger than necessary but readable by every PDF viewer; the existing `decompress.zig` already handles compressed streams from third-party PDFs without issue.

- [x] **PR-W5 · feat: `pdf.zig new` CLI subcommand (markdown → PDF)**
  > [!info]- Details
  > **Why.** Surfaces the writer to end users. Reads markdown from stdin or a file, emits a basic PDF with paragraphs and H1/H2 headings.
  > **Files-touched envelope.** `src/cli_pdfzig.zig` (new `new` subcommand + `parseNew` arg parser), `src/markdown_to_pdf.zig` (new, ~300 LOC), `src/integration_test.zig`, README.md.
  > **Acceptance gate.**
  > - `pdf.zig new --output out.pdf --input -` reads stdin markdown, writes PDF to file.
  > - Headings (`# `/`## `/`### `) render in larger size; paragraphs flow with word-wrap; lists basic indent.
  > - Page break on `\n\n---\n\n` markers (mirrors the v1.x `--output md` separator).
  > - Round-trip integration test: `pdf.zig extract foo.pdf | pdf.zig new --output bar.pdf` produces a PDF whose extracted text is byte-identical to the original (modulo paragraph-break collapsing).
  >
  > **Test strategy.** New integration_test cases + 1 README example.
  > **Codex gate.** Word-wrap doesn't split mid-character on multibyte UTF-8 (Tier 1: ASCII only, but flag the assumption); page-break heuristic stable.

- [x] **PR-W6 · feat: writer escape-hatch surface + CI gap fix (foundation)**
  > [!info]- Details
  > **Why.** Original PR-W6 scope was "replace ~50 hand-rolled `testpdf.zig` fixtures with writer calls". That requires the writer to support /Info, /Outlines, /Annots, AcroForm, /PageLabels — none of which it had. Split into a foundational PR (this one) + per-fixture-cluster follow-ups (W6.1+).
  > **What landed.**
  > - `DocumentBuilder.{addAuxiliaryObject, reserveAuxiliaryObject, setAuxiliaryPayload, setInfoDict, setCatalogExtras}` and `PageBuilder.{setPageExtras, objNum, content_obj_num}` for cyclic-aware aux graphs.
  > - Single-use enforcement (`error.DocumentAlreadyWritten` after first `write()`).
  > - **CI gap fix**: `pdf_writer.zig`, `pdf_document.zig`, `markdown_to_pdf.zig` were orphaned from `zig build test`. Test count jumped 474→856 once they were wired in. Two PR-W5 rc2 tests silently never ran and were broken; both fixed.
  >
  > **Test strategy.** 7 new tests cover the escape-hatch surface end-to-end (info round-trip, catalog ref splice, page extras, single-use guard, cyclic aux refs, unknown-aux rejection).
  > **Codex gate.** Cleared rc2 (Medium reserve/set + 3 Low all addressed).

- [x] **PR-W6.1–W6.5 · refactor: convert `testpdf.zig` standard fixtures cluster-by-cluster** (#20–#24)
  > [!info]- Details
  > Five per-cluster PRs migrated all standard fixtures to the writer API:
  > - W6.1 (#20): text-only — Minimal, MultiPage, TJ, Superscript
  > - W6.2 (#21): metadata + outlines — Metadata, Outline, NestedOutline, Utf16Be
  > - W6.3 (#22): link annotations — Link, MultiLink
  > - W6.4 (#23): AcroForm fields — FormField, AllFormFields
  > - W6.5 (#24): page labels — PageLabel, ExtendedPageLabel
  >
  > **Net delta:** ~−495 lines on `testpdf.zig` across the 13 migrated fixtures. Output is byte-different from the old hand-rolled bytes but semantically equivalent (same pageCount, font refs, extractable text, metadata/outline/annot/form/page-label structure). 1133/1133 tests pass.
  >
  > **Intentionally still hand-rolled** (the writer is for well-formed PDFs by design): CID font (Type0 composite), incremental update, encrypted, Form XObject malformed-resources variants, image XObject, tagged-table fixtures, generatePdfWithoutPageType.

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
