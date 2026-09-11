#!/usr/bin/env bash
# Verifies install/install.sh NEVER deletes or damages an already-installed
# binary when a re-download fails (issue #23: a real user's running kannaka
# was deleted on 2026-09-11 when curl hit ETXTBSY and the failure path rm'd the
# destination), on EVERY failure path — download error, sha256 mismatch on the
# pinned and the unpinned path, no sha256 tool, a directory at the
# destination, and an interrupt mid-download — and that a successful download
# replaces the file by rename so a running process keeps its inode. Also
# covers the fetch_pinned short-circuit: an installed file whose sha256
# already matches the manifest is not re-downloaded at all.
#
# Runs install.sh under a stubbed curl / uname — no network, no real download.
# sha256sum is REAL, so the short-circuit and the verify are exercised for real.
# Every optional tool the installer probes for (claude, node, npm, ollama,
# brew, sudo) is stubbed too, so nothing on the host is touched wherever those
# really live. Exits non-zero if any case misbehaves.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALL_SH="$HERE/../install/install.sh"
FAILS=0
MANIFEST_URL="https://stub.invalid/constellation.tsv"
PIN_URL="https://stub.invalid/kannaka-linux-x86_64"

# MSYS/Git Bash cannot honour the exec bit on an extensionless file and has no
# job control worth relying on, so the executable assertion, the running-binary
# case, the no-sha-tool case and the interrupt case only run on a real Unix.
case "$(uname -s)" in Linux|Darwin) REAL_UNIX=1 ;; *) REAL_UNIX=0 ;; esac

# The test's own digests (its PATH is never fenced) — macOS has shasum only.
sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}
sha_of_string() { printf '%s' "$1" > "$SCRATCH/s"; sha_of "$SCRATCH/s"; }
SCRATCH="$(mktemp -d)"

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
# is configured; serves a sha256 sidecar (the real digest of the fake payload,
# or FAKE_SIDECAR_SHA when set); writes the fake payload to -o for any binary
# URL — or exits 23 (curl's "write error", which is what ETXTBSY surfaces as)
# when FAKE_CURL_FAIL=1. FAKE_CURL_SLEEP delays the write so a signal can land
# mid-download.
dest=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in -o) dest="$2"; shift 2 ;; --max-time) shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
done
printf 'curl %s\n' "$url" >> "${FAKE_LOG:-/dev/null}"
case "$url" in
  "${FAKE_MANIFEST_URL:-none}")
    [ -n "${FAKE_MANIFEST:-}" ] && [ -f "$FAKE_MANIFEST" ] || exit 22
    cp "$FAKE_MANIFEST" "$dest"; exit 0 ;;
  *constellation.tsv|*.sig|*.pub) exit 22 ;;
  *.sha256)
    if [ -n "${FAKE_SIDECAR_SHA:-}" ]; then want="$FAKE_SIDECAR_SHA"
    else want="$(printf '%s' "$FAKE_PAYLOAD" | sha256sum | awk '{print $1}')"; fi
    printf '%s  kannaka\n' "$want" > "$dest"; exit 0 ;;
  *)
    [ "${FAKE_CURL_FAIL:-0}" = "1" ] && exit 23
    [ -n "${FAKE_CURL_SLEEP:-}" ] && sleep "$FAKE_CURL_SLEEP"
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
  # The installer's optional steps probe for these with `command -v`. Each is a
  # logging no-op here so the real tool is never reached, wherever it lives
  # (a nodesource npm puts `claude` in /usr/bin, inside the PATH fence).
  for t in claude ollama node npm brew sudo; do
    printf '#!/bin/sh\nprintf "%s %%s\\n" "$*" >> "${FAKE_LOG:-/dev/null}"\nexit 0\n' "$t" > "$1/$t"
  done
  chmod +x "$1/curl" "$1/uname" "$1"/claude "$1"/ollama "$1"/node "$1"/npm "$1"/brew "$1"/sudo
}

# A PATH with every system tool EXCEPT sha256sum/shasum: a symlink farm over
# /usr/bin and /bin, so `command -v sha256sum` honestly fails.
make_nosha_path() {
  mkdir -p "$1"
  for d in /usr/bin /bin; do
    [ -d "$d" ] || continue
    for t in "$d"/*; do
      n="${t##*/}"
      case "$n" in sha256sum|shasum) continue ;; esac
      [ -e "$1/$n" ] || ln -s "$t" "$1/$n" 2>/dev/null
    done
  done
}

# Per-case options, reset before every case.
reset_opts() {
  MSHA="-"; CURL_FAIL=0; SIDECAR=""; SEED="old"; NOSHA=0; INTERRUPT=0
  EXP_RC=1; EXP="unchanged"
}

