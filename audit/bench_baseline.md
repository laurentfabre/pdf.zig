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

## Baseline — 2026-05-05, 50 000 iters/target, Zig 0.16.0 Debug, base seed `0x19df7152cc1`

```
pdf.zig fuzz harness — iters=50000, base_seed=0x19df7152cc1, build=Debug
```

| Target | Wall time (ms) | µs / iter |
|---|---:|---:|
| tokenizer_count                  |     2 063 |   41.3 |
| stream_json_string               |    24 006 |  480.1 |
| stream_envelope_meta             |     1 132 |   22.6 |
| stream_envelope_page             |     8 559 |  171.2 |
| chunk_break_finder               |    28 578 |  571.6 |
| cli_parse_args                   |        35 |    0.7 |
| cli_page_range                   |        96 |    1.9 |
| pdf_open_random                  |       261 |    5.2 |
| pdf_open_magic_prefix            |       263 |    5.3 |
| pdf_extract_seed_repeat          |     5 005 |  100.1 |
| tokenizer_realistic_md           |     9 689 |  193.8 |
| lattice_content_random           |     3 002 |   60.0 |
| lattice_form_xobject_mutation    |     2 945 |   58.9 |
| tagged_table_mutation            |       380 |    7.6 |
| link_continuations_random        |        99 |    2.0 |
| lattice_pass_b_spans             |     1 060 |   21.2 |
| xmp_escape_xml                   |     4 473 |   89.5 |
| xmp_emit_random                  |     2 060 |   41.2 |
| encrypt_roundtrip_rc4            |    12 627 |  252.5 |
| encrypt_roundtrip_aes            |    13 433 |  268.7 |
| markdown_render_tagged           |     5 963 |  119.3 |
| truetype_parse_random            |       375 |    7.5 |
| jpeg_meta_random                 |       368 |    7.4 |
| **Total**                        | **126 472** | — |

## How the loop reads this file

Each loop iteration reruns the same command, parses its output into the same
table, and computes per-target ratios. A target whose new wall time is
> 1.10 × the baseline value is reported as a regression in the PR body so
the user can decide whether to accept the trade-off (e.g. defensive
bounds-checking added in response to a fuzz finding) or revisit.

The baseline is refreshed (this file rewritten) when a workaround lands and
its slowdown is intentional — never silently.
