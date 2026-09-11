#!/usr/bin/env bash
# Verifies plugins/kannaka/scripts/install-binary.sh (what `/kannaka install`
# runs) follows the same rules install/install.sh does (#23/#24), issue #26:
#   - a MISSING or EMPTY .sha256 sidecar is fatal — nothing is installed, an
#     existing binary is untouched (it used to install UNVERIFIED, silently);
#   - a sha256 mismatch or a failed download leaves an existing binary as it was;
#   - a good download replaces the file by rename with the verified bytes;
#   - a directory at the destination is refused, not written into;
#   - the temp file is per-run ("kannaka.download.<pid>"), so two concurrent
#     installs never share a temp or a sidecar and both succeed;
#   - an interrupt mid-download leaves no temp file behind.
#
# Runs the script under a stubbed curl / uname — no network, no real download.
# sha256sum is REAL, so the verify is exercised for real. Every optional tool
# the installers probe for (claude, node, npm, ollama, brew, sudo) is stubbed
# too, so nothing on the host is touched wherever those really live. Exits
# non-zero if any case misbehaves.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${INSTALL_BINARY_SH:-$HERE/../plugins/kannaka/scripts/install-binary.sh}"  # override to test a candidate
FAILS=0

# MSYS/Git Bash cannot honour the exec bit on an extensionless file and has no
# job control worth relying on, so the executable assertion and the interrupt
# case only run on a real Unix.
case "$(uname -s)" in Linux|Darwin) REAL_UNIX=1 ;; *) REAL_UNIX=0 ;; esac

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}
sha_of_string() { printf '%s' "$1" > "$SCRATCH/s"; sha_of "$SCRATCH/s"; }
SCRATCH="$(mktemp -d)"

# make_stubs <bindir>
make_stubs() {
  cat > "$1/curl" <<'EOF'
#!/bin/sh
# Stub curl. Logs every URL and -o target it is asked for; serves a sha256
# sidecar (the real digest of the fake payload, or FAKE_SIDECAR_SHA when set,
# or an EMPTY file when FAKE_SIDECAR_EMPTY=1, or exits 22 like a 404 when
# FAKE_NO_SIDECAR=1); writes the fake payload to -o for any binary URL — or
# exits 23 (curl's "write error") when FAKE_CURL_FAIL=1. FAKE_CURL_SLEEP delays
# the binary write so a signal, or a second install, can land mid-download.
dest=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in -o) dest="$2"; shift 2 ;; --max-time) shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
done
printf 'curl %s -> %s\n' "$url" "$dest" >> "${FAKE_LOG:-/dev/null}"
case "$url" in
  *.sha256)
    [ "${FAKE_NO_SIDECAR:-0}" = "1" ] && exit 22
    if [ "${FAKE_SIDECAR_EMPTY:-0}" = "1" ]; then : > "$dest"; exit 0; fi
    if [ -n "${FAKE_SIDECAR_SHA:-}" ]; then want="$FAKE_SIDECAR_SHA"
    else want="$(printf '%s' "$FAKE_PAYLOAD" | sha256sum | awk '{print $1}')"; fi
    printf '%s  kannaka\n' "$want" > "$dest"; exit 0 ;;
  *)
    [ "${FAKE_CURL_FAIL:-0}" = "1" ] && exit 23
    [ -n "${FAKE_CURL_SLEEP:-}" ] && sleep "$FAKE_CURL_SLEEP"
    [ -n "$dest" ] && { printf '%s' "$FAKE_PAYLOAD" > "$dest" || exit 23; }
    exit 0 ;;
esac
EOF
  cat > "$1/uname" <<'EOF'
#!/bin/sh
case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; *) echo Linux ;; esac
EOF
  # Same fence as the install.sh tests: each optional tool is a logging no-op
  # so the real one is never reached, wherever it lives.
  for t in claude ollama node npm brew sudo; do
    printf '#!/bin/sh\nprintf "%s %%s\\n" "$*" >> "${FAKE_LOG:-/dev/null}"\nexit 0\n' "$t" > "$1/$t"
  done
  chmod +x "$1/curl" "$1/uname" "$1"/claude "$1"/ollama "$1"/node "$1"/npm "$1"/brew "$1"/sudo
}

# Per-case options, reset before every case.
reset_opts() {
  CURL_FAIL=0; NO_SIDECAR=0; SIDECAR_EMPTY=0; SIDECAR=""; SEED="old"; INTERRUPT=0
  EXP_RC=1; EXP="unchanged"
}