# run_case <label>  — seeds ~/.local/bin/kannaka (SEED: old = OLD-BYTES, busy =
# a running copy of /bin/sleep, dir = a directory), runs the installer with the
# options above, and asserts the exit code, what is left at the destination,
# and that no *.download.* temp file remains.
run_case() {
  label="$1"
  work="$(mktemp -d)"; bin="$work/stub"; home="$work/home"; dest="$home/.local/bin/kannaka"
  mkdir -p "$bin" "$home/.local/bin"
  make_stubs "$bin"

  pid=""; exe_before=""
  case "$SEED" in
    busy)
      cp "$(command -v sleep)" "$dest"; chmod +x "$dest"
      "$dest" 60 & pid=$!
      sleep 0.2
      exe_before="$(sha_of /proc/$pid/exe)" ;;
    dir) mkdir "$dest" ;;
    *)   printf 'OLD-BYTES' > "$dest"; chmod +x "$dest" ;;
  esac
  before=""; [ -f "$dest" ] && before="$(sha_of "$dest")"

  manifest=""
  if [ "$MSHA" != "-" ]; then manifest="$work/constellation.tsv"; write_manifest "$manifest" "$MSHA"; fi

  # PATH is fenced to the stubs + the system dirs so the installer's optional
  # steps cannot see the real tools on a dev box.
  fence="/usr/bin:/bin"
  if [ "$NOSHA" = 1 ]; then make_nosha_path "$work/nosha"; fence="$work/nosha"; fi

  csleep=""; [ "$INTERRUPT" = 1 ] && csleep=1
  HOME="$home" PATH="$bin:$fence" SKIP_STATUSLINE=1 \
    KANNAKA_MANIFEST="$MANIFEST_URL" FAKE_MANIFEST_URL="$MANIFEST_URL" FAKE_MANIFEST="$manifest" \
    FAKE_PAYLOAD="NEW-BYTES" FAKE_CURL_FAIL="$CURL_FAIL" FAKE_SIDECAR_SHA="$SIDECAR" \
    FAKE_CURL_SLEEP="$csleep" FAKE_LOG="$work/curl.log" \
    sh "$INSTALL_SH" >"$work/out" 2>&1 &
  spid=$!
  if [ "$INTERRUPT" = 1 ]; then
    # Let the installer reach the (sleeping) download, then signal the shell
    # itself and wait for it to exit. TERM rather than INT: a non-interactive
    # bash starts background jobs with SIGINT ignored, and a shell cannot
    # un-ignore a signal it inherited ignored — the installer's trap handles
    # INT, TERM and HUP identically, so TERM exercises the same code.
    sleep 0.5; kill -TERM "$spid" 2>/dev/null
  fi
  wait "$spid"; rc=$?
  # A shell killed WITHOUT the trap dies at once while the stub curl is still
  # sleeping; the temp file only appears when the stub finishes. Wait it out
  # so the leftover check below is not racing the stub.
  [ "$INTERRUPT" = 1 ] && sleep 2

  bad=""
  [ "$rc" -eq "$EXP_RC" ] || bad="$bad rc=$rc(want $EXP_RC)"
  case "$EXP" in
    unchanged)
      if [ -f "$dest" ]; then [ "$(sha_of "$dest")" = "$before" ] || bad="$bad dest-bytes-changed"
      else bad="$bad dest-MISSING"; fi ;;
    dir)
      [ -d "$dest" ] || bad="$bad dest-no-longer-a-directory"
      [ -z "$(ls -A "$dest" 2>/dev/null)" ] || bad="$bad file-moved-INTO-directory:$(ls -A "$dest" | tr '\n' ' ')" ;;
    *)
      if [ -f "$dest" ]; then
        [ "$(sha_of "$dest")" = "$(sha_of_string "$EXP")" ] || bad="$bad dest-bytes-not-$EXP"
        [ "$REAL_UNIX" = 1 ] && { [ -x "$dest" ] || bad="$bad dest-not-executable"; }
      else bad="$bad dest-MISSING"; fi ;;
  esac
  leftovers="$(find "$home/.local/bin" -name '*.download.*' 2>/dev/null)"
  [ -z "$leftovers" ] || bad="$bad leftover-temp:$leftovers"
  if [ -n "$pid" ]; then
    # Liveness is not enough (a process survives rm of its binary); the
    # process must still be executing the SAME inode it started on.
    if kill -0 "$pid" 2>/dev/null; then
      [ "$(sha_of /proc/$pid/exe)" = "$exe_before" ] || bad="$bad running-process-exe-changed"
    else bad="$bad running-process-died"; fi
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  fi

  if [ -n "$bad" ]; then
    echo "FAIL [$label]:$bad"
    sed 's/^/    /' "$work/out"
    FAILS=$((FAILS + 1))
  else
    echo "ok   [$label]"
  fi
  # Hand the case's output and stub log back for extra assertions.
  LAST_OUT="$work/out"; LAST_LOG="$work/curl.log"; LAST_WORK="$work"
}
finish_case() { rm -rf "$LAST_WORK"; }

