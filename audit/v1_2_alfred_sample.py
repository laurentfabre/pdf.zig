#!/usr/bin/env python3
"""Stratified sampler for the v1.2 Alfred hotel-tables gold set.

Per docs/v1.2-table-detection-design.md §6.2, the gold set targets 120
manually verified tables across ~50 PDFs. Strata + counts:

  - 30 ruled price tables          (spa price lists with horizontal/vertical rules)
  - 35 unruled menu tables         (dining/breakfast menus with stream layout)
  - 25 unruled factsheet tables    (hotel factsheets, key/value rows)
  - 15 multi-page continuation     (brochures, tables spanning >=2 pages)
  -  8 rotated tables              (landscape rate cards)
  -  7 tagged-PDF tables           (accessibility-marked PDFs)

This script picks PDFs from Alfred's corpus matching each stratum's filename
heuristic, stratifies the sample across hotels for diversity, and writes
audit/tables-gold/<hotel_slug>/<pdf_basename>.tables.json skeletons.

Usage:
  python3 audit/v1_2_alfred_sample.py
  python3 audit/v1_2_alfred_sample.py --target-pdfs 50
  python3 audit/v1_2_alfred_sample.py --reset   # wipe existing skeletons
"""
from __future__ import annotations

import argparse
import json
import random
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

PROJECT = Path("/Users/lf/Projects/Pro/pdf.zig")
ALFRED = Path("/Users/lf/Projects/Pro/Alfred/data/hotel_assets")
GOLD_DIR = PROJECT / "audit" / "tables-gold"
PDFZIG = PROJECT / "zig-out" / "bin" / "pdf.zig"

RNG_SEED = 0x12FAB1E5  # "v1.2 tables"


@dataclass
class Stratum:
    name: str
    target: int
    filename_re: re.Pattern
    description: str
    pdfs: list[Path] = field(default_factory=list)


STRATA: list[Stratum] = [
    Stratum("ruled_price",       30, re.compile(r"(?i)(price|rate|tariff|spa[-_ ]?price|spa[-_ ]?menu)"), "ruled price/rate sheets, horizontal+vertical rules"),
    Stratum("unruled_menu",      35, re.compile(r"(?i)(menu|breakfast|dinner|lunch|brunch|drinks|wine|cocktail)"), "unruled food/drink menus"),
    Stratum("unruled_factsheet", 25, re.compile(r"(?i)(factsheet|fact[-_ ]?sheet|fiche|brochure|datasheet)"), "key/value factsheets"),
    Stratum("multi_page",        15, re.compile(r"(?i)(brochure|catalogue|catalog|guide|directory|booklet)"), "multi-page brochures w/ continued tables"),
    Stratum("rotated",            8, re.compile(r"(?i)(landscape|wide|rate[-_ ]?card)"), "rotated/landscape rate cards"),
    Stratum("tagged_pdf",         7, re.compile(r"(?i)(accessible|tagged|ada|wcag)"), "accessibility-tagged PDFs (/StructTreeRoot)"),
]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target-pdfs", type=int, default=50)
    parser.add_argument("--reset", action="store_true", help="wipe existing skeletons")
    parser.add_argument("--seed", type=lambda s: int(s, 0), default=RNG_SEED)
    args = parser.parse_args()

    if args.reset and GOLD_DIR.exists():
        shutil.rmtree(GOLD_DIR)
    GOLD_DIR.mkdir(parents=True, exist_ok=True)

    if not ALFRED.exists():
        print(f"FATAL: Alfred corpus missing at {ALFRED}", file=sys.stderr)
        return 2

    rng = random.Random(args.seed)

    # Index every PDF in Alfred by filename, classify into strata.
    all_pdfs = sorted(ALFRED.rglob("*.pdf"))
    print(f"Indexed {len(all_pdfs)} PDFs in {ALFRED}")

    # Each PDF lands in at most ONE stratum (first match wins) so we don't
    # double-count. Order in STRATA is "most specific first" → tagged_pdf
    # / rotated come last because their patterns are least selective.
    by_pdf_stratum: dict[Path, str] = {}
    for pdf in all_pdfs:
        for s in STRATA:
            if s.filename_re.search(pdf.name):
                if pdf not in by_pdf_stratum:
                    by_pdf_stratum[pdf] = s.name
                break

    by_stratum: dict[str, list[Path]] = {s.name: [] for s in STRATA}
    for pdf, sname in by_pdf_stratum.items():
        by_stratum[sname].append(pdf)

    # Stratified pick, balanced over hotels for diversity.
    picked: list[tuple[Path, str]] = []
    seen_hotels = set()
    for s in STRATA:
        pool = list(by_stratum[s.name])
        rng.shuffle(pool)
        # First pass: pick PDFs whose hotel hasn't appeared yet.
        for pdf in pool:
            hotel = pdf.relative_to(ALFRED).parts[0]
            if hotel in seen_hotels:
                continue
            picked.append((pdf, s.name))
            seen_hotels.add(hotel)
            if sum(1 for _, sn in picked if sn == s.name) >= max(1, s.target // 4):
                break
        # Second pass: top up from remaining pool ignoring hotel-uniqueness.
        for pdf in pool:
            if pdf in (p for p, _ in picked):
                continue
            picked.append((pdf, s.name))
            if sum(1 for _, sn in picked if sn == s.name) >= max(1, s.target // 4):
                break
        # Stop if we've hit the global PDF target.
        if len(picked) >= args.target_pdfs:
            break

    # Write skeleton .tables.json files.
    written = 0
    skipped = 0
    for pdf, sname in picked:
        rel = pdf.relative_to(ALFRED)
        out_dir = GOLD_DIR / rel.parts[0]
        out_dir.mkdir(parents=True, exist_ok=True)
        out_path = out_dir / (pdf.stem + ".tables.json")
        if out_path.exists():
            skipped += 1
            continue
        # Run pdf.zig info to capture page count, then write skeleton.
        page_count = 0
        try:
            r = subprocess.run([str(PDFZIG), "info", "--json", str(pdf)],
                               capture_output=True, timeout=30, check=False)
            if r.returncode == 0:
                rec = json.loads(r.stdout.decode("utf-8", "replace").splitlines()[0])
                page_count = rec.get("pages", 0)
        except Exception as e:
            print(f"  pdf.zig info failed on {rel}: {e}", file=sys.stderr)
        skeleton = {
            "doc": str(rel),
            "stratum": sname,
            "page_count": page_count,
            "size_bytes": pdf.stat().st_size,
            "annotation_status": "pending",
            "annotator": None,
            "annotated_at": None,
            "tables": [],
        }
        out_path.write_text(json.dumps(skeleton, indent=2))
        written += 1

    # Print summary
    print(f"\nPicked {len(picked)} PDFs from {len(seen_hotels)} hotels (seed=0x{args.seed:x})")
    print(f"Wrote {written} new skeletons to {GOLD_DIR} (skipped {skipped} existing)\n")
    for s in STRATA:
        n = sum(1 for _, sn in picked if sn == s.name)
        print(f"  {s.name:<20s} target={s.target:>2d} picked={n:>2d} pool={len(by_stratum[s.name]):>4d} — {s.description}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
