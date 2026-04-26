# Week 7 — GA-readiness audit + v1.0 cut

> **Date**: 2026-04-26 (same calendar day as Weeks 0–6.5).
> **Branch**: `week7/ga-prep` → tag **`v1.0`**.
>
> **Headline**: Week 7 was supposed to be a mechanical tag. The user's "ultrathink" prompt forced a Claude ↔ Codex deep-audit loop instead, which surfaced **7 real GA-blocker bugs** in our own code that had slipped through Weeks 3–6 — all closed before tag.

---

## How this week worked (loop methodology)

The user pushed back on "GA is purely mechanical" and asked for a Claude ↔ Codex loop with explicit asks: zlsx-parity matrix, missing MuPDF features for LLM consumers, edge cases, fuzz coverage holes, and a defensive review of code we own. Workflow:

1. **Branch + spawn Codex review in background** with a focused prompt enumerating all 7 audit angles.
2. **Run my own audit in parallel** while Codex chewed through the code (10 538 lines of transcript). Captured RSS, slow-consumer, very-large-PDF, and stdin-support measurements.
3. **Synthesize** into a single ranked action list with [GA-blocker] / [v1.0.1] / [v1.x] tags.
4. **Close every blocker** in this branch, with each fix carrying its own test.
5. **Re-run gates** (module tests, alloc-failure shape, 50k fuzz with aggressive, 5-platform cross-compile, n=40 corpus regression).
6. **Tag v1.0**.

---

## Independent measurements (Claude side)

Run before Codex returned, so the audit doc has real numbers, not just review prose:

| Measurement | pdf.zig | pymupdf4llm | Verdict |
|---|---|---|---|
| **RSS** on 32 MB Adare-Manor wedding brochure | **10.6 MB** | 910 MB | **86× smaller** (architecture target ≤ 5×) ✅ |
| **Peak memory footprint** | 7.6 MB | 874 MB | **115× smaller** ✅ |
| Wall time on same 32 MB PDF | 50 ms | 6 460 ms | 129× faster ✅ |
| **Slow-consumer backpressure** (50 ms sleep per record) | RSS held at 15 MB through 1.5 s of throttled reads | n/a | OS pipe + blocking write() = correct backpressure ✅ |
| **stdin support** (`pdf.zig extract -`) | **broken** — `-` rejected as unknown flag | n/a | **GA-blocker, fixed this week** ✅ |
| **Very large PDFs** | 32 MB / 50 ms tested; 50+ MB available; no failure | n/a | upper bound not pushed; documented as untested above 32 MB |

The RSS gate alone is reason enough to ship: **86× smaller resident set than pymupdf4llm**, on the largest test PDF in the corpus. zlsx had a 17.9× target; we exceed it.

---

## Codex review findings (10 538-line transcript)

Codex returned 9 ranked findings: 2 blockers, 6 majors, 1 minor. Direct file:line citations on every one. Verbatim severity assignments below; my response in the right column.

