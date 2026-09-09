#!/usr/bin/env bash
# Version-pin check for kannaka-plugin.
#
# The plugin does NOT hardcode a kannaka-memory version. Every installer
#   - install/install.sh
#   - install/install.ps1
#   - plugins/kannaka/scripts/install-binary.sh
# downloads the engine binary from the LATEST GitHub release of
# kannaka-labs/kannaka-memory (install-binary.sh also accepts an explicit tag).
# The "pin" is therefore that release + the asset names the installers ask for.
#
# This check asserts the pin is intact:
#   0. the installers still construct asset names the way this script assumes
#      (a rename there must not silently pass a stale check here),
#   1. the latest release exists and its tag looks like a real version (vX.Y.Z),
#   2. every binary asset the installers download — across all 3 OS targets —
#      is present on that release, together with the .sha256 sidecar the
#      installers verify against.
# If kannaka-memory stops publishing an asset the installers need, CI fails
# here instead of on users' machines.
set -euo pipefail

REPO="${KANNAKA_RELEASE_REPO:-kannaka-labs/kannaka-memory}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Binary asset matrix — mirrors the installers exactly:
#   install.sh / install-binary.sh:  kannaka-${o}-${a}  (o in linux,macos; a in x86_64,aarch64)
#   install.ps1 / install-binary.sh: kannaka-windows-x86_64.exe
ASSETS="
kannaka-linux-x86_64
kannaka-linux-aarch64
kannaka-macos-x86_64
kannaka-macos-aarch64
kannaka-windows-x86_64.exe
"

fail() { echo "FAIL: $*" >&2; exit 1; }

# 0. Guard: the installers still name assets the way the matrix above assumes.
grep -q 'kannaka-${o}-${a}' "$ROOT/install/install.sh" \
  || fail "install/install.sh no longer builds 'kannaka-\${o}-\${a}'; update ASSETS in this script."
grep -q 'kannaka-${o}-${a}' "$ROOT/plugins/kannaka/scripts/install-binary.sh" \
  || fail "install-binary.sh no longer builds 'kannaka-\${o}-\${a}'; update ASSETS in this script."
grep -q 'kannaka-windows-x86_64.exe' "$ROOT/install/install.ps1" \
  || fail "install.ps1 no longer references 'kannaka-windows-x86_64.exe'; update ASSETS in this script."
grep -q 'releases/latest/download' "$ROOT/install/install.sh" \
  || fail "install/install.sh no longer pins the LATEST release; update this check."

# 1. Fetch the latest release (authenticated via gh when available; else public API).
API="repos/$REPO/releases/latest"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  json="$(gh api "$API")"
else
  json="$(curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/$API")"
fi
[ -n "$json" ] || fail "empty response from $API"

# 2. Tag must look like vX.Y.Z (real published version, not a draft/garbage).
tag="$(grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"v[0-9]+\.[0-9]+\.[0-9]+[^"]*"' <<<"$json" \
       | head -1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+[^"]*' || true)"
[ -n "$tag" ] || fail "latest release of $REPO has no valid semver tag (vX.Y.Z)"
echo "latest release: $REPO $tag"

# 3. Every installer asset + its .sha256 sidecar must be present on the release.
missing=""
for asset in $ASSETS; do
  grep -qF "\"$asset\"" <<<"$json"        || missing="$missing $asset"
  grep -qF "\"$asset.sha256\"" <<<"$json" || missing="$missing $asset.sha256"
done
if [ -n "$missing" ]; then
  fail "latest release $tag is missing installer assets:$missing"
fi

echo "OK: all installer assets present on $REPO $tag"
for asset in $ASSETS; do echo "  - $asset (+ .sha256)"; done
