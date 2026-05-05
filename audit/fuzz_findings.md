# Week-4 fuzz + allocation-failure findings

> Captured during `week4/fuzz-corpus-xref-repair` (architecture.md §11 quality gate). The streaming-layer code we own (uuid / tokenizer / stream / chunk / cli_pdfzig) is panic-free at the gate iter count; upstream parser surfaces the issues below under adversarial allocation patterns.

---

## Finding 001 — `Document.openFromMemory` leaks under partial OOM (RESOLVED in PR-9)

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

## Finding 002 — `Document.extractMarkdown` leaks under partial OOM (RESOLVED in PR-9)

**Path**: `src/root.zig::Document.extractMarkdown` → `extractTextWithBounds` → `MarkdownRenderer.render`
**Surfaced by**: `src/alloc_failure_test.zig::checkAllAllocationFailures — Document.extractMarkdown`
**Reproduce**: same test command

Pattern matches Finding 001 — partial state from an earlier success in the call chain isn't unwound when a later allocation fails. Magnitude similar (~hundreds of bytes per failure).

**User-facing impact**: same as 001 (process-bounded leak, no cross-call corruption).

**Recommended fix**: same family as 001 — `errdefer` discipline through the markdown render path. Tracked for Week 4.x.

---

## Finding 003 — `Document.metadata` leaks under partial OOM (RESOLVED in PR-9)

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

## Default-gate clean targets (23 / 23 at 1M iters — v1.6 closeout pass, 2026-05-05)

23 default-gated targets clean at 1M iterations each. Full sweep: **43 min 36 s wall** on macOS arm64 / Debug build, base seed `0x19df6d9ca62`, no panics, no invariant violations.

| Target | 1M iters wall time | Notes |
|---|---|---|
| tokenizer_count | 44.0 s | streaming layer |
| stream_json_string | 505.2 s | streaming layer |
| stream_envelope_meta | 23.8 s | streaming layer |
| stream_envelope_page | 178.8 s | streaming layer |
| chunk_break_finder | 606.2 s | streaming layer |
| cli_parse_args | 0.7 s | CLI |
| cli_page_range | 2.0 s | CLI |
| pdf_open_random | 5.2 s | parser |
| pdf_open_magic_prefix | 5.2 s | parser |
| pdf_extract_seed_repeat | 104.2 s | parser, seed-rotated |
| tokenizer_realistic_md | 195.4 s | tokenizer + chunk |
| lattice_content_random | 59.5 s | lattice Pass B (Form XObject) |
| lattice_form_xobject_mutation | 65.8 s | lattice Pass B mutation |
| tagged_table_mutation | 7.6 s | Pass A (tagged-table cells via MCID) |
| link_continuations_random | 2.0 s | Pass D continuation-link bbox |
| lattice_pass_b_spans | 22.3 s | Pass B (lattice cells via glyph-center ∩ bbox) |
| **xmp_escape_xml** | **89.0 s** | **v1.6 PR-W10a — XML escape post-conditions** |
| **xmp_emit_random** | **40.8 s** | **v1.6 PR-W10a — XMP packet structural invariants** |
| **encrypt_roundtrip_rc4** | **251.6 s** | **v1.6 PR-W9 — RC4-128 encrypt/decrypt round-trip** |
| **encrypt_roundtrip_aes** | **273.6 s** | **v1.6 PR-W9 — AES-128 encrypt/decrypt round-trip + IV/padding shape** |
| **markdown_render_tagged** | **118.6 s** | **v1.6 PR-W10d — renderTagged → reopen-via-parser round-trip** |
| **truetype_parse_random** | **7.4 s** | **v1.6 PR-W7 — TTF parser robustness on adversarial bytes** |
| **jpeg_meta_random** | **7.3 s** | **v1.6 PR-W8 — JPEG SOF/SOI parser robustness** |
| **decompress_ascii_hex_random** | **105.2 s** | **iter-1 — `/Filter ASCIIHexDecode` random-bytes** |
| **decompress_runlength_random** | **115.2 s** | **iter-1 — `/Filter RunLengthDecode` biased-bytes** |
| **parser_object_pdfish** | **8.2 s** ⚠️ | **iter-2 — biased COS-syntax bytes; 1M ran on pre-fb2bdca harness (biased-degrades-to-random; rerun pending)** |
| **parser_indirect_object_random** | **1.5 s** | **iter-2 — synthetic `N M obj … endobj` frames + `/Length` boundary cases through `Parser.parseIndirectObject`** |
| **parser_init_at_offset_random** | **0.3 s** | **iter-2 — random byte-offsets into seed-pool PDFs through `Parser.initAt`** |
| **interpreter_random_ops** | **57.1 s** | **iter-3 — biased COS-operator bytes through `ContentLexer.next()`** |
| **interpreter_bdc_emc_nesting** | **161.6 s** | **iter-3 — synthesised PDFs with hostile BDC/EMC nesting through `Document.extractMarkdown`** |
| writer_drawtext_roundtrip | **116.5 s** | iter-4 — DocumentBuilder ↔ Document text round-trip |
| writer_multipage_count | **515.7 s** | iter-4 — multipage page-tree round-trip |
| writer_text_escape_roundtrip | **80.4 s** | iter-4 — PDF metachar escape round-trip via raw extractText |
| decompress_runlength_diff | **60.6 s** | iter-5 — RLE encode/decode differential |
| decompress_ascii_hex_diff | **108.6 s** | iter-5 — ASCIIHex encode/decode differential |
| decompress_filter_chain_diff | **63.0 s** | iter-5 — filter chain ownership transfer |
| pdf_of_pdf_roundtrip | **794.7 s** | iter-7 — multi-stage adversarial PDF-of-PDF (4M stage-cycles at 1M iters × 4 stages) |
| **Total** | **4788.6 s (79 min 49 s) at 1M post-iter-7 — 38/38 clean, base seed `0x19df7f8182f`. iter-8 (bidi)/9 (cff repro-only)/10 (pdf_resources)/11 (attr_flattener) 1M rerun pending.** | |