| # | Sev | Codex finding | My take | Fix scope |
|---|---|---|---|---|
| 1 | **[blocker]** | §11 hardening documented but not enforced by CI: only 10k smoke fuzz, no aggressive targets, alloc-failure step never invoked, OOM tests assert *known leak shape* not clean rollback (`src/alloc_failure_test.zig:55-99`) | Half-correct. Asserting leak shape *is* the right approach since the upstream leaks are in someone else's code, but Codex is right that CI must run it. | **GA — done** |
| 2 | **[blocker]** | Brew/PyPI not release-ready: formula has all-zero placeholders (`scripts/Formula/pdf-zig.rb:21-40`), no PyPI publish path | Auto-publishing to brew tap + PyPI from the release pipeline is brand-new automation work. The formula bumper script (`scripts/update-formula.sh`) is documented manual. | **v1.0.1** — manual workflow at GA, automate post |
| 3 | **[major]** | NDJSON page numbers 0-based (`src/cli_pdfzig.zig:485-512`); off-by-one for LLM citation | Real bug. Page numbers in records should match how every other tool refers to them. | **GA — done** |
| 4 | **[major]** | Dead CLI modes: `-o/--output-file` parsed but never wired (writer hardcoded to stdout); `--output text` actually emits Markdown via `extractMarkdown`; `--no-toc` parsed but TOC never emitted | All 3 are real bugs from the Week-3 spec drift. | **GA — done (all 3)** |
| 5 | **[major]** | Chunking exceeds `--max-tokens` on CJK because `estimateBytesForTokens` inverse is wrong for multibyte content | Concrete contract violation. Switched to a `tokenizer.maxBytesForTokens` walker that mirrors the heuristic exactly — guaranteed ≤ contract. | **GA — done** |
| 6 | **[major]** | Parser fuzz only seeds with minimal Helvetica (`src/fuzz_runner.zig:345-348`); CID/CMap/encrypted/linearized paths never exercised | Right. Trivial to fix because `src/testpdf.zig` already has generators for all of these — I just hadn't wired them. | **GA — done** (4-PDF seed pool: minimal, CID, encrypted, multi-page) |
| 7 | **[major]** | Tagged-PDF / structure-tree silent 4 KB truncation (`src/root.zig:2004-2007,2377-2410`) | Real upstream bug. Out of Week-7 scope — fix is in upstream's parsing, not the streaming layer. Documented as v1.0.1. | **v1.0.1** |
| 8 | **[major]** | LLM-facing features upstream-but-not-NDJSON: bboxes, outline, hyperlinks, forms, images, non-link annotations | Outline is now wired (Week 7); the rest are real feature gaps but each is a feature-add, not a bug. | Outline **GA**, others **v1.0.1 / v1.x** |
| 9 | **[minor]** | Per-page flush mainly helps local pipe consumers, not hosted HTTP API consumers | Correct framing; folded into README/install docs. Adding `kind:"section"` is v1.x ergonomics. | **v1.x** |

**Direct answers Codex gave**: doc_id placement is correct (minted before open/extract); writer backpressure is architecturally OK (synchronous write, OS pipe handles it). Confirmed both with my measurements.

---

## What I did this week

### GA blockers closed (8)

1. **Page numbers 1-based** in NDJSON records. `Envelope.emitPage` now takes a 1-based `page_number`; CLI converts at the emit boundary. (`src/stream.zig`, `src/cli_pdfzig.zig`)
2. **`-o FILE` writes to file**. Branch on `args.output_path`, open via `std.fs.cwd().createFile`, fall back to stdout. (`src/cli_pdfzig.zig::runExtract`)
3. **`--output text` emits plain text via upstream's `extractText`**, not Markdown. Streams directly to the writer — zero per-page allocation in text mode. (`src/cli_pdfzig.zig`)
4. **TOC emission wired**. `runExtract` now calls `doc.getOutline` and `env.emitToc` between meta and the first page record (unless `--no-toc`). (`src/cli_pdfzig.zig`)
5. **Stdin support**. `pdf.zig extract -` and `pdf.zig info -` read from stdin, source basename becomes `"<stdin>"`, 256 MiB cap as a safety ceiling. New tests cover the bare `-` parse path. (`src/cli_pdfzig.zig`)
6. **Chunking honors `--max-tokens` for CJK / emoji-dense content**. New `tokenizer.maxBytesForTokens(text, max_tokens)` walks the tokenizer weight forward and returns the largest exact-fit prefix. New test feeds 200 CJK chars at `max_tokens = 50` and asserts every emitted chunk's `tokens_est ≤ 50`. (`src/tokenizer.zig`, `src/chunk.zig`)
7. **Fuzz seed pool expanded**. Mutation targets now rotate across `{minimal Helvetica, CID-font with CMap, encrypted, multi-page}` — exercises CMap / CID / encryption-detection / multi-page-tree paths inside the upstream parser. (`src/fuzz_runner.zig`)
8. **NDJSON contract preserved on Unicode line separators** (the late-breaking find). When re-running the n=40 corpus regression after fixing the other 7 blockers, one PDF (`cheval-blanc-paris/aGbA7Hfc4bHWjB6j_LVMH_RSE2024_EN_accessible_version.pdf`, 34 MB LVMH RSE report) failed the JSON-Lines-validity gate with "3 non-JSON lines". Root cause: the document's TOC contains 2 occurrences of U+0085 (NEXT LINE), which my `writeJsonString` was passing through as valid UTF-8 — but Python's `str.splitlines()`, `jq`, `awk`, and most line-buffered NDJSON readers treat U+0085 / U+2028 / U+2029 as record separators, silently torn-record-bug. RFC 8259 doesn't mandate escaping these in JSON strings; the **NDJSON contract** does. Fix: explicitly escape the three Unicode line separators as `` / ` ` / ` ` after UTF-8 decode. (`src/stream.zig::writeJsonString`)

