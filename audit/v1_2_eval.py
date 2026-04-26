#!/usr/bin/env python3
"""v1.2 table-extraction evaluator (skeleton).

Compares pdf.zig's `kind:"table"` records against the Alfred hotel gold
set (`audit/tables-gold/<hotel>/<pdf>.tables.json`). Reports table-level
recall, structural F1, and per-stratum breakdown.

This is the v1.2-cycle-1 evaluator stub. TEDS-Struct + GriTS_Con will
land in v1.2-cycle-2 once Pass B/C are implemented and the gold set is
populated past the seed examples.

Per docs/v1.2-table-detection-design.md §5.1, hard gates for v1.2-rc1:
  - Table recall  ≥ 0.90 on Alfred gold set
  - TEDS-Struct  ≥ 0.85 on Alfred gold set
  - GriTS_Con    ≥ 0.75 on PubTables-1M sanity subset

Usage:
  python3 audit/v1_2_eval.py
  python3 audit/v1_2_eval.py --by-stratum
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

PROJECT = Path("/Users/lf/Projects/Pro/pdf.zig")
ALFRED = Path("/Users/lf/Projects/Pro/Alfred/data/hotel_assets")
GOLD_DIR = PROJECT / "audit" / "tables-gold"
PDFZIG = PROJECT / "zig-out" / "bin" / "pdf.zig"


def load_gold():
    gold = []
    for jf in sorted(GOLD_DIR.glob("*/*.tables.json")):
        sk = json.loads(jf.read_text())
        if sk.get("annotation_status") == "done" and sk.get("tables"):
            gold.append(sk)
    return gold


def predict(pdf_path: Path) -> list[dict]:
    """Run pdf.zig extract on a PDF and pull out kind:"table" records."""
    try:
        proc = subprocess.run(
            [str(PDFZIG), "extract", str(pdf_path)],
            capture_output=True, timeout=60, check=False,
        )
    except subprocess.TimeoutExpired:
        return []
    out = []
    for line in proc.stdout.decode("utf-8", "replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        if rec.get("kind") == "table":
            out.append(rec)
    return out


def page_recall(gold_tables: list[dict], predicted: list[dict]) -> tuple[int, int]:
    """Match each gold table to a predicted table on the same page with
    the same (n_rows, n_cols) shape. Returns (matched, total_gold)."""
    matched = 0
    pred_used = [False] * len(predicted)
    for g in gold_tables:
        for i, p in enumerate(predicted):
            if pred_used[i]:
                continue
            if (p.get("page") == g.get("page")
                and p.get("n_rows") == g.get("n_rows")
                and p.get("n_cols") == g.get("n_cols")):
                matched += 1
                pred_used[i] = True
                break
    return matched, len(gold_tables)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--by-stratum", action="store_true")
    args = ap.parse_args()

    if not PDFZIG.exists():
        print(f"FATAL: {PDFZIG} missing — run zig build -Doptimize=ReleaseSafe", file=sys.stderr)
        return 2

    gold = load_gold()
    if not gold:
        print("No annotated PDFs in the gold set — run the annotator first.", file=sys.stderr)
        return 1

    total_gold_tables = sum(len(sk["tables"]) for sk in gold)
    total_matched = 0
    total_predicted = 0
    by_stratum: dict[str, dict[str, int]] = {}

    for sk in gold:
        pdf = ALFRED / sk["doc"]
        if not pdf.exists():
            print(f"  [SKIP] {sk['doc']} missing on disk", file=sys.stderr)
            continue
        predicted = predict(pdf)
        m, g = page_recall(sk["tables"], predicted)
        total_matched += m
        total_predicted += len(predicted)
        engine_counts = {}
        for p in predicted:
            engine_counts[p.get("engine", "?")] = engine_counts.get(p.get("engine", "?"), 0) + 1
        st = sk.get("stratum", "?")
        by_stratum.setdefault(st, {"matched": 0, "gold": 0, "predicted": 0})
        by_stratum[st]["matched"] += m
        by_stratum[st]["gold"] += g
        by_stratum[st]["predicted"] += len(predicted)
        marker = "OK" if m == g else "PARTIAL" if m > 0 else "MISS"
        print(f"  [{marker:>7s}] {sk['doc']:<70s} gold={g} matched={m} predicted={len(predicted)} engines={engine_counts}")

    overall_recall = total_matched / total_gold_tables if total_gold_tables else 0.0
    overall_precision = total_matched / total_predicted if total_predicted else 0.0
    f1 = 2 * overall_recall * overall_precision / (overall_recall + overall_precision) if (overall_recall + overall_precision) > 0 else 0.0

    print()
    print(f"  Annotated PDFs    : {len(gold)}")
    print(f"  Gold tables       : {total_gold_tables}")
    print(f"  pdf.zig predicted : {total_predicted}")
    print(f"  Matched           : {total_matched}")
    print(f"  Recall            : {overall_recall:.3f}  (target ≥0.90 for v1.2-rc1)")
    print(f"  Precision         : {overall_precision:.3f}")
    print(f"  F1                : {f1:.3f}")

    if args.by_stratum:
        print(f"\n  Per-stratum:")
        for s, b in sorted(by_stratum.items()):
            r = b["matched"] / b["gold"] if b["gold"] else 0.0
            p = b["matched"] / b["predicted"] if b["predicted"] else 0.0
            print(f"    {s:<22s}  recall={r:.3f}  precision={p:.3f}  matched={b['matched']}/{b['gold']}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
