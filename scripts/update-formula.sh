#!/usr/bin/env bash
# Rewrite scripts/Formula/pdf-zig.rb's version + SHA256s after a release.
#
# Usage:
#   scripts/update-formula.sh v1.0-rc2 release/SHA256SUMS
#
# The SHA256SUMS file is produced by `.github/workflows/release.yml` and
# attached to the GitHub release. Download it, then run this script. The
# rewritten Formula gets copied into the tap repo (laurentfabre/homebrew-pdf.zig)
# in a separate PR.

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <tag> <SHA256SUMS-file>" >&2
  echo "  tag e.g. v1.0-rc2" >&2
  exit 1
fi

TAG="$1"
SUMS_FILE="$2"
VERSION="${TAG#v}"
FORMULA="$(dirname "$0")/Formula/pdf-zig.rb"

if [[ ! -f "$SUMS_FILE" ]]; then
  echo "$SUMS_FILE not found" >&2
  exit 2
fi
if [[ ! -f "$FORMULA" ]]; then
  echo "$FORMULA not found" >&2
  exit 2
fi

extract_sum() {
  local pattern="$1"
  local match
  match=$(grep -E "  pdf\.zig-${TAG}-${pattern}\.(tar\.gz|zip)$" "$SUMS_FILE" | awk '{print $1}')
  if [[ -z "$match" ]]; then
    echo "missing SHA256 for $pattern in $SUMS_FILE" >&2
    exit 3
  fi
  echo "$match"
}

ARM_MAC=$(extract_sum "aarch64-macos")
INTEL_MAC=$(extract_sum "x86_64-macos")
ARM_LIN=$(extract_sum "aarch64-linux")
INTEL_LIN=$(extract_sum "x86_64-linux")

# Bump version + replace the 4 placeholder sha256s by position.
python3 - "$FORMULA" "$VERSION" "$ARM_MAC" "$INTEL_MAC" "$ARM_LIN" "$INTEL_LIN" <<'PY'
import re, sys
formula_path, version, arm_mac, intel_mac, arm_lin, intel_lin = sys.argv[1:]
with open(formula_path) as f:
    src = f.read()

# Bump version
src = re.sub(r'version "[^"]+"', f'version "{version}"', src, count=1)

# Replace the 4 placeholder SHAs in document order
sums = [arm_mac, intel_mac, arm_lin, intel_lin]
def repl(m, _sums=iter(sums)):
    return f'sha256 "{next(_sums)}"'
src = re.sub(r'sha256 "0{64}"', repl, src, count=4)

with open(formula_path, "w") as f:
    f.write(src)
print(f"Updated {formula_path} -> version {version}")
PY

echo "Next steps:"
echo "  cp $FORMULA <homebrew-pdf.zig clone>/Formula/pdf-zig.rb"
echo "  cd <homebrew-pdf.zig clone> && git commit -am 'pdf.zig $TAG' && git push"
