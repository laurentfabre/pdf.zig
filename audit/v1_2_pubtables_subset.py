#!/usr/bin/env python3
"""Download a 100-table sanity subset of PubTables-1M for v1.2 regression.

PubTables-1M is the Microsoft Table Transformer (TATR) training corpus —
947k+ tables from PMC scientific papers, each with structure annotations
(rows, columns, spans, headers) in PASCAL-VOC XML format. Used as the
public regression baseline for our table extractor (target GriTS_Con
≥0.75 vs Microsoft's TATR baseline ≈0.985).

This script pulls the smallest tractable subset:
  - 100 tables from the validation split, randomly sampled with seed 0x12FAB1E5
  - Saves PDF page renderings + structure XML to audit/tables-pubtables-1m/

Source: https://huggingface.co/datasets/bsmock/pubtables-1m
Paper:  https://arxiv.org/abs/2110.00061

Why a subset, not the full 947k?
  - Full corpus is ~70 GB
  - For v1.2 acceptance gating we only need credibility, not exhaustive
  - Microsoft's own TATR paper reports GriTS_Con on the full validation set;
    a 100-table subset gives Wilson 95% CI half-width ≈4.5pp, sufficient
    for a per-release gate

Usage:
  pip install datasets  # one-time
  python3 audit/v1_2_pubtables_subset.py
"""
from __future__ import annotations

import argparse
import json
import random
import sys
from pathlib import Path

PROJECT = Path("/Users/lf/Projects/Pro/pdf.zig")
OUT_DIR = PROJECT / "audit" / "tables-pubtables-1m"
RNG_SEED = 0x12FAB1E5
SUBSET_SIZE = 100


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--n", type=int, default=SUBSET_SIZE)
    parser.add_argument("--split", default="validation",
                        choices=["train", "validation", "test"])
    parser.add_argument("--seed", type=lambda s: int(s, 0), default=RNG_SEED)
    args = parser.parse_args()

    try:
        from datasets import load_dataset
    except ImportError:
        print("ERROR: 'datasets' (HuggingFace) not installed.", file=sys.stderr)
        print("  pip install datasets", file=sys.stderr)
        return 2

    OUT_DIR.mkdir(parents=True, exist_ok=True)

    print(f"Streaming PubTables-1M / TSR (table structure recognition) split={args.split}...")
    # bsmock/pubtables-1m is ~70 GB. Use streaming to avoid the full pull.
    ds = load_dataset("bsmock/pubtables-1m", split=args.split, streaming=True)

    rng = random.Random(args.seed)

    # Reservoir sample: take first N, then for each subsequent item with
    # probability N/i, replace a random item in the reservoir.
    reservoir: list[dict] = []
    n = args.n
    print(f"Reservoir-sampling {n} tables (seed=0x{args.seed:x})...")
    for i, item in enumerate(ds):
        if i < n:
            reservoir.append(item)
        else:
            j = rng.randint(0, i)
            if j < n:
                reservoir[j] = item
        if i and i % 5000 == 0:
            print(f"  scanned {i:>7d} items, reservoir={len(reservoir)}")
        # Cap the scan; reservoir is a unbiased sample of what we've seen.
        if i >= 100_000:
            print(f"  capped scan at 100k items (full corpus is ~947k)")
            break

    # Persist
    manifest = []
    for idx, item in enumerate(reservoir):
        # Item shape (per dataset card): {"image": PIL.Image, "structure": dict}
        # Persist image as PNG and structure as JSON.
        img = item.get("image")
        struct = item.get("structure", {})
        png_path = OUT_DIR / f"{idx:04d}.png"
        json_path = OUT_DIR / f"{idx:04d}.json"
        try:
            if img is not None:
                img.save(png_path)
            json_path.write_text(json.dumps(struct, indent=2))
            manifest.append({"id": idx, "image": str(png_path.name), "structure": str(json_path.name)})
        except Exception as e:
            print(f"  failed to persist item {idx}: {e}", file=sys.stderr)

    (OUT_DIR / "manifest.json").write_text(json.dumps(manifest, indent=2))
    print(f"\nWrote {len(manifest)} items to {OUT_DIR}")
    print(f"Manifest: {OUT_DIR / 'manifest.json'}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
