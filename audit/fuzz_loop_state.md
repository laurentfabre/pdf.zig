# Autonomous fuzz / Codex / bench loop — state file

> Started 2026-05-05 by Laurent's directive: "Keep running loops in subagents
> between Claude Code and Codex to run complex fuzzing techniques on every
> entry point and deep functions (defense in depth) and refresh benchmarks
> periodically to check if workarounds have an effect on performance."

## Loop shape

> **Updated 2026-05-05 (post-iter-2):** the user added two directives —
> *escalate complexity per iter* (move beyond shallow byte-fuzz) and
> *audit for format-string vulnerabilities*. The complexity ladder
> below replaces the old flat inventory; the format-string audit
> findings are recorded inline.

### Complexity ladder (apply on top of the per-module inventory)

| Tier | Technique | Used in |
|---:|---|---|
| 1 | **Random-bytes byte-fuzz.** Drop random / biased bytes into a single entrypoint; assert no panic + simple bounds. | iter 0–1 (xmp / encrypt / md / truetype / jpeg / decompress) |
| 2 | **Single-call deep-API fuzz.** Reach a non-public-byte entrypoint directly (e.g. `Parser.parseObject` / `Parser.initAt`); assert structural post-conditions on returned objects (no NaN reals, depth ≤ MAX, `pos ≤ data.len`). | iter 2 (parser) |
| 3 | **Round-trip + property fuzz.** Encode → decode → equal; or decode → re-encode → re-decode → equal. Surfaces algebraic bugs the floor invariant misses. | iter 1 (encrypt + ASCII85 round-trip) |
| 4 | **Stateful sequence fuzz.** Drive a multi-call sequence (e.g. interpreter `q`/`Q` interleaving, BDC/EMC nesting, document-builder `addPage` / `setStructTree` / `write`); assert state-machine invariants across the sequence. | iter 3 (interpreter) |
| 5 | **Differential fuzz.** Run two implementations on the same input (e.g. our cmap parser vs `harfbuzz`-derived reference; our flate vs `std.compress.flate`); flag mismatches. | tier 5 — open |
| 6 | **Coverage-guided mutation fuzz.** AFL-style: track basic-block coverage, bias toward inputs that hit new edges. Zig has `zig fuzz` ≥0.16; not yet wired in. | tier 6 — open |
| 7 | **Multi-stage adversarial fuzz.** PDF-of-PDF: parse → mutate → emit → re-parse → mutate → … on the same fixture. Surfaces serialise/parse asymmetries. | tier 7 — open |

Future iters should pick the lowest-numbered tier the module hasn't
been hit at yet, OR escalate one tier on a previously-fuzzed module
when its current tier comes up clean.

### Format-string audit (one-off, 2026-05-05)

Audited every `std.fmt.bufPrint` / `allocPrint` / `format`,
`std.debug.print`, and writer `.print(…)` site (511 total).

**Findings:**

- **No traditional format-string vulns.** Zig 0.16's
  `std.fmt.format` and friends require the format string to be a
  comptime-known string literal. Passing attacker-controlled bytes
  as the format-string slot would fail to compile.
- **ANSI / terminal-escape leakage via stderr error messages
  (LOW severity)**: `src/main.zig:158` (`Error opening {s}: {}`),
  `src/main.zig:171` (`Error creating {s}: {}`),
  `src/main.zig:165` (encryption warning), and similar paths in
  `cli_pdfzig.zig` echo user-supplied PDF paths verbatim into
  stderr. A malicious filename containing `\x1b[…]` could inject
  ANSI escapes and pollute the user's terminal. Not exploitable
  beyond DoS-of-terminal-state; the user has to volunteer the
  filename. Logged here for completeness; revisit if pdf.zig grows
  any path that prints PDF-internal strings (e.g. `/Title` from
  the document /Info dict) to stderr.
- **JSON-escape boundary is heavily fuzzed.** `writeJsonString` in
  `src/stream.zig` is called on every attacker-controlled string
  field on the NDJSON output path (titles, page text, font names,
  URIs, image data, struct-element /Alt and /ActualText, …).
  Already covered by `stream_json_string` at 1M iters clean.
- **Action items:** none currently warrant a fuzz target. If a
  future feature emits PDF /Info or /Title strings to stderr,
  factor a `sanitiseForTerminal` helper and fuzz it.

## Loop shape (per-iter sequence)

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
| 2 | `parser.zig` | tokenizer, name-tree, dict, stream-len | iter-2 done — 3 default-gate targets reaching `parseObject`, `parseIndirectObject`, and `initAt` directly; no findings | ✅ iter 2 |
| 3 | `interpreter.zig` | content-stream operators (q/Q, cm, Tj, BDC/EMC, Do…) | iter-3 done — 2 default-gate targets (lexer + BDC/EMC nesting via DocumentBuilder); 3rd target dropped due to Finding 006 (ContentInterpreter bit-rot) | ✅ iter 3 |
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
| 2 | 2026-05-05 | parser.zig (Parser.parseObject / parseIndirectObject / initAt) | parser_object_pdfish · parser_indirect_object_random · parser_init_at_offset_random | none — all three targets clean at 100k iters in ReleaseSafe | parser targets at 100k iters: pdfish 155 ms, indirect 16 ms, initAt 4 ms (full bench rerun pending) | #76 |
| 3 | 2026-05-05 | interpreter.zig (content-stream operators) | interpreter_random_ops · interpreter_bdc_emc_nesting | **YES — Finding 006**: `ContentInterpreter(Writer)` is 0.16-stale (managed-ArrayList API at interpreter.zig:103 + 172). Compile-time only; no user-reachable runtime impact (the type is public surface but unused — extractContentStream drives ContentLexer directly). | iter-3 targets at 100k: random_ops 6.0 s, bdc_emc 17.0 s | #76 |
| 4 | TBD | tier-3 round-trip on a v1.6 module not yet at tier 3 | TBD | TBD | TBD | TBD |

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
