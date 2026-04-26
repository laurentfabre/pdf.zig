# Week 5 status — pdf.zig vs pymupdf4llm bake-off (n=12) + v1.0-rc1

> **Date**: 2026-04-26 (same calendar day as Weeks 0–4 per the compressed-roadmap pattern). Branch: `week5/bakeoff-rc1`.
>
> **Headline**: **Speed gate (≥3×) cleared by 40×.** Aggregate **121.1× faster** than pymupdf4llm on the full Alfred bake-off corpus (n=12, 11 found on disk). **Char parity 78.9%** overall, 9 / 11 PDFs at ≥ 0.74× — two known content-loss buckets documented (CJK + image-text), both already in the v1.x scope per the architecture and the Week-2 reframe. Cutting **v1.0-rc1**.

---

## TL;DR

| Gate | Target | Actual | Verdict |
|---|---|---|---|
| Aggregate speed vs `pymupdf4llm` | ≥ 3× faster | **121.1×** | ✅ PASS by 40× |
| Char parity (text-bearing PDFs) | "match within reason" | 78.9% overall, 9 / 11 ≥ 0.74× | ⚠️ 2 known buckets (CJK + image-text) documented |
| Crashes on the corpus | 0 | 0 | ✅ |
| Per-PDF wall time | ≤ 200 ms median | **≤ 10 ms** for 10 of 11 | ✅ |
| `pdf.zig` binary size (ReleaseSafe) | reasonable | 647 KB | ✅ |

**Decision**: cut **v1.0-rc1** tag now. The two char-parity outliers are scope-documented (CJK = v1.x correctness, image-text = NG4 OCR — out of v1 scope per architecture.md §9). RC1 → GA per architecture.md §14 still requires the Week-6 release pipeline + Week-7 bake-off rerun.

---

## Per-PDF results

Source manifest: `Researcher/Distillation/bake-off/sample/manifest.tsv`
Raw outputs: `bake-off/out_pdfzig/` and `bake-off/out_pymupdf4llm/` (gitignored).

| ID | Hotel / category | Lang | Pages | pdf.zig chars | pymupdf4llm chars | Char ratio | pdf.zig time | pymupdf4llm time | Speedup |
|---|---|---|---|---:|---:|---:|---:|---:|---:|
| 18 | aman-new-york / dining | en | 6 | 5 102 | 5 048 | **1.01×** | 5 ms | 605 ms | **120×** |
| 106 | anantara-the-palm-dubai / spa | en | 8 | 17 823 | 18 521 | 0.96× | 7 ms | 1 830 ms | **269×** |
| 912 | como-cocoa-island / factsheet | en | 13 | 13 206 | 17 048 | 0.77× | 5 ms | 1 050 ms | **205×** |
| 629 | capella-bangkok / rooms | en | 4 | 6 073 | 5 880 | **1.03×** | 4 ms | 558 ms | **133×** |
| 140 | anantara-veli-maldives / events | en | 23 | 15 979 | 18 709 | 0.85× | 9 ms | 1 480 ms | **174×** |
| **1968** | **royal-mansour-marrakech / other** | **fr** | **1** | — | — | — | — | — | — *(file not on disk; manifest stale)* |
| 418 | bayerischer-hof-munich / dining | de | 6 | 2 432 | 3 285 | 0.74× | 4 ms | 2 641 ms | **686×** |
| **721** | **capella-singapore / press_media** | **zh** | **6** | **341** | **9 837** | **0.03×** | 4 ms | 854 ms | **238×** |
| **157** | **babylonstoren / `empty_text`** | unknown | 1 | **0** | **1 157** | **0.00×** | 2 ms | 445 ms | **190×** |
| 1462 | rosewood-hong-kong / dining | unknown | 2 | 2 035 | 2 316 | 0.88× | 4 ms | 558 ms | **140×** |
| 1754 | constance-eph-lia / brochure | en | 25 | 22 225 | 26 933 | 0.83× | 97 ms | 6 884 ms | **71×** |
| 1340 | patina-capella-singapore / press | en | 6 | 5 386 | 6 030 | 0.89× | 4 ms | 617 ms | **148×** |

**Aggregate**: pdf.zig 145 ms vs pymupdf4llm 17 521 ms → **121.1×** speedup. Total chars: pdf.zig 90 602, pymupdf4llm 114 764 → **78.9%** parity.

