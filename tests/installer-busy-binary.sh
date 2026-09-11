#!/usr/bin/env bash
# Verifies install/install.sh NEVER deletes or damages an already-installed
# binary when the re-download fails (issue #23: a real user's running kannaka
# was deleted on 2026-09-11 when curl hit ETXTBSY and the failure path rm'd the
# destination), and that a successful download replaces the file by rename so
# a running process keeps its inode. Also covers the fetch_pinned short-circuit:
# an installed file whose sha256 already matches the manifest is not
# re-downloaded at all.
#
# Runs install.sh under a stubbed curl / uname — no network, no real download.
# sha256sum is REAL, so the short-circuit and the verify are exercised for real.
# Exits non-zero if any case misbehaves.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALL_SH="$HERE/../install/install.sh"
FAILS=0
MANIFEST_URL="https://stub.invalid/constellation.tsv"
PIN_URL="https://stub.invalid/kannaka-linux-x86_64"

# MSYS/Git Bash cannot honour the exec bit on an extensionless file, so the
# executable assertion (and the running-binary case) only run on a real Unix.
case "$(uname -s)" in Linux|Darwin) REAL_UNIX=1 ;; *) REAL_UNIX=0 ;; esac

sha_of_string() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }

# write_manifest <path> <sha256>  — a minimal constellation.tsv pinning kannaka
write_manifest() {
  printf '# kannaka-constellation/1\tgenerated\t2026-09-11T00:00:00Z\n' > "$1"
  printf 'component\tkannaka\tv9.9.9\thttps://github.com/kannaka-labs/kannaka-memory\tbinary\n' >> "$1"
  printf 'asset\tkannaka\tkannaka-linux-x86_64\tlinux-x86_64\t%s\t%s\n' "$PIN_URL" "$2" >> "$1"
}

# make_stubs <bindir>
make_stubs() {
  cat > "$1/curl" <<'EOF'
#!/bin/sh
# Stub curl. Logs every URL it is asked for; serves the fake manifest when one
# is configured; serves a real sha256 sidecar for the fake payload; writes the
# fake payload to -o for any binary URL — or exits 23 (curl's "write error",
# which is what ETXTBSY surfaces as) when FAKE_CURL_FAIL=1.
dest=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in -o) dest="$2"; shift 2 ;; --max-time) shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
done
printf '%s\n' "$url" >> "${FAKE_LOG:-/dev/null}"
case "$url" in
  "${FAKE_MANIFEST_URL:-none}")
    [ -n "${FAKE_MANIFEST:-}" ] && [ -f "$FAKE_MANIFEST" ] || exit 22
    cp "$FAKE_MANIFEST" "$dest"; exit 0 ;;
  *constellation.tsv|*.sig|*.pub) exit 22 ;;
  *.sha256) printf '%s  kannaka\n' "$(printf '%s' "$FAKE_PAYLOAD" | sha256sum | awk '{print $1}')" > "$dest"; exit 0 ;;
  *)
    [ "${FAKE_CURL_FAIL:-0}" = "1" ] && exit 23
    # A plain redirect onto a RUNNING binary fails with "Text file busy" on
    # Linux, exactly like curl did — so the busy case below is a real one.
    [ -n "$dest" ] && { printf '%s' "$FAKE_PAYLOAD" > "$dest" || exit 23; }
    exit 0 ;;
esac
EOF
  cat > "$1/uname" <<'EOF'
#!/bin/sh
case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; *) echo Linux ;; esac
EOF
  chmod +x "$1/curl" "$1/uname"
}