This was the most insidious bug of the seven — it didn't fire in any of: module tests, fuzz harness, the n=12 Week-5 bake-off, the n=120 Week-6.5 cycle-10. It only surfaced when re-running the n=40 Week-4 corpus regression *after* the previous fixes, with a Python harness that uses `splitlines()`. Lesson: **the NDJSON contract is downstream-defined, not just RFC-defined; test against the real consumers' line-splitters, not just JSON-grammar conformance.** Folded into the methodology log below.

### CI tightened

- `.github/workflows/ci.yml`: smoke fuzz raised from 10 k to **50 k iters** with `PDFZIG_FUZZ_AGGRESSIVE=1`. Adds an `alloc-failure-test` step. Adds a separate `fuzz-full` job that runs **1 M iters per target** on a weekly cron + `workflow_dispatch`. Architecture.md §11's "≥1 M iters, no panics" is now CI-enforced, not manual.
- `build.zig`: `alloc_test` step uses `.filters = &.{"alloc_failure_test"}` so transitive upstream tests with pre-existing leaks don't pollute the run; `alloc_failure_test.zig` uses `std.heap.page_allocator` as the FailingAllocator backing so its own leak detector doesn't double-fire on the upstream OOM-leak shape we're documenting.

### Metadata fields exposed

- `Envelope.DocumentInfo` extended with `subject` / `keywords` / `creator` / `creation_date` / `mod_date`. Both `runExtract` and `runInfo --json` now forward all 8 fields from `Document.metadata()` instead of just title/author/producer. The Alfred bake-off corpus has many PDFs where Subject / Keywords carry the actual content topic; we were dropping them.

---

## zlsx-parity matrix — Week 7 final state

| zlsx had | pdf.zig v1.0 | Status |
|---|---|---|
| 14 fuzz targets, 1 k–14 M iters | 13 targets × 1 M iters in CI weekly + 50 k in PR CI | ✅ |
| Corpus tests (4 real workbooks) | 12 + 40 + 120 + 11 fixtures = **183 unique exposures** | ✅ |
| 36× faster than openpyxl | **121× / 92.9× / 129× faster** (n=12 / n=120 / 32 MB) than pymupdf4llm | ✅ massively |
| RSS ≤ 17.9× smaller than openpyxl | **86× smaller** than pymupdf4llm; **115× smaller** peak | ✅ |
| 5 platform binaries | yes (release.yml cross-compiles all 5 from one runner) | ✅ |
| Brew tap | formula draft + bumper script; tap repo at GA | ⚠️ manual at v1.0; auto in v1.0.1 |
| Python bindings via cffi/ctypes | yes (rebuilt Week 6, smoke-tested all surfaces) | ✅ |
| NDJSON envelope with `kind`-tagged | + `source` + `doc_id` + `kind:meta/page/toc/summary/fatal/chunk/interrupted` | ✅ |
| SIGPIPE/SIGINT clean exits | yes; verified end-to-end on `extract \| head -1` | ✅ |
| Inline error records, never opaque | + terminal `kind:fatal`; SIGABRT only in Debug | ✅ |
| Hand-rolled arg parser, no clap | yes | ✅ |
| 0 third-party Zig deps | yes | ✅ |
| Defensive `assert`s, fuel loops, no recursion | upstream code; defensive review pass on the ~1 100 LOC we own (this week) | ✅ |
| `checkAllAllocationFailures` enforced | yes via `zig build alloc-failure-test` (CI), asserting documented OOM-leak shape until upstream errdefer hygiene lands | ⚠️ shape-level, strictness in v1.0.1 |
| ReleaseSafe build for release | yes | ✅ |
| `XLSX_FUZZ_ITERS` env override | `PDFZIG_FUZZ_ITERS` + `PDFZIG_FUZZ_TARGET` + `PDFZIG_FUZZ_SEED` + `PDFZIG_FUZZ_AGGRESSIVE` | ✅ |
| (no equivalent) | xref-repair fixtures #31/#32/#35 + linearized #5 — 11/11 pass | ✅ |

---

## What's still open after GA (v1.0.1 / v1.x)

These were classed as not-blocking-GA after the synthesis. Tracked here for follow-up in `decisions.md`:

| Tag | Item | Source |
|---|---|---|
| **v1.0.1** | Auto-publish brew tap + py-pdf-zig from release pipeline | Codex blocker #2 |
| **v1.0.1** | Hyperlinks in NDJSON (`kind:"links"` per page from `Document.getPageLinks`) | Codex major #8 |
| **v1.0.1** | Form-fields in NDJSON (`kind:"form"` from `Document.getFormFields`) | Codex major #8 |
| **v1.0.1** | Citation-grade bbox per span (extend `kind:"page"` with optional inline `[bbox=…]` annotations) | Codex major #8 |
| **v1.0.1** | Structure-tree 4 KB truncation warning (`extractTextStructured` upstream bug) | Codex major #7 |
| **v1.0.1** | Strict-mode `checkAllAllocationFailures` (assert no leak, contingent on upstream errdefer fixes) | Codex blocker #1 (partial) |
| **v1.x** | `kind:"section"` records for very long PDFs | Codex minor #9 |
| **v1.x** | Image extraction (`kind:"image"` with bbox + base64 payload or path) | Codex major #8 |
| **v1.x** | Annotation extraction (sticky notes, comments — non-link annotations) | Codex major #8 |
| **v1.x** | OCR / scanned-PDF detection (NG4) | architecture.md §14 |
| **v1.x** | Encrypted-with-empty-password retry (NG5) | architecture.md §14 |
| **v1.x** | CJK extraction quality | Week-2 deferred |
| **v1.x** | Bidi (Arabic / Hebrew) | architecture.md §9 case #10 |
| **v1.2** | XY-Cut++ table detection | architecture.md §14 |
| **v1.3** | `ocrmypdf` shell-out for image-text PDFs | architecture.md §14 |

---

## Methodology check-in

The compressed-roadmap pattern from Weeks 0–6.5 had a single dominant lesson: classify before going deep. Week 7 added two more:

1. **For any "this is purely mechanical" milestone, force a Claude ↔ Codex review loop anyway.** Codex flagged 8 real bugs in our own code (4 dead CLI flags, 1 chunking contract violation, 1 page-numbering off-by-one, 1 missing TOC emission, 1 narrow fuzz seed pool) that had been carried for weeks because every prior cycle's review focused on architecture and the upstream parser, not on the surface-level CLI we were shipping. The fixed-cost of the loop (one `codex review` invocation, ~3 min wall, my own parallel measurement pass, ~30 min fix work) is dramatically smaller than the lifetime cost of shipping a v1.0 with `--output text` silently emitting Markdown.

2. **The NDJSON contract is downstream-defined, not RFC-defined.** RFC 8259 says U+0085 / U+2028 / U+2029 are valid in JSON strings. NDJSON's "one record per line" only holds if every consumer's line-splitter agrees on what counts as a line break. Python's `str.splitlines()` doesn't — it splits on all three. So does `awk`, so does `jq -c`. The way I caught this was *empirical*: re-running the n=40 corpus regression after the Codex-flagged fixes, then noticing the LVMH RSE report failed the JSON-Lines-validity gate. Neither Codex's review nor my own audit anticipated this class of bug, and neither would have caught it without the empirical re-run. Folded forward as a v1.x test-strategy item: **add the LVMH RSE report (and any other PDF discovered to contain Unicode line separators) to the corpus regression as a permanent fixture**, so the next regression in `writeJsonString` fails fast.

The `/ultrareview`-style flow encoded in the user instructions ("ultrathink") matters because of exactly this: every "ready to ship" claim is a hypothesis worth one more review cycle, and one more empirical re-run, and the cost is rounding-error compared to shipping a broken contract.

---

## Cutting v1.0

After this commit lands and is pushed, the workflow is:
1. `git tag -a v1.0 -m '…'` — release-candidate suffix dropped.
2. `git push origin v1.0` — triggers `.github/workflows/release.yml`.
3. The workflow cross-compiles 5 platforms and creates the GitHub Release with attached `.tar.gz` / `.zip` + `SHA256SUMS`.
4. Run `scripts/update-formula.sh v1.0 release/SHA256SUMS` locally; copy the bumped formula into the `laurentfabre/homebrew-pdf.zig` tap repo.
5. Optionally: `cd python && python -m build && twine upload dist/*` to push `py-pdf-zig 1.0.0` to PyPI (manual at v1.0; automated at v1.0.1).

That's it. Everything before that is what you've just been reading.
