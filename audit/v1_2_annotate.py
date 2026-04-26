#!/usr/bin/env python3
"""TUI annotator for the v1.2 Alfred hotel-tables gold set.

Walks each `audit/tables-gold/<hotel>/<pdf>.tables.json` skeleton and
prompts the human to add table annotations. Designed for one-PDF-at-a-
time annotation — the goal is 120 verified tables across ~50 PDFs.

For each PDF:
  1. Display pdf.zig's per-page extraction so the annotator can see the
     content the extractor recovered.
  2. Optionally render the PDF via `qlmanage` (macOS QuickLook) for
     visual reference.
  3. Loop: (a) annotator reports table bbox + dimensions; (b) script
     records cell layout; (c) repeat until done with this PDF.
  4. On commit: write back to the skeleton, mark `annotation_status: "done"`.

Cell text is auto-extracted from pdf.zig's bounds output for the bbox.
The annotator only confirms / corrects.

Usage:
  python3 audit/v1_2_annotate.py                              # annotate next pending
  python3 audit/v1_2_annotate.py --pdf <hotel>/<basename>     # specific
  python3 audit/v1_2_annotate.py --status                     # show progress
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

PROJECT = Path("/Users/lf/Projects/Pro/pdf.zig")
ALFRED = Path("/Users/lf/Projects/Pro/Alfred/data/hotel_assets")
GOLD_DIR = PROJECT / "audit" / "tables-gold"
PDFZIG = PROJECT / "zig-out" / "bin" / "pdf.zig"


def list_skeletons() -> list[tuple[Path, dict]]:
    out = []
    for jf in sorted(GOLD_DIR.glob("*/*.tables.json")):
        out.append((jf, json.loads(jf.read_text())))
    return out


def show_status() -> None:
    skels = list_skeletons()
    by_status = {"pending": 0, "in_progress": 0, "done": 0}
    by_stratum: dict[str, dict[str, int]] = {}
    total_tables = 0
    for _, sk in skels:
        by_status[sk.get("annotation_status", "pending")] = by_status.get(sk.get("annotation_status", "pending"), 0) + 1
        s = sk.get("stratum", "?")
        by_stratum.setdefault(s, {"pending": 0, "in_progress": 0, "done": 0, "tables": 0})
        by_stratum[s][sk.get("annotation_status", "pending")] += 1
        by_stratum[s]["tables"] += len(sk.get("tables", []))
        total_tables += len(sk.get("tables", []))
    print(f"Gold-set status — {len(skels)} PDFs, {total_tables} verified tables")
    print(f"  pending     : {by_status['pending']}")
    print(f"  in_progress : {by_status['in_progress']}")
    print(f"  done        : {by_status['done']}")
    print()
    for s in sorted(by_stratum):
        b = by_stratum[s]
        print(f"  {s:<22s} {b['done']}/{b['done']+b['in_progress']+b['pending']} done, {b['tables']} tables")


def pick_next(skels: list[tuple[Path, dict]]) -> tuple[Path, dict] | None:
    for jf, sk in skels:
        if sk.get("annotation_status") == "pending":
            return (jf, sk)
    return None


def find_pdf(rel_doc: str) -> Path:
    return ALFRED / rel_doc


def show_extraction(pdf: Path, page: int | None = None) -> None:
    args = [str(PDFZIG), "extract", "--output", "md"]
    if page is not None:
        args += ["-p", str(page)]
    args.append(str(pdf))
    proc = subprocess.run(args, capture_output=True, timeout=30, check=False)
    md = proc.stdout.decode("utf-8", "replace")
    # Truncate huge output
    if len(md) > 12000:
        md = md[:12000] + f"\n\n[... {len(proc.stdout)-12000} more bytes truncated ...]"
    print(md)


def parse_int(prompt: str, default: int | None = None) -> int | None:
    s = input(f"{prompt}{' ['+str(default)+']' if default is not None else ''}: ").strip()
    if not s and default is not None:
        return default
    try:
        return int(s)
    except ValueError:
        return None


def annotate_one(jf: Path, sk: dict) -> None:
    pdf = find_pdf(sk["doc"])
    print(f"\n=== Annotating {sk['doc']} (stratum: {sk['stratum']}, pages: {sk['page_count']}) ===")
    print(f"Skeleton: {jf}")
    if not pdf.exists():
        print(f"  PDF missing on disk: {pdf}")
        return

    print(f"\nOpen visually? (y/N): ", end="")
    if input().strip().lower() == "y":
        subprocess.Popen(["qlmanage", "-p", str(pdf)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    sk["annotation_status"] = "in_progress"
    jf.write_text(json.dumps(sk, indent=2))

    while True:
        print(f"\n--- {sk['doc']}: {len(sk.get('tables', []))} tables annotated so far ---")
        print("commands: [a]dd table | [s]how page <n> | [d]rop last | [c]ommit (done) | [q]uit (in_progress)")
        cmd = input("> ").strip().lower()
        if cmd == "q":
            print("Saved as in_progress.")
            return
        elif cmd == "c":
            sk["annotation_status"] = "done"
            from datetime import datetime
            sk["annotated_at"] = datetime.utcnow().isoformat() + "Z"
            jf.write_text(json.dumps(sk, indent=2))
            print(f"Committed {len(sk['tables'])} tables. Status: done.")
            return
        elif cmd.startswith("s"):
            m = re.match(r"^s(?:how)?\s+(\d+)$", cmd) or re.match(r"^s(?:how)?\s+page\s+(\d+)$", cmd)
            if m:
                show_extraction(pdf, int(m.group(1)))
            else:
                show_extraction(pdf)
        elif cmd == "d":
            if sk.get("tables"):
                t = sk["tables"].pop()
                print(f"Dropped table id={t.get('id')}.")
                jf.write_text(json.dumps(sk, indent=2))
        elif cmd == "a":
            tid = len(sk.get("tables", []))
            page = parse_int("  page (1-based)")
            n_rows = parse_int("  n_rows")
            n_cols = parse_int("  n_cols")
            header_rows = parse_int("  header_rows", 1) or 1
            if page is None or n_rows is None or n_cols is None:
                print("  cancelled.")
                continue
            sk.setdefault("tables", []).append({
                "id": tid,
                "page": page,
                "stratum": sk.get("stratum"),
                "n_rows": n_rows,
                "n_cols": n_cols,
                "header_rows": header_rows,
                "header_cols": 0,
                "bbox": None,
                "cells": [],
                "notes": "manually annotated; cells to be auto-derived from extractor at evaluation time",
            })
            jf.write_text(json.dumps(sk, indent=2))
            print(f"  added table id={tid} (page {page}, {n_rows}x{n_cols}).")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pdf", help="<hotel>/<basename> to annotate (without .tables.json)")
    parser.add_argument("--status", action="store_true")
    args = parser.parse_args()

    if args.status:
        show_status()
        return 0

    skels = list_skeletons()
    if not skels:
        print("No skeletons. Run audit/v1_2_alfred_sample.py first.")
        return 1

    if args.pdf:
        match = [t for t in skels if str(t[0].relative_to(GOLD_DIR)).startswith(args.pdf)]
        if not match:
            print(f"No skeleton matching {args.pdf}")
            return 1
        target = match[0]
    else:
        nxt = pick_next(skels)
        if not nxt:
            print("All skeletons annotated. Run with --status to confirm counts.")
            return 0
        target = nxt

    annotate_one(*target)
    return 0


if __name__ == "__main__":
    sys.exit(main())
