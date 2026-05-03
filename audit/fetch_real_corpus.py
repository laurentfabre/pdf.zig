#!/usr/bin/env python3
"""Fetch the real-world CJK corpus listed in real-corpus-manifest.json.

PR-15 follow-up: each entry is sourced from Internet Archive and carries an
explicit Public Domain Mark or CC0 license URL. The script verifies the live
licenseurl on each item's metadata against an allow-list before downloading;
any mismatch aborts that item with a clear message rather than silently
fetching potentially-restricted content.

Usage:
    python3 audit/fetch_real_corpus.py              # fetch all 30
    python3 audit/fetch_real_corpus.py --lang ja    # only Japanese
    python3 audit/fetch_real_corpus.py --lang zh,ko # multi-lang
    python3 audit/fetch_real_corpus.py --dry-run    # license-check only
    python3 audit/fetch_real_corpus.py --max-mb 20  # skip items larger than 20 MB

After fetching, run:
    python3 audit/cjk_subset.py
    python3 audit/v1_4_cjk_run.py
"""

from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import re
import sys
import urllib.request
import urllib.error
from pathlib import Path
from typing import Iterable

# Public Domain Mark 1.0 — manifest tag "PD-Mark".
PD_MARK_LICENSES = {
    "http://creativecommons.org/publicdomain/mark/1.0/",
    "https://creativecommons.org/publicdomain/mark/1.0/",
}
# CC0 1.0 — manifest tag "CC0".
CC0_LICENSES = {
    "http://creativecommons.org/publicdomain/zero/1.0/",
    "https://creativecommons.org/publicdomain/zero/1.0/",
}
ALLOWED_LICENSES = PD_MARK_LICENSES | CC0_LICENSES

# Items whose IA metadata doesn't carry licenseurl but are in the public domain
# under US copyright (pre-1929 publication). The manifest tags these with
# license="PD-pre-1929"; we cross-check IA's metadata.date / metadata.year
# fields and fail closed if neither resolves to a year ≤ 1928.
PD_BY_DATE_TAG = "PD-pre-1929"
PD_BY_DATE_CUTOFF_YEAR = 1928  # inclusive — anything published in 1928 or earlier.

# Manifest entry id is used to construct the output filename. Restrict to a
# conservative charset so a malicious / typo'd manifest entry can't path-
# traverse out of DEST_DIR.
ID_RE = re.compile(r"^[A-Za-z0-9._-]+$")

REPO_ROOT = Path(__file__).resolve().parent.parent
MANIFEST_PATH = REPO_ROOT / "audit" / "cjk-pdfs" / "real-corpus-manifest.json"
DEST_DIR = REPO_ROOT / "audit" / "cjk-pdfs" / "real"

USER_AGENT = "pdf.zig/PR-15 corpus-fetcher (https://github.com/laurentfabre/pdf.zig)"

# %PDF-1.x magic, leniently — IA serves a small handful of malformed-header
# PDFs (e.g. utf-8 BOM + %PDF) so we sniff for the four-byte literal anywhere
# in the first 1024 bytes rather than insisting on offset 0.
PDF_MAGIC = b"%PDF-"


def http_json(url: str) -> dict:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


def http_download(url: str, dest: Path) -> tuple[int, str]:
    """Download to ``dest``. Returns (bytes_written, sha256-hex)."""
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    h = hashlib.sha256()
    with urllib.request.urlopen(req, timeout=120) as r, dest.open("wb") as out:
        n = 0
        while True:
            chunk = r.read(64 * 1024)
            if not chunk:
                break
            out.write(chunk)
            h.update(chunk)
            n += len(chunk)
    return n, h.hexdigest()


def find_pdf_in_metadata(meta: dict) -> tuple[str, int] | None:
    """Pick the largest .pdf in the IA item's file list. Returns (name, size_bytes)."""
    files = meta.get("files", [])
    pdfs = []
    for f in files:
        if not isinstance(f, dict):
            continue
        name = f.get("name", "")
        if not name.lower().endswith(".pdf"):
            continue
        if f.get("source") not in ("original", "derivative"):
            continue
        try:
            size = int(f.get("size", "0") or 0)
        except (TypeError, ValueError):
            size = 0
        pdfs.append((name, size))
    if not pdfs:
        return None
    pdfs.sort(key=lambda t: t[1], reverse=True)
    return pdfs[0]


def _ia_publication_year(meta: dict) -> int | None:
    """Best-effort year extraction from IA metadata.date / metadata.year."""
    md = meta.get("metadata", {})
    for key in ("date", "year", "publicdate"):
        val = md.get(key)
        if isinstance(val, list):
            val = val[0] if val else ""
        if not val:
            continue
        m = re.search(r"\b(\d{4})\b", str(val))
        if m:
            try:
                y = int(m.group(1))
            except ValueError:
                continue
            # publicdate is the IA upload year — useful only as an upper bound.
            # Treat any reasonable year as a candidate.
            if 1 <= y <= _dt.date.today().year:
                return y
    return None


