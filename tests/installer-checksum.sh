#!/usr/bin/env bash
# Verifies install/install.sh FAILS CLOSED on a missing/mismatched checksum
# (the hard-fail-on-missing-checksum fix) rather than installing an unverified
# binary. Runs install.sh under stubbed curl / uname / sha256sum — no network,
# no real download. Exits non-zero if any case misbehaves.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALL_SH="$HERE/../install/install.sh"
FAILS=0

# label  sha_present  want  got  expect_rc  expect_binary(1/0)
run_case() {
  label="$1"; present="$2"; want="$3"; got="$4"; exp_rc="$5"; exp_bin="$6"
  work="$(mktemp -d)"; bin="$work/stub"; home="$work/home"
  mkdir -p "$bin" "$home"

  cat > "$bin/curl" <<'EOF'
#!/bin/sh
dest=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in -o) dest="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
done
case "$url" in
  *.sha256) [ "${FAKE_SHA_PRESENT:-1}" = "1" ] || exit 22
            printf '%s  kannaka\n' "${FAKE_WANT:-aaaa}" > "$dest" ;;
  *) [ -n "$dest" ] && printf 'BINARY-BYTES' > "$dest" ;;
esac
exit 0
EOF
  cat > "$bin/uname" <<'EOF'
#!/bin/sh
case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; *) echo Linux ;; esac
EOF
  cat > "$bin/sha256sum" <<'EOF'
#!/bin/sh
printf '%s  %s\n' "${FAKE_GOT:-aaaa}" "$1"
EOF
  chmod +x "$bin/curl" "$bin/uname" "$bin/sha256sum"
  # The installer's optional steps probe for these with `command -v`; each is
  # a no-op here so a dev box's real claude/node/npm are never touched, and
  # PATH is fenced to the stubs + the system dirs.
  for t in claude ollama node npm brew sudo; do
    printf '#!/bin/sh\nexit 0\n' > "$bin/$t"; chmod +x "$bin/$t"
  done

  HOME="$home" PATH="$bin:/usr/bin:/bin" FAKE_SHA_PRESENT="$present" FAKE_WANT="$want" FAKE_GOT="$got" \
    SKIP_STATUSLINE=1 sh "$INSTALL_SH" >"$work/out" 2>&1
  rc=$?
  have_bin=0; [ -f "$home/.local/bin/kannaka" ] && have_bin=1

  if [ "$rc" -ne "$exp_rc" ] || [ "$have_bin" -ne "$exp_bin" ]; then
    echo "FAIL [$label]: rc=$rc (want $exp_rc) binary=$have_bin (want $exp_bin)"
    sed 's/^/    /' "$work/out"
    FAILS=$((FAILS + 1))
  else
    echo "ok   [$label]"
  fi
  rm -rf "$work"
}

# THE FIX: a missing checksum must be fatal and leave no binary behind.
run_case "missing-checksum-hard-fails" 0 aaaa aaaa 1 0
# A mismatch must be fatal and leave no binary behind.
run_case "mismatch-fails"              1 beef dead 1 0
# A present + matching checksum installs successfully.
run_case "match-installs"              1 beef beef 0 1

[ "$FAILS" -eq 0 ] && echo "installer-checksum.sh: all cases passed" || { echo "installer-checksum.sh: $FAILS failed"; exit 1; }
