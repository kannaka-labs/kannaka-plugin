#!/bin/bash
# Install the kannaka binary from GitHub releases for the current OS/arch.
# Usage: install-binary.sh [tag]        (default: latest)
# Override repo with KANNAKA_RELEASE_REPO, install dir with KANNAKA_BIN_DIR.
set -uo pipefail
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

mkdir -p "$DEST_DIR"
echo "→ $REPO ($TAG)  asset: $asset"
echo "→ downloading…"
curl -fL# "$url" -o "$DEST_DIR/$out.tmp" || { echo "download failed: $url" >&2; exit 1; }
if curl -fsSL "$url.sha256" -o "$DEST_DIR/$out.sha256" 2>/dev/null; then
  want=$(awk '{print $1}' "$DEST_DIR/$out.sha256")
  if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum "$DEST_DIR/$out.tmp" | awk '{print $1}')
  else got=$(shasum -a 256 "$DEST_DIR/$out.tmp" | awk '{print $1}'); fi
  rm -f "$DEST_DIR/$out.sha256"
  if [ "$want" != "$got" ]; then echo "✗ sha256 mismatch (want $want got $got)" >&2; rm -f "$DEST_DIR/$out.tmp"; exit 1; fi
  echo "✓ sha256 verified"
fi
chmod +x "$DEST_DIR/$out.tmp" && mv "$DEST_DIR/$out.tmp" "$DEST_DIR/$out"
echo "✅ installed: $DEST_DIR/$out"
case ":$PATH:" in *":$DEST_DIR:"*) ;; *) echo "   note: $DEST_DIR is not on PATH — add it, or the statusline resolves it directly." ;; esac
"$DEST_DIR/$out" --version 2>/dev/null | head -1 || true