def verify_license(meta: dict, expected_tag: str) -> tuple[bool, str]:
    """Confirm the live IA metadata matches the manifest license tag.

    Allow-lists are tag-specific: ``PD-Mark`` only accepts the PD Mark URLs,
    ``CC0`` only accepts the CC0 URLs. ``PD-pre-1929`` requires the IA
    publication year to be ≤ 1928; otherwise the manifest assertion is
    rejected (fail-closed).

    Returns ``(ok, reason)``.
    """
    md = meta.get("metadata", {})
    live = md.get("licenseurl") or md.get("license") or ""
    if isinstance(live, list):
        live = live[0] if live else ""

    if expected_tag == "PD-Mark":
        if live in PD_MARK_LICENSES:
            return True, f"licenseurl={live}"
        return False, f"licenseurl={live!r} is not Public Domain Mark 1.0"

    if expected_tag == "CC0":
        if live in CC0_LICENSES:
            return True, f"licenseurl={live}"
        return False, f"licenseurl={live!r} is not CC0 1.0"

    if expected_tag == PD_BY_DATE_TAG:
        # If IA carries a recognised allowed licenseurl, that's a strict match.
        if live in ALLOWED_LICENSES:
            return True, f"licenseurl={live}"
        year = _ia_publication_year(meta)
        if year is not None and year <= PD_BY_DATE_CUTOFF_YEAR:
            return True, f"IA year={year} ≤ {PD_BY_DATE_CUTOFF_YEAR} (US PD)"
        if year is not None:
            return False, (
                f"IA year={year} > {PD_BY_DATE_CUTOFF_YEAR}; "
                f"licenseurl={live!r} not in allow-list"
            )
        return False, (
            "IA metadata has no year and no recognised licenseurl; "
            f"refusing to honour PD-pre-1929 assertion (live={live!r})"
        )

    return False, f"unknown manifest license tag {expected_tag!r}"


def safe_dest_for_id(entry_id: str) -> Path:
    """Map a manifest id to a path inside DEST_DIR, refusing traversal.

    Rejects ids that contain anything outside ``[A-Za-z0-9._-]`` or that
    resolve to a path outside ``DEST_DIR`` after normalisation.
    """
    if not ID_RE.match(entry_id):
        raise ValueError(f"manifest id {entry_id!r} has unsafe characters")
    candidate = (DEST_DIR / f"{entry_id}.pdf").resolve()
    dest_root = DEST_DIR.resolve()
    try:
        candidate.relative_to(dest_root)
    except ValueError as e:
        raise ValueError(
            f"manifest id {entry_id!r} resolves outside {dest_root}"
        ) from e
    return candidate


def _sniff_pdf(dest: Path) -> bool:
    try:
        with dest.open("rb") as f:
            head = f.read(1024)
    except OSError:
        return False
    return PDF_MAGIC in head


def fetch_entry(entry: dict, lang: str, dry_run: bool, max_mb: int | None) -> str:
    iid = entry["ia_id"]
    raw_id = entry["id"]
    try:
        dest = safe_dest_for_id(raw_id)
    except ValueError as e:
        return f"  ERROR  {raw_id!r}: {e}"
    out_name = dest.name
    if dest.exists():
        return f"  skip   {out_name} (already exists)"

    if max_mb is not None and entry.get("size_mb", 0) > max_mb:
        return f"  skip   {out_name} ({entry.get('size_mb')} MB > --max-mb {max_mb})"

    try:
        meta = http_json(f"https://archive.org/metadata/{iid}")
    except urllib.error.URLError as e:
        return f"  ERROR  {out_name}: metadata fetch failed: {e}"

    ok, reason = verify_license(meta, entry["license"])
    if not ok:
        return f"  ERROR  {out_name}: license mismatch — {reason}"

    pdf_info = find_pdf_in_metadata(meta)
    if pdf_info is None:
        return f"  ERROR  {out_name}: no .pdf file in IA item {iid}"
    pdf_name, pdf_size = pdf_info

    if dry_run:
        return f"  dry-ok {out_name} ({reason})"

    url = f"https://archive.org/download/{iid}/{urllib.parse.quote(pdf_name)}"
    try:
        n, sha = http_download(url, dest)
    except urllib.error.URLError as e:
        if dest.exists():
            dest.unlink()
        return f"  ERROR  {out_name}: download failed: {e}"

    # Integrity gates: the bytes-on-wire must match the IA-advertised size
    # (if any), the file must look like a PDF, and we record sha256 so a
    # later run can detect drift.
    if pdf_size > 0 and n != pdf_size:
        dest.unlink(missing_ok=True)
        return f"  ERROR  {out_name}: size mismatch ({n} != IA-declared {pdf_size})"
    if not _sniff_pdf(dest):
        dest.unlink(missing_ok=True)
        return f"  ERROR  {out_name}: %PDF magic not found in first 1024 bytes"

    expected_sha = entry.get("sha256")
    if expected_sha and sha.lower() != expected_sha.lower():
        dest.unlink(missing_ok=True)
        return f"  ERROR  {out_name}: sha256 mismatch (got {sha}, manifest {expected_sha})"

    return f"  ok     {out_name} ({n // 1024} KB, sha256={sha[:16]}…)"


def main(argv: Iterable[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--lang", help="Comma-separated subset: ja,zh,ko (default: all)")
    p.add_argument("--dry-run", action="store_true", help="License-check only; do not download")
    p.add_argument("--max-mb", type=int, default=None, help="Skip items larger than N MB")
    args = p.parse_args(list(argv))

    if not MANIFEST_PATH.exists():
        print(f"ERROR: {MANIFEST_PATH} missing", file=sys.stderr)
        return 1

    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    DEST_DIR.mkdir(parents=True, exist_ok=True)

    requested = (
        {x.strip() for x in args.lang.split(",")}
        if args.lang
        else {"ja", "zh", "ko"}
    )

    failures = 0
    for lang in sorted(requested):
        if lang not in manifest:
            print(f"WARN: unknown lang '{lang}', skipping")
            continue
        print(f"[{lang}]")
        for entry in manifest[lang]:
            line = fetch_entry(entry, lang, args.dry_run, args.max_mb)
            print(line)
            if " ERROR " in line:
                failures += 1

    if failures:
        print(f"\n{failures} item(s) failed.", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    import urllib.parse  # local import; only used by main()
    sys.exit(main(sys.argv[1:]))
