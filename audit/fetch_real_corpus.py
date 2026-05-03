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
import json
import sys
import urllib.request
import urllib.error
from pathlib import Path
from typing import Iterable

ALLOWED_LICENSES = {
    "http://creativecommons.org/publicdomain/mark/1.0/",
    "https://creativecommons.org/publicdomain/mark/1.0/",
    "http://creativecommons.org/publicdomain/zero/1.0/",
    "https://creativecommons.org/publicdomain/zero/1.0/",
}

# Items whose IA metadata doesn't carry licenseurl but are in the public domain
# under US copyright (pre-1929). The manifest tags these with
# license="PD-pre-1929"; we don't cross-check IA in that case.
PD_BY_DATE_TAG = "PD-pre-1929"

REPO_ROOT = Path(__file__).resolve().parent.parent
MANIFEST_PATH = REPO_ROOT / "audit" / "cjk-pdfs" / "real-corpus-manifest.json"
DEST_DIR = REPO_ROOT / "audit" / "cjk-pdfs" / "real"

USER_AGENT = "pdf.zig/PR-15 corpus-fetcher (https://github.com/laurentfabre/pdf.zig)"


def http_json(url: str) -> dict:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


def http_download(url: str, dest: Path) -> int:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=120) as r, dest.open("wb") as out:
        n = 0
        while True:
            chunk = r.read(64 * 1024)
            if not chunk:
                break
            out.write(chunk)
            n += len(chunk)
    return n


def find_pdf_in_metadata(meta: dict) -> str | None:
    """Pick the largest .pdf in the IA item's file list."""
    files = meta.get("files", [])
    pdfs = [
        f for f in files
        if isinstance(f, dict)
        and f.get("name", "").lower().endswith(".pdf")
        and f.get("source") in ("original", "derivative")
    ]
    if not pdfs:
        return None
    pdfs.sort(key=lambda f: int(f.get("size", "0") or 0), reverse=True)
    return pdfs[0]["name"]


def verify_license(meta: dict, expected_tag: str) -> tuple[bool, str]:
    """Confirm the live licenseurl on IA metadata matches the manifest tag.

    Returns (ok, reason).
    """
    if expected_tag == PD_BY_DATE_TAG:
        # Manifest asserts pre-1929 / US public domain; we don't cross-check IA
        # because pre-1929 items frequently lack a licenseurl field.
        return True, "manifest assertion: pre-1929 US public domain"

    md = meta.get("metadata", {})
    live = md.get("licenseurl") or md.get("license") or ""
    if isinstance(live, list):
        live = live[0] if live else ""

    if expected_tag in {"PD-Mark", "CC0"} and live in ALLOWED_LICENSES:
        return True, f"licenseurl={live}"
    return False, f"licenseurl={live!r} not in allow-list (expected {expected_tag})"


def fetch_entry(entry: dict, lang: str, dry_run: bool, max_mb: int | None) -> str:
    iid = entry["ia_id"]
    out_name = f"{entry['id']}.pdf"
    dest = DEST_DIR / out_name
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

    pdf_name = find_pdf_in_metadata(meta)
    if not pdf_name:
        return f"  ERROR  {out_name}: no .pdf file in IA item {iid}"

    if dry_run:
        return f"  dry-ok {out_name} ({reason})"

    url = f"https://archive.org/download/{iid}/{urllib.parse.quote(pdf_name)}"
    try:
        n = http_download(url, dest)
    except urllib.error.URLError as e:
        if dest.exists():
            dest.unlink()
        return f"  ERROR  {out_name}: download failed: {e}"
    return f"  ok     {out_name} ({n // 1024} KB)"


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
