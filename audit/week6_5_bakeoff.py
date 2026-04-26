#!/usr/bin/env python3
"""Week 6.5 — cycle-10 of docs/alfred-bakeoff-report.md.

Scales the n=12 Week-5 bake-off up to ≥100 PDFs across the full Alfred
corpus, stratified by hotel and page-count bucket, and confirms the
aggregate speedup + char-parity numbers from Week 5 hold.

Per architecture.md §14, this is the last gate before v1.0 GA.

Output:
  audit/week6_5_bakeoff_results.tsv
  audit/week6_5_bakeoff_results.json
"""
from __future__ import annotations

import json
import random
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

PROJECT = Path("/Users/lf/Projects/Pro/pdf.zig")
PDFZIG = PROJECT / "zig-out" / "bin" / "pdf.zig"
ALFRED = Path("/Users/lf/Projects/Pro/Alfred/data/hotel_assets")
PYMUPDF_VENV = Path("/Users/lf/Projects/Pro/Alfred/.venv/bin/python")
OUT_TSV = PROJECT / "audit" / "week6_5_bakeoff_results.tsv"
OUT_JSON = PROJECT / "audit" / "week6_5_bakeoff_results.json"

TARGET_N = 120              # ≥100 per architecture; aim for 120 to cover skips
TIMEOUT_S = 60
MEASURED_RUNS = 1            # 1 run/PDF at this scale (n=120 vs n=12 in Week 5)
RNG_SEED = 0x65C10000  # week 6.5, cycle 10


@dataclass
class Result:
    path: str
    size_bytes: int
    page_count_est: int
    bucket: str
    pdfzig_chars: int = 0
    pdfzig_headers: int = 0
    pdfzig_pipe_lines: int = 0
    pdfzig_time_s: float = 0.0
    pdfzig_rc: int = 0
    pym_chars: int = 0
    pym_headers: int = 0
    pym_pipe_lines: int = 0
    pym_time_s: float = 0.0
    pym_rc: int = 0
    notes: list[str] = field(default_factory=list)

    @property
    def speedup(self) -> float:
        return self.pym_time_s / self.pdfzig_time_s if self.pdfzig_time_s > 0 else 0.0

    @property
    def char_ratio(self) -> float:
        return self.pdfzig_chars / self.pym_chars if self.pym_chars > 0 else float("inf")


def md_metrics(md: str) -> tuple[int, int, int]:
    return (
        len(md),
        len(re.findall(r"(?m)^#{1,6} ", md)),
        len(re.findall(r"(?m)^\|.*\|\s*$", md)),
    )


def page_bucket(size_bytes: int) -> str:
    """Approximate page bucket from file size — exact page count requires
    parsing, which the pdf.zig binary will report. The bucket here is just
    for stratified sampling."""
    kb = size_bytes / 1024
    if kb < 100: return "S"     # small: mostly 1-3 pages
    if kb < 500: return "M"     # medium: 3-15 pages
    if kb < 2000: return "L"    # large: 15-50 pages
    return "XL"                  # extra-large: 50+ pages


def stratified_sample(seed: int, target_n: int) -> list[Path]:
    """Sample target_n PDFs across hotels, balanced over size buckets."""
    by_hotel: dict[str, dict[str, list[Path]]] = {}
    for p in sorted(ALFRED.rglob("*.pdf")):
        rel = p.relative_to(ALFRED)
        hotel = rel.parts[0] if len(rel.parts) > 1 else "_root"
        b = page_bucket(p.stat().st_size)
        by_hotel.setdefault(hotel, {}).setdefault(b, []).append(p)

    rng = random.Random(seed)
    hotels = list(by_hotel.keys())
    rng.shuffle(hotels)
    bucket_quota = {"S": int(target_n * 0.30), "M": int(target_n * 0.40),
                    "L": int(target_n * 0.20), "XL": int(target_n * 0.10)}
    bucket_picked = {b: 0 for b in bucket_quota}
    picked: list[Path] = []

    # Round-robin across hotels, draw one PDF per hotel per bucket pass.
    while len(picked) < target_n and hotels:
        for h in hotels[:]:
            if len(picked) >= target_n:
                break
            # Pick the under-quota bucket with most candidates available
            available = [(b, len(by_hotel[h].get(b, []))) for b in bucket_quota
                         if bucket_picked[b] < bucket_quota[b]]
            available = [(b, n) for b, n in available if n > 0]
            if not available:
                hotels.remove(h)
                continue
            b = max(available, key=lambda bn: bn[1])[0]
            pool = by_hotel[h][b]
            pdf = pool.pop(rng.randrange(len(pool)))
            picked.append(pdf)
            bucket_picked[b] += 1
    return picked


