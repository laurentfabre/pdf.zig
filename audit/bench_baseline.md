# pdf.zig — perf baseline (fuzz wall-times)

Used by the autonomous fuzz/bench loop (`audit/fuzz_loop_state.md`). Each iter
re-runs the harness at this iter count and compares per-target wall time.
Regressions ≥10 % on any single target trigger a flag in the loop's PR body.

## Signal source

The fuzz harness is also a benchmark: every target executes the same code
path on every iter, so wall-time at a fixed iter count is a stable per-
subsystem perf number. Cheaper than maintaining a separate corpus + bench
binary, and the coverage is broader than `zig build bench` (which only
benches `Document.open` + `extractText`).

`zig build bench -- audit/cjk-pdfs/synthetic/ko-h-01.pdf` is also runnable
post the 0.16 migration (this PR), but the in-tree CJK corpus is ≤1.3 KB
per file — too small for meaningful end-to-end numbers. Treat it as a
smoke-test of the bench binary, not a perf gate.

## Baseline — 2026-05-05 (post-iter-22 refresh), 50 000 iters/target, Zig 0.16.0 Debug, base seed `0x19df75b03c3`

72 default-gate targets (the 6 `reproducer_only` and 2 `aggressive`
entries of the 80-target registry are excluded — they either trip an
open Finding deterministically or require `PDFZIG_FUZZ_AGGRESSIVE=1`).
Iter-21 closed at 70 default-gate targets; iter-22 adds none — this
refresh exists because the previous baseline tracked only 24 targets
and the loop has added 48 more across iters 2–21 with no comparable
table to flag regressions against.

```
pdf.zig fuzz harness — iters=50000, base_seed=0x19df75b03c3, build=Debug
```

| Target | Wall time (ms) | µs / iter |
|---|---:|---:|
| tokenizer_count                             |     2 097 |   41.9 |
| stream_json_string                          |    25 302 |  506.0 |
| stream_envelope_meta                        |     1 200 |   24.0 |
| stream_envelope_page                        |     9 118 |  182.4 |
| chunk_break_finder                          |    30 307 |  606.1 |
| cli_parse_args                              |        35 |    0.7 |
| cli_page_range                              |       100 |    2.0 |
| pdf_open_random                             |       268 |    5.4 |
| pdf_open_magic_prefix                       |       267 |    5.3 |
| pdf_extract_seed_repeat                     |     5 323 |  106.5 |
| tokenizer_realistic_md                      |     9 929 |  198.6 |
| lattice_content_random                      |     3 072 |   61.4 |
| lattice_form_xobject_mutation               |     3 134 |   62.7 |
| tagged_table_mutation                       |       383 |    7.7 |
| link_continuations_random                   |       103 |    2.1 |
| lattice_pass_b_spans                        |     1 139 |   22.8 |
| xmp_escape_xml                              |     4 475 |   89.5 |
| xmp_emit_random                             |     2 079 |   41.6 |
| encrypt_roundtrip_rc4                       |    12 845 |  256.9 |
| encrypt_roundtrip_aes                       |    14 082 |  281.6 |
| markdown_render_tagged                      |     6 026 |  120.5 |
| truetype_parse_random                       |       380 |    7.6 |
| jpeg_meta_random                            |       375 |    7.5 |
| decompress_ascii_hex_random                 |     5 080 |  101.6 |
| decompress_runlength_random                 |     5 684 |  113.7 |
| parser_object_pdfish                        |       419 |    8.4 |
| parser_indirect_object_random               |        74 |    1.5 |
| parser_init_at_offset_random                |        15 |    0.3 |
| interpreter_random_ops                      |     2 927 |   58.5 |
| interpreter_bdc_emc_nesting                 |     8 204 |  164.1 |
| pdf_of_pdf_roundtrip                        |    40 489 |  809.8 |
| bidi_resolve_random_codepoints              |     2 203 |   44.1 |
| bidi_reorder_property                       |     3 629 |   72.6 |
| bidi_format_character_storm                 |     5 298 |  106.0 |
| writer_drawtext_roundtrip                   |     5 916 |  118.3 |
| writer_multipage_count                      |    25 955 |  519.1 |
| writer_text_escape_roundtrip                |     4 019 |   80.4 |
| decompress_runlength_diff                   |     3 056 |   61.1 |
| decompress_ascii_hex_diff                   |     5 469 |  109.4 |
| decompress_filter_chain_diff                |     3 188 |   63.8 |
| pdf_resources_builtin_dedup                 |       227 |    4.5 |
| pdf_resources_image_register_assign         |       364 |    7.3 |
| pdf_resources_freeze_after_assign           |       225 |    4.5 |
| attr_flattener_random_tree                  |     8 593 |  171.9 |
| attr_flattener_in_place_idempotent          |     3 718 |   74.4 |
| attr_flattener_depth_bound                  |     2 265 |   45.3 |
| markdown_render_pdf_to_md                   |     5 794 |  115.9 |
| markdown_to_pdf_untagged                    |     4 868 |   97.4 |
| image_writer_emit_dct_verbatim              |       409 |    8.2 |
| image_writer_emit_roundtrip_dims            |       327 |    6.5 |
| a11y_emitter_synth_tree_emit                |     2 550 |   51.0 |
| a11y_emitter_flatten_then_emit              |     2 498 |   50.0 |
| a11y_emitter_reading_order_dfs              |     2 565 |   51.3 |
| struct_writer_setroot_depth_boundary        |       886 |   17.7 |
| struct_writer_emit_object_count             |       703 |   14.1 |
| struct_writer_roundtrip_via_documentbuilder |     2 809 |   56.2 |
| mcid_resolver_resolve_one_oracle            |     2 697 |   53.9 |
| mcid_resolver_resolve_batch_parallel        |    11 338 |  226.8 |
| mcid_resolver_parse_struct_tree_with_text   |     4 998 |  100.0 |
| pdf_writer_name_escape_roundtrip            |       421 |    8.4 |
| pdf_writer_string_escape_roundtrip          |       548 |   11.0 |
| pdf_writer_xref_byte_offsets                |     1 540 |   30.8 |
| pagetree_balanced_shape                     |    28 815 |  576.3 |
| pagetree_parent_consistency                 |    23 083 |  461.7 |
| outline_flat_chain_count                    |     5 646 |  112.9 |
| outline_nested_levels                       |     3 818 |   76.4 |
| outline_adversarial_mutate                  |     2 735 |   54.7 |
| encrypt_authenticate_user_roundtrip         |    15 898 |  318.0 |
| encrypt_authenticate_random_o_u             |     3 979 |   79.6 |
| xmp_level_view_total                        |         5 |    0.1 |
| xmp_escape_utf8_storm                       |     4 852 |   97.0 |
| xmp_emit_level_pair_consistency             |       589 |   11.8 |
| **Total**                                   |  **403 427** | — |

