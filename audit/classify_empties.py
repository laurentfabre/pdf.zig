#!/usr/bin/env python3
"""Classify the 39 unexplained empty cases from week-0 audit:
class A — image-text (pymupdf4llm uses 'picture text extraction' marker; OUT OF SCOPE for v1)
class B — real text streams (pymupdf4llm extracts clean text; this is a zpdf bug)
class C — other (pymupdf4llm also fails or produces little text)

Output: audit/empties_classified.tsv with one row per empty PDF + verdict
"""
from __future__ import annotations
import json
import sqlite3
import subprocess
import sys
from pathlib import Path

ZPDF = Path("/Users/lf/Projects/Pro/pdf.zig/zig-out/bin/zpdf")
ALFRED = Path("/Users/lf/Projects/Pro/Alfred/data/hotel_assets")
PYMUPDF_VENV = Path("/Users/lf/Projects/Pro/Alfred/.venv/bin/python")
OUT = Path("/Users/lf/Projects/Pro/pdf.zig/audit/empties_classified.tsv")

js = json.loads(Path("/Users/lf/Projects/Pro/pdf.zig/audit/week0_results.json").read_text())
empty_paths = [r["path"] for r in js["results"] if r["outcome"] == "empty"]

db = sqlite3.connect("/Users/lf/Projects/Pro/Alfred/data/alfred.db")
flagged = set(fn for fn, in db.execute(
    "SELECT filename FROM document WHERE quality_flag IS NOT NULL"
))

unexplained = []
for path in empty_paths:
    fn = path.split("/")[-1]
    if fn in flagged:
        continue
    unexplained.append(path)

print(f"Triaging {len(unexplained)} unexplained empties via pymupdf4llm comparison...\n")

OUT.write_text("path\tpym_chars\tpym_picture_marker\tpym_first120\tverdict\n")
classes = {"A_image_text": 0, "B_real_text_zpdf_bug": 0, "C_other": 0}

for i, path in enumerate(unexplained, 1):
    full = ALFRED / path
    if not full.exists():
        continue
    try:
        # Run pymupdf4llm on page 1 only for speed
        res = subprocess.run(
            [str(PYMUPDF_VENV), "-c",
             f"import pymupdf4llm; "
             f"t = pymupdf4llm.to_markdown('{full}', pages=[0], show_progress=False); "
             f"print(t)"],
            capture_output=True, text=True, timeout=30, check=False,
        )
        pym = res.stdout
    except subprocess.TimeoutExpired:
        pym = "TIMEOUT"

    # Classify
    has_picture_marker = "picture text" in pym.lower() or "intentionally omitted" in pym.lower()
    pym_clean = pym.replace("\n", " ").strip()[:120]
    pym_chars = len(pym)

    if has_picture_marker:
        verdict = "A_image_text"
    elif pym_chars > 200 and not pym_chars < 50:
        verdict = "B_real_text_zpdf_bug"
    else:
        verdict = "C_other"
    classes[verdict] += 1

    with OUT.open("a") as f:
        f.write(f"{path}\t{pym_chars}\t{int(has_picture_marker)}\t{pym_clean}\t{verdict}\n")

    if i % 5 == 0 or i == len(unexplained):
        print(f"  [{i:>3d}/{len(unexplained)}]  A={classes['A_image_text']:>3d}  "
              f"B={classes['B_real_text_zpdf_bug']:>3d}  C={classes['C_other']:>3d}")

print(f"\nSummary:")
for k, v in classes.items():
    print(f"  {k:<24s}  {v}/{len(unexplained)}")
print(f"\nOutput → {OUT}")