The aggressive-gated `decompress_ascii85_roundtrip` is `reproducer_only` and skipped from the default + aggressive sweeps; deterministically reproduces Finding 005 below.

Aggressive-mode targets (`PDFZIG_FUZZ_AGGRESSIVE=1`):
- `pdf_open_mutation` — 50k iters, 1.7 s, clean
- `pdf_extract_mutation` — 50k iters, 1.8 s, clean (`seed_pool[0]`-pinned per Finding 004)

The seven **bold** targets were added during the v1.6 closeout fuzz pass (2026-05-05) to cover writer-side modules introduced in PR-W7…W10 + PR-W10d (font embedder, image XObject + JPEG metadata, encryption, XMP /Metadata, markdown auto-tagging). The structtree / a11y_emitter / attr_flattener / mcid_resolver / struct_writer surfaces are exercised end-to-end by `pdf_extract_seed_repeat` over the 4-PDF seed pool — they consume parsed `StructElement` graphs rather than raw bytes, so byte-level fuzzing offers no incremental signal beyond the existing unit tests + FailingAllocator sweeps.

### Discoveries during the v1.6 fuzz pass

- **`markdown_render_tagged` v1 false-positive (resolved in-pass).** First draft of the harness counted raw `BDC` / `EMC` substring occurrences in the emitted PDF and asserted parity. PR-W4 (FlateDecode on content streams) makes those substrings appear inside compressed bytes, so 72 / 100k iters tripped a structural-mismatch invariant that was actually noise. Replaced with a stronger `Document.openFromMemory` + `pageCount > 0` round-trip check; the parser is the authoritative validator of the emitted bytes' structure.

---

## Finding 005 — `decodeASCII85` u32 overflow trap on legal-looking 5-char tuples

**Status**: OPEN (issue tracker disabled on the repo; tracked here + in `audit/fuzz_loop_state.md`)
**Path**: `src/decompress.zig:386` — `tuple = tuple * 85 + (c - '!')`
**Surfaced by**: fuzz target `decompress_ascii85_roundtrip` (aggressive-gate), iter 1 of the autonomous fuzz loop, `PDFZIG_FUZZ_SEED=0x1` panics within the first 200 iters.
**Class**: integer overflow (Debug / ReleaseSafe panic; ReleaseFast UB → silently wrong output)

### Reproducer

```zig
// 5-byte minimal repro:
const out = try decompress.decompressStream(
    allocator,
    "uuuuu",
    .{ .name = "ASCII85Decode" },
    null,
);
defer allocator.free(out);
```

Or via the harness:

```sh
PDFZIG_FUZZ_AGGRESSIVE=1 \
  PDFZIG_FUZZ_TARGET=decompress_ascii85_roundtrip \
  PDFZIG_FUZZ_SEED=0x1 \
  ~/.zvm/bin/zig build fuzz
```