def run_pdfzig(pdf: Path) -> tuple[str, float, int]:
    t0 = time.time()
    p = subprocess.run(
        [str(PDFZIG), "extract", "--output", "md", str(pdf)],
        capture_output=True, timeout=TIMEOUT_S, check=False,
    )
    return p.stdout.decode("utf-8", "replace"), time.time() - t0, p.returncode


def run_pymupdf4llm(pdf: Path) -> tuple[str, float, int]:
    script = (
        "import sys, pymupdf4llm; "
        f"sys.stdout.write(pymupdf4llm.to_markdown(r'{pdf}', show_progress=False))"
    )
    t0 = time.time()
    p = subprocess.run(
        [str(PYMUPDF_VENV), "-c", script],
        capture_output=True, timeout=TIMEOUT_S, check=False,
    )
    return p.stdout.decode("utf-8", "replace"), time.time() - t0, p.returncode


def main() -> int:
    if not PDFZIG.exists():
        print(f"FATAL: {PDFZIG} missing — run zig build -Doptimize=ReleaseSafe", file=sys.stderr)
        return 2
    if not PYMUPDF_VENV.exists():
        print(f"FATAL: pymupdf4llm venv at {PYMUPDF_VENV} missing", file=sys.stderr)
        return 2

    sample = stratified_sample(RNG_SEED, TARGET_N)
    n_hotels = len({p.relative_to(ALFRED).parts[0] for p in sample})
    print(f"cycle-10 bake-off: n={len(sample)} PDFs across {n_hotels} hotels (seed=0x{RNG_SEED:x})\n")

    results: list[Result] = []
    crash_count = 0
    fatal_count = 0
    timeout_count = 0

    for i, pdf in enumerate(sample, 1):
        size = pdf.stat().st_size
        b = page_bucket(size)
        rel = pdf.relative_to(ALFRED)
        r = Result(path=str(rel), size_bytes=size, page_count_est=0, bucket=b)
        try:
            pz_md, pz_t, pz_rc = run_pdfzig(pdf)
        except subprocess.TimeoutExpired:
            r.notes.append(f"pdfzig timeout >{TIMEOUT_S}s")
            pz_md, pz_t, pz_rc = "", TIMEOUT_S, -1
            timeout_count += 1
        r.pdfzig_chars, r.pdfzig_headers, r.pdfzig_pipe_lines = md_metrics(pz_md)
        r.pdfzig_time_s, r.pdfzig_rc = pz_t, pz_rc
        if pz_rc < 0:
            crash_count += 1
        elif pz_rc != 0:
            fatal_count += 1

        try:
            pm_md, pm_t, pm_rc = run_pymupdf4llm(pdf)
        except subprocess.TimeoutExpired:
            r.notes.append(f"pymupdf4llm timeout >{TIMEOUT_S}s")
            pm_md, pm_t, pm_rc = "", TIMEOUT_S, -1
        r.pym_chars, r.pym_headers, r.pym_pipe_lines = md_metrics(pm_md)
        r.pym_time_s, r.pym_rc = pm_t, pm_rc

        results.append(r)
        marker = "OK" if r.pdfzig_rc == 0 else ("CRASH" if r.pdfzig_rc < 0 else f"RC={r.pdfzig_rc}")
        if i % 10 == 0 or i == len(sample) or marker != "OK":
            print(f"  [{i:>3d}/{len(sample)}] [{marker}] {b} {r.pdfzig_time_s*1000:6.0f}ms vs {r.pym_time_s*1000:6.0f}ms  "
                  f"chars {r.pdfzig_chars:>6d}/{r.pym_chars:>6d}  speed×{r.speedup:5.1f}  {str(rel)[:55]}")

    # Aggregate
    total_pdfzig_s = sum(r.pdfzig_time_s for r in results)
    total_pym_s = sum(r.pym_time_s for r in results)
    total_pdfzig_chars = sum(r.pdfzig_chars for r in results)
    total_pym_chars = sum(r.pym_chars for r in results)
    aggregate_speedup = total_pym_s / total_pdfzig_s if total_pdfzig_s > 0 else 0
    char_parity = total_pdfzig_chars / total_pym_chars if total_pym_chars > 0 else 0

    # Per-bucket aggregates
    by_bucket: dict[str, list[Result]] = {}
    for r in results:
        by_bucket.setdefault(r.bucket, []).append(r)

    OUT_TSV.write_text(
        "path\tsize\tbucket\tpdfzig_rc\tpdfzig_chars\tpdfzig_headers\tpdfzig_pipe\tpdfzig_ms\tpym_rc\tpym_chars\tpym_headers\tpym_pipe\tpym_ms\tspeedup\tchar_ratio\tnotes\n" +
        "\n".join(
            "\t".join([
                r.path, str(r.size_bytes), r.bucket,
                str(r.pdfzig_rc), str(r.pdfzig_chars), str(r.pdfzig_headers), str(r.pdfzig_pipe_lines),
                f"{r.pdfzig_time_s*1000:.0f}",
                str(r.pym_rc), str(r.pym_chars), str(r.pym_headers), str(r.pym_pipe_lines),
                f"{r.pym_time_s*1000:.0f}",
                f"{r.speedup:.1f}", f"{r.char_ratio:.3f}",
                "; ".join(r.notes),
            ]) for r in results
        ) + "\n"
    )

    OUT_JSON.write_text(json.dumps({
        "n": len(results),
        "n_hotels": n_hotels,
        "crash_count": crash_count,
        "fatal_count": fatal_count,
        "timeout_count": timeout_count,
        "total_pdfzig_s": total_pdfzig_s,
        "total_pym_s": total_pym_s,
        "total_pdfzig_chars": total_pdfzig_chars,
        "total_pym_chars": total_pym_chars,
        "aggregate_speedup_x": aggregate_speedup,
        "char_parity": char_parity,
        "results": [r.__dict__ for r in results],
    }, indent=2, default=str))

    print(f"\n{'=' * 78}")
    print(f"  Sample              : n={len(results)} across {n_hotels} hotels")
    print(f"  Crashes (signal)    : {crash_count}")
    print(f"  Non-zero exit       : {fatal_count}")
    print(f"  Timeouts (>{TIMEOUT_S}s)  : {timeout_count}")
    print(f"  pdf.zig wall total  : {total_pdfzig_s:7.2f} s")
    print(f"  pymupdf4llm total   : {total_pym_s:7.2f} s")
    print(f"  Aggregate speedup   : {aggregate_speedup:5.1f}× faster")
    print(f"  pdf.zig chars       : {total_pdfzig_chars:>10,d}")
    print(f"  pymupdf4llm chars   : {total_pym_chars:>10,d}")
    print(f"  Char parity         : {char_parity*100:5.1f}%")
    print()
    print(f"  Per-bucket:")
    for b in ("S", "M", "L", "XL"):
        rs = by_bucket.get(b, [])
        if not rs:
            continue
        b_pdfzig = sum(r.pdfzig_time_s for r in rs)
        b_pym = sum(r.pym_time_s for r in rs)
        b_speed = b_pym / b_pdfzig if b_pdfzig > 0 else 0
        b_chars_pz = sum(r.pdfzig_chars for r in rs)
        b_chars_pm = sum(r.pym_chars for r in rs)
        b_parity = b_chars_pz / b_chars_pm if b_chars_pm > 0 else 0
        print(f"    {b:>2s} (n={len(rs):>3d}): {b_speed:5.1f}× faster, char parity {b_parity*100:5.1f}%")
    print()
    print(f"  Architecture.md §11 gate (≥3× faster): {'PASS' if aggregate_speedup >= 3.0 else 'FAIL'}")
    print(f"  Crash-free target     : {'PASS' if crash_count == 0 else 'FAIL'}")
    print()
    print(f"  TSV  : {OUT_TSV}")
    print(f"  JSON : {OUT_JSON}")

    return 0 if (crash_count == 0 and aggregate_speedup >= 3.0) else 1


if __name__ == "__main__":
    sys.exit(main())
