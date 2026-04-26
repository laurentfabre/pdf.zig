# Xref-repair fixture set (architecture.md §9 cases #31–35)

Fixtures for the deferred Week-0 gate criterion #4 — "cross-ref repair attempted on dirty PDFs". Identified by raw-byte scan of Alfred's full PDF corpus (`/Users/lf/Projects/Pro/Alfred/data/hotel_assets/**/*.pdf`).

## Case #32 — multiple `%%EOF` (incremental updates)

**Population**: 1300 candidates / 1776 PDFs = **73% of the corpus**. This is normal for any PDF that's been edited; the parser MUST walk the chain of `Prev` pointers in successive trailer dicts.

**Selected fixtures** (mix of sizes for fast + comprehensive tests):

| EOF count | Size | Path |
|---|---|---|
| 8 | 1.4 MB | `como-cocoa-island/podere_san_filippo_one_page_factsheet.pdf` |
| 6 | 4.2 MB | `bayerischer-hof-munich/30_HBH_Koch-und_Genussbuch_Osterlamm.pdf` |
| 5 | 211 KB | `bayerischer-hof-munich/Gala_Weinkarte_Bankett_Feb24.pdf` |
| 4 | 2.1 MB | `the-reverie-saigon/Dinner-Dimsum-Menu.pdf` |
| 4 | 249 KB | `chewton-glen-hotel-spa/welcoming-dogs-in-the-treehouses-2020.pdf` |

**Test expectation**: parser walks all trailers; final extracted text equals the latest revision (not the first); no spurious "object not found" errors from stale `Prev` pointers.

## Case #31 — no `%%EOF` marker (truncated / broken)

**Population**: 1 candidate / 1776 = 0.06%. A single truly-truncated PDF.

| Size | Path |
|---|---|
| 11.8 MB | `babylonstoren/33_ELLE-Sep-2013.pdf` |

**Test expectation**: parser falls back to linear-scan recovery. Either emits partial output for what it can recover, OR emits `fatal:truncated` with a clear error. Anything in-between (silent empty, segfault) fails the case.

## Case #35 — trailing garbage after `%%EOF`

**Population**: 1 candidate (with >100B trailing content).

| Trailing bytes | Path |
|---|---|
| 798 198 B (in 798 720 B file) | `babylonstoren/my-fair-lady-march-2019-sa.pdf` |

**Test expectation**: parser ignores trailing content; emits `trailing-garbage:N` warning if the residue is >100 B; doesn't crash on parsing what's after `%%EOF`.

## Cases #33 / #34 — stale trailers / wrong xref entries

**Detection**: requires actually parsing the trailer chains and comparing `Prev` offsets to verify they resolve. Out of scope for the byte-pattern audit; would need a dedicated mini-parser to enumerate. **Action**: catch these via real-world failures during Week 1 audit; back-fill into fixture set as we find them.

## Bonus: linearized PDFs (case #5 — web-optimized first-page hint)

**Population**: 907 candidates / 1776 = **51% of the corpus**.

These aren't broken — they're optimized for web/streaming consumption (first-page hint dictionary). Testing: parser must (a) detect them via the linearization dict, (b) optionally exploit the hint table for fast first-page extraction, (c) gracefully ignore the hint and parse normally if the hint is unreliable.

**Selected fixtures**:

| Size | Path |
|---|---|
| 32 MB | `adare-manor/Wedding-brochure-Nov-24-2.pdf` |
| 16 MB | `aman-le-melezin/Aman-Le-Melezin-Spa-Menu.pdf` |
| 6.5 MB | `airelles-chateau-de-versailles-le-grand-controle/aZM7HFWLo0XkEjDy_MenuTDJ.pdf` |
| 770 KB | `aman-le-melezin/Aman-Le-Melezin-Nama-Menu.pdf` |

## Reproducibility

```bash
# Re-run the byte-pattern scan:
python3 -c '
from pathlib import Path
corpus = Path("/Users/lf/Projects/Pro/Alfred/data/hotel_assets")
for pdf in sorted(corpus.rglob("*.pdf")):
    b = pdf.read_bytes()
    eof = b.count(b"%%EOF")
    if eof > 1: print(eof, pdf.relative_to(corpus))
'
```

## Status

These fixtures are not yet tested against zpdf. Week-1 task: write `audit/xref_repair_test.py` that runs each fixture and verifies the test-expectation criteria. Failures here downgrade the Week-0 gate retroactively (force a Week-1 deeper-audit before committing to the 5-week plan).