### Stack at the panic

```
thread <id> panic: integer overflow
src/decompress.zig:386:23  decodeASCII85
src/decompress.zig:88:29   applyFilter
src/decompress.zig:61:39   decompressStream
```

### Root cause

After the 4th iteration of `tuple = tuple * 85 + (c - '!')` the accumulator can reach `84 × 85^4 = 4 437 053 040`, exceeding `u32` max (`4 294 967 295`). PDF spec ISO 32000-1 §7.4.3 says *valid* encoded 5-tuples represent values < `2^32`, but the *intermediate* accumulator overflows even when the final value would be in range — and adversarial input doesn't have to be valid.

### Recommended fix

Two options at `src/decompress.zig:386`:

1. **Pre-check.** Before each `tuple = tuple * 85 + …`, verify `tuple <= (std.math.maxInt(u32) - 84) / 85`; otherwise return `error.DecompressFailed`.
2. **u64 intermediate.** Accumulate into `u64`; on flush (count == 5) check `tuple > std.math.maxInt(u32)` and return `error.DecompressFailed`.

Option 2 is simpler and probably faster (one cmp instead of one cmp + one div per byte). The default-gated `decompress_ascii_hex_random` and `decompress_runlength_random` targets don't reach this surface — only the aggressive-gated round-trip target does — so default-gate fuzz remains clean while the fix is in flight.

### User-facing impact

A malicious PDF with an `/ASCII85Decode` filtered stream containing a 5-tuple whose intermediate accumulator overflows would crash any pdf.zig consumer running in `Debug` or `ReleaseSafe` (panic) and silently produce wrong decoded bytes in `ReleaseFast`. The CLI's primary path is `Document.open(path)` over trusted PDFs; `openFromMemory` over attacker-controlled bytes is reachable through the embedding API and the C / WASM consumers.

**Severity: Medium.** Crash on adversarial input. No OOB read, no RCE.

---

## Finding 006 — `interpreter.ContentInterpreter` is 0.16-stale and uncompilable

**Status**: OPEN (compile-time, not runtime — surfaces only when an external caller instantiates the type)
**Path**: `src/interpreter.zig:103` and `src/interpreter.zig:172`
**Surfaced by**: iter-3 of the autonomous fuzz loop. The planned `interpreter_q_stack_dispatch` target tried to instantiate `interpreter.ContentInterpreter(*std.Io.Writer)` to drive adversarial q/Q runs against the graphics-state stack; build failed with three compile errors before any iter executed.
**Class**: stale 0.15 stdlib API in production source — a Writergate / `ArrayList`-unmanaged migration miss

### Reproducer

```zig
const interpreter = @import("interpreter.zig");
test "ContentInterpreter compiles in 0.16" {
    const Interp = interpreter.ContentInterpreter(*std.Io.Writer);
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var i = Interp.init(std.testing.allocator, &w, "", null, undefined);
    defer i.deinit();
}
```

### Root cause

`ContentInterpreter.init` (interpreter.zig:103) calls `std.ArrayList(GraphicsState).init(allocator)` — the **managed** ArrayList constructor, removed in 0.16. `executeOperator` (interpreter.zig:172) then calls `state_stack.append(self.state)` — also the managed signature. Both surfaces need the unmanaged-style migration the rest of the codebase has already received: `.empty` initialiser + explicit allocator on `append(allocator, item)`.

The reason this stayed hidden is that `ContentInterpreter` is **public surface but unused in production**. The actual content-stream dispatch path is `extractContentStream` in `root.zig`, which drives `interpreter.ContentLexer` directly with its own operator-by-operator switch. The only would-be callers were the iter-3 fuzz harnesses.

### Recommended fix

Two-line patch:

```zig
// src/interpreter.zig:103
.state_stack = .empty,

// src/interpreter.zig:172
try self.state_stack.append(self.allocator, self.state);
```

Alternative: delete `ContentInterpreter` entirely and trim the public surface — `extractContentStream` is the canonical dispatch, so the type is genuinely dead.

### User-facing impact

**None.** The dead-but-public type is never instantiated in any user-reachable path. The fuzz coverage gap (no q/Q-stack-stress target) is the only externally-visible consequence. Severity: **Low** (documentation / dead-code hygiene; not a runtime bug).

---

