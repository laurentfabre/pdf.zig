#!/usr/bin/env python3
"""Week-0 audit: run upstream Lulzx/zpdf against Alfred's full PDF corpus.

Per pdf.zig architecture.md §17, this is the structural-defect gate before
committing to the 5-week Option C build:

  Pass criteria:
  - Zero segfaults / OOMs / panics across the full Alfred corpus (1 776 PDFs)
  - Output produced for ≥95% of input PDFs
  - Structured markdown on ≥10 sampled clean PDFs (≥1 heading visible)
  - Cross-ref repair attempted on dirty PDFs (cases #31–35) — partial output OK

  NOT pass criteria (these are week-1/2 cleanup, not gate failures):
  - Word spacing
  - CJK / Arabic Unicode
  - Reading-order quality

Output:
  audit/week0_results.json   — per-PDF outcome dict
  audit/week0_results.tsv    — flat table
  docs/week0-audit.md        — narrative report (written by separate step)
"""
from __future__ import annotations

import json
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

PROJECT = Path("/Users/lf/Projects/Pro/pdf.zig")
# Binary lives at the project root after fork (was upstream/zig-out/bin/zpdf pre-fork).
# Upstream still exposes the `zpdf` binary name; we'll add a `pdf.zig` binary in Week 3.
ZPDF_BIN = PROJECT / "zig-out" / "bin" / "zpdf"
ALFRED_PDFS = Path("/Users/lf/Projects/Pro/Alfred/data/hotel_assets")
OUT_JSON = PROJECT / "audit" / "week0_results.json"
OUT_TSV = PROJECT / "audit" / "week0_results.tsv"

TIMEOUT_S = 15        # generous; fail anything taking longer
WORKERS = 6


def classify(pdf: Path) -> dict:
    """Run zpdf extract on a single PDF; classify the outcome."""
    t0 = time.time()
    try:
        res = subprocess.run(
            [str(ZPDF_BIN), "extract", str(pdf)],
            capture_output=True, text=False,  # binary stdout (Unicode-safe)
            timeout=TIMEOUT_S, check=False,
        )
        elapsed = time.time() - t0
        rc = res.returncode
        out_bytes = len(res.stdout) if res.stdout else 0
        out_lines = res.stdout.count(b"\n") if res.stdout else 0
        # Heuristic: structured = has at least one markdown heading marker
        has_heading = bool(res.stdout and b"\n#" in res.stdout)
        # Heuristic: text-bearing = has any alnum byte in output
        has_text = bool(res.stdout and any(0x20 < b < 0x7f for b in res.stdout[:1024]))

        if rc == 0 and out_bytes > 100 and has_text:
            outcome = "clean"
        elif rc == 0 and out_bytes <= 100:
            outcome = "empty"
        elif rc == 0:
            outcome = "garbage"  # rc=0 but no recognizable text
        elif rc < 0:  # killed by signal (negative on POSIX)
            outcome = f"signal:{-rc}"
        elif rc == 124 or rc == 137:
            outcome = "oom_or_killed"
        else:
            outcome = f"exit:{rc}"

        return {
            "path": str(pdf.relative_to(ALFRED_PDFS)),
            "size_bytes": pdf.stat().st_size,
            "outcome": outcome,
            "rc": rc,
            "elapsed_s": round(elapsed, 3),
            "out_bytes": out_bytes,
            "out_lines": out_lines,
            "has_heading": has_heading,
            "stderr_first120": (res.stderr[:120].decode("utf-8", errors="replace")
                                 if res.stderr else ""),
        }
    except subprocess.TimeoutExpired:
        return {
            "path": str(pdf.relative_to(ALFRED_PDFS)),
            "size_bytes": pdf.stat().st_size,
            "outcome": "timeout",
            "rc": -1,
            "elapsed_s": TIMEOUT_S,
            "out_bytes": 0, "out_lines": 0,
            "has_heading": False,
            "stderr_first120": "",
        }
    except Exception as e:
        return {
            "path": str(pdf.relative_to(ALFRED_PDFS)),
            "size_bytes": 0,
            "outcome": "harness_error",
            "rc": -2,
            "elapsed_s": 0.0,
            "out_bytes": 0, "out_lines": 0,
            "has_heading": False,
            "stderr_first120": f"{type(e).__name__}:{e}"[:120],
        }


