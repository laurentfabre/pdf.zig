#!/usr/bin/env python3
"""PR-15 [feat]: CJK extraction byte-equality harness.

Runs `pdf.zig extract --output text` against every PDF surfaced by
`audit/cjk_subset.py`, compares the output to a reference (the
synthetic-fixture `expected_utf8` ground truth, or `pymupdf4llm`
output on real PDFs), and emits a per-language byte-equality summary.

Acceptance gate (architecture.md §11):
  - ≥ 95 % byte-identical text vs reference for non-vertical writing.
  - Vertical-writing PDFs are expected to be wrong; the harness checks
    that pdf.zig emits a `kind:"warning"` `vertical_writing_unsupported`
    record when running with `--output ndjson`.

Output:
  audit/v1_4_cjk_results.json — per-PDF + per-language stats
  exit code 0 if both gates pass, 1 otherwise.

Dependencies (audit-only — NOT a runtime dep of pdf.zig):
  pip install pymupdf4llm  # for real-PDF reference comparison

Usage:
    # Synthetic only (no extra deps):
    python3 audit/v1_4_cjk_run.py --skip-real
    # Synthetic + real with pymupdf4llm reference:
    python3 audit/v1_4_cjk_run.py
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import unicodedata
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Optional

PROJECT = Path(__file__).resolve().parent.parent
PDFZIG = PROJECT / "zig-out" / "bin" / "pdf.zig"
INDEX_PATH = PROJECT / "audit" / "cjk_corpus_index.json"
RESULTS_PATH = PROJECT / "audit" / "v1_4_cjk_results.json"

LANGS = ("ja", "zh", "ko")
TARGET_BYTE_EQUALITY = 0.95


@dataclass
class FileResult:
    id: str
    lang: str
    source: str
    wmode: Optional[int]
    expected_text: Optional[str]
    pdfzig_text: str
    pdfzig_bytes: int
    reference_text: Optional[str]
    reference_bytes: int
    byte_identical: bool
    char_identical: bool  # NFC-normalised
    has_vertical_warning: Optional[bool] = None
    notes: list[str] = field(default_factory=list)


def run_pdfzig_text(pdf_path: Path) -> str:
    proc = subprocess.run(
        [str(PDFZIG), "extract", str(pdf_path), "--output", "text"],
        capture_output=True,
        timeout=30,
    )
    if proc.returncode not in (0, 141):
        raise RuntimeError(
            f"pdf.zig failed on {pdf_path}: rc={proc.returncode} stderr={proc.stderr!r}"
        )
    return proc.stdout.decode("utf-8", errors="replace")


def run_pdfzig_ndjson(pdf_path: Path) -> list[dict]:
    proc = subprocess.run(
        [str(PDFZIG), "extract", str(pdf_path), "--output", "ndjson"],
        capture_output=True,
        timeout=30,
    )
    records: list[dict] = []
    for line in proc.stdout.decode("utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return records


def run_pymupdf4llm(pdf_path: Path) -> str:
    """Reference extraction — opt-in (real PDFs only)."""
    import pymupdf4llm  # type: ignore[import-not-found]

    return pymupdf4llm.to_markdown(str(pdf_path))


def normalise(text: str) -> str:
    """NFC + collapse all whitespace runs and strip trailing whitespace.
    pdf.zig and pymupdf4llm disagree on trailing newlines / page-feed
    bytes; the underlying code-point stream is what we gate on."""
    norm = unicodedata.normalize("NFC", text)
    return " ".join(norm.split()).strip()


def load_index() -> list[dict]:
    if not INDEX_PATH.exists():
        print(
            f"error: {INDEX_PATH} missing — run `python3 audit/cjk_subset.py` first",
            file=sys.stderr,
        )
        sys.exit(2)
    return json.loads(INDEX_PATH.read_text(encoding="utf-8"))["entries"]


def evaluate(entry: dict, *, skip_real: bool) -> Optional[FileResult]:
    pdf_path = Path(entry["path"])
    pdfzig_out = run_pdfzig_text(pdf_path)

    reference: Optional[str] = None
    if entry["source"] == "synthetic":
        reference = entry.get("expected_utf8")
    else:
        if skip_real:
            return None
        try:
            reference = run_pymupdf4llm(pdf_path)
        except ImportError:
            print(
                "error: pymupdf4llm not installed — pass --skip-real or `pip install pymupdf4llm`",
                file=sys.stderr,
            )
            sys.exit(2)

    has_vert = None
    if entry.get("wmode") == 1 or entry["source"] == "real":
        # NDJSON probe: did pdf.zig surface vertical_writing_unsupported?
        records = run_pdfzig_ndjson(pdf_path)
        has_vert = any(
            r.get("kind") == "warning"
            and r.get("code") == "vertical_writing_unsupported"
            for r in records
        )

    pdfzig_norm = normalise(pdfzig_out)
    ref_norm = normalise(reference) if reference else ""

    byte_identical = pdfzig_out == reference if reference is not None else False
    char_identical = pdfzig_norm == ref_norm if reference is not None else False

    return FileResult(
        id=entry["id"],
        lang=entry["lang"],
        source=entry["source"],
        wmode=entry.get("wmode"),
        expected_text=reference,
        pdfzig_text=pdfzig_out,
        pdfzig_bytes=len(pdfzig_out.encode("utf-8")),
        reference_text=reference,
        reference_bytes=len(reference.encode("utf-8")) if reference else 0,
        byte_identical=byte_identical,
        char_identical=char_identical,
        has_vertical_warning=has_vert,
    )


def _common_byte_prefix(a: bytes, b: bytes) -> int:
    n = min(len(a), len(b))
    i = 0
    while i < n and a[i] == b[i]:
        i += 1
    return i


def summarise(results: list[FileResult]) -> dict:
    """Aggregate by language.

    Tracks two distinct gates:
      - horizontal_char_match: NFC + whitespace-collapsed equality (per-file).
        Tolerant of trailing-newline / page-feed differences that
        pymupdf4llm and pdf.zig disagree on.
      - horizontal_byte_ratio: aggregate prefix-match bytes over reference
        bytes across all horizontal files in the language. This is the
        true ``≥95% byte-identical text`` invariant from architecture.md
        §11: it weights by file size and refuses to let whitespace
        collapse hide regressions.
    """
    bucket_keys = {
        "total": 0,
        "horizontal": 0,
        "horizontal_char_match": 0,
        "horizontal_byte_match": 0,
        "horizontal_ref_bytes": 0,
        "horizontal_prefix_bytes": 0,
        "vertical": 0,
        "vertical_warned": 0,
    }
    by_lang: dict[str, dict] = {lang: dict(bucket_keys) for lang in LANGS}
    for r in results:
        bucket = by_lang.setdefault(r.lang, dict(bucket_keys))
        bucket["total"] += 1
        if r.wmode == 1:
            bucket["vertical"] += 1
            if r.has_vertical_warning:
                bucket["vertical_warned"] += 1
        else:
            bucket["horizontal"] += 1
            if r.char_identical:
                bucket["horizontal_char_match"] += 1
            if r.byte_identical:
                bucket["horizontal_byte_match"] += 1
            if r.reference_text is not None:
                ref_b = r.reference_text.encode("utf-8")
                got_b = r.pdfzig_text.encode("utf-8")
                bucket["horizontal_ref_bytes"] += len(ref_b)
                bucket["horizontal_prefix_bytes"] += _common_byte_prefix(got_b, ref_b)
    return by_lang


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--skip-real", action="store_true", help="skip the real-PDF leg (no pymupdf4llm dep)")
    p.add_argument("--out", default=str(RESULTS_PATH))
    args = p.parse_args()

    if not PDFZIG.exists():
        print(f"error: {PDFZIG} missing — run `zig build` first", file=sys.stderr)
        return 2

    entries = load_index()
    results: list[FileResult] = []
    for entry in entries:
        r = evaluate(entry, skip_real=args.skip_real)
        if r is not None:
            results.append(r)

    by_lang = summarise(results)

    # Acceptance gate: ≥ 95 % byte-identical text per language. The byte
    # ratio is the architecture.md §11 invariant; the char-identity rate
    # is reported alongside as a softer signal but does not gate.
    horizontal_byte_ratio: dict[str, float] = {}
    horizontal_char_match_rate: dict[str, float] = {}
    failed_langs: list[str] = []
    for lang, b in by_lang.items():
        if b["horizontal"] == 0:
            horizontal_byte_ratio[lang] = float("nan")
            horizontal_char_match_rate[lang] = float("nan")
            continue
        ref_total = b["horizontal_ref_bytes"]
        byte_ratio = (b["horizontal_prefix_bytes"] / ref_total) if ref_total > 0 else 0.0
        horizontal_byte_ratio[lang] = byte_ratio
        horizontal_char_match_rate[lang] = b["horizontal_char_match"] / b["horizontal"]
        if byte_ratio < TARGET_BYTE_EQUALITY:
            failed_langs.append(lang)

    # Acceptance: every vertical-writing PDF must trigger the warning.
    vertical_failures: list[str] = []
    for r in results:
        if r.wmode == 1 and not r.has_vertical_warning:
            vertical_failures.append(r.id)

    summary = {
        "version": 2,
        "n_files": len(results),
        "by_lang": by_lang,
        "horizontal_byte_ratio": horizontal_byte_ratio,
        "horizontal_char_match_rate": horizontal_char_match_rate,
        "vertical_failures": vertical_failures,
        "target_horizontal_byte_ratio": TARGET_BYTE_EQUALITY,
        "results": [asdict(r) for r in results],
    }

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")

    print(f"\nwrote {out_path}")
    print("=== Per-language horizontal byte-identity (gate) ===")
    for lang in LANGS:
        rate = horizontal_byte_ratio.get(lang, float("nan"))
        rate_pct = "n/a" if rate != rate else f"{rate * 100:.1f}%"
        b = by_lang[lang]
        print(
            f"  {lang}: {rate_pct} "
            f"({b['horizontal_prefix_bytes']}/{b['horizontal_ref_bytes']} bytes, "
            f"{b['horizontal_byte_match']}/{b['horizontal']} files exact)"
        )
    print("=== Per-language horizontal char-identity (informational) ===")
    for lang in LANGS:
        rate = horizontal_char_match_rate.get(lang, float("nan"))
        rate_pct = "n/a" if rate != rate else f"{rate * 100:.1f}%"
        print(f"  {lang}: {rate_pct} ({by_lang[lang]['horizontal_char_match']}/{by_lang[lang]['horizontal']})")
    print("=== Vertical-writing warning emission ===")
    for lang in LANGS:
        b = by_lang[lang]
        print(f"  {lang}: {b['vertical_warned']}/{b['vertical']} flagged")

    rc = 0
    if failed_langs:
        print(f"\nFAIL: languages below {TARGET_BYTE_EQUALITY * 100:.0f}% byte-identical: {failed_langs}", file=sys.stderr)
        rc = 1
    if vertical_failures:
        print(f"FAIL: vertical-writing PDFs missing warning: {vertical_failures}", file=sys.stderr)
        rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