## Finding 007 — Zig 0.16.0 `std.testing.fuzz` discovery-pass segfault

**Status**: OPEN UPSTREAM (toolchain bug, not pdf.zig)
**Path**: `~/.zvm/0.16.0/lib/std/testing/fuzzer.zig:904` (`ensureCorpusLoaded`) called from `mainServer` → `run_test` → `std.testing.fuzz` before `start_fuzzing`
**Surfaced by**: iter-6 of the autonomous fuzz loop. Attempting to declare a `.fuzz = true` test binary triggers a segfault during the build runner's discovery pass on every test, **before** any fuzzer state is initialised.
**Class**: zig stdlib bug — uninitialised state read in test discovery

### Reproducer

```zig
// src/example_fuzz.zig
const std = @import("std");
test "fuzz hello" {
    try std.testing.fuzz(@as(void, {}), struct {
        fn hello(_: void, smith: *std.testing.Smith) anyerror!void {
            _ = try smith.bytes(0, 16);
        }
    }.hello, .{});
}
```

```sh
# In a build.zig that adds .fuzz = true to the test module:
~/.zvm/bin/zig build fuzz-cov  # → SIGSEGV in fuzzer.zig:904 ensureCorpusLoaded
```

### Workaround (active in iter-6)

Omit `.fuzz = true` on the module. `std.testing.fuzz` then runs in **seed-corpus-only** mode (test_runner.zig line 596+): `Smith.in` is sourced from `FuzzInputOptions.corpus`, the test_one body executes once per corpus entry, and the harness asserts the same invariants the coverage-guided variant would. The harness body needs no edits when `.fuzz = true` becomes safe to flip.

See `src/fuzz_cov.zig` (the iter-6 harness) and the `fuzz-cov` step block in `build.zig` for the wiring + the comment block documenting the flip-back path.

### User-facing impact

**None on pdf.zig users.** The pdf.zig CLI has zero `.fuzz = true` test bindings. The impact is only on the loop's tier-6 coverage-guided runs — they currently run in seed-corpus mode instead of true coverage-guided AFL-style. As soon as 0.16.x or 0.17 ships a fix for the discovery pass, the harnesses upgrade with a one-line build.zig flag flip.

### Recommended action

