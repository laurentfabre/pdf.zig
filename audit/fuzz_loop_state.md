# Autonomous fuzz / Codex / bench loop — state file

> Started 2026-05-05 by Laurent's directive: "Keep running loops in subagents
> between Claude Code and Codex to run complex fuzzing techniques on every
> entry point and deep functions (defense in depth) and refresh benchmarks
> periodically to check if workarounds have an effect on performance."

## Loop shape

Each iteration:

1. **Pick** the next module from the deepening inventory (below).
2. **Author** deep fuzz harnesses via a `zig-defensive` subagent in an
   isolated worktree. Coverage target = every public entry point + every
   non-trivial branch reachable through them. Defense-in-depth — not just
   the byte-level boundary `fuzz/2026-05-05-v1.6` covered.
3. **Run** the new harnesses at ≥1 M iters until clean.
4. **Codex review** the new harnesses + invariants via `repo-review` on the
   diff. Use the second-opinion to catch missed invariants or weak post-
   conditions.
5. **Re-bench** — rerun `PDFZIG_FUZZ_ITERS=50000 zig build fuzz` and diff
   against `audit/bench_baseline.md`. Targets > 1.10× baseline are flagged.
6. **Land** — commit + push + open a non-draft PR. Title: `test(fuzz):
   iter-N — deep fuzz <module>`. Body lists harnesses added, findings (if
   any), bench delta table.
7. **If a real bug surfaces** — open a separate GitHub issue with the
   reproducer; do **not** auto-fix. The user reviews and authorises a fix
   in a follow-up.
8. **Update this file** — tick the module's row, append the iteration to
   the history log.
9. **Schedule** the next wakeup (ScheduleWakeup with the original directive
   verbatim).

## Deepening inventory

Modules ordered by attack-surface heat. Coverage column tracks current
state; "byte-input" means the `fuzz/2026-05-05-v1.6` pass already covered
the raw-bytes boundary and only deeper-API or stateful fuzzing remains.

| # | Module | Surface | Current coverage | Loop iter |
|---:|---|---|---|---:|
| 1 | `decompress.zig` | FlateDecode / RunLengthDecode / ASCIIHex / ASCII85 streams | iter-1 done — 2 default + 1 aggressive-gate; ASCII85 u32 overflow surfaced (Finding 005) | ✅ iter 1 |
| 2 | `parser.zig` | tokenizer, name-tree, dict, stream-len | only via `pdf_open_random/magic_prefix` | |
| 3 | `interpreter.zig` | content-stream operators (q/Q, cm, Tj, BDC/EMC, Do…) | only via `lattice_content_random` | |
| 4 | `bidi.zig` | UAX #9 Level-1 resolution | none | |
| 5 | `cff.zig` | CFF Type 2 glyph parsing (used in font_embedder fallback) | none | |
| 6 | `truetype.zig` | already byte-fuzzed (`truetype_parse_random`); add `subset()` deep fuzz | byte-input | |
| 7 | `font_embedder.zig` | `emit()` — assembles cmap + ToUnicode + subsetted glyf | none | |
| 8 | `image_writer.zig` | `emitImageObject()` — DCT passthrough + raw paths | byte-input (jpeg_meta only) | |
| 9 | `encrypt_writer.zig` | already round-trip fuzzed; deepen `authenticateUser/Owner` paths | byte-input | |
| 10 | `mcid_resolver.zig` | random parsed-tree shapes | none | |
| 11 | `attr_flattener.zig` | random parsed-tree shapes (depth, attr inheritance) | none | |
| 12 | `a11y_emitter.zig` | random parsed-tree shapes | none | |
| 13 | `struct_writer.zig` | random in-memory tree descriptions | none | |
| 14 | `xmp_writer.zig` | already byte-fuzzed; deepen `levelView` corner cases | byte-input | |
| 15 | `markdown.zig` | the markdown parser itself (not just `renderTagged`) | only via tokenizer_realistic_md | |
| 16 | `markdown_to_pdf.zig` | already byte-fuzzed (`markdown_render_tagged`); deepen `renderCore(tagged=false)` | byte-input | |
| 17 | `pdf_writer.zig` | low-level Writer — escape + indirect refs | none | |
| 18 | `pdf_resources.zig` | resource registry (font/image/colorspace handles) | none | |
| 19 | `pagetree.zig` | balanced page-tree assembly | none | |
| 20 | `outline.zig` | bookmarks tree | none | |
| 21 | `crypto.zig` | RC4 / AES primitives | only via encrypt_roundtrip | |
| 22 | `tables.zig` | table detector | none | |
| 23 | `chunk.zig` | already byte-fuzzed (`chunk_break_finder`); deepen `chunkMarkdown` end-to-end | byte-input | |
| 24 | `tokenizer.zig` | already byte-fuzzed (`tokenizer_count`, `tokenizer_realistic_md`); deepen heuristic vs cl100k | byte-input | |

## History

| Iter | Date | Module | Harnesses added | Bug? | Bench delta | PR |
|---:|---|---|---|---|---|---|
| 0 | 2026-05-05 | seven v1.6 modules | xmp_escape_xml · xmp_emit_random · encrypt_roundtrip_{rc4,aes} · markdown_render_tagged · truetype_parse_random · jpeg_meta_random | n/a (initial pass) | baseline | #76 |
| 1 | 2026-05-05 | decompress.zig | decompress_ascii_hex_random · decompress_runlength_random · decompress_ascii85_roundtrip (aggressive) | **YES — Finding 005**: u32 overflow in `decodeASCII85` at src/decompress.zig:386. Aggressive-gated; default-gate clean. | within noise (full bench rerun pending; per-target wall ASCIIHex 9.9 s, RunLength 11.2 s at 100k — close to subagent's 10.0/11.5 s) | #76 |
| 2 | TBD | parser.zig (tokenizer, name-tree, dict, stream-len) | TBD | TBD | TBD | TBD |

## Rules the loop must obey

- **Subagents commit only — main session pushes.** (Memorised feedback.)
- **No `--no-verify`, no force-push to main.**
- **If a fuzz target panics or produces a real invariant violation:** open a
  GitHub issue with the byte-exact reproducer, the seed, and the iter
  number. Do **not** auto-fix.
- **Bench regressions ≥10 % per target:** flag in the PR body but do not
  block landing. The user decides whether the slowdown is acceptable
  (e.g., a defensive workaround) or whether to revert and rethink.
- **Don't pile on more than 3 new targets per PR.** Smaller PRs review
  faster and land cleaner.
- **Before each iter:** `git fetch origin && git checkout -b
  fuzz/<date>-iter-<N> origin/main`. Always branch off latest origin/main.

## Stopping the loop

Type `/loop stop` or simply tell the next-firing iteration "stop". The
ScheduleWakeup chain is broken on first reply that contains "stop".