# run_case <label> <manifest-sha|-> <curl-fail 0/1> <expect-rc> <expect-dest-content> [busy]
#   Seeds ~/.local/bin/kannaka with OLD-BYTES (or, with "busy", a running copy
#   of /bin/sleep), runs the installer, and asserts the exit code, the exact
#   bytes left at the destination, and that no *.download.* temp file remains.
run_case() {
  label="$1"; msha="$2"; cfail="$3"; exp_rc="$4"; exp_content="$5"; busy="${6:-}"
  work="$(mktemp -d)"; bin="$work/stub"; home="$work/home"; dest="$home/.local/bin/kannaka"
  mkdir -p "$bin" "$home/.local/bin"
  make_stubs "$bin"

  pid=""
  if [ "$busy" = "busy" ]; then
    cp "$(command -v sleep)" "$dest"; chmod +x "$dest"
    "$dest" 60 & pid=$!
    sleep 0.2
  else
    printf 'OLD-BYTES' > "$dest"; chmod +x "$dest"
  fi
  before="$(sha256sum "$dest" | awk '{print $1}')"

  manifest=""
  if [ "$msha" != "-" ]; then manifest="$work/constellation.tsv"; write_manifest "$manifest" "$msha"; fi

  # PATH is fenced to the stubs + the system dirs so the installer's optional
  # steps (claude, node, ollama…) cannot see the real tools on a dev box.
  HOME="$home" PATH="$bin:/usr/bin:/bin" SKIP_STATUSLINE=1 \
    KANNAKA_MANIFEST="$MANIFEST_URL" FAKE_MANIFEST_URL="$MANIFEST_URL" FAKE_MANIFEST="$manifest" \
    FAKE_PAYLOAD="NEW-BYTES" FAKE_CURL_FAIL="$cfail" FAKE_LOG="$work/curl.log" \
    sh "$INSTALL_SH" >"$work/out" 2>&1
  rc=$?

  bad=""
  [ "$rc" -eq "$exp_rc" ] || bad="$bad rc=$rc(want $exp_rc)"
  if [ -f "$dest" ]; then
    case "$exp_content" in
      unchanged) [ "$(sha256sum "$dest" | awk '{print $1}')" = "$before" ] || bad="$bad dest-bytes-changed" ;;
      *) [ "$(cat "$dest")" = "$exp_content" ] || bad="$bad dest-bytes=$(cat "$dest")(want $exp_content)"
         [ "$REAL_UNIX" = 1 ] && { [ -x "$dest" ] || bad="$bad dest-not-executable"; } ;;
    esac
  else
    bad="$bad dest-MISSING"
  fi
  leftovers="$(find "$home/.local/bin" -name '*.download.*' 2>/dev/null)"
  [ -z "$leftovers" ] || bad="$bad leftover-temp:$leftovers"
  if [ -n "$pid" ]; then
    kill -0 "$pid" 2>/dev/null || bad="$bad running-process-died"
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  fi

  if [ -n "$bad" ]; then
    echo "FAIL [$label]:$bad"
    sed 's/^/    /' "$work/out"
    FAILS=$((FAILS + 1))
  else
    echo "ok   [$label]"
  fi
  # Hand the case's output and curl log back for extra assertions.
  LAST_OUT="$work/out"; LAST_LOG="$work/curl.log"; LAST_WORK="$work"
}
finish_case() { rm -rf "$LAST_WORK"; }

NEW_SHA="$(sha_of_string 'NEW-BYTES')"
OLD_SHA="$(sha_of_string 'OLD-BYTES')"

# THE FIX (#23): a failed download must leave the existing binary untouched —
# on the unpinned (latest + .sha256) path and on the manifest-pinned path.
run_case "unpinned-download-fails-keeps-existing" -          1 1 unchanged; finish_case
run_case "pinned-download-fails-keeps-existing"   "$NEW_SHA" 1 1 unchanged; finish_case

# Short-circuit: installed bytes already match the manifest → no download.
run_case "pinned-already-installed-skips-download" "$OLD_SHA" 0 0 unchanged
if ! grep -q 'already installed and verified' "$LAST_OUT"; then
  echo "FAIL [pinned-already-installed-skips-download]: no 'already installed and verified' line"; FAILS=$((FAILS + 1))
fi
if grep -q "^$PIN_URL\$" "$LAST_LOG"; then
  echo "FAIL [pinned-already-installed-skips-download]: the pinned binary was downloaded anyway"; FAILS=$((FAILS + 1))
fi
finish_case

# A good download replaces the file in place with the verified bytes.
run_case "pinned-replaces-existing" "$NEW_SHA" 0 0 NEW-BYTES; finish_case

# The real thing: the destination is a RUNNING executable. Writing onto it
# would be ETXTBSY; the rename must still land the new bytes, and the old
# process must survive on its old inode. Linux only (macOS allows the write).
if [ "$(uname -s)" = "Linux" ]; then
  run_case "busy-binary-replaced-while-running" "$NEW_SHA" 0 0 NEW-BYTES busy; finish_case
else
  echo "skip [busy-binary-replaced-while-running] (needs Linux ETXTBSY semantics; got $(uname -s))"
fi

[ "$FAILS" -eq 0 ] && echo "installer-busy-binary.sh: all cases passed" || { echo "installer-busy-binary.sh: $FAILS failed"; exit 1; }