# run_case <label>  — seeds ~/.local/bin/kannaka (SEED: old = OLD-BYTES, none =
# nothing installed, dir = a directory), runs the script with the options
# above, and asserts the exit code, what is left at the destination, and that
# no temp file or sidecar remains.
run_case() {
  label="$1"
  work="$(mktemp -d)"; bin="$work/stub"; home="$work/home"; dest="$home/.local/bin/kannaka"
  mkdir -p "$bin" "$home/.local/bin"
  make_stubs "$bin"

  case "$SEED" in
    none) ;;
    dir)  mkdir "$dest" ;;
    *)    printf 'OLD-BYTES' > "$dest"; chmod +x "$dest" ;;
  esac
  before=""; [ -f "$dest" ] && before="$(sha_of "$dest")"

  csleep=""; [ "$INTERRUPT" = 1 ] && csleep=1
  HOME="$home" PATH="$bin:/usr/bin:/bin" \
    FAKE_PAYLOAD="NEW-BYTES" FAKE_CURL_FAIL="$CURL_FAIL" FAKE_NO_SIDECAR="$NO_SIDECAR" \
    FAKE_SIDECAR_EMPTY="$SIDECAR_EMPTY" FAKE_SIDECAR_SHA="$SIDECAR" \
    FAKE_CURL_SLEEP="$csleep" FAKE_LOG="$work/curl.log" \
    sh "$SCRIPT" >"$work/out" 2>&1 &
  spid=$!
  if [ "$INTERRUPT" = 1 ]; then
    # TERM rather than INT: a non-interactive bash starts background jobs with
    # SIGINT ignored and the script cannot un-ignore it; its trap handles INT,
    # TERM and HUP identically.
    sleep 0.5; kill -TERM "$spid" 2>/dev/null
  fi
  wait "$spid"; rc=$?
  # Without the trap the shell dies while the stub curl is still sleeping and
  # the temp file only appears when the stub finishes; wait it out so the
  # leftover check is not racing the stub.
  [ "$INTERRUPT" = 1 ] && sleep 2

  bad=""
  [ "$rc" -eq "$EXP_RC" ] || bad="$bad rc=$rc(want $EXP_RC)"
  case "$EXP" in
    unchanged)
      if [ -f "$dest" ]; then [ "$(sha_of "$dest")" = "$before" ] || bad="$bad dest-bytes-changed"
      else bad="$bad dest-MISSING"; fi ;;
    absent)
      [ -e "$dest" ] && bad="$bad dest-EXISTS(installed-unverified)" ;;
    dir)
      [ -d "$dest" ] || bad="$bad dest-no-longer-a-directory"
      [ -z "$(ls -A "$dest" 2>/dev/null)" ] || bad="$bad file-moved-INTO-directory:$(ls -A "$dest" | tr '\n' ' ')" ;;
    *)
      if [ -f "$dest" ]; then
        [ "$(sha_of "$dest")" = "$(sha_of_string "$EXP")" ] || bad="$bad dest-bytes-not-$EXP"
        [ "$REAL_UNIX" = 1 ] && { [ -x "$dest" ] || bad="$bad dest-not-executable"; }
      else bad="$bad dest-MISSING"; fi ;;
  esac
  leftovers="$(find "$home/.local/bin" \( -name '*.download.*' -o -name '*.tmp' -o -name '*.sha256' \) 2>/dev/null)"
  [ -z "$leftovers" ] || bad="$bad leftover-temp:$leftovers"

  if [ -n "$bad" ]; then
    echo "FAIL [$label]:$bad"
    sed 's/^/    /' "$work/out"
    FAILS=$((FAILS + 1))
  else
    echo "ok   [$label]"
  fi
  LAST_OUT="$work/out"; LAST_LOG="$work/curl.log"; LAST_WORK="$work"
}
finish_case() { rm -rf "$LAST_WORK"; }
expect_line() {  # expect_line <label> <grep pattern> <what>
  grep -q -- "$2" "$LAST_OUT" || { echo "FAIL [$1]: output has no '$3' line"; sed 's/^/    /' "$LAST_OUT"; FAILS=$((FAILS + 1)); }
}
forbid_line() {  # forbid_line <label> <grep pattern> <what>
  ! grep -q -- "$2" "$LAST_OUT" || { echo "FAIL [$1]: output claims '$3'"; sed 's/^/    /' "$LAST_OUT"; FAILS=$((FAILS + 1)); }
}

# THE FIX (#26a): a missing sidecar is fatal. Fresh machine: nothing installed.
# Existing install: untouched. Either way the script says why and never says
# "installed" or "verified".
reset_opts; NO_SIDECAR=1; SEED=none; EXP=absent; run_case "missing-sidecar-installs-nothing"
expect_line "missing-sidecar-installs-nothing" 'refusing to install' 'refusing to install'
forbid_line "missing-sidecar-installs-nothing" 'installed:' 'installed'
forbid_line "missing-sidecar-installs-nothing" 'sha256 verified' 'sha256 verified'
finish_case
reset_opts; NO_SIDECAR=1; run_case "missing-sidecar-keeps-existing"
expect_line "missing-sidecar-keeps-existing" 'refusing to install' 'refusing to install'
finish_case
reset_opts; SIDECAR_EMPTY=1; run_case "empty-sidecar-keeps-existing"
expect_line "empty-sidecar-keeps-existing" 'was empty' 'checksum was empty'
finish_case

