# pdf.zig

*Zig CLI for PDF → Markdown extraction, optimised for LLM streaming consumers.*

![Status](https://img.shields.io/badge/status-v1.0--rc2-blue)
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

## Install

> **Status (2026-04-26)**: **v1.0-rc2** released. RC artifacts on the [GitHub Releases page](https://github.com/laurentfabre/pdf.zig/releases). v1.0 GA after Week-7 cycle-10 bake-off rerun.

### Homebrew (macOS / Linux)

```bash
brew tap laurentfabre/pdf.zig
brew install pdf.zig
```

The tap formula lives at [`scripts/Formula/pdf-zig.rb`](scripts/Formula/pdf-zig.rb) in this repo and is mirrored to `laurentfabre/homebrew-pdf.zig` at each release.

### Pre-built binary (any platform)

Download the matching tarball/zip from [Releases](https://github.com/laurentfabre/pdf.zig/releases), verify the checksum, and put `bin/pdf.zig` somewhere on your `$PATH`:

```bash
TAG=v1.0-rc2
ARCH=aarch64-macos   # or x86_64-macos / x86_64-linux / aarch64-linux / x86_64-windows
curl -LO "https://github.com/laurentfabre/pdf.zig/releases/download/$TAG/pdf.zig-$TAG-$ARCH.tar.gz"
curl -LO "https://github.com/laurentfabre/pdf.zig/releases/download/$TAG/SHA256SUMS"
sha256sum -c <(grep "$ARCH" SHA256SUMS)
tar xzf "pdf.zig-$TAG-$ARCH.tar.gz"
sudo mv "pdf.zig-$TAG-$ARCH/bin/pdf.zig" /usr/local/bin/
```

### Python bindings

```bash
pip install py-pdf-zig
```

```python
from zpdf import Document

with Document("hotel.pdf") as doc:
    for i in range(doc.page_count):
        print(doc.extract_page(i))
```

The package keeps the upstream-compat import name `zpdf` for ABI continuity.

### From source

```bash
git clone https://github.com/laurentfabre/pdf.zig
cd pdf.zig
zig build -Doptimize=ReleaseSafe       # requires zig 0.16.0+
./zig-out/bin/pdf.zig --help
```

5-platform cross-compilation works from any single host: `zig build -Dtarget=aarch64-linux …` etc.

---

## Status

**2026-04-26**: ✅ **v1.0-rc2** cut. All Week-0 → Week-6 gates green:
- **Week 0**: 0 crashes on Alfred's 1,776-PDF corpus, 98.5% output rate on the text-bearing subset, 7 s full-corpus runtime
- **Week 4**: 11 fuzz targets × 1M iters each = **11M iters, 0 panics**; 11/11 xref-repair fixtures; 40-PDF corpus regression clean; 4 NaN/inf upstream panic sites fixed
- **Week 5**: bake-off vs `pymupdf4llm` n=12 — **121× faster aggregate**, 78.9% char parity, 2 documented out-of-scope buckets (CJK + image-text)
- **Week 6**: GH Actions release pipeline (5 platforms cross-compile from one runner), brew tap formula, Python bindings rebuilt against pdf.zig HEAD

Remaining for v1.0 GA: cycle-10 of [`docs/alfred-bakeoff-report.md`](docs/alfred-bakeoff-report.md) (Week 6.5) → v1.0 GA tag (Week 7). Per-week status docs live alongside the architecture: [`docs/week0-audit.md`](docs/week0-audit.md), [`docs/week1-status.md`](docs/week1-status.md), [`docs/week2-status.md`](docs/week2-status.md), [`docs/streaming-layer-design.md`](docs/streaming-layer-design.md), [`docs/week5-bakeoff-report.md`](docs/week5-bakeoff-report.md).

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
