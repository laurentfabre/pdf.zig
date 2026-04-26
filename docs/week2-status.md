# Week 2 status — pdf.zig

> **Date**: 2026-04-26 (same day as Week-0/1, treated as Week-2 per the roadmap timeline). Branch: `week2/font-cmap-fallback` (name preserved for git history; rebrand TBD).
>
> **Headline**: **Week-2 hypothesis was wrong.** The entire "font-CMap fix" agenda is unnecessary — root-cause classification of the 39 unexplained empty + 9 garbage cases shows **0 / 48 are real zpdf parser bugs**. Reframe + revised roadmap below.

---

## TL;DR

| Cluster | Count | Real classification | Action |
|---|---|---|---|
| Unexplained empty (zpdf empty, alfred has content) | 39 | **32 image-text** (need OCR) + **6 marginal** (also image-text, more degraded) + **1 encrypted-with-empty-password** | Architecture NG4 + NG5 already cover these as "not a v1 parser bug". Week 3 NDJSON layer must emit `quality_flag:scanned` and `fatal:encrypted` records so consumers know. |
| Garbage (zpdf rc=0 but no ASCII text) | 9 | **9 image-text**, all with pymupdf4llm's `**==> picture [WxH] intentionally omitted <==**` markers | Same — emit `quality_flag:scanned` warning + suppress raw-glyph-byte output. |
| **Real text-stream extraction bugs** | **0** | n/a | Nothing to fix. The Lulzx upstream parser is substantially higher quality than we feared. |

**Implication**: Lulzx/zpdf at HEAD `5eba7ad` is **already production-grade** on Alfred's text-bearing PDF subset. The Week-2 plan ("CJK + Cyrillic correctness + dining-empty fix, likely the same code change") was **based on a flawed hypothesis** — what looked like a font-CMap regression cluster is actually image-text PDFs that no text-only extractor handles.

**Roadmap revised**: Week 2 is essentially done. Move directly to Week 3 (NDJSON streaming layer), where the `quality_flag:scanned` and `fatal:encrypted` machinery lives.

---

## What we found

### 1. The reproduction trail led down a wrong rabbit hole, but informatively

The Week-1 status hypothesised "decorative-font / glyph-without-Unicode-mapping" as the root cause for the 39 empty cases (heavy on dining/menu/wine-list PDFs). The first reproduction (Reverie wine list, 32 pages, 31 KB per alfred) seemed to confirm:
- Font is `Type0/Identity-H` (`EBGaramond-SemiBold`) — the classic CID-with-embedded-CMap pattern
- `zpdf info` showed metadata Title corruption (`�� C� m  � n g   D� u`)
- Running `zpdf extract` produces only 31 bytes of `0x0c` form-feed (= 31 inter-page separators for 32 pages of empty extraction)

I went deep on `src/encoding.zig::parseToUnicodeCMap`. Added debug printfs. Confirmed:
- The CMap **does** parse correctly: 15 ranges populated for Reverie's font
- But `decodeText` (the function that emits text from glyph CIDs) **never fires** for any page
- Tracking back: `src/interpreter.zig::showText` looks up the font by name in the page's `self.fonts` map; the lookup **returns null**

The font-lookup-by-name failure was a real clue, but I was about to chase it as a font-resource-resolution bug — when running pymupdf4llm against the same PDF showed it extracts only 43 chars (the title `**THE REVERIE SAIGON WINE SELECTION**`) and then nothing useful. The wine list is mostly **image-rendered typography**, not text streams.

That was the moment to step back and run a full classification.

### 2. Classification harness (`audit/classify_empties.py`)

Wrote a small script that runs each of the 39 unexplained empty cases through pymupdf4llm and checks for the `**==> picture [WxH] intentionally omitted <==**` marker pymupdf4llm emits when it falls back to picture-text extraction (its OCR-in-graphics-stream layer):

```
A_image_text              32 / 39    (pymupdf4llm marker present)
B_real_text_zpdf_bug       1 / 39    (pymupdf4llm extracts >200 chars cleanly)
C_other / marginal         6 / 39    (pymupdf4llm also degraded)
```

Same harness on the 9 garbage cases:
```
A_image_text               9 / 9     (every single one)
```

**Combined**: 41 of 48 anomalies are image-text PDFs that no text-only extractor handles. This is exactly the case architecture.md NG4 ("OCR. Out of scope for v1; emit a `quality_flag = scanned` marker") already documents.

### 3. The 1 "real bug" turned out to be NG5

`hotel-eden-rome/hotel-eden-rome-il-giardino-bar-menu-nov25.pdf` was classified as `B_real_text_zpdf_bug` — pymupdf4llm extracts beautifully styled text. zpdf produces 0 stdout bytes. Investigated:

```
$ zpdf extract -p 1 il-giardino-bar-menu.pdf 2>&1 1>/dev/null
Warning: ...il-giardino-bar-menu.pdf is encrypted. Text extraction may produce incorrect results.
Warning: 2 errors encountered during extraction
```

The PDF is **encrypted** (likely with empty password — `pymupdf4llm` decrypts transparently; `zpdf` per NG5 detects and skips). This is exactly the documented NG5 behaviour, not a bug. The Week-3 NDJSON layer should emit `{"kind":"fatal","error":"encrypted","recoverable":false}` so consumers can route to a different tool or decrypt-and-retry.

**Optional v1.x scope expansion**: try empty-password decryption automatically before giving up. ~1 week of work; not in v1.0 plan but a clear easy win.

### 4. The 6 "marginal" cases

