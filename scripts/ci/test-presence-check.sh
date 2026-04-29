#!/usr/bin/env bash
# Gate 5: Test-presence check.
#
# Fails the PR if a non-trivial change touches src/* .zig files without a
# corresponding test change. "Non-trivial" excludes blank lines and `//`
# comments.
#
# Test changes accepted:
#   - Any file under python/tests/ added/modified/removed (Python pytest)
#   - Any `test "..."` block added/modified/removed in any .zig file
#   - Any change to src/integration_test.zig or src/alloc_failure_test.zig
#
# Escape: PR label `no-test-needed` (refactors, comments-only, formatting).
#
# Required env: BASE_SHA, HEAD_SHA, LABELS (JSON array of label names).
# Local invocation:
#   BASE_SHA=$(git merge-base origin/main HEAD) HEAD_SHA=HEAD LABELS='[]' \
#     bash scripts/ci/test-presence-check.sh

set -euo pipefail

: "${BASE_SHA:?BASE_SHA must be set}"
: "${HEAD_SHA:?HEAD_SHA must be set}"
: "${LABELS:=[]}"

# Escape label
if printf '%s' "$LABELS" | grep -q '"no-test-needed"'; then
  echo "Skipping: PR has the \`no-test-needed\` label."
  exit 0
fi

changed=$(git diff --name-only "$BASE_SHA" "$HEAD_SHA")

src_changed=$(printf '%s\n' "$changed" | grep -E '^src/.*\.zig$' || true)
if [ -z "$src_changed" ]; then
  echo "No src/ .zig changes — gate not applicable."
  exit 0
fi

# Non-trivial: any added/removed line that isn't blank or a `//` comment.
sig_lines=$(git diff "$BASE_SHA" "$HEAD_SHA" -- $src_changed \
  | grep -E '^[+-][^+-]' \
  | grep -vE '^[+-][[:space:]]*$' \
  | grep -vE '^[+-][[:space:]]*//' \
  | wc -l | tr -d ' ')

if [ "$sig_lines" -eq 0 ]; then
  echo "Only blank/comment changes in src/* — gate not applicable."
  exit 0
fi

# Test changes: python/tests/* file changed, OR any test "..." block changed
# in any .zig file under src/, OR src/integration_test.zig / src/alloc_failure_test.zig touched.
pytest_changed=$(printf '%s\n' "$changed" | grep -E '^python/tests/' || true)
test_block_diff=$(git diff "$BASE_SHA" "$HEAD_SHA" -- 'src/*.zig' \
  | grep -E '^[+-]test "' || true)
test_files_touched=$(printf '%s\n' "$changed" | grep -E '^src/(integration_test|alloc_failure_test)\.zig$' || true)

if [ -n "$pytest_changed" ] || [ -n "$test_block_diff" ] || [ -n "$test_files_touched" ]; then
  echo "Tests changed:"
  [ -n "$pytest_changed" ] && echo "  python/tests/ files:" && printf '    %s\n' $pytest_changed
  [ -n "$test_block_diff" ] && echo "  test \"...\" blocks affected: $(printf '%s\n' "$test_block_diff" | wc -l | tr -d ' ')"
  [ -n "$test_files_touched" ] && echo "  test-runner files touched:" && printf '    %s\n' $test_files_touched
  exit 0
fi

cat >&2 <<EOF
ERROR: src/* .zig changed without any test change.

Files with non-trivial source changes:
$(printf '  %s\n' $src_changed)
Significant lines added/removed: $sig_lines

Expected one of:
  - A new or modified file under python/tests/
  - A new or modified \`test "..."\` block in any src/*.zig file
  - A change to src/integration_test.zig or src/alloc_failure_test.zig

Escape: add the \`no-test-needed\` label to this PR if the change is a
pure refactor, comments-only, or otherwise truly test-neutral.
EOF
exit 1
