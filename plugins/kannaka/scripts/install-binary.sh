#!/bin/sh
# Install the kannaka binary from GitHub releases for the current OS/arch.
# Usage: install-binary.sh [tag]        (default: latest)
# Override repo with KANNAKA_RELEASE_REPO, install dir with KANNAKA_BIN_DIR.
#
# POSIX sh (runs under dash); pipefail is taken only where the shell has it.
set -eu
(set -o pipefail) 2>/dev/null && set -o pipefail
REPO="${KANNAKA_RELEASE_REPO:-kannaka-labs/kannaka-memory}"
DEST_DIR="${KANNAKA_BIN_DIR:-$HOME/.local/bin}"
TAG="${1:-latest}"

os=$(uname -s); arch=$(uname -m)
case "$os" in
  Linux*)  o=linux ;;
  Darwin*) o=macos ;;
  MINGW*|MSYS*|CYGWIN*) o=windows ;;
  *) echo "unsupported OS: $os" >&2; exit 1 ;;
esac
case "$arch" in
  x86_64|amd64) a=x86_64 ;;
  aarch64|arm64) a=aarch64 ;;
  *) echo "unsupported arch: $arch" >&2; exit 1 ;;
esac
if [ "$o" = windows ]; then asset="kannaka-windows-x86_64.exe"; out="kannaka.exe"; else asset="kannaka-${o}-${a}"; out="kannaka"; fi

base="https://github.com/$REPO/releases"
if [ "$TAG" = latest ]; then url="$base/latest/download/$asset"; else url="$base/download/$TAG/$asset"; fi

# THE TEMP+MV RULE (same as install/install.sh's fetch_verified, #23/#24):
# never curl onto the destination. Download to a per-run temp file next to it
# ("kannaka.download.<pid>" — a fixed "kannaka.tmp" raced when two installs
# ran at once and verified one run's bytes against the other's digest), verify
# THAT, chmod it, and `mv -f` it over the destination. rename(2) replaces a
# busy inode atomically, so a running kannaka keeps its old binary. Every
# failure path removes only the temp file and the sidecar and never touches an
# existing destination.
dest="$DEST_DIR/$out"
tmp="$dest.download.$$"
sha="$tmp.sha256"
trap 'rm -f "$tmp" "$sha"; exit 130' INT TERM HUP
fail() { echo "✗ $*" >&2; rm -f "$tmp" "$sha"; exit 1; }

mkdir -p "$DEST_DIR"
# A directory at the destination would make `mv` drop the file INSIDE it and
# report success; refuse before downloading anything.
if [ -d "$dest" ]; then fail "$dest is a directory — refusing to install over it"; fi
echo "→ $REPO ($TAG)  asset: $asset"
echo "→ downloading…"
curl -fL# "$url" -o "$tmp" || fail "download failed: $url"
# The release always publishes a per-file .sha256. A MISSING or EMPTY sidecar
# means we cannot verify — fail closed rather than install an unverified
# binary. (Verification used to be nested inside the sidecar download's `if`,
# so a missing .sha256 silently skipped it — #26.)
curl -fsSL "$url.sha256" -o "$sha" 2>/dev/null \
  || fail "checksum $asset.sha256 could not be downloaded — refusing to install an unverified binary"
want=$(awk '{print $1}' "$sha"); rm -f "$sha"
[ -n "$want" ] || fail "checksum $asset.sha256 was empty — refusing to install an unverified binary"
if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum "$tmp" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then got=$(shasum -a 256 "$tmp" | awk '{print $1}')
else fail "no sha256 tool (sha256sum/shasum) available — cannot verify"; fi
[ -n "$got" ] || fail "could not compute the sha256 of the download"
[ "$want" = "$got" ] || fail "sha256 mismatch (want $want got $got)"
echo "✓ sha256 verified"
# Re-check right before the rename: the directory could have appeared during
# the download.
if [ -d "$dest" ]; then fail "$dest is a directory — refusing to install over it"; fi
chmod +x "$tmp" || fail "could not chmod +x $tmp"
mv -f "$tmp" "$dest" || fail "could not move the verified binary into place at $dest"
trap - INT TERM HUP
echo "✅ installed: $dest"
case ":$PATH:" in *":$DEST_DIR:"*) ;; *) echo "   note: $DEST_DIR is not on PATH — add it, or the statusline resolves it directly." ;; esac
"$dest" --version 2>/dev/null | head -1 || true