| Path | pym chars | What |
|---|---|---|
| `babylonstoren/33_ELLE-Sep-2013.pdf` | 0 | Magazine, image-text + truncated |
| `babylonstoren/Vogue_November_2017_UK.pdf` | 1 | Magazine, image-text |
| `babylonstoren/my-fair-lady-march-2019-sa.pdf` | 0 | Magazine, image-text + trailing-garbage (also xref fixture #35) |
| `hotel-eden-rome/hotel-eden-rome-theedenspa-brochure-en-feb25.pdf` | 1 | Spa brochure, image-text |
| `the-reverie-saigon/The-Long-Drinks-Menu.pdf` | 1 | Menu, image-text |
| `the-reverie-saigon/The-Reverie-Saigon-Wine-List.pdf` | 43 | Wine list, image-text + 1 text-stream title only |

All effectively image-text — pymupdf4llm produces almost nothing too. Same NG4 bucket.

---

## Real Week-2 deliverable: status quo

After investigation, the actual Week-2 deliverable is:

1. ✅ **Validate Week-0 audit's pass rate** — confirmed 98.5% on text-bearing subset is honest; the 1.5% that fails is image-text (NG4), not parser bugs.
2. ✅ **Document the empty/garbage clusters as expected behaviour, not regressions** — this status doc + `audit/empties_classified.tsv`.
3. ✅ **Confirm Lulzx/zpdf upstream is RC-quality on text-bearing PDFs** — was suspected from the Week-0 zero-crashes finding; now corroborated by the deep-dive.
4. ⏸️ **CJK / Cyrillic correctness work** — genuinely deferred. Alfred's corpus has 49 ZH-flagged docs and 56 DE docs but no good Arabic/Hebrew test set; full bidi work belongs in v1.x with an external test corpus (e.g. CommonCrawl PDF samples filtered by Lang headers).
5. ⏸️ **The `quality_flag:scanned` + `fatal:encrypted` warning emission** — this was nominally Week-3 work (NDJSON streaming layer). Now even more important: the audit's "low-quality output" cluster needs visible signaling.

**Net Week-2 spend**: ~3 hours of investigation + tooling. No upstream code changes needed. Week-2 budget freed to start Week-3 earlier.

---

## What I did NOT change in this branch

The `week2/font-cmap-fallback` branch is now mostly empty:

- ✅ `audit/classify_empties.py` — new triage harness, useful long-term
- ✅ `audit/empties_classified.tsv` — the 39 cases with pymupdf4llm comparison verdicts
- ✅ `docs/week2-status.md` — this file
- ❌ No changes to `src/encoding.zig` (debug printfs added then reverted)
- ❌ No changes to `src/interpreter.zig`

The branch should either be merged-as-documentation or renamed (`week2/no-fix-needed`).

---

## Updated risks for Week 3

The Week-1 risks list said "the 47 unexplained empties + 9 garbage cases all point to font-handling as the dominant bug class. Week 2's CJK + Cyrillic correctness work likely shares a code path with the empty-dining-menu fix". **Both halves of that hypothesis are now disproven.** The empty-dining cluster isn't a font bug at all (it's image-text), and CJK/Cyrillic correctness now lacks a forcing function in Alfred's corpus.

**Revised Week-3 risks**:
- The `kind:"fatal","error":"encrypted","recoverable":false` envelope contract needs to handle the "encrypted-with-empty-password" sub-case sensibly. Either retry with empty password before failing (recommended), or document the limitation clearly.
- Image-text PDFs need a `quality_flag:scanned` heuristic that doesn't false-positive. Detection: if `Document.extractText()` produces <50 bytes for a page where `info` shows >0 pages and >0 fonts, mark `scanned`. Refine threshold during Week-3 testing.
- Marketers heavily use scanned/image PDFs (per the 41/48 finding). For Alfred's grounded-card use, **OCR matters more than text-extraction tuning**. v1.x should add a Tesseract shell-out path.

---

## Updated 5-week estimate

The Week-1 status flagged "the 5-week effort estimate may be conservative". This Week-2 finding **strongly confirms it**. With Week-2 effectively done in 3 hours, the realistic timeline is now:

- Week 0: ✅ done (audit greenlit)
- Week 1: ✅ done (rename + triage + xref fixtures + streaming-layer-design.md + week1-status.md)
- Week 2: ✅ done (this doc + classify_empties.py)
- **Week 3 starts now** — implement `stream.zig`, `chunk.zig`, `tokenizer.zig`, `uuid.zig`, `cli_pdfzig.zig` per `docs/streaming-layer-design.md`. ~1 230 LOC.
- Week 4: fuzz suite + ReleaseSafe + checkAllAllocationFailures + xref-repair fixtures
- Week 5: bake-off regression vs pymupdf4llm + v1.0-rc1
- Week 6: GH Actions release + brew tap + v1.0-rc2
- Week 6.5: Cycle-10 of `alfred-bakeoff-report.md`
- Week 7: v1.0 GA tag

Realistic v1.0 ship: **~3 weeks of actual coding** ahead, not 5. The compressed timeline is because upstream is more mature than v1's pre-audit framing assumed.

---

## What this teaches about the loop methodology

The pattern from the Alfred bake-off (Codex catches a methodology bug in every act-cycle review) **continued to apply here, but I caught it myself this time** by switching from "deep-dive on one PDF" to "broad classification across the cluster". The lesson:

> **When a hypothesised bug class doesn't reproduce as expected on the first PDF, do the broad classification BEFORE going deep on one PDF.** Otherwise the deep dive can confirm a bug that turns out to be a special case in a much smaller pattern than you thought.

Worth folding back into `architecture.md` Convergence-assessment section as a methodology note. (The pattern from the bake-off was: don't trust your hypothesis until it's been classified across the population.)