### Drift vs the post-iter-1 baseline (24 inherited targets)

Same seed (`0x19df75b03c3`), same iter count (50 000), same Zig version
(0.16.0 Debug). Reported per-target ratio = `iter-22 ms / iter-1 ms`.

| Target | iter-1 (ms) | iter-22 (ms) | ratio |
|---|---:|---:|---:|
| tokenizer_count                  |  1 901 |  2 097 | 1.103× (refuted, see iter-23) |
| stream_json_string               | 25 224 | 25 302 | 1.00× |
| stream_envelope_meta             |  1 160 |  1 200 | 1.03× |
| stream_envelope_page             |  8 927 |  9 118 | 1.02× |
| chunk_break_finder               | 30 223 | 30 307 | 1.00× |
| cli_parse_args                   |     34 |     35 | 1.03× |
| cli_page_range                   |     98 |    100 | 1.02× |
| pdf_open_random                  |    263 |    268 | 1.02× |
| pdf_open_magic_prefix            |    262 |    267 | 1.02× |
| pdf_extract_seed_repeat          |  5 226 |  5 323 | 1.02× |
| tokenizer_realistic_md           |  9 801 |  9 929 | 1.01× |
| lattice_content_random           |  2 964 |  3 072 | 1.04× |
| lattice_form_xobject_mutation    |  3 051 |  3 134 | 1.03× |
| tagged_table_mutation            |    381 |    383 | 1.01× |
| link_continuations_random        |    100 |    103 | 1.03× |
| lattice_pass_b_spans             |  1 172 |  1 139 | 0.97× |
| xmp_escape_xml                   |  4 517 |  4 475 | 0.99× |
| xmp_emit_random                  |  2 091 |  2 079 | 0.99× |
| encrypt_roundtrip_rc4            | 12 632 | 12 845 | 1.02× |
| encrypt_roundtrip_aes            | 13 775 | 14 082 | 1.02× |
| markdown_render_tagged           |  5 958 |  6 026 | 1.01× |
| truetype_parse_random            |    374 |    380 | 1.02× |
| jpeg_meta_random                 |    371 |    375 | 1.01× |
| decompress_ascii_hex_random      |  5 003 |  5 080 | 1.02× |
| decompress_runlength_random      |  5 562 |  5 684 | 1.02× |

`tokenizer_count` was originally flagged at 1.103× the iter-1 number,
but iter-23 refuted the regression as **bench-environment drift between
sessions** — see the "Iter-23 root-cause investigation" section below
for the full profile evidence. Both the iter-1 binary AND the iter-22
binary measure within the same 2 100-2 400 ms band on this hardware
today; at 200k iters (4× denoise), iter-22 is actually 2.5 % FASTER
than iter-1. The 1.103× figure in the table above is preserved for
historical comparison but **no longer treated as a regression**. The
~200 ms delta vs the original 1 901 ms run is attributable to system-
state drift across the ~9 days between iter-1 (2026-04-26) and iter-22
(2026-05-05).

