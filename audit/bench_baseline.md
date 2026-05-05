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

## Baseline — 2026-05-05 (post-iter-1), 50 000 iters/target, Zig 0.16.0 Debug, base seed `0x19df75b03c3`

```
pdf.zig fuzz harness — iters=50000, base_seed=0x19df75b03c3, build=Debug
```

| Target | Wall time (ms) | µs / iter |
|---|---:|---:|
| tokenizer_count                  |     1 901 |   38.0 |
| stream_json_string               |    25 224 |  504.5 |
| stream_envelope_meta             |     1 160 |   23.2 |
| stream_envelope_page             |     8 927 |  178.5 |
| chunk_break_finder               |    30 223 |  604.5 |
| cli_parse_args                   |        34 |    0.7 |
| cli_page_range                   |        98 |    2.0 |
| pdf_open_random                  |       263 |    5.3 |
| pdf_open_magic_prefix            |       262 |    5.2 |
| pdf_extract_seed_repeat          |     5 226 |  104.5 |
| tokenizer_realistic_md           |     9 801 |  196.0 |
| lattice_content_random           |     2 964 |   59.3 |
| lattice_form_xobject_mutation    |     3 051 |   61.0 |
| tagged_table_mutation            |       381 |    7.6 |
| link_continuations_random        |       100 |    2.0 |
| lattice_pass_b_spans             |     1 172 |   23.4 |
| xmp_escape_xml                   |     4 517 |   90.3 |
| xmp_emit_random                  |     2 091 |   41.8 |
| encrypt_roundtrip_rc4            |    12 632 |  252.6 |
| encrypt_roundtrip_aes            |    13 775 |  275.5 |
| markdown_render_tagged           |     5 958 |  119.2 |
| truetype_parse_random            |       374 |    7.5 |
| jpeg_meta_random                 |       371 |    7.4 |
| **decompress_ascii_hex_random**  |   **5 003** |  100.1 |
| **decompress_runlength_random**  |   **5 562** |  111.2 |
| **Total**                        | **141 070** | — |

Drift vs the pre-iter-1 baseline (`0x19df7152cc1`, 126 472 ms): +14 598 ms total
of which ≈ +10 565 ms is the two new iter-1 targets and the remaining
+4 033 ms is per-target drift (≤ +5 % per target — within thermal /
context-switch noise on an unloaded laptop). No regression flagged.

The previous baseline is preserved below for the historical 23-target
shape; future iters compare against the **post-iter-1** numbers above.

### Pre-iter-1 baseline (historical) — base seed `0x19df7152cc1`, 126 472 ms total

23 default-gated targets, 50 000 iters each. Identical methodology;
preserved as the v1.6-closeout-end snapshot for back-compat with PR
#76's first commit.

## How the loop reads this file

Each loop iteration reruns the same command, parses its output into the same
table, and computes per-target ratios. A target whose new wall time is
> 1.10 × the baseline value is reported as a regression in the PR body so
the user can decide whether to accept the trade-off (e.g. defensive
bounds-checking added in response to a fuzz finding) or revisit.

The baseline is refreshed (this file rewritten) when a workaround lands and
its slowdown is intentional — never silently.