NEW_SHA="$(sha_of_string 'NEW-BYTES')"
OLD_SHA="$(sha_of_string 'OLD-BYTES')"
OTHER_SHA="$(sha_of_string 'SOMETHING-ELSE')"

# THE FIX (#23): a failed download must leave the existing binary untouched —
# on the unpinned (latest + .sha256) path and on the manifest-pinned path.
reset_opts; CURL_FAIL=1;               run_case "unpinned-download-fails-keeps-existing"; finish_case
reset_opts; CURL_FAIL=1; MSHA="$NEW_SHA"; run_case "pinned-download-fails-keeps-existing";   finish_case

# The other failure paths: a sha256 mismatch (pinned: manifest says one thing,
# the bytes are another; unpinned: the sidecar is wrong) and no sha256 tool at
# all must also refuse without touching the existing binary.
reset_opts; MSHA="$OTHER_SHA";                  run_case "pinned-mismatch-keeps-existing";   finish_case
reset_opts; SIDECAR="$(sha_of_string 'WRONG')"; run_case "unpinned-mismatch-keeps-existing"; finish_case
if [ "$REAL_UNIX" = 1 ]; then
  reset_opts; MSHA="$NEW_SHA"; NOSHA=1; run_case "no-sha-tool-keeps-existing"
  grep -q 'no sha256 tool' "$LAST_OUT" || { echo "FAIL [no-sha-tool-keeps-existing]: the installer did not report the missing sha256 tool"; FAILS=$((FAILS + 1)); }
  finish_case
else
  echo "skip [no-sha-tool-keeps-existing] (needs a symlink farm; got $(uname -s))"
fi

# A directory at the destination: `mv` would drop the file INSIDE it and the
# script would print "installed". It must refuse and leave the directory empty.
reset_opts; MSHA="$NEW_SHA"; SEED=dir; EXP=dir; run_case "pinned-directory-dest-refused";   finish_case
reset_opts; SEED=dir; EXP=dir;                  run_case "unpinned-directory-dest-refused"; finish_case

# Short-circuit: installed bytes already match the manifest → no download.
reset_opts; MSHA="$OLD_SHA"; EXP_RC=0; run_case "pinned-already-installed-skips-download"
if ! grep -q 'already installed and verified' "$LAST_OUT"; then
  echo "FAIL [pinned-already-installed-skips-download]: no 'already installed and verified' line"; FAILS=$((FAILS + 1))
fi
if grep -q "^curl $PIN_URL\$" "$LAST_LOG"; then
  echo "FAIL [pinned-already-installed-skips-download]: the pinned binary was downloaded anyway"; FAILS=$((FAILS + 1))
fi
finish_case

# A good download replaces the file in place with the verified bytes.
reset_opts; MSHA="$NEW_SHA"; EXP_RC=0; EXP=NEW-BYTES; run_case "pinned-replaces-existing"; finish_case

if [ "$REAL_UNIX" = 1 ]; then
  # The real thing: the destination is a RUNNING executable. Writing onto it
  # would be ETXTBSY; the rename must still land the new bytes, and the old
  # process must keep executing its old inode. Linux only (macOS allows the
  # write, and has no /proc).
  if [ "$(uname -s)" = "Linux" ]; then
    reset_opts; MSHA="$NEW_SHA"; EXP_RC=0; EXP=NEW-BYTES; SEED=busy; run_case "busy-binary-replaced-while-running"; finish_case
  else
    echo "skip [busy-binary-replaced-while-running] (needs Linux ETXTBSY semantics; got $(uname -s))"
  fi
  # Ctrl-C mid-download: the trap must remove the temp file and the existing
  # binary must be untouched. The shell exits 130.
  reset_opts; MSHA="$NEW_SHA"; INTERRUPT=1; EXP_RC=130; run_case "interrupt-mid-download-leaves-no-temp"; finish_case
else
  echo "skip [busy-binary-replaced-while-running] (needs Linux ETXTBSY semantics; got $(uname -s))"
  echo "skip [interrupt-mid-download-leaves-no-temp] (needs job control; got $(uname -s))"
fi

rm -rf "$SCRATCH"
[ "$FAILS" -eq 0 ] && echo "installer-busy-binary.sh: all cases passed" || { echo "installer-busy-binary.sh: $FAILS failed"; exit 1; }
