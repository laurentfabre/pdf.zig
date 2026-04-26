# Decisions log

Chronological record of architecture-level decisions, with links to the analysis that drove each.

## 2026-04-26 — Naming

**Decision**: Project name is `pdf.zig` (not `zpdf` or `zigpdf`).

**Rationale**:
- `zpdf` is taken by [Lulzx/zpdf](https://github.com/Lulzx/zpdf) — the upstream we're forking.
- `zl` prefix matches `zlsx` (the sibling project, by the same maintainer, same playbook).
- Avoids upstream naming collision; allows attribution + clear differentiation.

**Source**: `architecture.md` §4.4.

---

## 2026-04-26 — Architecture path: Option C (fork Lulzx/zpdf)

**Decision**: Fork [Lulzx/zpdf](https://github.com/Lulzx/zpdf) (CC0) as the parser foundation. Build LLM-streaming + NDJSON envelope + zlsx-grade hardening on top.

**Alternatives rejected**:
- **Option A (MuPDF wrapper)**: AGPL contamination forces `pdf.zig` itself to be AGPL — incompatible with brew-tap-friendly distribution model. Reserve as fallback if Week-0 audit fails on Option C.
- **Option B (pure Zig from scratch)**: 8–24 person-weeks vs 2–10 for Option C. The bake-off doesn't justify the extra ML/layout quality that B could eventually deliver.

**Weighted score**: A 7.6/10, B 7.4/10, **C 7.9/10**.

**Source**: `architecture.md` §5 (option matrix), §5.4 (decision matrix scoring).

---

## 2026-04-26 — Quality bar: pymupdf4llm-equivalent

**Decision**: Target `pymupdf4llm`-equivalent extraction quality on Alfred's n=12 bake-off corpus. NOT targeting docling/MinerU-grade ML layout.

**Rationale**:
- The 9-cycle Alfred bake-off (`alfred-bakeoff-report.md`) showed that `pymupdf4llm`, `docling`, and `opendataloader-pdf` are directionally similar on grounded-card output (mean 6.89/7 sections, 52.8 bullets).
- The cycle-9 grounding verification showed Haiku-distilled cards from `pymupdf4llm`-style extraction are 90% supported / 0% hallucinated.
- Replicating docling's ML layout layer is a multi-quarter project that the bake-off does not justify.

**Caveat (Codex cycle-1 P1)**: the bake-off validated table-recovery + priority-cohort scope, not full multi-doc grounded-card. The corpus-wide multi-doc verifier rerun is a v1.x follow-on, not a v1 prerequisite.

**Source**: `architecture.md` §1.1; `alfred-bakeoff-report.md` §3.7, §3.8, §3.10.

---

## 2026-04-26 — License: MIT or CC0 (NOT AGPL)

**Decision**: `pdf.zig` ships under MIT (or CC0 to mirror upstream Lulzx attribution). NOT AGPL.

**Implication**: Option A (MuPDF wrapper) is reclassified as AGPL-only because static-linking AGPL libraries forces the wrapper itself to be AGPL. If we ever pursue Option A, it would live in a separate `pdf.zig-mupdf` repo with explicit AGPL distribution.

**Source**: `architecture.md` §5.1 (cycle-1 P1 fix); §12 (distribution branching).

---

## 2026-04-26 — Streaming protocol: NDJSON with `kind` + `source` + `doc_id`

**Decision**: Default output is line-buffered NDJSON. Every record carries `kind` + `source` + `doc_id`. UUIDv7 minted at invocation start (not at `meta` emission). Per-page flush. Terminal `kind:"fatal"` on parser death.

**Rationale**:
- Mirrors zlsx's NDJSON envelope (proven for LLM consumers).
- `source` + `doc_id` (cycle-1 P1 fix) prevent multi-file pipeline ambiguity (`xargs -P4 pdf.zig extract`).
- UUIDv7 at invocation (cycle-2 P2 fix) ensures `fatal` records before `meta` emission still have a stable `doc_id`.
- Terminal `fatal` record (cycle-1 P1 fix) lets consumers distinguish clean EOF from parser death — SIGABRT in release was wrong.

**Source**: `architecture.md` §6.1, §6.4.

---

## 2026-04-26 — Defensive programming: full TigerStyle alignment

**Decision**: ReleaseSafe build mode (NOT ReleaseFast), `std.testing.checkAllAllocationFailures` on every parse path, fuel-limited loops, no recursion, `errdefer` everywhere.

**Rationale (Codex cycle-1 P2 fix)**: v1 had TigerStyle slogans without the two practices that actually prove the cleanup paths and keep runtime checks on in production. Per `Defensive-Programming-Zig.md` §3.4 and §3.6, both are mandatory for parsers handling adversarial input.

**Cost**: ~5–15% perf vs ReleaseFast. Worth it — a parser that never SIGSEGV's on a hostile PDF.

**Source**: `architecture.md` §8.4, §11 (quality gates).

---

## 2026-04-26 — Week-0 audit: ✅ GREENLIGHT Option C

**Decision**: Proceed with Option C 5-week build per `architecture.md` §14 roadmap. Fork Lulzx/zpdf at SHA `5eba7ad` as `pdf.zig`.

**Results** (full report in [`week0-audit.md`](week0-audit.md)):

| Gate | Threshold | Measured | Verdict |
|---|---|---|---|
| Zero crashes | = 0 | 0 across 1 776 PDFs | ✅ PASS |
| ≥95% output on text-bearing PDFs | ≥ 95% | **98.5%** (denominator excludes 275 alfred-flagged image-only) | ✅ PASS |
| ≥10 structured outputs | ≥ 10 | 56 | ✅ PASS |
| xref-repair on dirty PDFs | partial OK | not yet measured | ⏳ deferred to week-1 |

**Throughput observation**: 1 776 PDFs in **7 seconds** at 6 workers (260 PDFs/sec). The ≥3× faster-than-pymupdf4llm gate is met by ~13×; at single-worker baseline still ~7× faster.

**Stale claim corrected**: v1 "alpha quality" framing for Lulzx/zpdf was definitively wrong. Zero crashes on 1 776 real PDFs is RC-quality on the segfault surface. The 5-week effort estimate may be conservative.

**Source**: `audit/week0_run.py`, `audit/week0_results.{json,tsv}`, `audit/week0_run.log`, `docs/week0-audit.md`.