# The other failure paths leave the existing binary exactly as it was.
reset_opts; SIDECAR="$(sha_of_string 'WRONG')"; run_case "sha-mismatch-keeps-existing"
expect_line "sha-mismatch-keeps-existing" 'sha256 mismatch' 'sha256 mismatch'
finish_case
reset_opts; CURL_FAIL=1; run_case "download-fails-keeps-existing"; finish_case

# A good download replaces the file in place with the verified bytes.
reset_opts; EXP_RC=0; EXP=NEW-BYTES; run_case "verified-download-replaces-existing"
expect_line "verified-download-replaces-existing" 'sha256 verified' 'sha256 verified'
finish_case
reset_opts; EXP_RC=0; EXP=NEW-BYTES; SEED=none; run_case "verified-download-fresh-install"; finish_case

# A directory at the destination: `mv` would drop the file INSIDE it and the
# script would print "installed". It must refuse and leave the directory empty.
reset_opts; SEED=dir; EXP=dir; run_case "directory-dest-refused"
expect_line "directory-dest-refused" 'is a directory' 'is a directory'
finish_case

# THE FIX (#26b): two installs at once get DISTINCT per-run temp names (the
# old fixed "kannaka.tmp" / "kannaka.sha256" were shared), and both succeed.
label="concurrent-installs-distinct-temps"
work="$(mktemp -d)"; bin="$work/stub"; home="$work/home"; dest="$home/.local/bin/kannaka"
mkdir -p "$bin" "$home/.local/bin"; make_stubs "$bin"
printf 'OLD-BYTES' > "$dest"; chmod +x "$dest"
for i in 1 2; do
  HOME="$home" PATH="$bin:/usr/bin:/bin" FAKE_PAYLOAD="NEW-BYTES" FAKE_CURL_SLEEP=1 FAKE_LOG="$work/curl.$i.log" \
    sh "$SCRIPT" >"$work/out.$i" 2>&1 &
  eval "p$i=\$!"
done
wait "$p1"; rc1=$?; wait "$p2"; rc2=$?
bad=""
[ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] || bad="$bad rc=$rc1/$rc2"
[ -f "$dest" ] && [ "$(sha_of "$dest")" = "$(sha_of_string NEW-BYTES)" ] || bad="$bad dest-bytes-not-NEW-BYTES"
t1="$(sed -n 's/.* -> \(.*kannaka\.download\.[0-9][0-9]*\)$/\1/p' "$work/curl.1.log" | head -1)"
t2="$(sed -n 's/.* -> \(.*kannaka\.download\.[0-9][0-9]*\)$/\1/p' "$work/curl.2.log" | head -1)"
[ -n "$t1" ] && [ -n "$t2" ] || bad="$bad temp-name-not-per-run:$(cat "$work"/curl.*.log | tr '\n' ' ')"
[ "$t1" != "$t2" ] || bad="$bad same-temp-name:$t1"
s1="$(sed -n 's/.*\.sha256 -> \(.*\)$/\1/p' "$work/curl.1.log" | head -1)"
s2="$(sed -n 's/.*\.sha256 -> \(.*\)$/\1/p' "$work/curl.2.log" | head -1)"
[ -n "$s1" ] && [ "$s1" != "$s2" ] || bad="$bad same-sidecar-name:$s1"
leftovers="$(find "$home/.local/bin" \( -name '*.download.*' -o -name '*.tmp' -o -name '*.sha256' \) 2>/dev/null)"
[ -z "$leftovers" ] || bad="$bad leftover-temp:$leftovers"
if [ -n "$bad" ]; then
  echo "FAIL [$label]:$bad"; sed 's/^/    /' "$work"/out.* "$work"/curl.*.log; FAILS=$((FAILS + 1))
else echo "ok   [$label]"; fi
rm -rf "$work"

if [ "$REAL_UNIX" = 1 ]; then
  # Ctrl-C mid-download: the trap must remove the temp file and the existing
  # binary must be untouched. The shell exits 130.
  reset_opts; INTERRUPT=1; EXP_RC=130; run_case "interrupt-mid-download-leaves-no-temp"; finish_case
else
  echo "skip [interrupt-mid-download-leaves-no-temp] (needs job control; got $(uname -s))"
fi

rm -rf "$SCRATCH"
[ "$FAILS" -eq 0 ] && echo "plugin-install-binary.sh: all cases passed" || { echo "plugin-install-binary.sh: $FAILS failed"; exit 1; }
