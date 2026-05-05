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
| 6 | **Coverage-guided mutation fuzz.** AFL-style: track basic-block coverage, bias toward inputs that hit new edges. Zig 0.16's `std.testing.fuzz` API was wired in iter-6 in **forward-portable mode** (seed-corpus today, `.fuzz = true` flip-ready) via `~/.zvm/bin/zig build fuzz-cov`. **Toolchain block (Finding 007)**: 0.16.0's `.fuzz = true` test binary segfaults during the discovery pass at `fuzzer.zig:904 ensureCorpusLoaded`. Flip the flag once 0.16.x fixes the discovery pass — harness body unaffected. | iter 6 (seed-corpus mode) |
| 7 | **Multi-stage adversarial fuzz.** PDF-of-PDF: parse → mutate → emit → re-parse → mutate → … on the same fixture. Surfaces serialise/parse asymmetries. | iter 7 (4-stage cycle, pdf_of_pdf_roundtrip target) |

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
| 1 | `decompress.zig` | FlateDecode / RunLengthDecode / ASCIIHex / ASCII85 streams | iter-1 done — 2 default + 1 aggressive-gate; ASCII85 u32 overflow surfaced (Finding 005). iter-5 done — 3 default-gate differentials (RLE, AsciiHex, multi-filter chain); flate-vs-stdlib pivot documented (decompress.zig:135 wraps stdlib). | ✅ iter 1, 5 |
| 2 | `parser.zig` | tokenizer, name-tree, dict, stream-len | iter-2 done — 3 default-gate targets reaching `parseObject`, `parseIndirectObject`, and `initAt` directly; no findings | ✅ iter 2 |
| 3 | `interpreter.zig` | content-stream operators (q/Q, cm, Tj, BDC/EMC, Do…) | iter-3 done — 2 default-gate targets (lexer + BDC/EMC nesting via DocumentBuilder); 3rd target dropped due to Finding 006 (ContentInterpreter bit-rot) | ✅ iter 3 |
| 4 | `bidi.zig` | UAX #9 Level-1 resolution | iter-8 done — 3 default-gate targets (resolve, reorder property, format-char storm); SUT-independent invariants (byte conservation, UTF-8 valid, multiset equality); no findings | ✅ iter 8 |
| 5 | `cff.zig` | CFF Type 2 glyph parsing (used in font_embedder fallback) | iter-9 done — 3 reproducer_only targets (`cff_init_random_bytes`, `cff_init_biased_header`, `cff_dict_random_topdict`); **Finding 008** (two bugs) — Index.parse last-offset underflow at cff.zig:263, parseTopDict @intCast trap on negative operand at cff.zig:105. All three trip in ReleaseSafe < 10k iters across multiple seeds. | ✅ iter 9 |
| 6 | `truetype.zig` | already byte-fuzzed (`truetype_parse_random`); add `subset()` deep fuzz | byte-input | |
| 7 | `font_embedder.zig` | `emit()` — assembles cmap + ToUnicode + subsetted glyf | none | |
| 8 | `image_writer.zig` | `emitImageObject()` — DCT passthrough + raw paths | iter-13 done — 2 default-gate targets (`image_writer_emit_dct_verbatim`, `image_writer_emit_roundtrip_dims`) + 1 reproducer_only (`image_writer_emit_random_geom`). **Finding 010**: `pdf_writer.writeStreamCompressed` panics inside stdlib flate when body ≤ 8 B (root cause: `initCapacity(body.len)` at pdf_writer.zig:397 too small for zlib header). Repro at seed 0x1, < 1k iters. | ✅ iter 13 |
| 9 | `encrypt_writer.zig` | already round-trip fuzzed; deepen `authenticateUser/Owner` paths | byte-input | |
| 10 | `mcid_resolver.zig` | random parsed-tree shapes | none | |
| 11 | `attr_flattener.zig` | random parsed-tree shapes (depth, attr inheritance) | none | |
| 12 | `a11y_emitter.zig` | random parsed-tree shapes | iter-14 done — 3 default-gate targets (`a11y_emitter_synth_tree_emit`, `a11y_emitter_flatten_then_emit`, `a11y_emitter_reading_order_dfs`); arena-synth StructTree + minimal Document; SUT-independent invariants (UTF-8, brace balance, NDJSON terminator, /Alt-inheritance count, reading_order DFS monotonicity); no findings. | ✅ iter 14 |
| 13 | `struct_writer.zig` | random in-memory tree descriptions | none | |
| 14 | `xmp_writer.zig` | already byte-fuzzed; deepen `levelView` corner cases | byte-input | |
| 15 | `markdown.zig` | the markdown parser itself (not just `renderTagged`) | iter-12 done — `markdown.zig` is in fact a PDF→Markdown *renderer* (no parser exists). 1 default-gate target (`markdown_render_pdf_to_md`) drives `renderPageToMarkdown` with biased TextSpan slices (heading-trip font sizes, bullet / numbered-prefix texts, indent buckets); SUT-independent invariants (UTF-8 in→out, output ≤ 32 × per element + slack, no embedded NUL); no findings. | ✅ iter 12 |
| 16 | `markdown_to_pdf.zig` | already byte-fuzzed (`markdown_render_tagged`); deepen `renderCore(tagged=false)` | iter-12 done — `markdown_to_pdf_untagged` covers the `tagged=false` branch (PDF magic + `%%EOF`, reparse via Document.openFromMemory yields `pageCount > 0`, negative-space: no `/StructTreeRoot`); no findings. | ✅ iter 12 |
| 17 | `pdf_writer.zig` | low-level Writer — escape + indirect refs | iter-4 done — 3 default-gate round-trip targets via DocumentBuilder ↔ Document; no findings | ✅ iter 4 |
| 18 | `pdf_resources.zig` | resource registry (font/image/colorspace handles) | iter-10 done — 3 default-gate stateful-sequence targets (`pdf_resources_builtin_dedup`, `pdf_resources_image_register_assign`, `pdf_resources_freeze_after_assign`); no findings | ✅ iter 10 |
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
| 4 | 2026-05-05 | pdf_writer / DocumentBuilder ↔ Document round-trip (tier 3) | writer_drawtext_roundtrip · writer_multipage_count · writer_text_escape_roundtrip | none — all 3 default-gate targets clean at 100k iters in ReleaseSafe | iter-4 targets at 100k: drawtext_roundtrip 12.2 s · multipage_count 53.6 s · text_escape_roundtrip 8.3 s | #76 |
| 5 | 2026-05-05 | decompress.zig differential (tier 5) — encoder/decoder round-trip on RLE / ASCIIHex / multi-filter chain. **Pivoted away from flate-vs-stdlib**: src/decompress.zig:135 wraps `std.compress.flate.Decompress` directly, so a flate differential is tautological. Reference encoders are inline in fuzz_runner.zig (encodeRunLengthLiteral · encodeRunLengthMixed · encodeAsciiHex). Multi-filter chain target uses `/Filter [ASCIIHexDecode RunLengthDecode]` to exercise the inter-stage ownership transfer in `decompressStream`. | decompress_runlength_diff · decompress_ascii_hex_diff · decompress_filter_chain_diff | none — all 3 default-gate targets clean at 100k iters in ReleaseSafe (initial encoder bug in repeat-mode RLE was caught by the differential property and fixed before commit; details in PR body) | iter-5 targets at 100k: runlength_diff 1.5 s · ascii_hex_diff 2.0 s · filter_chain_diff 1.5 s | #76 |
| 6 | 2026-05-05 | tier-6 (coverage-guided fuzz) — wired up Zig 0.16's `std.testing.fuzz` API in **forward-portable mode**. New `src/fuzz_cov.zig` (305 LOC) + `build.zig` step `fuzz-cov`. **Pivot**: 0.16.0 ships `.fuzz = true` test discovery broken (segfault at fuzzer.zig:904 ensureCorpusLoaded — Finding 007). Today the harness runs in seed-corpus-only mode; flip `.fuzz = true` once 0.16.x ships the discovery-pass fix and the same harness becomes coverage-guided AFL-style with no edits. | fuzz_cov.zig harnesses (parser_object + decompress_filter_chain) — driven via `~/.zvm/bin/zig build fuzz-cov` | none in pdf.zig source. **Finding 007 (toolchain)**: 0.16.0 std.testing.fuzz crashes during discovery; tracked in audit/fuzz_findings.md. | fuzz-cov runs <1 s on the seed corpus today | #76 |
| 7 | 2026-05-05 | tier-7 (multi-stage adversarial PDF-of-PDF) — 4-stage build → parse → canonicalise → mutate → re-emit cycle per iter. Canonicalisation joins per-page extractMarkdown by US byte 0x1f. Mutates 1-6 PDF-meaningful punctuation flips per stage; re-emits via DocumentBuilder.drawText. Drift between adjacent stages surfaces serialise/parse asymmetries. | pdf_of_pdf_roundtrip — driven via the standard fuzz_runner loop. | none — 100k iters clean in 5.5 s (=4 stages each = 400k stage-cycles) and 500k iters clean in 27 s. The drawText WinAnsi filter + literal-string escape rules + extractMarkdown ASCII recovery converge to a stable filtered canon by stage 1. **Codex P2 caveat**: oracle re-parses the emitted PDF and uses that as the next-stage expected value; weakens the test to detect parser non-determinism rather than serialise/parse asymmetry. Documented inline as a CAVEAT block; deferred to a follow-up iter (needs WinAnsi filter as a public helper). | wall: 5.5 ms/iter (1.4 ms/stage) | #76 |
| 8 | 2026-05-05 | bidi.zig (UAX #9 Level-1 resolver + reorder) — first iter past the 7-tier closeout. SUT-independent invariants: byte conservation, UTF-8 valid in→valid out, multiset-equality permutation, containsRtl preservation. Heavy bias toward isolating + embedding controls (LRO/RLO/PDF/FSI/RLI/LRI/PDI/LRE/RLE) at extreme depths to stress the embedding stack (UAX #9 spec cap = 125). | bidi_resolve_random_codepoints · bidi_reorder_property · bidi_format_character_storm | none — all 3 default-gate targets clean at 100k iters in ReleaseSafe; also clean at 50k iters under alternate seeds 0xDEADBEEF and 0xCAFEBABE. | iter-8 targets at 100k: resolve 1.05 s · reorder 1.45 s · format_storm 2.13 s | #76 |
| 9 | 2026-05-05 | cff.zig (CFF Type 2 parser, row 5 — first iter on this module). `CffParser.init(allocator, bytes)` is fuzzable from byte 0; SUT-independent invariants (`charsets.len ≤ charstrings_index.count`; getString/getGlyphName return null OR a bounded-length slice; getGlyphName(gid) ↔ getString(charsets[gid]) agreement). Three targets: pure random bytes, biased CFF header (major=1, minor=0, hdr_size 4-16, off_size 1-4) to drive past the version gate, and synthetic CFF wrapping a random Top DICT body to drive `DictParser.next` + `readNumber` directly. | cff_init_random_bytes · cff_init_biased_header · cff_dict_random_topdict (all `reproducer_only`) | **YES — Finding 008 (two bugs)**: 008a `Index.parse` last-offset underflow @ cff.zig:263 (`data_size = readOffSize(off_size) - 1` underflows when last offset is 0); 008b `parseTopDict` `@intCast` trap @ cff.zig:105 on negative DICT operand. Both reproduce at seeds 0x1, 0x2, 0xDEADBEEF in ReleaseSafe; 008a trips between 5k-10k iters, 008b trips by iter ≤ 50. All 3 targets are `reproducer_only` because every iter that reaches Index.parse / parseTopDict has a ~uniform chance of tripping the bugs — there's no constrained input that exercises the parser surface and dodges both findings. Promote to default-gate once 008a + 008b are fixed. | iter-9 targets — wall time not measured to 100k clean (panics earlier); harness build + 100-iter smoke ~80 ms total across all 46 targets. | (this PR) |
| 10 | 2026-05-05 | pdf_resources.zig (`ResourceRegistry`, row 18). Tier-4 stateful sequence fuzz on a self-contained registry — no XRef / parsing setup required. Three targets: `pdf_resources_builtin_dedup` (1..32 random builtin-font registrations, asserts idempotent dedup + `/F<idx>` name stability + pairwise-unique names + `fontCount()` == distinct-fonts-seen), `pdf_resources_image_register_assign` (0..16 random images, drives `assignImageObjectNumbers` against a real `pdf_writer.Writer`, asserts `/Im<idx>` names + obj_num != 0 + pairwise-distinct obj_nums + the registry/entry mirror invariant `image_obj_nums[idx] == images.items[idx].ref.obj_num`), and `pdf_resources_freeze_after_assign` (registers fonts+images, calls `assignFontObjectNumbers` to flip the freeze flag, asserts negative-space invariants — `registerBuiltinFont` rejects with `error.ObjectNumbersAlreadyAssigned`, `assignFontObjectNumbers` rejects on second call, `registerImage` also rejects (shared epoch) — plus positive-space: counts unchanged after rejected calls; assigned font obj_nums non-zero and pairwise distinct). | pdf_resources_builtin_dedup · pdf_resources_image_register_assign · pdf_resources_freeze_after_assign | none — all 3 default-gate targets clean at 100k iters in ReleaseSafe; also clean at 50k iters under alternate seeds 0xDEADBEEF and 0xCAFEBABE. **Note (no finding)**: `assignImageObjectNumbers` does NOT flip the registry-wide freeze flag (only `assignFontObjectNumbers` does — see src/pdf_resources.zig:378 comment). T3 documents this asymmetry inline rather than asserting it as an invariant; the harness drives the freeze through the font path and validates the shared-epoch behaviour for image register. | iter-10 targets at 100k: builtin_dedup 52 ms · image_register_assign 73 ms · freeze_after_assign 49 ms | (this PR) |
| 12 | 2026-05-05 | markdown.zig (row 15) + markdown_to_pdf.zig `tagged=false` branch (row 16). **Discovery**: row 15's "the markdown parser itself" is a misnomer — `src/markdown.zig` is a PDF-spans → Markdown *renderer* (no parser exists in this codebase). Two default-gate targets: `markdown_render_pdf_to_md` builds biased `[]TextSpan` slices (pool of 20 texts including bullets U+2022/U+25CF/U+25A0, numbered prefixes `1.` / `2)` / `(i)` / `a.` / `Z:`, plus empty / whitespace; font sizes biased to {6,9,10,11,12,14,18,24,36,48} with body=12pt → exercises h1/h2/h3 ratio branches; x0 indented in 36-pt buckets to hit `indentLevel`; y0 descends in 14-pt steps with jitter to drive both line-flush and paragraph-gap branches) and asserts UTF-8 in→out, output ≤ 32×(N+Σ text.len)+1024, no embedded NUL. `markdown_to_pdf_untagged` is the pivot per the iter-12 brief — random bytes through `markdown_to_pdf.render` (the `tagged=false` half of `renderCore`) with the same `%PDF-` / `%%EOF` / reparse → pageCount > 0 invariants as `markdown_render_tagged`, plus a negative-space check (`/StructTreeRoot` substring must be absent on the untagged path). | markdown_render_pdf_to_md · markdown_to_pdf_untagged | none — both default-gate targets clean at 100k iters in ReleaseSafe; also clean at 50k iters under alternate seeds 0xDEADBEEF and 0xCAFEBABE. | iter-12 targets at 100k: markdown_render_pdf_to_md 1.0 s · markdown_to_pdf_untagged 1.4 s | (this PR) |
| 13 | 2026-05-05 | image_writer.zig (row 8) — `emitImageObject` was previously only reachable via the `jpeg_meta` byte-input fuzz. Three targets exercise the embed-into-PDF path itself: `image_writer_emit_random_geom` covers all three encodings (DCT / raw_uncompressed / raw_flate) × three colorspaces (gray/rgb/cmyk) × varied geometry (1..1024) and BPC ∈ {1,2,4,8,16}, asserting object framing (`N 0 obj` / `endobj` / `stream` / `endstream`), required image-XObject dict keys (/Subtype/Image, /Width N, /Height N, /ColorSpace /Device*, /BitsPerComponent N), and per-encoding filter discipline (DCT → /DCTDecode; raw_flate → /FlateDecode; raw_uncompressed → no /Filter). `image_writer_emit_dct_verbatim` asserts the DCT passthrough contract (input bytes appear verbatim in the emitted stream body). `image_writer_emit_roundtrip_dims` parses the emitted indirect object via `parser.Parser.parseIndirectObject` and asserts integer-equality round-trip on Width / Height / BitsPerComponent + name-equality on Subtype + ColorSpace. | image_writer_emit_random_geom (reproducer_only) · image_writer_emit_dct_verbatim · image_writer_emit_roundtrip_dims | **YES — Finding 010**: `pdf_writer.writeStreamCompressed` panics inside stdlib flate when body ≤ 8 B. Root cause: `initCapacity(body.len)` at pdf_writer.zig:397 — zlib header (~8 B) doesn't fit. Trips `image_writer_emit_random_geom` at seed 0x1 in < 1k iters. T1 is `reproducer_only` until the fix lands; T2 + T3 dodge the bug by construction (DCT-only / uncompressed-or-DCT) and are default-gate. | iter-13 targets at 100k: image_writer_emit_dct_verbatim 0.80 s · image_writer_emit_roundtrip_dims 0.65 s | (this PR) |
| 14 | 2026-05-05 | a11y_emitter.zig (row 12) — emits the `kind:"a11y_tree"` NDJSON record from a parsed StructTree. **Public surface = `emit()` only**; `emitElement` and `writeReadingOrder` are file-private, so the harness drives the public `emit()` end-to-end against an arena-synth `StructTree` paired with a real minimal `*Document` (so `doc.pages.items` is non-empty and the page-obj→idx map walk doesn't trip on attacker-controlled empty input). Three default-gate targets. T1 (`a11y_emitter_synth_tree_emit`) builds a random tree with all opts off (no flatten / no MCID-text / no reading_order), asserts the byte-level envelope contract: starts with `{"kind":"a11y_tree"`, ends `}\n`, valid UTF-8, no embedded NUL, brace+bracket balance is zero outside string literals (SUT-independent JSON-shape oracle), reading_order key absent (negative-space when disabled), and `"root":{ … }` vs `"root":null` matches whether the synth tree was non-empty. T2 (`a11y_emitter_flatten_then_emit`) pins root /Alt to a `PINSENTINEL` value (no overlap with the input pool), enables `flatten_attrs:true`, and asserts that the count of `"alt":"PINSENTINEL"` substrings in the JSON equals exactly `1 + countDescendantsInheritingRootAlt(root)` — i.e. root + descendants whose nearest alt-bearing ancestor is the root, computed by SUT-independent walk over the pre-flatten tree. (Critical correctness detail: `attr_flattener.flattenInPlace` propagates **only** /Alt and /ActualText; /Lang and /resolved_role are owned by `structtree.propagateLang` which is NOT called in this iter — so the oracle uses /Alt, not /Lang.) T3 (`a11y_emitter_reading_order_dfs`) builds a tree where every leaf MCID carries `page_ref = doc.pages.items[0].ref` and is monotonically numbered by the synth builder; with `include_reading_order:true` the emitted `reading_order` array MUST list MCIDs in strictly-monotonic order (=DFS order), and the count must equal the number of MCIDs allocated. | a11y_emitter_synth_tree_emit · a11y_emitter_flatten_then_emit · a11y_emitter_reading_order_dfs | none — all 3 default-gate targets clean at 100k iters in ReleaseSafe; also clean at 50k iters under alternate seeds 0xDEADBEEF and 0xCAFEBABE. **Note (no finding)**: confirming the documented division of labour between `attr_flattener.flattenInPlace` (/Alt + /ActualText) and `structtree.propagateLang` (/Lang). T2's first draft asserted /Lang propagation through `flattenInPlace` and tripped immediately on seed 0x42 — fix was to switch the oracle to /Alt (the field flattenInPlace actually owns) and document the inheritance scope rules inline. | iter-14 targets at 100k: synth_tree_emit 725 ms · flatten_then_emit 705 ms · reading_order_dfs 692 ms | (this PR) |

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