def main() -> int:
    if not ZPDF_BIN.exists():
        print(f"FATAL: zpdf binary missing at {ZPDF_BIN}", file=sys.stderr)
        return 2
    if not ALFRED_PDFS.exists():
        print(f"FATAL: Alfred corpus missing at {ALFRED_PDFS}", file=sys.stderr)
        return 2

    pdfs = sorted(ALFRED_PDFS.rglob("*.pdf"))
    print(f"Found {len(pdfs)} PDFs under {ALFRED_PDFS}")
    print(f"Running upstream zpdf with {WORKERS} workers, {TIMEOUT_S}s timeout per file...\n")

    results: list[dict] = []
    counters = {"clean": 0, "empty": 0, "garbage": 0, "timeout": 0,
                "harness_error": 0, "other": 0}
    crashes: list[dict] = []
    has_heading_count = 0

    t_start = time.time()
    with ThreadPoolExecutor(max_workers=WORKERS) as ex:
        futs = {ex.submit(classify, pdf): pdf for pdf in pdfs}
        for i, fut in enumerate(as_completed(futs), 1):
            r = fut.result()
            results.append(r)
            o = r["outcome"]
            if o in counters:
                counters[o] += 1
            else:
                counters["other"] += 1
                if o.startswith("signal:") or o.startswith("exit:") or o == "oom_or_killed":
                    crashes.append(r)
            if r["has_heading"]:
                has_heading_count += 1
            if i % 50 == 0 or i == len(pdfs):
                elapsed = time.time() - t_start
                rate = i / max(0.001, elapsed)
                eta = (len(pdfs) - i) / max(0.001, rate)
                print(f"  [{i:>4d}/{len(pdfs)}] {elapsed:5.0f}s, "
                      f"clean={counters['clean']:>4d} "
                      f"empty={counters['empty']:>3d} "
                      f"timeout={counters['timeout']:>3d} "
                      f"crashes={len(crashes):>3d} "
                      f"({rate:.1f}/s, ETA {eta:.0f}s)")

    elapsed_total = time.time() - t_start

    # Sort results by outcome class for easier reading
    results.sort(key=lambda r: (r["outcome"], r["path"]))

    OUT_JSON.parent.mkdir(parents=True, exist_ok=True)
    OUT_JSON.write_text(json.dumps({
        "harness": "week0_run.py",
        "binary": str(ZPDF_BIN),
        "corpus": str(ALFRED_PDFS),
        "n_pdfs": len(pdfs),
        "elapsed_s": round(elapsed_total, 1),
        "workers": WORKERS,
        "timeout_s": TIMEOUT_S,
        "counters": counters,
        "crashes_n": len(crashes),
        "has_heading_n": has_heading_count,
        "crashes": crashes[:50],   # cap for json size; full set in TSV
        "results": results,
    }, indent=2))

    with OUT_TSV.open("w") as f:
        f.write("path\tsize_bytes\toutcome\trc\telapsed_s\tout_bytes\tout_lines\thas_heading\tstderr_first120\n")
        for r in results:
            f.write("\t".join([
                r["path"], str(r["size_bytes"]), r["outcome"], str(r["rc"]),
                str(r["elapsed_s"]), str(r["out_bytes"]), str(r["out_lines"]),
                str(int(r["has_heading"])), r["stderr_first120"].replace("\t", " ").replace("\n", " "),
            ]) + "\n")

    # Gate evaluation per architecture.md §17
    n = len(pdfs)
    output_produced = counters["clean"] + counters["garbage"]  # rc=0 with any output
    output_pct = output_produced / max(1, n) * 100
    crashes_total = len(crashes) + counters["timeout"]
    structured_n = has_heading_count

    print(f"\n{'='*70}")
    print(f"WEEK-0 AUDIT RESULTS (n={n} PDFs, elapsed {elapsed_total:.0f}s)")
    print(f"{'='*70}")
    print(f"  clean         : {counters['clean']:>5d}  ({counters['clean']/n*100:.1f}%)")
    print(f"  empty         : {counters['empty']:>5d}  ({counters['empty']/n*100:.1f}%)")
    print(f"  garbage       : {counters['garbage']:>5d}  ({counters['garbage']/n*100:.1f}%)")
    print(f"  timeout       : {counters['timeout']:>5d}  ({counters['timeout']/n*100:.1f}%)")
    print(f"  crashes       : {len(crashes):>5d}  ({len(crashes)/n*100:.1f}%)")
    print(f"  harness_error : {counters['harness_error']:>5d}")
    print(f"  has_heading   : {has_heading_count:>5d}  ({has_heading_count/n*100:.1f}%)")
    print()
    print(f"GATE CRITERIA (architecture.md §17):")
    print(f"  Zero crashes       : {'✅ PASS' if crashes_total == 0 else f'❌ FAIL ({crashes_total} crashes/timeouts)'}")
    print(f"  ≥95% output        : {'✅ PASS' if output_pct >= 95 else f'❌ FAIL ({output_pct:.1f}%)'}")
    print(f"  ≥10 structured     : {'✅ PASS' if structured_n >= 10 else f'❌ FAIL ({structured_n})'}")
    print()
    print(f"  RAW JSON  → {OUT_JSON}")
    print(f"  RAW TSV   → {OUT_TSV}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
