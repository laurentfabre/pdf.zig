#!/usr/bin/env python3
"""TEDS-Struct + GriTS_Con evaluators for pdf.zig v1.2 tables.

Per docs/v1.2-table-detection-design.md §5.1, the v1.2 acceptance gates
are:

  - Table recall @ IoU≥0.8 ≥ 0.90  (gold set)
  - TEDS-Struct ≥ 0.85              (gold set)
  - GriTS_Con ≥ 0.75                (PubTables-1M sanity subset)

This module implements two structural metrics. Both are content-blind
in v1: they score on (n_rows, n_cols, header_rows, cell-grid shape with
rowspan/colspan), not cell text. Once the v1.2 evaluator harness has
cell text from Pass-B-text + Pass-C-text, we'll extend with content
variants (full TEDS, GriTS_Top, etc.).

Usage:
  python3 audit/v1_2_teds.py                  # gold set
  python3 audit/v1_2_teds.py --by-stratum
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

PROJECT = Path("/Users/lf/Projects/Pro/pdf.zig")
ALFRED = Path("/Users/lf/Projects/Pro/Alfred/data/hotel_assets")
GOLD_DIR = PROJECT / "audit" / "tables-gold"
PDFZIG = PROJECT / "zig-out" / "bin" / "pdf.zig"


# ----------------------------------------------------------------------
# Tree representation for TEDS-Struct
# ----------------------------------------------------------------------

@dataclass
class Node:
    label: str
    children: list["Node"] = field(default_factory=list)


def to_struct_tree(table: dict) -> Node:
    """Convert a table dict (n_rows, n_cols, header_rows, cells) into a
    nested HTML-like tree: <table><tr><td|th></td|th>...</tr>...</table>.
    Header rows produce <th>; non-header rows produce <td>. Spans are
    encoded into the cell label as `td:rs=R,cs=C`."""
    n_rows = table.get("n_rows", 0)
    n_cols = table.get("n_cols", 0)
    header_rows = table.get("header_rows", 0)
    cells = table.get("cells", [])

    # Build a 2D index by (r, c).
    by_rc: dict[tuple[int, int], dict] = {}
    for c in cells:
        by_rc[(c.get("r", 0), c.get("c", 0))] = c

    root = Node(label="table")
    for r in range(n_rows):
        is_header_row = r < header_rows
        tr = Node(label="tr")
        c = 0
        while c < n_cols:
            cell = by_rc.get((r, c))
            if cell is None:
                # Annotators may omit cells for unfilled positions; fill placeholder.
                tr.children.append(Node(label="td"))
                c += 1
                continue
            tag = "th" if (is_header_row or cell.get("is_header")) else "td"
            rs = cell.get("rowspan", 1)
            cs = cell.get("colspan", 1)
            label = tag if (rs == 1 and cs == 1) else f"{tag}:rs={rs},cs={cs}"
            tr.children.append(Node(label=label))
            c += cs
        root.children.append(tr)
    return root


def tree_size(n: Node) -> int:
    return 1 + sum(tree_size(c) for c in n.children)


def tree_edit_distance(a: Node, b: Node) -> int:
    """Simple Zhang-Shasha-flavoured tree edit distance:
       cost(insert) = cost(delete) = 1
       cost(rename) = 0 if labels match else 1
    Restricted to label/insert/delete (no subtree-swap). Quadratic in
    children count which is fine for tables (≤ a few hundred nodes)."""
    # If either is None / leaf w/ no children, the "remaining" cost is
    # the size difference + label mismatch.
    if a is None and b is None:
        return 0
    if a is None:
        return tree_size(b)
    if b is None:
        return tree_size(a)
    label_cost = 0 if a.label == b.label else 1

    # Forest distance over children: dynamic programming.
    m = len(a.children)
    n = len(b.children)
    fd = [[0] * (n + 1) for _ in range(m + 1)]
    for i in range(1, m + 1):
        fd[i][0] = fd[i - 1][0] + tree_size(a.children[i - 1])
    for j in range(1, n + 1):
        fd[0][j] = fd[0][j - 1] + tree_size(b.children[j - 1])
    for i in range(1, m + 1):
        for j in range(1, n + 1):
            fd[i][j] = min(
                fd[i - 1][j] + tree_size(a.children[i - 1]),         # delete child i
                fd[i][j - 1] + tree_size(b.children[j - 1]),         # insert child j
                fd[i - 1][j - 1] + tree_edit_distance(a.children[i - 1], b.children[j - 1]),
            )
    return label_cost + fd[m][n]


def teds_struct(predicted: dict, ground_truth: dict) -> float:
    p_tree = to_struct_tree(predicted)
    g_tree = to_struct_tree(ground_truth)
    dist = tree_edit_distance(p_tree, g_tree)
    denom = max(tree_size(p_tree), tree_size(g_tree))
    if denom == 0:
        return 1.0
    return max(0.0, 1.0 - dist / denom)


# ----------------------------------------------------------------------
# GriTS_Con (structure-only variant in v1)
# ----------------------------------------------------------------------

def to_cell_grid(table: dict) -> list[list[str]]:
    """Flatten cells (with rowspans + colspans) to a 2D grid where each
    cell occupies its rect; the cell label is "th" or "td" per row.
    When the source `cells` field is empty (annotators may only fill
    `header_cells` + `row_labels`), synthesize a placeholder grid from
    (n_rows, n_cols, header_rows) so the structural compare still works."""
    n_rows = table.get("n_rows", 0)
    n_cols = table.get("n_cols", 0)
    header_rows = table.get("header_rows", 0)
    grid = [[None] * n_cols for _ in range(n_rows)]
    cells = table.get("cells", [])
    if not cells:
        for r in range(n_rows):
            label = "th" if r < header_rows else "td"
            for c in range(n_cols):
                grid[r][c] = label
        return grid
    for c in cells:
        r = c.get("r", 0)
        col = c.get("c", 0)
        rs = c.get("rowspan", 1)
        cs = c.get("colspan", 1)
        is_h = bool(c.get("is_header", False))
        label = "th" if is_h else "td"
        for dr in range(rs):
            for dc in range(cs):
                if 0 <= r + dr < n_rows and 0 <= col + dc < n_cols:
                    grid[r + dr][col + dc] = label
    # Fill any remaining None positions with "td" so LCS comparisons aren't
    # poisoned by sparse annotations.
    for r in range(n_rows):
        for c in range(n_cols):
            if grid[r][c] is None:
                grid[r][c] = "td"
    return grid


def lcs_length(a: list, b: list) -> int:
    if not a or not b:
        return 0
    m, n = len(a), len(b)
    dp = [[0] * (n + 1) for _ in range(m + 1)]
    for i in range(1, m + 1):
        for j in range(1, n + 1):
            if a[i - 1] == b[j - 1]:
                dp[i][j] = dp[i - 1][j - 1] + 1
            else:
                dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
    return dp[m][n]


def grits_con(predicted: dict, ground_truth: dict) -> float:
    """Grid Table Similarity (content variant, structure-only in v1).
    For each row pair, LCS of cell labels; same for column pairs.
    F1 over both axes. Score in [0,1]."""
    p = to_cell_grid(predicted)
    g = to_cell_grid(ground_truth)
    if not p or not g:
        return 0.0

    # Row LCS
    p_rows = max(len(p), 1)
    g_rows = max(len(g), 1)
    dp_rows = [[0] * (g_rows + 1) for _ in range(p_rows + 1)]
    for i in range(1, p_rows + 1):
        for j in range(1, g_rows + 1):
            row_lcs = lcs_length(p[i - 1] if i - 1 < len(p) else [], g[j - 1] if j - 1 < len(g) else [])
            dp_rows[i][j] = max(dp_rows[i - 1][j - 1] + row_lcs, dp_rows[i - 1][j], dp_rows[i][j - 1])
    row_aligned = dp_rows[p_rows][g_rows]
    row_total_p = sum(len(r) for r in p)
    row_total_g = sum(len(r) for r in g)
    row_recall = row_aligned / row_total_g if row_total_g else 0
    row_precision = row_aligned / row_total_p if row_total_p else 0

    # Col LCS
    p_cols = list(zip(*p)) if p[0] else []
    g_cols = list(zip(*g)) if g and g[0] else []
    pc = max(len(p_cols), 1)
    gc = max(len(g_cols), 1)
    dp_cols = [[0] * (gc + 1) for _ in range(pc + 1)]
    for i in range(1, pc + 1):
        for j in range(1, gc + 1):
            col_lcs = lcs_length(list(p_cols[i - 1]) if i - 1 < len(p_cols) else [], list(g_cols[j - 1]) if j - 1 < len(g_cols) else [])
            dp_cols[i][j] = max(dp_cols[i - 1][j - 1] + col_lcs, dp_cols[i - 1][j], dp_cols[i][j - 1])
    col_aligned = dp_cols[pc][gc]
    col_total_p = sum(len(c) for c in p_cols)
    col_total_g = sum(len(c) for c in g_cols)
    col_recall = col_aligned / col_total_g if col_total_g else 0
    col_precision = col_aligned / col_total_p if col_total_p else 0

    rec = (row_recall + col_recall) / 2
    pre = (row_precision + col_precision) / 2
    if rec + pre == 0:
        return 0.0
    return 2 * rec * pre / (rec + pre)


# ----------------------------------------------------------------------
# Driver
# ----------------------------------------------------------------------

def predict_tables(pdf_path: Path) -> list[dict]:
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


def best_match(gold: dict, predicted: list[dict], used: set[int] | None = None) -> tuple[dict | None, int | None, float]:
    """Pick the predicted table that maximises TEDS-Struct against `gold`,
    skipping any prediction whose index is already in `used`. Returns
    (predicted, index, score). Codex review v1.2-rc1 [P2]: enforce one-
    to-one assignment so a single oversized prediction can't score
    multiple gold entries and inflate means."""
    used_set = used or set()
    best = None
    best_score = -1.0
    best_idx: int | None = None
    for i, p in enumerate(predicted):
        if i in used_set:
            continue
        if p.get("page") != gold.get("page"):
            continue
        s = teds_struct(p, gold)
        if s > best_score:
            best_score = s
            best = p
            best_idx = i
    return best, best_idx, max(best_score, 0.0)


def load_gold():
    gold_pdfs = []
    for jf in sorted(GOLD_DIR.glob("*/*.tables.json")):
        sk = json.loads(jf.read_text())
        if sk.get("annotation_status") == "done" and sk.get("tables"):
            gold_pdfs.append(sk)
    return gold_pdfs


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--by-stratum", action="store_true")
    args = ap.parse_args()

    if not PDFZIG.exists():
        print(f"FATAL: {PDFZIG} missing — run zig build -Doptimize=ReleaseSafe", file=sys.stderr)
        return 2

    gold = load_gold()
    if not gold:
        print("No annotated PDFs in the gold set — annotate first.", file=sys.stderr)
        return 1

    by_stratum: dict[str, dict[str, float]] = {}
    total_teds = 0.0
    total_grits = 0.0
    total_pairs = 0

    print("=" * 78)
    for sk in gold:
        pdf = ALFRED / sk["doc"]
        if not pdf.exists():
            print(f"  [SKIP] {sk['doc']} missing on disk")
            continue
        predicted = predict_tables(pdf)
        st = sk.get("stratum", "?")
        by_stratum.setdefault(st, {"teds_sum": 0, "grits_sum": 0, "n": 0})
        used: set[int] = set()
        for g in sk["tables"]:
            match, midx, teds = best_match(g, predicted, used)
            if midx is not None:
                used.add(midx)
            grits = grits_con(match, g) if match else 0.0
            total_teds += teds
            total_grits += grits
            total_pairs += 1
            by_stratum[st]["teds_sum"] += teds
            by_stratum[st]["grits_sum"] += grits
            by_stratum[st]["n"] += 1
            mark = "MATCH" if match else "MISS "
            print(f"  [{mark}] {sk['doc'][:55]:<55s}  gold(p{g.get('page')},{g.get('n_rows')}x{g.get('n_cols')})  TEDS-Struct={teds:.3f}  GriTS_Con={grits:.3f}")

    overall_teds = total_teds / total_pairs if total_pairs else 0.0
    overall_grits = total_grits / total_pairs if total_pairs else 0.0

    print()
    print(f"  Annotated PDFs   : {len(gold)}")
    print(f"  Gold tables      : {total_pairs}")
    print(f"  TEDS-Struct mean : {overall_teds:.3f}  (target ≥0.85 for v1.2-rc1)")
    print(f"  GriTS_Con mean   : {overall_grits:.3f}  (target ≥0.75 for v1.2-rc1)")

    if args.by_stratum:
        print()
        print(f"  Per stratum:")
        for s, b in sorted(by_stratum.items()):
            n = b["n"]
            print(f"    {s:<22s}  TEDS-Struct={b['teds_sum']/n:.3f}  GriTS_Con={b['grits_sum']/n:.3f}  n={n}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
