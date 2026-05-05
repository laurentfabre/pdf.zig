#!/usr/bin/env python3
"""PR-22a [infra]: qpdf --check CI harness.

Materialises every public `generate*Pdf` fixture from
`src/testpdf.zig` to a temp dir and runs `qpdf --check` on each.
Emits a markdown summary, exits non-zero if the pass rate is below the
configured threshold (default 80%).

`qpdf --check` exit codes:
    0 — clean (pass)
    2 — warnings only, file is usable (pass)
    3 — errors (fail)
    other — qpdf itself is unhappy (fail, recorded as `tool_error`)

The harness treats both 0 and 2 as "pass" against the threshold; 2 is
counted separately as a warning so the markdown report can show which
fixtures squeak through with warnings vs which are clean.

The escalation plan (see `docs/v1.6-wave3-and-v2.0-design.md` §PR-22a)
is to bump `--min-pass-pct` from 80 to 100 once PR-W10b lands and the
emitted /OutputIntents fix the most-likely current failure.

Usage:
    python3 audit/qpdf_check.py                       # threshold 80%
    python3 audit/qpdf_check.py --min-pass-pct 100    # tightened gate
    python3 audit/qpdf_check.py --min-pass-pct 0      # report-only run

Environment variables:
    ZIG  — path to the Zig compiler (default: `zig` on PATH)
    QPDF — path to the qpdf binary (default: `qpdf` on PATH)
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
EMITTER_SRC = PROJECT / "audit" / "qpdf_emit_fixtures.zig"
EMITTER_INSTALLED = PROJECT / "zig-out" / "bin" / "qpdf-emit-fixtures"


@dataclass
class FixtureResult:
    name: str
    path: str
    status: str  # "pass" | "warn" | "fail" | "emit_fail" | "tool_error"
    exit_code: int
    detail: str  # short stderr/stdout snippet, blank on clean pass


def _short(text: str, limit: int = 200) -> str:
    text = text.strip().replace("\n", " ")
    if len(text) > limit:
        return text[: limit - 3] + "..."
    return text


def have(cmd: str) -> bool:
    return shutil.which(cmd) is not None


def build_emitter(zig: str) -> Path:
    """Run `zig build qpdf-emit-fixtures` and return the installed binary.

    The emitter imports `../src/testpdf.zig`, which `zig build-exe`
    refuses to load standalone (`error: import of file outside module
    path`). Going through `zig build` keeps the import legal because
    `build.zig` declares the module rooted at the project directory.
    """
    cmd = [zig, "build", "qpdf-emit-fixtures"]
    proc = subprocess.run(cmd, cwd=PROJECT, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.stderr.write("qpdf_check: emitter build failed\n")
        sys.stderr.write(proc.stdout)
        sys.stderr.write(proc.stderr)
        sys.exit(2)
    if not EMITTER_INSTALLED.is_file():
        sys.stderr.write(f"qpdf_check: emitter not found at {EMITTER_INSTALLED}\n")
        sys.exit(2)
    return EMITTER_INSTALLED


def emit_fixtures(emitter: Path, out_dir: Path) -> tuple[list[str], list[tuple[str, str]]]:
    """Returns (emitted_names, emit_failures).

    emit_failures is a list of (fixture_name, error_name) pairs.
    """
    proc = subprocess.run(
        [str(emitter), str(out_dir)],
        capture_output=True,
        text=True,
        cwd=PROJECT,
    )
    emitted: list[str] = []
    failures: list[tuple[str, str]] = []
    for line in proc.stdout.splitlines():
        if line.startswith("OK\t"):
            emitted.append(line.split("\t", 1)[1].strip())
    for line in proc.stderr.splitlines():
        if line.startswith("EMIT_FAIL\t"):
            parts = line.split("\t")
            if len(parts) >= 3:
                failures.append((parts[1].strip(), parts[2].strip()))
    if proc.returncode != 0 and not emitted:
        sys.stderr.write("qpdf_check: emitter produced no fixtures\n")
        sys.stderr.write(proc.stdout)
        sys.stderr.write(proc.stderr)
        sys.exit(2)
    return emitted, failures


def run_qpdf_check(qpdf: str, pdf_path: Path) -> tuple[int, str]:
    proc = subprocess.run(
        [qpdf, "--check", str(pdf_path)],
        capture_output=True,
        text=True,
    )
    detail = proc.stderr or proc.stdout
    return proc.returncode, detail


def status_for(rc: int) -> str:
    if rc == 0:
        return "pass"
    if rc == 2:
        return "warn"
    if rc == 3:
        return "fail"
    return "tool_error"


def render_markdown(
    results: list[FixtureResult],
    pass_pct: float,
    threshold: float,
    qpdf_version: str,
) -> str:
    total = len(results)
    passed = sum(1 for r in results if r.status == "pass")
    warned = sum(1 for r in results if r.status == "warn")
    failed = sum(1 for r in results if r.status == "fail")
    emit_failed = sum(1 for r in results if r.status == "emit_fail")
    tool_err = sum(1 for r in results if r.status == "tool_error")

    lines: list[str] = []
    lines.append("# qpdf --check report")
    lines.append("")
    lines.append(f"- qpdf: `{qpdf_version}`")
    lines.append(f"- total fixtures: {total}")
    lines.append(f"- clean pass (rc=0): {passed}")
    lines.append(f"- warnings (rc=2, counted as pass): {warned}")
    lines.append(f"- errors (rc=3): {failed}")
    lines.append(f"- generation failed (emitter error): {emit_failed}")
    lines.append(f"- qpdf tool error (rc not in {{0,2,3}}): {tool_err}")
    lines.append(f"- pass rate (pass+warn / total): {pass_pct:.1f}% (threshold {threshold:.0f}%)")
    lines.append("")
    lines.append("| fixture | status | rc | detail |")
    lines.append("| --- | --- | --- | --- |")
    for r in sorted(results, key=lambda x: (x.status != "fail", x.status, x.name)):
        rc = "-" if r.exit_code is None else str(r.exit_code)
        lines.append(f"| `{r.name}` | {r.status} | {rc} | {_short(r.detail, 120) or '—'} |")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--min-pass-pct", type=float, default=80.0, help="Pass-rate threshold (default 80)")
    parser.add_argument("--report", type=Path, default=None, help="Optional path to write markdown report (default: stdout only)")
    parser.add_argument("--keep", action="store_true", help="Keep the temp fixture dir for inspection")
    parser.add_argument("--emitter", type=Path, default=None, help="Pre-built emitter binary (default: build via `zig build qpdf-emit-fixtures`)")
    args = parser.parse_args()

    zig = os.environ.get("ZIG", "zig")
    qpdf = os.environ.get("QPDF", "qpdf")

    if not have(qpdf):
        sys.stderr.write(f"qpdf_check: qpdf not found (`{qpdf}`) -- skipping check (install qpdf or set QPDF=...).\n")
        # Build-step contract: skip cleanly so local devs without qpdf
        # don't get a red `zig build qpdf-check`.
        print("# qpdf --check report\n\n_qpdf not on PATH -- skipped._")
        return 0

    if args.emitter is not None:
        emitter = args.emitter
    else:
        if not have(zig):
            sys.stderr.write(f"qpdf_check: zig not found (`{zig}`); cannot build fixture emitter\n")
            print("# qpdf --check report\n\n_zig not on PATH -- skipped._")
            return 0
        emitter = build_emitter(zig)
    if not Path(emitter).is_file():
        sys.stderr.write(f"qpdf_check: emitter binary missing at {emitter}\n")
        return 2

    qpdf_version_proc = subprocess.run([qpdf, "--version"], capture_output=True, text=True)
    qpdf_version = qpdf_version_proc.stdout.splitlines()[0] if qpdf_version_proc.stdout else "unknown"

    work = Path(tempfile.mkdtemp(prefix="pdfzig-qpdf-check-"))
    try:
        fixtures_dir = work / "fixtures"
        fixtures_dir.mkdir()
        emitted, emit_failures = emit_fixtures(emitter, fixtures_dir)

        results: list[FixtureResult] = []
        for name in emitted:
            pdf_path = fixtures_dir / f"{name}.pdf"
            if not pdf_path.is_file():
                results.append(FixtureResult(name, str(pdf_path), "emit_fail", -1, "emitter claimed OK but file missing"))
                continue
            rc, detail = run_qpdf_check(qpdf, pdf_path)
            results.append(FixtureResult(name, str(pdf_path), status_for(rc), rc, detail))
        for name, errname in emit_failures:
            results.append(FixtureResult(name, "", "emit_fail", -1, errname))

        if not results:
            sys.stderr.write("qpdf_check: no fixtures produced\n")
            return 2

        passed_or_warned = sum(1 for r in results if r.status in ("pass", "warn"))
        pass_pct = 100.0 * passed_or_warned / len(results)

        md = render_markdown(results, pass_pct, args.min_pass_pct, qpdf_version)
        print(md)
        if args.report is not None:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(md, encoding="utf-8")

        if pass_pct + 1e-9 < args.min_pass_pct:
            sys.stderr.write(f"qpdf_check: pass rate {pass_pct:.1f}% < threshold {args.min_pass_pct:.0f}%\n")
            return 1
        return 0
    finally:
        if not args.keep:
            shutil.rmtree(work, ignore_errors=True)
        else:
            sys.stderr.write(f"qpdf_check: keeping work dir at {work}\n")


if __name__ == "__main__":
    sys.exit(main())