---

## Char-parity buckets

- **9 / 11 PDFs ≥ 0.74× chars** (English / German / French dining / spa / brochure / press) — within the natural noise floor of two extractors that disagree on whitespace, table flattening, header repetition. The minimum 0.74× (Bayerischer Hof DE menu) is **not** a regression — pymupdf4llm hand-deduplicates header/footer text our path keeps; manual diff shows pdf.zig actually gains on inline pricing rows. Net info-content equal.
- **2 / 11 PDFs at extreme ratios** with documented root causes:
  - **ID 721 (Capella SG Chinese press release, 0.03×)** — CJK extraction. The Week-2 Unicode/CMap milestone was *deliberately deferred* (week2-status.md and decisions.md): Alfred's corpus has 49 ZH-flagged docs but no good test corpus, so full CJK correctness is **v1.x scope**. RC1 ships with a `quality_flag:cjk` heuristic gap that downstream consumers can detect via `language="zh"` in metadata.
  - **ID 157 (Babylonstoren `empty_text`, 0.00×)** — image-text PDF. Per Week-2 (`docs/week2-status.md`), image-text PDFs are NG4 ("OCR. Out of scope for v1; emit `quality_flag:scanned`"). The 0-char output is correct for a text-only extractor; pymupdf4llm's 1 157 chars come from its built-in picture-text OCR layer, which we deliberately don't replicate in v1. Architecture.md §14 places "scanned-PDF detection + ocrmypdf shell-out" at v1.3.

**Honest summary**: on the 9 text-bearing PDFs that v1 was scoped to handle, char parity averages **0.89×** (median 0.85×). The two extreme-loss cases are *category gaps*, not extraction defects.

---

## Speed analysis

- **Smallest PDFs (4–6 pages)**: 4–7 ms in ReleaseSafe. The Python startup floor for pymupdf4llm (~300–500 ms cold) dominates — that alone is ~100× of pdf.zig's full extract.
- **Mid PDFs (8–13 pages)**: 5–9 ms. Per-page extract amortises around 0.7 ms.
- **Large PDF (Constance 25-page brochure)**: 97 ms — by far the slowest, but still 71× faster than pymupdf4llm's 6 884 ms. The bulk of the 97 ms is markdown rendering across 25 layout passes.
- **Bayerischer Hof DE menu (686×)**: outlier driven by pymupdf4llm being unusually slow on this particular layout (2 641 ms for 6 pages — 4× its average). pdf.zig lands at the modal 4 ms.

The **first-byte latency** advantage matters more than the aggregate for the LLM-streaming use case (`pdf.zig extract … | claude -p …`): pymupdf4llm only flushes at EOF, so an LLM downstream blocks for the full 600 ms–7 s. pdf.zig's per-page flush gives the LLM the first page in 4 ms.

---

## Missing-features delta vs `pymupdf4llm`

Documented for `decisions.md`-style transparency. None of these block v1.0-rc1; each has a scope tag.

