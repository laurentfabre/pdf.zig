## Summary

<!-- 1-3 sentences: what changes and why. -->

## Scope

**In scope:**

-

**Out of scope:**

-

## Test plan

<!-- Concrete: which `zig build` step exercises the change, which test file(s), which fixtures. -->

- [ ] `zig build test` passes locally (1133+ tests)
- [ ] `zig build alloc-failure-test` passes (if parser / OOM paths touched)
- [ ] `zig build fuzz` smoke (50k iters/target) passes (if parser touched)
- [ ] `zig fmt --check src/ build.zig` clean

## C ABI impact

- [ ] No C ABI surface changed.
- [ ] **C ABI changed** — if checked, confirm the 3-file transaction:
  - [ ] `src/capi.zig` updated
  - [ ] `python/zpdf/_cdef.h` updated (matching `extern fn` and struct order)
  - [ ] `python/zpdf/_ffi.py` updated
  - [ ] `python/tests/test_zpdf.py` exercises the new surface
  - [ ] Older-binary feature-probe / skip in place
  - [ ] Python-side integer arguments are bounded before cffi narrowing

## Writer impact (v1.5+)

- [ ] No writer surface changed.
- [ ] **Writer changed** — confirm:
  - [ ] `DocumentBuilder` / `PageBuilder` / `BuiltinFont` API stable or bumped intentionally
  - [ ] Tests added under `src/pdf_writer.zig`, `src/pdf_document.zig`, or `src/markdown_to_pdf.zig`
  - [ ] Round-trip test: writer output parses cleanly via `Document.openFromMemory`
  - [ ] Failure-atomicity contract documented (poisoned builder discarded after error)

## Roadmap link

<!-- Item from docs/ROADMAP.md (PR-N or PR-W6.X format). -->

## Agent attribution (optional)

- Author agent: _e.g. claude-opus-4-7 / human / codex-gpt-5_
- Reviewer agent: _e.g. /zig-defensive / codex review / human_
