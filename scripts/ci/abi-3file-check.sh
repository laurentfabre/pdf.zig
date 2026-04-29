#!/usr/bin/env bash
# Gate 6: C ABI 3-file transaction check.
#
# Fails the PR if `src/capi.zig` changes without `python/zpdf/_cdef.h` AND
# `python/zpdf/_ffi.py` also changing in the same PR.
#
# Rationale: every C ABI change must touch all three files in lockstep
# so the Python binding stays coherent with the Zig export. See AGENTS.md
# "C ABI rules" section.
#
# Escape: PR label `abi-no-3file` for internal refactors that do NOT
# alter the public ABI surface (e.g., renaming a private helper).
#
# Required env: BASE_SHA, HEAD_SHA, LABELS (JSON array of label names).

set -euo pipefail

: "${BASE_SHA:?BASE_SHA must be set}"
: "${HEAD_SHA:?HEAD_SHA must be set}"
: "${LABELS:=[]}"

if printf '%s' "$LABELS" | grep -q '"abi-no-3file"'; then
  echo "Skipping: PR has the \`abi-no-3file\` label."
  exit 0
fi

changed=$(git diff --name-only "$BASE_SHA" "$HEAD_SHA")

if ! printf '%s\n' "$changed" | grep -qx 'src/capi.zig'; then
  echo "src/capi.zig not changed — gate not applicable."
  exit 0
fi

missing=()
printf '%s\n' "$changed" | grep -qx 'python/zpdf/_cdef.h' \
  || missing+=("python/zpdf/_cdef.h")
printf '%s\n' "$changed" | grep -qx 'python/zpdf/_ffi.py' \
  || missing+=("python/zpdf/_ffi.py")

if [ "${#missing[@]}" -gt 0 ]; then
  cat >&2 <<EOF
ERROR: src/capi.zig changed but the C ABI 3-file transaction is incomplete.

Missing changes:
$(printf '  - %s\n' "${missing[@]}")

A C ABI surface change must touch all three files in the same PR:
  - src/capi.zig                   (the Zig export)
  - python/zpdf/_cdef.h            (the C header — hand-maintained)
  - python/zpdf/_ffi.py            (the cffi mirror)

See AGENTS.md "C ABI rules" section.

Escape: add the \`abi-no-3file\` label if this is an internal refactor
that does NOT alter the public ABI surface.
EOF
  exit 1
fi

echo "OK: all three ABI files changed."
