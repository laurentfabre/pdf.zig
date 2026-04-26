# Week 1 status — pdf.zig

> **Date**: 2026-04-26 (start of week 1, post-Week-0 greenlight). Project renamed from `zlpdf` to `pdf.zig` per user decision. Roadmap source: [`architecture.md`](architecture.md) §14.
>
> **Status**: ✅ Tractable Week-1 acted-on items complete (rename + audit triage + xref fixture hunt + streaming layer design). 🟡 GitHub-fork-blocked items pending user (fork upstream + repo init + CI scaffolding). Ready for Week 2 (Unicode/CMap correctness) once fork lands.

---

## Done this week

### 1. Project rename: `zlpdf` → `pdf.zig`

- Folder: `~/Projects/Pro/zlpdf/` → `~/Projects/Pro/pdf.zig/`
- All references in `docs/` + `audit/` + `README.md` + `decisions.md` updated
- Convention matches user's `~/Projects/Pro/zeroboot.zig/` pattern
- Binary will be invoked as `pdf.zig` (folder/repo/binary all share the name)
- Repo path will be `github.com/laurentfabre/pdf.zig` (when forked)
- Brew tap will be `laurentfabre/pdf.zig`

### 2. Audit triage of 47 unexplained empty outputs

(Per [`week0-audit.md`](week0-audit.md) §6 risk #1.)

The Week-0 audit reported 288 empty cases; 241 were already alfred-flagged as `empty_text`/`low_text`/`lang_unknown` (legitimately un-extractable image-only PDFs). The 39 unexplained empties (corrected from "47" earlier; refined count after exact filename-key cross-check) cluster sharply:

| Category | Count | Mean chars (per alfred) | Mean pages |
|---|---|---|---|
| dining (menus, wine lists) | **19** | 8 211 | 7.6 |
| press_media | 6 | 3 987 | 3.0 |
| other | 6 | 5 384 | 2.5 |
| events_meetings | 3 | 9 909 | 19.0 |
| spa_wellness | 2 | 23 480 | 13.5 |
| factsheet | 1 | 2 583 | 13.0 |
| (no alfred row) | 2 | 0 | 0 |

**Top examples** (PDFs where alfred extracts content but zpdf returns empty):
- `the-reverie-saigon/The-Reverie-Saigon-Wine-List.pdf` (32p, 31 KB per alfred)
- `sandy-lane/non_resident_spa_brochure_website_final-ua-661432ee66856.pdf` (19p, 30 KB)
- `the-reverie-saigon/The-Long-Drinks-Menu.pdf` (25p, 24 KB)
- `vakkaru-maldives/ayurveda-by-siddhalepa.pdf` (8p, 16 KB)
- `shangri-la-boracay/Cielo-Food-Menu-2025.pdf` (2p, 12 KB)

**Diagnosis**: the dining concentration (19/39 = 49% of unexplained) plus the spa-brochure / wine-list pattern strongly suggests the **decorative-font / glyph-without-Unicode-mapping class** — same as the 9 "garbage" cases identified in Week-0. Restaurant menus and spa brochures love calligraphic typography, and that typography often ships as embedded fonts WITHOUT ToUnicode CMaps.

**Fix path** (Week 1–2 implementation): per `architecture.md` §9 case #7, when a font has no ToUnicode mapping AND no usable AGL fallback:
1. Emit a `font-cmap-missing:Fn` warning per page
2. Try AGL (Adobe Glyph List) fallback via glyph name → Unicode
3. If that also fails, emit `unmappable-glyph` warning + insert `\u{fffd}` for each unmappable glyph
4. **Crucially: emit something (even garbled) instead of empty**, because empty-and-no-warning is the worst failure mode

The upstream parser already has `agl.zig` (Adobe Glyph List support) and `encoding.zig` (CMap / WinAnsi / MacRoman). Need to verify those code paths are firing on these test cases vs being short-circuited.

### 3. Xref-repair fixture hunt — cases #31–35

(Per [`week0-audit.md`](week0-audit.md) §4 gate #4 deferred + [`xref_fixtures.md`](../audit/xref_fixtures.md).)

Byte-pattern scan of all 1 776 PDFs surfaced:

| Case | Population | Action |
|---|---|---|
| **#32** Multiple `%%EOF` (incremental updates) | **1 300 / 1 776 = 73%** | 5 fixtures saved; verify zpdf walks the chain of trailers correctly |
| **#31** No `%%EOF` marker (truncated) | 1 / 1 776 | Single fixture; verify zpdf falls back to linear scan or emits clean fatal |
| **#35** Trailing garbage after `%%EOF` | 1 / 1 776 | Single fixture; verify graceful ignore + warning |
| **#5 (bonus)** Linearized PDFs (web-optimized) | **907 / 1 776 = 51%** | 4 fixtures saved; verify hint-table handling |

**Surprise finding**: 73% of the corpus has incremental updates, 51% is linearized. These aren't edge cases — they're the norm. Lulzx zpdf clearly handles them in some form (zero crashes), but **correctness is unverified**: a stale `Prev` pointer or a misread linearization-hint table could silently produce wrong content. Week 1–2 needs a fixture-driven correctness test: for each fixture, eyeball-extract via pymupdf4llm + compare zpdf output, flag any divergences.

**Out of scope for byte-pattern detection**:
- Case #33 (stale trailer / wrong Prev offset) — needs trailer-parsing
- Case #34 (wrong xref entries / gen mismatch) — needs object-header parsing

These will be back-filled into the fixture set as we encounter them in Week 1–2 audit work.

### 4. Streaming layer design note

[`streaming-layer-design.md`](streaming-layer-design.md) — concrete module map, data flow, and APIs for the LLM-streaming layer. Summary:

- **~1 230 new LOC of Zig** to add on top of upstream's existing parser:
  - `stream.zig` (NDJSON envelope, per-page flush, signal handling) — ~300 LOC
  - `chunk.zig` (token-aware chunking) — ~150 LOC
  - `tokenizer.zig` (embedded BPE for token estimates) — ~250 LOC
  - `uuid.zig` (UUIDv7 generator) — ~80 LOC
  - `cli_pdfzig.zig` (pdf.zig-flavored CLI dispatch) — ~400 LOC
  - `main_pdfzig.zig` (entry point) — ~50 LOC
- Upstream's `Document.extractText()` is the workhorse; we're the I/O envelope + LLM ergonomics layer
- All architecture.md cycle-1/2 fixes baked into the API design (UUIDv7 at invocation start, terminal `fatal` record, no SIGABRT in release, `--jobs` forbidden for stdout NDJSON)

---

## Pending (blocked on user / next session)

### 5. Fork upstream Lulzx/zpdf into `github.com/laurentfabre/pdf.zig`

I can't execute `gh repo fork` without authenticated CLI access. Either:
- **You run**: `gh repo fork Lulzx/zpdf --remote=true --clone=false --org=laurentfabre /pdf.zig` (or whatever the actual flow is for your account)
- Then: replace `~/Projects/Pro/pdf.zig/upstream/` with the fork as the canonical source tree (rename `upstream/` → `src/` etc., or set up a vendored upstream + our overlay)
- Or: keep upstream as a submodule and develop our additions in a parallel `src/` tree

**Suggested layout post-fork** (mirrors zlsx where applicable):
```
pdf.zig/
├── README.md
├── LICENSE                        # CC0 or MIT (decide post-fork)
├── build.zig
├── build.zig.zon
├── src/                           # our code (+ vendored upstream OR fresh fork checkout)
│   ├── main.zig
│   ├── stream.zig                 # NEW per streaming-layer-design.md
│   ├── chunk.zig                  # NEW
│   ├── tokenizer.zig              # NEW
│   ├── uuid.zig                   # NEW
│   ├── cli.zig                    # NEW (or fork main.zig and extend)
│   └── (upstream files, possibly vendored or via @import)
├── tests/
│   └── corpus/                    # ≥30 real PDFs from Alfred + xref-repair fixtures
├── audit/                         # current week-0 work + future audits
├── docs/                          # current docs
├── bake-off/                      # cycle-10 of alfred-bakeoff vs upstream + pymupdf4llm
├── packaging/                     # brew tap, .deb, etc. (mirror zlsx)
├── scripts/                       # publish_homebrew_tap.sh etc.
├── bindings/python/               # ctypes wrapper over C ABI (mirror zlsx)
└── .github/workflows/             # CI: ci.yml, release.yml, pypi.yml
```

### 6. Two upstream PRs to send back (good-citizen)

After fork, contribute back the bug fixes we land that aren't pdf.zig-specific:
- Whatever fix solves the dining/spa empty-output class (font-CMap fallback)
- Any segfault/correctness fixes we discover

---

## Risks for Week 2 (Unicode/CMap correctness)

The 39 unexplained empties + 9 garbage cases all point to font-handling as the dominant bug class. Week 2's CJK + Cyrillic correctness work likely shares a code path with the empty-dining-menu fix — if so, both are addressed by the same set of changes to `encoding.zig` + `agl.zig`. **Plan**: don't separate "empty fix" from "Unicode fix"; treat them as the same Week-2 work item.

---

## Risks for Week 3 (NDJSON streaming layer)

Per the streaming-layer-design.md open question #4: **does upstream's `extractText` ever silently drop content?** If yes, our `warnings` array contract is leaky and Week-3 needs to either (a) go upstream and add a warnings sink to their API, or (b) accept that some warnings will be missing from our stream. **Plan**: instrument extractText calls in Week 2 with a wrap that diffs upstream's text output vs the warning records we emit; quantify the gap.

---

## Risks for Week 5 (bake-off rerun)

The Week-0 throughput number (260 PDFs/sec) was a 6-worker-parallel run. The single-worker baseline is unmeasured. If single-worker zpdf turns out to be e.g. 5 PDFs/sec, the ≥3× pymupdf4llm gate is still met (pymupdf4llm is ~1 PDF/sec single-threaded), but it's worth establishing the baseline before claims land in v1.0.

---

## File state at end of Week 1

```
~/Projects/Pro/pdf.zig/
├── README.md
├── upstream/                        # Lulzx/zpdf @ 5eba7ad (clone, builds clean, 775 KB binary)
├── audit/
│   ├── week0_run.py
│   ├── week0_results.{json,tsv}
│   ├── week0_run.log
│   └── xref_fixtures.md            # NEW this week
├── docs/
│   ├── architecture.md             # v3 + cycle-3 P3 polish
│   ├── alfred-bakeoff-report.md    # v3.10 (copied from Research/Distillation)
│   ├── decisions.md
│   ├── week0-audit.md
│   ├── streaming-layer-design.md   # NEW this week
│   └── week1-status.md             # NEW this week (this file)
├── bake-off/                        # empty (Week 5 work)
└── scripts/                         # empty (Week 6 work)
```

Ready for Week 2 once user forks the upstream and we set up the proper source tree.