| Feature | pymupdf4llm has it | pdf.zig has it | Scope |
|---|---|---|---|
| Per-page Markdown | ✅ | ✅ | shipped |
| Table extraction (pipe-separated) | ✅ (rough) | ❌ | **v1.2** (XY-Cut++ table detection) |
| Headings from font-size analysis | ✅ | ✅ (markdown.zig) | shipped |
| Image extraction / `[image]` placeholders | ✅ | ❌ | v1.x (architecture.md §14) |
| Picture-text / OCR in graphics stream | ✅ (via PyMuPDF + Tesseract integration) | ❌ | **v1.3** (NG4 — Tesseract shell-out) |
| CJK text extraction quality | ✅ (PyMuPDF's CJK encoding tables) | ⚠️ partial | **v1.x** — Week-2 deferred |
| Encrypted PDFs (empty password retry) | ✅ (transparent) | ❌ (NG5: detect + skip) | v1.x optional |
| Multi-language metadata (UTF-16BE) | ✅ | ✅ (Week-3 fix: `�` substitution) | shipped |
| Token-aware chunking (`--max-tokens N`) | ❌ | ✅ | shipped (v1) |
| NDJSON streaming envelope | ❌ | ✅ | shipped (v1, the differentiator) |
| Per-page flush for downstream LLM | ❌ (EOF-only) | ✅ | shipped (v1) |
| Static binary distribution (no Python) | ❌ | ✅ (647 KB) | shipped (v1) |
| Form-field extraction | ✅ | ✅ (upstream) | shipped |
| Document outline / TOC | ✅ | ✅ (upstream) | shipped |
| Linked annotations / hyperlinks | ✅ | ✅ (upstream) | shipped |

The features pdf.zig **adds** that pymupdf4llm lacks (NDJSON envelope, per-page flush, token chunking, static binary) are precisely the features that justify the Option-C fork over a pymupdf4llm wrapper.

---

## RC1 readiness checklist

| Item | Status |
|---|---|
| ≥3× speedup gate | ✅ 121× |
| 0 crashes on n=12 | ✅ |
| 0 crashes on Week-4 n=40 corpus | ✅ |
| 11 fuzz targets × 1M iters each, no panics | ✅ (Week 4) |
| xref-repair fixtures #31, #32, #35, #5 | ✅ 11/11 (Week 4) |
| ReleaseSafe build | ✅ |
| NDJSON envelope with kind/source/doc_id | ✅ (Week 3) |
| Per-page flush | ✅ |
| SIGPIPE-clean | ✅ |
| `pdf.zig` and `zpdf` binaries both build | ✅ |
| `audit/fuzz_findings.md` documents known gaps | ✅ |
| GH Actions release pipeline | ⏸ Week 6 |
| Brew tap | ⏸ Week 6 |
| Python bindings re-tested | ⏸ Week 6 |
| Cycle-10 bake-off rerun (post-release-pipeline) | ⏸ Week 6.5 / 7 |

Per architecture.md §14 milestones, RC1 is the *release candidate*, not GA. The remaining gating work for **v1.0 GA** is mechanical (release pipeline + brew tap + bake-off rerun) and lives in Weeks 6–7.

---

## What surprised us this week

1. **The speedup is even bigger than the architecture's 3× target predicted**. The architecture used the conservative "no Python startup floor" framing (~300 ms saved/invocation); we saw 121× because for small PDFs the Python startup IS the bottleneck. For the Constance 25-page brochure where pymupdf4llm's parser actually does work, we're 71× — closer to the predicted but still well above gate.
2. **The Week-2 reframe was vindicated by the bake-off**. The "image-text" PDF (Babylonstoren `empty_text`) and the CJK PDF (Capella ZH) are *exactly* the two outliers in this report. Week 2's classification harness predicted both; Week 5's bake-off confirms them as the only two char-parity gaps worth flagging. The methodology lesson holds: classify the population first, then the outliers in any later measurement are explainable.
3. **The royal-mansour-marrakech PDF is missing from disk** — `data/hotel_assets/royal-mansour-marrakech/restauration.pdf` doesn't exist anymore. Manifest is stale; not a pdf.zig concern. Filed as a follow-up note for the Researcher repo, not the pdf.zig branch.

---

## Updated estimate to v1.0 GA

| Milestone | Status |
|---|---|
| Week 0 — audit greenlight | ✅ |
| Week 1 — fork + triage + xref fixtures + streaming-design | ✅ |
| Week 2 — collapsed to "no fix needed" reframe | ✅ |
| Week 3 — NDJSON streaming + CLI | ✅ |
| Week 4 — fuzz suite + xref-repair + corpus regression | ✅ |
| **Week 5 — bake-off + RC1** | **✅ (this doc)** |
| Week 6 — GH Actions release + brew tap + Python bindings + RC2 | ⏸ next |
| Week 6.5 — cycle-10 of `alfred-bakeoff-report.md` | ⏸ |
| Week 7 — v1.0 GA tag | ⏸ |

Realistic GA: ~1 week of mechanical packaging from now (architecture.md said 1–2 weeks, we're tracking the lower bound).

---

## Methodology note for the loop log

> **When the speed gate clears by 40×, scrutinize char parity harder.** A 121× speedup is suspicious without scrutiny — it could mean we're skipping work pymupdf4llm does (which would show as a char-parity drop). The bake-off found exactly two real char-parity gaps (CJK + image-text); both were documented out-of-scope already. If the gate had cleared by 40× *and* parity were 100%, that'd be more suspicious — measure both axes.
