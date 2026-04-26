# Week-4 fuzz + allocation-failure findings

> Captured during `week4/fuzz-corpus-xref-repair` (architecture.md §11 quality gate). The streaming-layer code we own (uuid / tokenizer / stream / chunk / cli_pdfzig) is panic-free at the gate iter count; upstream parser surfaces the issues below under adversarial allocation patterns.

---

## Finding 001 — `Document.openFromMemory` leaks under partial OOM

**Path**: `src/root.zig::Document.openFromMemory` → `parseDocument` → `xref_table`/`object_cache`/`font_cache` initialisation
**Surfaced by**: `src/alloc_failure_test.zig::checkAllAllocationFailures — Document.openFromMemory`
**Reproduce**: `zig test src/alloc_failure_test.zig` (one of three new tests fails)

```
fail_index: 3/6
allocated bytes: 800
freed bytes:     368
allocations:     3
deallocations:   1
```

When the third allocation (a `hash_map.allocate` → `grow` call inside the xref/object cache setup) is forced to fail, the partial Document state is dropped without freeing the first two allocations. Net leak ~432 bytes per failed open.

**User-facing impact**: under genuine OOM, the CLI surfaces the right exit code (`5 oom`) but leaks ~432 bytes per attempt before the OS reclaims at process exit. The leak does **not** corrupt subsequent invocations because each invocation is its own process.

**Recommended fix**: convert the cascading `init` calls in `openFromMemoryUnsafe` into an explicit `errdefer` chain (or arena-only allocation) so a failure in any later step rolls back the earlier hashmap allocations. Out of Week-4 scope; tracked for Week 4.x.

---

## Finding 002 — `Document.extractMarkdown` leaks under partial OOM

**Path**: `src/root.zig::Document.extractMarkdown` → `extractTextWithBounds` → `MarkdownRenderer.render`
**Surfaced by**: `src/alloc_failure_test.zig::checkAllAllocationFailures — Document.extractMarkdown`
**Reproduce**: same test command

Pattern matches Finding 001 — partial state from an earlier success in the call chain isn't unwound when a later allocation fails. Magnitude similar (~hundreds of bytes per failure).

**User-facing impact**: same as 001 (process-bounded leak, no cross-call corruption).

**Recommended fix**: same family as 001 — `errdefer` discipline through the markdown render path. Tracked for Week 4.x.

---

## Finding 003 — `Document.metadata` leaks under partial OOM

**Path**: `src/root.zig::Document.metadata` (called against an open Document)
**Surfaced by**: `src/alloc_failure_test.zig::checkAllAllocationFailures — Document.metadata`
**Reproduce**: same test command

The `metadata()` call resolves an indirect reference into the trailer dict; the resolution path allocates and at least one rollback edge isn't covered. Same shape as 001 / 002.

**Recommended fix**: same family. Tracked for Week 4.x.

---

## Finding 004 — `extractMarkdown` hangs on adversarially-mutated CID/encrypted/multi-page seeds

**Path**: `src/root.zig::extractMarkdown` → upstream content-stream interpreter
**Surfaced by**: Week-7 expanded fuzz seed pool. After rotating across `{minimal, CID-font, encrypted, multi-page}`, `pdf_extract_mutation` started hanging at 100 % CPU on some byte-flips of the three richer seeds. Reproduced multiple times during the GA audit (see the zombie-process triage).

**Mitigation in v1.0**: `pdf_extract_mutation` is pinned to `seed_pool[0]` (minimal Helvetica) only — the other 12 targets, including `pdf_open_mutation` which mutates the same expanded pool, complete cleanly at 50 k iters. The hang is **not user-reachable** through the pdf.zig CLI: the production code path (`Document.open(path)`) opens trusted PDFs from disk, never byte-flipped buffers; the hang requires `openFromMemory` + a successful parse of a hostile-mutated CID/encrypted/multi-page seed before reaching `extractMarkdown`.

**Recommended fix (v1.0.1 / v1.x)**: add per-page wall-clock or operator-fuel watchdog to the upstream content-stream interpreter so a malformed content stream surfaces as `error.ContentStreamFuelExhausted` instead of an unbounded loop. Once the watchdog lands, broaden `pdf_extract_mutation`'s seed rotation back to all 4 seeds.

---

## Non-finding — fuzz harness use-after-free (resolved 2026-04-26)

Initial pdf_open_mutation runs at 100k iters segfaulted in `std.mem.eql`'s 4-byte SIMD compare. Stack trace pointed at upstream parser, which produced the false impression of a heap-safety bug. **Root cause was in the fuzz harness itself**: `seed_pdf` was allocated from the same arena that gets reset every 4096 iters, so by target 10's iter 0 it pointed at freed memory. Fixed by allocating the seed PDF from `std.heap.page_allocator` (lifetime = whole program).

Lesson: when a fuzz crash repros under harness but not under the production CLI on the saved input, **suspect harness state before suspecting the SUT**. (Same methodology pattern as Week-2's "deep-dive on Reverie was a wrong rabbit hole until classification fixed it" — broad ground-truth check before deep investigation.)

---

## Default-gate clean targets (11 / 11 at 200k iters, 1M run in progress)

| Target | 200k iters wall time |
|---|---|
| tokenizer_count | 4.1 s |
| stream_json_string | 26.8 s |
| stream_envelope_meta | 1.1 s |
| stream_envelope_page | 12.2 s |
| chunk_break_finder | 31.9 s |
| cli_parse_args | 21 ms |
| cli_page_range | 30 ms |
| pdf_open_random | 155 ms |
| pdf_open_magic_prefix | 155 ms |
| pdf_extract_seed_repeat | 1.2 s |
| tokenizer_realistic_md | 3.1 s |
| **Total** | **80.7 s** |

Aggressive-mode targets (`PDFZIG_FUZZ_AGGRESSIVE=1`):
- `pdf_open_mutation` — 50k iters, 1.7 s, clean
- `pdf_extract_mutation` — 50k iters, 1.8 s, clean

---

## Reproducer index

- `audit/fuzz_corpus_crash_001.bin` — the 643-byte mutated PDF that initially caused the false-positive harness segfault. Kept as an interesting input even though the crash was harness-side; it is a useful smoke-test PDF for parser robustness (CLI handles it cleanly: `pdf.zig info audit/fuzz_corpus_crash_001.bin` → `pages: 0`).
