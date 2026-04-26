#!/usr/bin/env python3
"""Week-5 bake-off: pdf.zig vs pymupdf4llm on the n=12 Alfred corpus.

Architecture.md §11 quality bar: ≥3× faster than pymupdf4llm with
markdown-content parity. Source manifest:
/Users/lf/Projects/Researcher/Research/Distillation/bake-off/sample/manifest.tsv

Output:
  audit/week5_bakeoff_results.tsv
  audit/week5_bakeoff_results.json
  bake-off/out_pdfzig/<id>.md       # raw pdf.zig markdown
  bake-off/out_pymupdf4llm/<id>.md  # raw pymupdf4llm markdown
"""
from __future__ import annotations

import csv
import json
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
MANIFEST = Path("/Users/lf/Projects/Researcher/Research/Distillation/bake-off/sample/manifest.tsv")
OUT_DIR = PROJECT / "bake-off"
OUT_PDFZIG = OUT_DIR / "out_pdfzig"
OUT_PYM = OUT_DIR / "out_pymupdf4llm"
OUT_TSV = PROJECT / "audit" / "week5_bakeoff_results.tsv"
OUT_JSON = PROJECT / "audit" / "week5_bakeoff_results.json"

TIMEOUT_S = 60
WARMUP_RUNS = 1  # discard first run for cache warmup
MEASURED_RUNS = 3  # take min of these


@dataclass
class Sample:
    id: str
    hotel_slug: str
    filename: str
    category: str
    language: str
    page_count: int
    quality_flag: str


@dataclass
class Result:
    sample: Sample
    found: bool
    pdf_path: str
    # pdf.zig extract --output md
    pdfzig_chars: int = 0
    pdfzig_headers: int = 0
    pdfzig_pipe_table_lines: int = 0
    pdfzig_time_s: float = 0.0
    pdfzig_rc: int = 0
    # pymupdf4llm.to_markdown
    pym_chars: int = 0
    pym_headers: int = 0
    pym_pipe_table_lines: int = 0
    pym_time_s: float = 0.0
    pym_rc: int = 0
    notes: list[str] = field(default_factory=list)


def load_samples() -> list[Sample]:
    samples: list[Sample] = []
    with MANIFEST.open() as f:
        reader = csv.DictReader(f, delimiter="\t")
        for row in reader:
            samples.append(Sample(
                id=row["id"],
                hotel_slug=row["hotel_slug"],
                filename=row["filename"],
                category=row["category"],
                language=row["language"],
                page_count=int(row["page_count"]),
                quality_flag=row.get("quality_flag", "") or "",
            ))
    return samples


def find_pdf(s: Sample) -> Path | None:
    candidate = ALFRED / s.hotel_slug / s.filename
    if candidate.exists():
        return candidate
    # Some manifests have casemark slugs; try basename match within hotel dir
    hotel_dir = ALFRED / s.hotel_slug
    if hotel_dir.exists():
        for p in hotel_dir.iterdir():
            if p.name.lower() == s.filename.lower():
                return p
    return None


def md_metrics(md: str) -> tuple[int, int, int]:
    chars = len(md)
    headers = len(re.findall(r"(?m)^#{1,6} ", md))
    pipe_lines = len(re.findall(r"(?m)^\|.*\|\s*$", md))
    return chars, headers, pipe_lines


def time_min(fn, runs: int = MEASURED_RUNS) -> float:
    times: list[float] = []
    for _ in range(runs):
        t0 = time.time()
        fn()
        times.append(time.time() - t0)
    return min(times)


def run_pdfzig(pdf: Path, out_md: Path) -> tuple[str, float, int]:
    # Warmup
    subprocess.run([str(PDFZIG), "extract", "--output", "md", str(pdf)], capture_output=True, timeout=TIMEOUT_S, check=False)
    # Measured runs (discard ≥1 warmup, take min of remaining)
    last: subprocess.CompletedProcess[bytes] | None = None
    times: list[float] = []
    for _ in range(MEASURED_RUNS):
        t0 = time.time()
        last = subprocess.run(
            [str(PDFZIG), "extract", "--output", "md", str(pdf)],
            capture_output=True, timeout=TIMEOUT_S, check=False,
        )
        times.append(time.time() - t0)
    md = (last.stdout if last else b"").decode("utf-8", "replace")
    out_md.parent.mkdir(parents=True, exist_ok=True)
    out_md.write_text(md)
    return md, min(times), (last.returncode if last else -1)


