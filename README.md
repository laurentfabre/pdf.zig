# pdf.zig

*Zig CLI for PDF → Markdown extraction, optimised for LLM streaming consumers.*

![Status](https://img.shields.io/badge/status-pre_alpha_(audit_in_progress)-orange)
![Target](https://img.shields.io/badge/target-zlsx_grade_quality-blue)
![Upstream](https://img.shields.io/badge/upstream-Lulzx%2Fzpdf_(CC0)-purple)

> Companion to [zlsx](../zlsx) (Excel reader). Same playbook: production-grade Zig CLI, NDJSON-streaming, brew-tap distributable, fuzz-tested, no Python interpreter floor.
>
> Replaces `pymupdf4llm` in [Alfred](../Alfred)'s pipeline. Validated quality bar = `pymupdf4llm`-equivalent on the [9-cycle Alfred bake-off](docs/alfred-bakeoff-report.md).

---

## What this is

A PDF text-extraction CLI that streams Markdown (and NDJSON) on a per-page basis as it parses. Designed primarily for piping into LLMs:

```bash
pdf.zig extract hotel.pdf | claude -p "Summarise this hotel"
pdf.zig extract --output ndjson *.pdf | python ingest.py
```

vs `pymupdf4llm`, the gains are: (1) no Python startup floor (~300 ms saved per invocation), (2) genuine page-by-page flush (LLM sees content as it parses, doesn't wait for EOF), (3) single static binary distribution.

## Project layout

**This repo is a fork of [Lulzx/zpdf](https://github.com/Lulzx/zpdf)** (CC0). Upstream's source tree is preserved as-is at the project root (`src/`, `build.zig`, `python/`, `web/`, `examples/`); our additions layer alongside in `docs/`, `audit/`, `bake-off/`, `scripts/`. Per Week 3 of the roadmap we'll add `src/stream.zig`, `src/chunk.zig`, etc. per `docs/streaming-layer-design.md`.

```
pdf.zig/
├── README.md                       # this file
├── UPSTREAM-README.md              # Lulzx/zpdf's README, preserved for upstream-PR context
├── LICENSE                         # CC0 (inherited from upstream)
├── build.zig + build.zig.zon       # upstream's; will be extended in Week 3
├── src/                            # upstream parser (16 .zig modules, ~15K LOC)
├── benchmark/  examples/  python/  web/   # upstream's auxiliary trees
├── docs/                           # ← OURS
│   ├── architecture.md             # v3 architecture plan (3 Codex review cycles)
│   ├── alfred-bakeoff-report.md    # 9-cycle empirical evidence for the quality bar
│   ├── decisions.md                # chronological architecture decisions
│   ├── week0-audit.md              # ✅ GREENLIT week-0 audit
│   ├── streaming-layer-design.md   # Week 3 NDJSON layer design
│   └── week1-status.md             # this week's acted-on summary
├── audit/                          # ← OURS
│   ├── week0_run.py                # reproducible harness (1 776 PDFs in ~7 s)
│   ├── xref_fixtures.md            # cases #31–35 fixture set
│   └── (week0_results.{json,tsv}, week0_run.log — gitignored, regenerable)
├── bake-off/                       # ← OURS, empty (Week 5: pdf.zig vs pymupdf4llm rerun)
└── scripts/                        # ← OURS, empty (Week 6: brew-tap publisher etc.)
```

git remotes:
- `origin`   → `git@github.com:laurentfabre/pdf.zig.git` (our fork)
- `upstream` → `https://github.com/Lulzx/zpdf.git` (for `git fetch upstream`)

## Status

**2026-04-26**: ✅ **Week-0 audit GREENLIT** (`docs/week0-audit.md`). All structural gates pass: **0 crashes** on Alfred's 1 776-PDF corpus, **98.5% output rate** on the text-bearing subset, **56 structured outputs**, **7 second** full-corpus runtime at 6 workers (~260 PDFs/sec).

**Next**: 5-week Option C build per [`docs/architecture.md` §14 Roadmap](docs/architecture.md):
- Week 1: fork at SHA `5eba7ad`, triage 47 unexplained empties + 9 decorative-font menu garbages, build xref-repair fixtures
- Week 2: CJK + Cyrillic Unicode correctness (Arabic = emit-as-is + warn)
- Week 3: NDJSON streaming layer + CLI
- Week 4: fuzz suite + ReleaseSafe + checkAllAllocationFailures
- Week 5: bake-off regression vs pymupdf4llm + v1.0-rc1
- Week 6: GH Actions release pipeline + brew tap + v1.0-rc2
- Week 6.5: Cycle-10 of `alfred-bakeoff-report.md` (pdf.zig vs pymupdf4llm rerun)
- Week 7: v1.0 GA tag

## Decisions log (high-level)

See [`docs/decisions.md`](docs/decisions.md) for the full chain.

- **Naming**: `pdf.zig` (not `zpdf` — that name is taken by Lulzx upstream; `zl` prefix matches `zlsx`).
- **Architecture**: Fork Lulzx/zpdf, add LLM-streaming layer + NDJSON envelope + `pymupdf4llm`-parity target. Three options analysed in `docs/architecture.md` §5; Option C wins on weighted-score (~7.9/10 vs 7.6 for MuPDF wrap, 7.4 for from-scratch).
- **Quality bar**: zlsx parity matrix (`docs/architecture.md` §11). Fuzz ≥10 targets at ≥1M iters; corpus ≥30 PDFs incl. xref-repair fixtures (cases #31–35); ReleaseSafe build mode (not ReleaseFast); ≥3× faster than `pymupdf4llm` on Alfred's n=12 corpus.
- **Streaming protocol**: NDJSON envelope with `kind` + `source` + `doc_id` (UUIDv7 minted at invocation start); per-page flush; SIGPIPE-clean; terminal `kind:"fatal"` record on parser death (no SIGABRT in release).
- **License**: MIT or CC0 to match upstream Lulzx attribution. Option A (MuPDF wrapper) was reclassified as AGPL-only after Codex caught the static-link copyleft contagion (see `docs/architecture.md` §5.1).

## Source / context

- **Architecture**: [`docs/architecture.md`](docs/architecture.md) (v3, ~800 lines, 2 Claude↔Codex review cycles)
- **Quality bar evidence**: [`docs/alfred-bakeoff-report.md`](docs/alfred-bakeoff-report.md) (v3.10, 9 review cycles)
- **Sibling project pattern**: [`../zlsx`](../zlsx) — same playbook, ships as brew tap
- **Upstream parser**: [Lulzx/zpdf](https://github.com/Lulzx/zpdf) — CC0, weekly cadence, beta-quality as of Mar 2026
