#!/usr/bin/env python3
"""Download a 50-table subset of FinTabNet for v1.2 numeric/currency gating.

FinTabNet is IBM's financial-document table corpus — 112,887 tables from
S&P 500 annual reports, with HTML cell annotations. Closer to hotel rate
sheets than PubTables-1M's scientific tables, because of:
  - Currency symbols and decimal/thousand-separator variation
  - Heavy merged headers ("FY 2023 / FY 2022")
  - Numeric column alignment

Used as the secondary public regression baseline for v1.2.

Source: https://github.com/ibm-aur-nlp/PubTabNet/tree/master/FinTabNet
Paper:  https://arxiv.org/abs/2005.00589

Note: FinTabNet's primary distribution is via IBM's PubTabNet repo, NOT
HuggingFace. As of April 2026 the canonical mirror is the JSONL +
PNG-per-table format. This script downloads from the PubTabNet HTTPS
mirror and reservoir-samples 50 tables.

Usage:
  python3 audit/v1_2_fintabnet_subset.py
"""
from __future__ import annotations

import argparse
import json
import random
import sys
import urllib.request
from pathlib import Path

PROJECT = Path("/Users/lf/Projects/Pro/pdf.zig")
OUT_DIR = PROJECT / "audit" / "tables-fintabnet"
SUBSET_SIZE = 50
RNG_SEED = 0x12FAB1E5

# Canonical mirror of FinTabNet's val.jsonl (~700 MB unfiltered).
# As of v1.2 design time, the IBM mirror is the authoritative source.
FINTABNET_VAL_URL = "https://dax-cdn.cdn.appdomain.cloud/dax-fintabnet/1.0.0/fintabnet.tar.gz"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--n", type=int, default=SUBSET_SIZE)
    parser.add_argument("--seed", type=lambda s: int(s, 0), default=RNG_SEED)
    parser.add_argument("--cache", type=Path, default=PROJECT / ".cache" / "fintabnet.tar.gz",
                        help="cache the upstream tarball locally")
    args = parser.parse_args()

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    args.cache.parent.mkdir(parents=True, exist_ok=True)

    if not args.cache.exists():
        print(f"Downloading FinTabNet from {FINTABNET_VAL_URL}...")
        print(f"  (cached at {args.cache} — ~700 MB; reuse on subsequent runs)")
        try:
            urllib.request.urlretrieve(FINTABNET_VAL_URL, args.cache)
        except Exception as e:
            print(f"FATAL: download failed: {e}", file=sys.stderr)
            print("  IBM's mirror sometimes 404s. Manually download per the", file=sys.stderr)
            print("  PubTabNet README: https://github.com/ibm-aur-nlp/PubTabNet#fintabnet", file=sys.stderr)
            return 2

    # Extract just the validation split's JSONL — full extraction is many GB.
    import tarfile
    print(f"Extracting validation split from {args.cache}...")
    val_jsonl: list[dict] = []
    try:
        with tarfile.open(args.cache, "r:gz") as tf:
            for member in tf:
                if member.name.endswith("val.jsonl") or member.name.endswith("validation.jsonl"):
                    f = tf.extractfile(member)
                    if f is None:
                        continue
                    for line in f:
                        try:
                            val_jsonl.append(json.loads(line))
                        except json.JSONDecodeError:
                            continue
                    break
    except tarfile.ReadError as e:
        print(f"FATAL: tarball read failed: {e}", file=sys.stderr)
        return 2

    if not val_jsonl:
        print("ERROR: no val.jsonl found in tarball", file=sys.stderr)
        return 2

    rng = random.Random(args.seed)
    sample = rng.sample(val_jsonl, k=min(args.n, len(val_jsonl)))

    manifest = []
    for idx, item in enumerate(sample):
        json_path = OUT_DIR / f"{idx:04d}.json"
        json_path.write_text(json.dumps(item, indent=2))
        manifest.append({"id": idx, "filename": item.get("filename", ""), "structure": str(json_path.name)})

    (OUT_DIR / "manifest.json").write_text(json.dumps(manifest, indent=2))
    print(f"\nSampled {len(manifest)} tables from FinTabNet validation (n={len(val_jsonl)} candidates)")
    print(f"Wrote to {OUT_DIR}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
