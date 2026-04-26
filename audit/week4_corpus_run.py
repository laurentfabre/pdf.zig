#!/usr/bin/env python3
"""Week-4 corpus regression: ≥30 Alfred PDFs through pdf.zig + upstream zpdf.

Per architecture.md §11: corpus tests ≥30 real PDFs, no crashes, every
NDJSON record from pdf.zig has kind/source/doc_id, output is valid JSON
Lines + valid UTF-8. Cross-check byte-count against upstream zpdf so a
regression is loud.

Outputs:
  audit/week4_corpus_results.tsv
  audit/week4_corpus_results.json
"""
from __future__ import annotations

import json
import random
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

PROJECT = Path("/Users/lf/Projects/Pro/pdf.zig")
PDFZIG = PROJECT / "zig-out" / "bin" / "pdf.zig"
ZPDF = PROJECT / "zig-out" / "bin" / "zpdf"
ALFRED = Path("/Users/lf/Projects/Pro/Alfred/data/hotel_assets")
OUT_TSV = PROJECT / "audit" / "week4_corpus_results.tsv"
OUT_JSON = PROJECT / "audit" / "week4_corpus_results.json"

TIMEOUT_S = 30
SAMPLE_SIZE = 40  # ≥30 per architecture.md gate
RNG_SEED = 0x4D04


@dataclass
class CorpusResult:
    path: str
    size_bytes: int
    rc_pdfzig: int
    rc_zpdf: int
    elapsed_pdfzig_s: float
    elapsed_zpdf_s: float
    pages_emitted: int
    bytes_emitted: int
    fatal_kind: str | None
    upstream_bytes: int  # zpdf extract byte count for cross-check
    valid_json_lines: bool
    valid_utf8: bool
    envelope_complete: bool  # every record has kind/source/doc_id
    notes: list[str] = field(default_factory=list)

    @property
    def passed(self) -> bool:
        return (
            self.rc_pdfzig == 0
            and self.valid_json_lines
            and self.valid_utf8
            and self.envelope_complete
        )


def sample_corpus(seed: int = RNG_SEED, n: int = SAMPLE_SIZE) -> list[Path]:
    """Stratified sample across hotel directories so we exercise variety."""
    by_hotel: dict[str, list[Path]] = {}
    for p in sorted(ALFRED.rglob("*.pdf")):
        rel = p.relative_to(ALFRED)
        hotel = rel.parts[0] if len(rel.parts) > 1 else "_root"
        by_hotel.setdefault(hotel, []).append(p)

    rng = random.Random(seed)
    hotels = list(by_hotel.keys())
    rng.shuffle(hotels)

    picked: list[Path] = []
    while len(picked) < n and hotels:
        for h in hotels[:]:
            if not by_hotel[h]:
                hotels.remove(h)
                continue
            pdf = by_hotel[h].pop(rng.randrange(len(by_hotel[h])))
            picked.append(pdf)
            if len(picked) >= n:
                break
    return picked


def run_pdfzig(pdf: Path) -> tuple[subprocess.CompletedProcess[bytes], float]:
    t0 = time.time()
    p = subprocess.run(
        [str(PDFZIG), "extract", str(pdf)],
        capture_output=True, timeout=TIMEOUT_S, check=False,
    )
    return p, time.time() - t0


def run_upstream(pdf: Path) -> tuple[int, int, float]:
    t0 = time.time()
    try:
        p = subprocess.run(
            [str(ZPDF), "extract", str(pdf)],
            capture_output=True, timeout=TIMEOUT_S, check=False,
        )
    except subprocess.TimeoutExpired:
        return -1, 0, TIMEOUT_S
    return p.returncode, len(p.stdout), time.time() - t0


def analyse(pdf: Path) -> CorpusResult:
    proc, elapsed = run_pdfzig(pdf)
    raw = proc.stdout

    valid_utf8 = True
    try:
        raw.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        valid_utf8 = False

    pages_emitted = 0
    bytes_emitted = 0
    fatal_kind: str | None = None
    valid_json_lines = True
    envelope_complete = True
    parse_errs = 0

    for line in raw.decode("utf-8", "replace").splitlines():
        if not line.strip():
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            valid_json_lines = False
            parse_errs += 1
            continue
        for required in ("kind", "source", "doc_id"):
            if required not in rec:
                envelope_complete = False
        if rec.get("kind") == "page":
            pages_emitted += 1
        elif rec.get("kind") == "summary":
            bytes_emitted = rec.get("bytes_emitted", 0)
        elif rec.get("kind") == "fatal":
            fatal_kind = rec.get("error", "unknown")

    rc_zpdf, upstream_bytes, elapsed_zpdf = run_upstream(pdf)

    notes: list[str] = []
    if parse_errs:
        notes.append(f"{parse_errs} non-JSON lines")
    if not valid_utf8:
        notes.append("invalid UTF-8 in pdf.zig stdout")
    if proc.returncode < 0:
        notes.append(f"signal {-proc.returncode}")

    return CorpusResult(
        path=str(pdf.relative_to(ALFRED)),
        size_bytes=pdf.stat().st_size,
        rc_pdfzig=proc.returncode,
        rc_zpdf=rc_zpdf,
        elapsed_pdfzig_s=elapsed,
        elapsed_zpdf_s=elapsed_zpdf,
        pages_emitted=pages_emitted,
        bytes_emitted=bytes_emitted,
        fatal_kind=fatal_kind,
        upstream_bytes=upstream_bytes,
        valid_json_lines=valid_json_lines,
        valid_utf8=valid_utf8,
        envelope_complete=envelope_complete,
        notes=notes,
    )