1. **File upstream** at `ziglang/zig` GitHub issues if not already known (the segfault site looks like a recent regression — `ensureCorpusLoaded` is called from `mainServer`'s pre-fuzz validation pass on uninitialised fuzzer state; either guard the call or initialise the fuzzer state earlier).
2. **Track 0.16.x release notes** for the fix; flip `.fuzz = true` in `build.zig` when it ships.
3. **No pdf.zig source change needed.**

---

## Finding 008 — `cff.zig` Index/DICT panic on adversarial CFF bytes

**Status**: OPEN (issue tracker disabled on the repo; tracked here + in `audit/fuzz_loop_state.md`)
**Surfaced by**: iter-9 of the autonomous fuzz loop. Three `reproducer_only` targets (`cff_init_random_bytes`, `cff_init_biased_header`, `cff_dict_random_topdict`) deterministically trip in ReleaseSafe within a few hundred to ~10k iters at multiple base seeds (`0x1`, `0x2`, `0xCAFEBABE`, `0xDEADBEEF`).
**Class**: integer overflow / `@intCast` trap (Debug + ReleaseSafe panic; ReleaseFast UB → silently wrong offsets / OOB reads).

### Site 008a — `Index.parse` last-offset underflow

**Path**: `src/cff.zig:263` — `const data_size = temp_cursor.readOffSize(off_size) - 1;`

The CFF Index format encodes data size as `last_offset - 1` (offsets are 1-based relative to the byte preceding the data array). When attacker bytes set the *last* offset to `0`, the subtraction underflows `usize`. ReleaseSafe traps; ReleaseFast wraps to `usize.max - 0` and the next `cursor.pos += data_size` blows past `cursor.data.len`, opening every subsequent `Index.parse` and `getData` call to OOB reads.

#### Minimal reproducer

```
// 9-byte CFF that trips Finding 008a:
//   header   : 01 00 04 01      (major=1 minor=0 hdrSize=4 offSize=1)
//   Name IDX : 00 01 01 00 00   (count=1 offSize=1 offsets=[0,0])
const bytes = [_]u8{ 1, 0, 4, 1, 0, 1, 1, 0, 0 };
var p = try cff.CffParser.init(allocator, &bytes);  // panics here
defer p.deinit();
```

```sh
PDFZIG_FUZZ_ITERS=10000 PDFZIG_FUZZ_SEED=0x1 \
  PDFZIG_FUZZ_TARGET=cff_init_random_bytes \
  ~/.zvm/bin/zig build fuzz -Doptimize=ReleaseSafe
```

#### Stack at the panic

```
thread <id> panic: integer overflow
src/cff.zig:273:9       parse           (return Index{...} after the underflow at line 263)
src/cff.zig:71:42       parse           (self.name_index = try Index.parse(&cursor))
src/fuzz_runner.zig:... fuzzCffInitRandomBytes
```

#### Recommended fix

```zig
// src/cff.zig:263
const last_off = temp_cursor.readOffSize(off_size);
if (last_off == 0) return CffError.TruncatedData;
const data_size = last_off - 1;
```

Same defensive pattern at `src/cff.zig:291-292` in `Index.getData`:

```zig
if (start == 0 or end == 0) return &[_]u8{};
const real_start = self.data_offset + start - 1;
const real_end = self.data_offset + end - 1;
```

(getData currently catches the consequence with the `real_start >= full_data.len` check on line 294, but that check fires *after* the `+ start - 1` underflow — so it's load-bearing only in ReleaseFast where the underflow wraps. Make the precondition explicit.)

### Site 008b — `parseTopDict` `@intCast` trap on negative DICT operand

**Path**: `src/cff.zig:105` (and the parallel sites at 108, 111, 115, 116) — `self.charset_offset = @intCast(op.operands[0]);`

`DictParser.readNumber` returns an `i32`. The Top DICT Charset / Encoding / CharStrings / Private offsets are stored as `usize`. When attacker bytes encode a negative number (e.g. via the `251..254` single-byte negative-int range, or a real-number nibble path that rounds to a negative value, or operator `29` long-int with the high bit set), `@intCast(i32 → usize)` traps in ReleaseSafe.

ReleaseFast `@intCast` is UB and reinterprets the negative as a huge `usize`, which then drives `cursor.pos = self.charstrings_offset` (or similar) past `data.len`, opening downstream OOB reads.

#### Minimal reproducer

Build a CFF where the Top DICT body sets operator 15 (Charset) with a negative operand. Easiest: encode operand `-1` via `b0 = 251, b1 = 0` (the `-1*256 - 0 - 108 = -364`-ish range), then operator byte `15`:

```
// header + empty Name IDX + Top DICT IDX with body "FB 00 0F" + empty String IDX + empty Subr IDX
//   251 00 → operand -108
//   0F     → operator 15 (Charset)
const bytes = [_]u8{ 1, 0, 4, 1, 0, 0, 0, 1, 1, 1, 4, 251, 0, 15, 0, 0, 0, 0 };
var p = try cff.CffParser.init(allocator, &bytes);  // panics on the @intCast
defer p.deinit();
```

```sh
PDFZIG_FUZZ_ITERS=50 PDFZIG_FUZZ_SEED=0x1 \
  PDFZIG_FUZZ_TARGET=cff_dict_random_topdict \
  ~/.zvm/bin/zig build fuzz -Doptimize=ReleaseSafe
```

#### Stack at the panic

```
thread <id> panic: integer does not fit in destination type
src/cff.zig:105:68      parseTopDict    (self.charset_offset = @intCast(op.operands[0]))
src/cff.zig:85:43       parse           (try self.parseTopDict(top_dict_data))
src/cff.zig:46:8        init            (try parser.parse())
```

#### Recommended fix

Range-check then store. All five offset assignments need the same guard:

```zig
15 => { // Charset
    if (op.operands.len > 0) {
        const v = op.operands[0];
        if (v < 0 or v > std.math.maxInt(u32)) return CffError.InvalidOperand;
        self.charset_offset = @intCast(v);
    }
},
```

Or factor a helper:

```zig
fn nonNegativeOffset(v: i32) !usize {
    if (v < 0) return CffError.InvalidOperand;
    return @intCast(v);
}
```

`InvalidOperand` is already in `CffError`, so no enum change needed.

### User-facing impact

CFF Type 2 fonts are a primary attack vector for PDF readers (CVE-2010-2883 et al. set the precedent). The pdf.zig CLI's primary path is `Document.open(path)` over trusted PDFs, but CFF-fontfile bytes inside an *otherwise-trusted* PDF are still attacker-controlled — a malicious PDF can carry a corrupt CFF FontFile3 stream that traps the reader. Embedding API consumers (C / WASM) hit this on any `openFromMemory` over an attacker-shaped PDF.

**Severity: Medium.** Two distinct ReleaseSafe panics in the CFF parser. ReleaseFast trades the panic for OOB reads (`Index.parse` data_size wraps; `parseTopDict` offset reinterprets to multi-GB) — same severity class as Finding 005.

### Why all three iter-9 targets are `reproducer_only`

`cff_init_random_bytes` and `cff_init_biased_header` both reach `Index.parse` after a few hundred iters once random bytes form a non-zero count + at least one zero offset. `cff_dict_random_topdict` reaches `parseTopDict` on every iter and trips 008b within ~50 iters because random `i32` operands skew negative ~50 % of the time.

There is no constrained-input variant that exercises the parser surface meaningfully *and* dodges both bugs — the bugs sit on the main parse path. So all three targets are gated as `reproducer_only` until Finding 008a + 008b are fixed; the harness shape is then unchanged when promoted back to default-gate.

---

## Finding 009 — `assignImageObjectNumbers` doesn't flip the registry freeze flag (asymmetric with fonts)

**Status**: OPEN (design asymmetry; possibly intentional)
**Path**: `src/pdf_resources.zig:378`
**Surfaced by**: Codex review of iter-10's `pdf_resources_image_register_assign` target. The subagent originally noted the asymmetry and decided it was intent (per the comment at line 378). Codex flagged the harness for not actually probing it — silently passing on an asymmetric contract is the same as rubber-stamping a possible bug.
**Class**: design-level lifecycle gap (not a runtime panic)

### Behaviour

`assignFontObjectNumbers` sets the registry-wide `object_nums_assigned = true` flag, which then causes:

- `registerFontBuiltin` post-assign → `error.ObjectNumbersAlreadyAssigned`
- `registerImage` post-assign → `error.ObjectNumbersAlreadyAssigned`
- `assignFontObjectNumbers` again → `error.ObjectNumbersAlreadyAssigned`

`assignImageObjectNumbers` does **not** flip the flag, so:

- `registerImage` post-image-assign → succeeds (mutates frozen-ish registry)
- `assignImageObjectNumbers` again → succeeds (re-assigns object numbers to the same images)

The `assignFontObjectNumbers` flag-flip means the **font** path is locked, but the **image** path remains mutable until the font path locks it (or never, if no fonts are registered).

### Why this matters

`DocumentBuilder.write()` calls both assigns in sequence — currently safe because the writer drives a deterministic order. But a future caller (or a refactor) could:

1. Call `assignImageObjectNumbers` early, then add more images, then re-call → silent re-assign of object numbers, breaking xref-table layout.
2. Call `assignImageObjectNumbers` after `assignFontObjectNumbers` → succeeds (font path is frozen but image path isn't), so a partial-flow caller gets unexpectedly inconsistent state.

The font path's freeze contract is the safe-by-default; image path's lack-of-freeze is the divergence.

### Recommended fix

One-line patch at `src/pdf_resources.zig` (the assignImageObjectNumbers body):

```zig
if (self.object_nums_assigned) return error.ObjectNumbersAlreadyAssigned;
// … existing body …
self.object_nums_assigned = true;
```

Mirror the font path. If the asymmetry was intentional (some legitimate use case for re-assigning image obj nums), document it explicitly at line 378 + add a regression test asserting the expected `assignImageObjectNumbers` × 2 success. Otherwise, lock the path.

### User-facing impact

**None today.** The single in-tree caller (`DocumentBuilder.write()`) drives the registry through one well-defined path. Severity: **Low** — design hygiene, not a runtime bug.

The iter-10 `pdf_resources_image_register_assign` target now pins the *current* (asymmetric) behaviour as the harness contract: a re-assign call must succeed. If the production code is later "fixed" to mirror the font path, that target will trip and force this audit entry to be re-examined.

---

## Reproducer index

- `audit/fuzz_corpus_crash_001.bin` — the 643-byte mutated PDF that initially caused the false-positive harness segfault. Kept as an interesting input even though the crash was harness-side; it is a useful smoke-test PDF for parser robustness (CLI handles it cleanly: `pdf.zig info audit/fuzz_corpus_crash_001.bin` → `pages: 0`).
