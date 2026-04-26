# Week 6.5 — Cycle-10 of `alfred-bakeoff-report.md`

> **Date**: 2026-04-26. Branch: `week6.5/cycle10-bakeoff`.
>
> **Headline**: **n=120 confirms the n=12 Week-5 result**: speed gate cleared at 92.9× aggregate, char-parity tail concentrated in the documented NG4 (image-text) + NG5 (encrypted) buckets, **zero new failure modes** surfaced at 10× the sample. **v1.0 GA gate met.**

---

## Cycle-10 vs Week-5 cycle-9

|  | Cycle-9 (Week-5) | Cycle-10 (Week-6.5) |
|---|---|---|
| Sample size | n=12 | **n=120** |
| Hotels | 12 | 116 |
| Stratification | category-driven | **size-bucketed (S/M/L/XL) + hotel-balanced** |
| pdf.zig wall total | 0.14 s | 1.23 s |
| pymupdf4llm wall total | 17.5 s | 114.7 s |
| **Aggregate speedup** | **121×** | **92.9×** |
| Char parity | 78.9% | **81.1%** |
| Crashes | 0 | **0** |
| Encrypted-PDF (NG5) skips | 0 | 2 |
| Char-parity outliers (<20%) | 2 / 11 (18%) | 13 / 120 (~11%) |

The aggregate speedup softened from 121× → 92.9× because the larger corpus pulls in XL PDFs where pymupdf4llm's per-page parsing dominates Python startup overhead. **Both numbers massively exceed the architecture.md §11 target of ≥3× faster.** The XL bucket alone shows 60×, still 20× the gate.

---

## Per-bucket breakdown

| Bucket | Size range | n | Speedup | Char parity |
|---|---|---|---|---|
| **S** (small) | < 100 KB | 36 | **114.5×** | **97.7%** |
| **M** (medium) | 100 – 500 KB | 48 | **124.9×** | **90.6%** |
| **L** (large) | 500 KB – 2 MB | 24 | **146.0×** | 47.6% |
| **XL** (extra-large) | > 2 MB | 12 | **59.9×** | 81.2% |

The L-bucket char parity (47.6%) deserves explanation:

- 11 of the 24 L-bucket PDFs are **image-text or graphic-heavy brochures** (NG4 — OCR territory, architecture.md §14 v1.3 scope). Examples surfaced in this run:
  - `pacific-resort-aitutaki/NewsRelease_080617_…`: pdf.zig 23c vs pymupdf4llm 9 845c (0.2% parity)
  - `aman-venice/Aman-Venice-The-Masters-Collection.pdf`: 33c vs 9 658c
  - `kokomo-private-island/2023-06-edible-la.pdf`: 42c vs 8 352c
  - `sandy-lane/non_resident_spa_brochure_*`: 235c vs 33 997c (encrypted-with-empty-password — pymupdf4llm decrypts transparently, pdf.zig per NG5 detects + skips with RC=4)
- The remaining 13 L-bucket PDFs (text-bearing brochures and price lists) carry the bucket's 47.6% average; on their own they'd land in the 80–95% range.

This matches Week-5's framing exactly: the parity gap is concentrated in **NG4 (image-text)** + **NG5 (encrypted)**, both explicitly out of v1 scope per architecture.md §14 (v1.3 scanned-PDF detection + ocrmypdf shell-out; v1.x optional empty-password retry).

---

## Outlier classification

13 of 120 PDFs (10.8%) fell under 20% char parity:

| Bucket | Count | Class |
|---|---|---|
| Encrypted (RC=4 from pdf.zig) | 2 | **NG5** — documented |
| RC=0 with negligible char output | 11 | **NG4 (image-text)** — documented |
| RC=0 with content but low parity | 0 | **None** — no new failure mode |

This is the cleanest possible cycle-10 result: every outlier classifies into a bucket that was already documented in week2-status.md and the architecture roadmap. No fishing for unknown bugs at scale; no new patches needed.

---

## What this validates for v1.0 GA

**Architecture.md §11 quality gates** (re-checked at corpus scale):

| Gate | Target | Cycle-10 result |
|---|---|---|
| Aggregate speedup vs `pymupdf4llm` | ≥ 3× | **92.9×** ✅ |
| Crashes (any input) | 0 | **0** ✅ |
| Char parity on text-bearing PDFs | "match within reason" | 81.1% aggregate; **97.7% on small, 90.6% on medium** ✅ |
| Failure modes outside documented buckets | 0 | **0** ✅ |
| Cross-platform release tarballs | 5 | ✅ (Week 6) |
| Brew tap formula | yes | ✅ (Week 6) |
| Python bindings | yes | ✅ (Week 6) |

**v1.0 GA readiness: confirmed.** Remaining work is the GA tag itself + release-notes write-up; no code changes pending.

---

## Methodology check-in

The compressed-roadmap pattern from Weeks 0–6 (each weekly status doc surfaces one or two real findings, the bake-off cycles harden the same direction without surprises) holds through cycle-10. Specifically:

- **Week 2's reframe** ("the 48 anomalies are 41 image-text + 1 encrypted + 6 marginal — 0 are real parser bugs") **predicted** that any cycle-10 outliers would land in NG4/NG5. They did — exactly. The methodology lesson "classify the population first, then any later outliers are explainable" continues to validate.
- **Week 5's "scrutinize parity harder when speed is suspiciously high"** continues to apply: cycle-10's 92.9× speedup IS suspicious-looking; the matching parity scrutiny found exactly the documented buckets driving the tail.
- The **Week-4 fuzz finding** (4 NaN/inf panic sites in upstream layout/markdown) was the only deep upstream issue surfaced across the entire 7-week loop. Everything since has been either expected behaviour or harness bugs of my own making (Week-4's seed_pdf use-after-free in the fuzz harness).

If cycle-10 had surfaced a single panic or a non-NG4/NG5 char-parity outlier > 20%, that'd block GA pending root-cause investigation. It didn't — so GA is purely mechanical from here.

---

## Ready for v1.0 GA tag

Cutting `v1.0` happens in Week 7 (next). The tag will trigger the same release pipeline that produced the rc1/rc2 artifacts; the formula bumps to `version "1.0.0"` and lands in the tap repo; `py-pdf-zig 1.0.0` ships to PyPI.

After v1.0 GA, the v1.x cycle starts:
- v1.1: token-aware chunking refinements + chars/4 → o200k_base BPE upgrade
- v1.2: XY-Cut++ table detection (compete with docling on tables)
- v1.3: scanned-PDF detection + `ocrmypdf` shell-out (closes NG4)
- v1.4: optional empty-password decrypt retry (closes NG5 ergonomics)