def main() -> int:
    if not PDFZIG.exists():
        print(f"FATAL: {PDFZIG} missing — run zig build -Doptimize=ReleaseSafe", file=sys.stderr)
        return 2
    if not ZPDF.exists():
        print(f"FATAL: {ZPDF} missing — same build step", file=sys.stderr)
        return 2

    sample = sample_corpus()
    print(f"Sampled {len(sample)} PDFs across {len({p.relative_to(ALFRED).parts[0] for p in sample})} hotels (seed=0x{RNG_SEED:x})\n")

    results: list[CorpusResult] = []
    fail_count = 0
    crash_count = 0

    for i, pdf in enumerate(sample, 1):
        r = analyse(pdf)
        results.append(r)
        if r.rc_pdfzig < 0:
            crash_count += 1
        if not r.passed:
            fail_count += 1
        marker = "PASS" if r.passed else "FAIL"
        print(f"  [{i:>2d}/{len(sample)}] [{marker}] pages={r.pages_emitted:>4d} bytes(pdf.zig)={r.bytes_emitted:>6d} bytes(zpdf)={r.upstream_bytes:>6d} {r.elapsed_pdfzig_s*1000:6.1f}ms  {r.path[:55]}")
        if r.notes:
            for n in r.notes:
                print(f"               {n}")

    OUT_TSV.write_text(
        "path\tsize\trc_pdfzig\trc_zpdf\telapsed_pdfzig_ms\telapsed_zpdf_ms\tpages\tbytes_pdfzig\tbytes_zpdf\tfatal\tvalid_json\tvalid_utf8\tenvelope_complete\tnotes\n" +
        "\n".join(
            "\t".join([
                r.path, str(r.size_bytes), str(r.rc_pdfzig), str(r.rc_zpdf),
                f"{r.elapsed_pdfzig_s*1000:.0f}", f"{r.elapsed_zpdf_s*1000:.0f}",
                str(r.pages_emitted), str(r.bytes_emitted), str(r.upstream_bytes),
                r.fatal_kind or "", str(int(r.valid_json_lines)),
                str(int(r.valid_utf8)), str(int(r.envelope_complete)),
                "; ".join(r.notes),
            ]) for r in results
        ) + "\n"
    )

    OUT_JSON.write_text(json.dumps({
        "sample_size": len(sample),
        "fail_count": fail_count,
        "crash_count": crash_count,
        "total_pages_pdfzig": sum(r.pages_emitted for r in results),
        "total_bytes_pdfzig": sum(r.bytes_emitted for r in results),
        "total_bytes_zpdf": sum(r.upstream_bytes for r in results),
        "total_elapsed_pdfzig_s": sum(r.elapsed_pdfzig_s for r in results),
        "total_elapsed_zpdf_s": sum(r.elapsed_zpdf_s for r in results),
        "results": [r.__dict__ for r in results],
    }, indent=2, default=str))

    print(f"\n{'=' * 70}")
    print(f"  Corpus size       : {len(sample)}")
    print(f"  Crashes           : {crash_count}")
    print(f"  Failed gate       : {fail_count}")
    print(f"  Pages emitted     : {sum(r.pages_emitted for r in results)}")
    print(f"  Bytes (pdf.zig)   : {sum(r.bytes_emitted for r in results):,}")
    print(f"  Bytes (zpdf)      : {sum(r.upstream_bytes for r in results):,}")
    print(f"  Wall time pdf.zig : {sum(r.elapsed_pdfzig_s for r in results):.1f}s")
    print(f"  Wall time zpdf    : {sum(r.elapsed_zpdf_s for r in results):.1f}s")
    print(f"  TSV               : {OUT_TSV}")
    print(f"  JSON              : {OUT_JSON}")

    return 0 if fail_count == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