All other 23 inherited targets remain within ±5 % — no regressions
flagged. **Going forward, regression-flag comparisons must be made
within a single session** (same machine state, same thermal envelope);
when refreshing baselines across sessions, rerun the prior baseline's
binary in the new session to recalibrate before flagging any per-
target ratio.

### iter-23 root-cause investigation — `tokenizer_count` regression refuted

**TL;DR — the 1.17× regression is bench-environment drift, not code drift.
The iter-22 binary is in fact 2.5 % FASTER than the iter-1 binary when
both are run head-to-head on the same hardware in the same session.**

Methodology:

1. `git worktree add /tmp/iter-1-bench d247c6e --detach` (the post-iter-1
   baseline commit that produced the original 1 901 ms number).
2. `md5 src/tokenizer.zig` — byte-identical between `d247c6e` and `4ae96c3`
   (`47a571a205cc90036f5e0ee879ef8521`), confirming `tokenizer.zig` itself
   has not changed.
3. Build the iter-1 fuzz binary (`PDFZIG_FUZZ_TARGET=tokenizer_count
   PDFZIG_FUZZ_ITERS=1 PDFZIG_FUZZ_SEED=0x19df75b03c3 zig build fuzz`) and
   the iter-22 fuzz binary the same way; copy each to `/tmp/fuzz_iter1`
   and `/tmp/fuzz_iter22`. Same Zig 0.16.0, same Debug mode.
4. Run both binaries on the same hardware in the same shell, same seed,
   same iter count — **5 runs of 50 000 iters** then **3 runs of 200 000
   iters** for jitter denoising.

Results — 50 000 iters, 5 runs each, `tokenizer_count` only:

| Binary       | run-1 | run-2 | run-3 | run-4 | run-5 | mean |
|---|---:|---:|---:|---:|---:|---:|
| iter-1  (28 targets, 4.95 MB) | 2 220 | 2 224 | 2 228 | 2 217 | 2 271 | **2 232** |
| iter-22 (80 targets, 5.55 MB) | 2 217 | 2 154 | 2 368 | 2 309 | 2 219 | **2 253** |

Results — 200 000 iters, 3 runs each (4× more samples → tighter CI):

| Binary       | run-1 | run-2 | run-3 | mean |
|---|---:|---:|---:|---:|
| iter-1  | 9 402 | 8 885 | 8 891 | **9 059** |
| iter-22 | 8 869 | 8 815 | 8 811 | **8 832** |

iter-22 is **−2.5 %** at the 200k denoise level vs iter-1 (8 832 / 9 059).

**Conclusion — accept and move on.** The "1.17× the original baseline"
claim conflated two different machine states. The `1 901 ms` original
measurement was taken on a less-loaded machine on 2026-04-26; both
binaries today land in the 2 100-2 400 ms band. Hypothesis 1 (binary-
bloat / cache pressure) and Hypothesis 2 (build-config drift) are
**refuted** — the iter-22 binary is the same speed as, or faster than,
the iter-1 binary on identical hardware. Hypothesis 3 (thermal
throttling / cumulative system load between Apr 26 and May 5) is the
surviving explanation.

**Recommendation**: drop the `tokenizer_count ⚠️` flag. The post-iter-22
`2 097 ms` line in the per-target table above is the live anchor; the
"1.103× vs 1 901 ms" comparison crossed measurement environments and
should not be treated as a regression. For future iters' regression
flags, only compare numbers measured in the same machine state (same
session, same load, same thermal envelope). When refreshing baselines
across sessions, rerun the prior baseline binary in the new session
to recalibrate before flagging any per-target ratio.

Investigation artifacts — both binaries preserved at `/tmp/fuzz_iter1`
(28 targets, 4 948 616 B, MD5'd `tokenizer.zig`) and `/tmp/fuzz_iter22`
(80 targets, 5 546 184 B, same `tokenizer.zig`) for follow-up audits.

### Pre-iter-1 baseline (historical) — base seed `0x19df7152cc1`, 126 472 ms total

23 default-gated targets, 50 000 iters each. Identical methodology;
preserved as the v1.6-closeout-end snapshot for back-compat with PR
#76's first commit.

### Post-iter-1 baseline (historical) — base seed `0x19df75b03c3`, 141 070 ms total

25 default-gated targets, 50 000 iters each. Superseded by the
post-iter-22 table above as the active baseline. Preserved here as a
reference point for any future regression-archaeology of the 24
shared targets.

## How the loop reads this file

Each loop iteration reruns the same command, parses its output into the same
table, and computes per-target ratios. A target whose new wall time is
> 1.10 × the baseline value is reported as a regression in the PR body so
the user can decide whether to accept the trade-off (e.g. defensive
bounds-checking added in response to a fuzz finding) or revisit.

The baseline is refreshed (this file rewritten) when a workaround lands and
its slowdown is intentional — never silently. **Refreshes also happen on
schedule** when the target count grows: this iter-22 refresh adds 47 new
targets (added across iters 2–21) to the comparison set, so future iters
have something to compare against on the modules where deep fuzz coverage
landed.