def run_pymupdf4llm(pdf: Path, out_md: Path) -> tuple[str, float, int]:
    script = (
        "import sys, pymupdf4llm; "
        f"sys.stdout.write(pymupdf4llm.to_markdown(r'{pdf}', show_progress=False))"
    )
    subprocess.run([str(PYMUPDF_VENV), "-c", script], capture_output=True, timeout=TIMEOUT_S, check=False)
    last: subprocess.CompletedProcess[bytes] | None = None
    times: list[float] = []
    for _ in range(MEASURED_RUNS):
        t0 = time.time()
        last = subprocess.run(
            [str(PYMUPDF_VENV), "-c", script],
            capture_output=True, timeout=TIMEOUT_S, check=False,
        )
        times.append(time.time() - t0)
    md = (last.stdout if last else b"").decode("utf-8", "replace")
    out_md.parent.mkdir(parents=True, exist_ok=True)
    out_md.write_text(md)
    return md, min(times), (last.returncode if last else -1)


def main() -> int:
    if not PDFZIG.exists():
        print(f"FATAL: {PDFZIG} missing — run zig build -Doptimize=ReleaseSafe", file=sys.stderr)
        return 2
    if not PYMUPDF_VENV.exists():
        print(f"FATAL: pymupdf4llm venv missing at {PYMUPDF_VENV}", file=sys.stderr)
        return 2
    if not MANIFEST.exists():
        print(f"FATAL: manifest missing at {MANIFEST}", file=sys.stderr)
        return 2

    samples = load_samples()
    print(f"Bake-off corpus: {len(samples)} PDFs from {MANIFEST}\n")

    OUT_PDFZIG.mkdir(parents=True, exist_ok=True)
    OUT_PYM.mkdir(parents=True, exist_ok=True)

    results: list[Result] = []
    for i, s in enumerate(samples, 1):
        pdf = find_pdf(s)
        if pdf is None:
            r = Result(sample=s, found=False, pdf_path="")
            r.notes.append("pdf not found on disk")
            results.append(r)
            print(f"  [{i:>2d}/{len(samples)}] [SKIP] {s.hotel_slug}/{s.filename}")
            continue

        r = Result(sample=s, found=True, pdf_path=str(pdf))
        try:
            pz_md, pz_t, pz_rc = run_pdfzig(pdf, OUT_PDFZIG / f"{s.id}.md")
            r.pdfzig_chars, r.pdfzig_headers, r.pdfzig_pipe_table_lines = md_metrics(pz_md)
            r.pdfzig_time_s = pz_t
            r.pdfzig_rc = pz_rc
        except subprocess.TimeoutExpired:
            r.notes.append(f"pdfzig timeout >{TIMEOUT_S}s")
            r.pdfzig_rc = -1
            r.pdfzig_time_s = TIMEOUT_S

        try:
            pm_md, pm_t, pm_rc = run_pymupdf4llm(pdf, OUT_PYM / f"{s.id}.md")
            r.pym_chars, r.pym_headers, r.pym_pipe_table_lines = md_metrics(pm_md)
            r.pym_time_s = pm_t
            r.pym_rc = pm_rc
        except subprocess.TimeoutExpired:
            r.notes.append(f"pymupdf4llm timeout >{TIMEOUT_S}s")
            r.pym_rc = -1
            r.pym_time_s = TIMEOUT_S

        speedup = (r.pym_time_s / r.pdfzig_time_s) if r.pdfzig_time_s > 0 else 0
        char_ratio = (r.pdfzig_chars / r.pym_chars) if r.pym_chars > 0 else float("inf")
        results.append(r)
        print(f"  [{i:>2d}/{len(samples)}] {s.id:>4s} {s.category:<18s} {s.language:<3s} p={s.page_count:>2d}  "
              f"pdf.zig: {r.pdfzig_chars:>6d}c {r.pdfzig_time_s*1000:6.0f}ms  "
              f"pymupdf4llm: {r.pym_chars:>6d}c {r.pym_time_s*1000:6.0f}ms  "
              f"speed×{speedup:5.1f} chars={char_ratio:5.2f}× ({s.filename[:35]})")

    OUT_TSV.parent.mkdir(parents=True, exist_ok=True)
    OUT_TSV.write_text("id\thotel\tcategory\tlanguage\tpages\tflag\tpdfzig_chars\tpdfzig_headers\tpdfzig_pipe_lines\tpdfzig_time_ms\tpdfzig_rc\tpym_chars\tpym_headers\tpym_pipe_lines\tpym_time_ms\tpym_rc\tspeedup_x\tnotes\n" +
        "\n".join(
            "\t".join([
                r.sample.id, r.sample.hotel_slug, r.sample.category, r.sample.language,
                str(r.sample.page_count), r.sample.quality_flag,
                str(r.pdfzig_chars), str(r.pdfzig_headers), str(r.pdfzig_pipe_table_lines),
                f"{r.pdfzig_time_s*1000:.0f}", str(r.pdfzig_rc),
                str(r.pym_chars), str(r.pym_headers), str(r.pym_pipe_table_lines),
                f"{r.pym_time_s*1000:.0f}", str(r.pym_rc),
                f"{(r.pym_time_s / r.pdfzig_time_s) if r.pdfzig_time_s > 0 else 0:.1f}",
                "; ".join(r.notes),
            ]) for r in results
        ) + "\n")

    found = [r for r in results if r.found]
    if not found:
        print("\nFATAL: no PDFs found on disk", file=sys.stderr)
        return 2

    total_pdfzig_s = sum(r.pdfzig_time_s for r in found)
    total_pym_s = sum(r.pym_time_s for r in found)
    total_pdfzig_chars = sum(r.pdfzig_chars for r in found)
    total_pym_chars = sum(r.pym_chars for r in found)
    aggregate_speedup = total_pym_s / total_pdfzig_s if total_pdfzig_s > 0 else 0
    char_parity = total_pdfzig_chars / total_pym_chars if total_pym_chars > 0 else 0

    OUT_JSON.write_text(json.dumps({
        "corpus_size": len(samples),
        "found": len(found),
        "total_pdfzig_time_s": total_pdfzig_s,
        "total_pym_time_s": total_pym_s,
        "total_pdfzig_chars": total_pdfzig_chars,
        "total_pym_chars": total_pym_chars,
        "aggregate_speedup_x": aggregate_speedup,
        "char_parity_ratio": char_parity,
        "results": [{**r.__dict__, "sample": r.sample.__dict__} for r in results],
    }, indent=2, default=str))

    print(f"\n{'=' * 70}")
    print(f"  Corpus               : {len(samples)} PDFs ({len(found)} found on disk)")
    print(f"  pdf.zig total time   : {total_pdfzig_s*1000:.0f} ms ({total_pdfzig_s:.2f} s)")
    print(f"  pymupdf4llm total    : {total_pym_s*1000:.0f} ms ({total_pym_s:.2f} s)")
    print(f"  Aggregate speedup    : {aggregate_speedup:.1f}× faster")
    print(f"  pdf.zig chars        : {total_pdfzig_chars:,}")
    print(f"  pymupdf4llm chars    : {total_pym_chars:,}")
    print(f"  Char parity          : {char_parity*100:.1f}% (target ≥80% on text-bearing PDFs)")
    print()
    print(f"  Architecture.md §11 quality bar:")
    speed_pass = "PASS" if aggregate_speedup >= 3.0 else "FAIL"
    print(f"    ≥3× faster than pymupdf4llm  →  {speed_pass} ({aggregate_speedup:.1f}×)")
    print()
    print(f"  TSV  : {OUT_TSV}")
    print(f"  JSON : {OUT_JSON}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
