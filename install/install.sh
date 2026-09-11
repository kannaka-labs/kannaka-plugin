#!/bin/sh
# Kannaka one-shot installer (macOS / Linux).
#
# Binary-FIRST and Claude-OPTIONAL: the kannaka memory engine is a standalone
# binary that works with or without Claude Code. This installer always installs
# the binary first (the only requirement is being able to download it), puts it
# on PATH, and verifies it runs. THEN, if Claude Code is detected, it wires up
# the plugin + live statusline as a bonus — and if it isn't, it says so and
# finishes successfully rather than failing.
#
# Pass --with-claude to also install Node.js + Claude Code when missing (opt-in;
# off by default so standalone users aren't forced into a Node/Claude install).
#
# Idempotent — safe to re-run. Run directly:
#   curl -fsSL https://raw.githubusercontent.com/kannaka-labs/kannaka-plugin/master/install/install.sh | sh
RELEASE_REPO="${KANNAKA_RELEASE_REPO:-kannaka-labs/kannaka-memory}"
TUI_REPO="${KANNAKA_TUI_REPO:-kannaka-labs/kannaka-tui}"
INSTALL_URL="https://raw.githubusercontent.com/kannaka-labs/kannaka-plugin/master/install/install.sh"
WITH_CLAUDE=0
SKIP_TUI=0
# Constellation Pass credentials. Accepted as flags or environment so the
# portal can hand a subscriber one line that works, and so a re-run without
# them leaves an existing credential file untouched rather than blanking it.
NATS_USER_ARG="${KANNAKA_NATS_USER:-}"
NATS_PASS_ARG="${KANNAKA_NATS_PASSWORD:-}"
CLAIM=0
CLAIM_ONLY=0
PORTAL_API="${KANNAKA_PORTAL_API:-https://ninja-portal.com}"
# The constellation manifest: one signed document naming every component's
# pinned release, asset URL and sha256. Read first, so an install is a
# COHERENT SET rather than whatever each repo's `latest` happened to be when
# each download ran. Unreachable manifest = fall back to `latest` and say so.
MANIFEST_URL="${KANNAKA_MANIFEST:-https://ninja-portal.com/constellation.tsv}"
# The fallback is a RELEASE asset, not a Pages URL. When the constellation moved
# into an organisation, every other URL shape redirected and Pages did not:
# <old-owner>.github.io/<repo> simply 404s afterwards. A release download URL
# redirects like a repository does, so this survives the next move too.
MANIFEST_FALLBACK="https://github.com/kannaka-labs/kannaka-library/releases/download/library/constellation.tsv"
MANIFEST=""            # path to the verified copy, empty when unavailable
MANIFEST_STATE="none"  # none | unsigned | signed
NO_MANIFEST=0
SKIP_HDL=0
BRAIN=""               # local | hosted | none (empty = say how, do nothing)
BRAIN_EMAIL="${KANNAKA_BRAIN_EMAIL:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --with-claude) WITH_CLAUDE=1 ;;
    --skip-statusline) SKIP_STATUSLINE=1 ;;
    --skip-tui) SKIP_TUI=1 ;;
    --nats-user) NATS_USER_ARG="${2:-}"; shift ;;
    --nats-password) NATS_PASS_ARG="${2:-}"; shift ;;
    --nats-user=*) NATS_USER_ARG="${1#*=}" ;;
    --nats-password=*) NATS_PASS_ARG="${1#*=}" ;;
    --claim) CLAIM=1 ;;
    --no-manifest) NO_MANIFEST=1 ;;
    --manifest) MANIFEST_URL="${2:-}"; shift ;;
    --manifest=*) MANIFEST_URL="${1#*=}" ;;
    --skip-hdl) SKIP_HDL=1 ;;
    # A brain is what makes `kannaka ask` answer in her voice. Local runs the
    # open weights under ollama and costs nothing; hosted mints a budgeted key
    # against ninja-portal.com/v1. Neither is done unless asked for.
    --brain) BRAIN="${2:-}"; shift ;;
    --brain=*) BRAIN="${1#*=}" ;;
    --email) BRAIN_EMAIL="${2:-}"; shift ;;
    --email=*) BRAIN_EMAIL="${1#*=}" ;;
    # Link a pass on a machine that already has the engine. This is what the
    # double-clickable launcher runs, so it must not spend a minute
    # re-downloading binaries the user already has.
    --claim-only) CLAIM=1; CLAIM_ONLY=1 ;;
  esac
  shift
done

say()  { printf '\033[36m▸\033[0m %s\n' "$1"; }
warn() { printf '\033[33m!\033[0m %s\n' "$1" >&2; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ───────────────────────────────────────────────────────────────────────────
# THE MANIFEST
#
# constellation.tsv is the shell-readable half of constellation.json: one line
# per fact, tab separated, so `awk` is the entire parser and this script keeps
# its "no dependencies" promise. It is served from ninja-portal.com and
# mirrored on GitHub Pages, and it is signed with the constellation's ed25519
# key.
#
# The signature is checked when openssl can do it (OpenSSL 3 `pkeyutl -rawin`;
# LibreSSL, which is what macOS ships as `openssl`, cannot, and Homebrew's
# openssl3 is looked for by path). It is defence in depth rather than the only
# defence: every asset this script installs is checked against the sha256 the
# manifest carries, so a tampered manifest still cannot make an unverified
# binary land on disk — it can only name a different, real, hashed file.
# ───────────────────────────────────────────────────────────────────────────
MANIFEST_PUB_URL="${KANNAKA_MANIFEST_PUB:-https://github.com/kannaka-labs/kannaka-library/releases/download/library/manifest.pub}"

openssl3() {
  for c in /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl openssl; do
    if command -v "$c" >/dev/null 2>&1 && "$c" version 2>/dev/null | grep -q '^OpenSSL 3'; then
      printf '%s' "$c"; return 0
    fi
  done
  return 1
}

load_manifest() {
  [ "$NO_MANIFEST" = "1" ] && { say "Manifest skipped (--no-manifest); using each repo's latest release."; return 1; }
  have curl || return 1
  lm_tmp="${TMPDIR:-/tmp}/kannaka-manifest.$$"
  # Remember WHICH url served it. The signature is fetched from alongside the
  # manifest, and deriving it from $MANIFEST_URL regardless meant every install
  # that fell back looked for a signature next to a url that had just failed —
  # so a fallback install silently reported "unsigned" and skipped the check.
  lm_from="$MANIFEST_URL"
  if ! curl -fsSL --max-time 20 "$MANIFEST_URL" -o "$lm_tmp" 2>/dev/null; then
    lm_from="$MANIFEST_FALLBACK"
    curl -fsSL --max-time 20 "$MANIFEST_FALLBACK" -o "$lm_tmp" 2>/dev/null || {
      rm -f "$lm_tmp"
      warn "Could not fetch the constellation manifest — falling back to each repo's latest release."
      return 1
    }
  fi
  # A file that is not the manifest is worse than no manifest: it would make
  # every lookup miss silently and the install would quietly de-pin itself.
  if ! head -1 "$lm_tmp" | grep -q '^# kannaka-constellation/1'; then
    rm -f "$lm_tmp"; warn "The manifest did not look like a manifest — using latest releases."; return 1
  fi
  MANIFEST="$lm_tmp"; MANIFEST_STATE="unsigned"
  if ssl=$(openssl3) && curl -fsSL --max-time 20 "${lm_from}.sig" -o "$lm_tmp.sig" 2>/dev/null \
     && curl -fsSL --max-time 20 "$MANIFEST_PUB_URL" -o "$lm_tmp.pub" 2>/dev/null; then
    if base64 -d < "$lm_tmp.sig" > "$lm_tmp.sigraw" 2>/dev/null || base64 -D < "$lm_tmp.sig" > "$lm_tmp.sigraw" 2>/dev/null; then
      if "$ssl" pkeyutl -verify -pubin -inkey "$lm_tmp.pub" -rawin -in "$lm_tmp" -sigfile "$lm_tmp.sigraw" >/dev/null 2>&1; then
        MANIFEST_STATE="signed"
      else
        # A manifest that fails its own signature is the one case where
        # falling back is right: prefer no manifest to a bad one.
        rm -f "$lm_tmp" "$lm_tmp.sig" "$lm_tmp.pub" "$lm_tmp.sigraw"
        MANIFEST=""; MANIFEST_STATE="none"
        warn "The manifest's signature did NOT verify — ignoring it and using latest releases."
        return 1
      fi
    fi
  fi
  rm -f "$lm_tmp.sig" "$lm_tmp.pub" "$lm_tmp.sigraw"
  mf_gen=$(head -1 "$MANIFEST" | awk -F'\t' '{print $3}')
  ok "Manifest loaded (${MANIFEST_STATE}, generated ${mf_gen})"
  return 0
}

# manifest_asset <component> <target>  ->  "url<TAB>sha256" on stdout
manifest_asset() {
  [ -n "$MANIFEST" ] || return 1
  awk -F'\t' -v c="$1" -v t="$2" '$1=="asset" && $2==c && $4==t {print $5 "\t" $6; found=1; exit} END{exit !found}' "$MANIFEST"
}
manifest_version() {
  [ -n "$MANIFEST" ] || return 1
  awk -F'\t' -v c="$1" '$1=="component" && $2==c {print $3; found=1; exit} END{exit !found}' "$MANIFEST"
}
manifest_field() { # manifest_field <kind> <id> <column>
  [ -n "$MANIFEST" ] || return 1
  awk -F'\t' -v k="$1" -v i="$2" -v n="$3" '$1==k && $2==i {print $n; found=1; exit} END{exit !found}' "$MANIFEST"
}

# The rc file THIS user's interactive shell will actually read, created if it
# does not exist yet.
#
# The previous version picked the right file and then threw it away:
#
#   case "$SHELL" in *zsh) rc="$HOME/.zshrc";; esac
#   [ -f "$rc" ] || rc="$HOME/.profile"     # <- here
#
# A fresh macOS account has no ~/.zshrc, so that fallback fired and wrote both
# the PATH line and the swarm credentials into ~/.profile — which zsh does not
# read for interactive shells. The install reported success and then `kannaka`
# was command-not-found forever, with NATS_USER unset to match. Hit by a real
# subscriber on 2026-08-23.
#
# A missing rc file is not a reason to write somewhere else; it is a reason to
# create it. Only a shell we cannot identify falls back to ~/.profile.
shell_rc() {
  rc=""
  case "${SHELL:-}" in
    *zsh)  rc="$HOME/.zshrc" ;;
    *bash)
      # bash on macOS reads ~/.bash_profile for login shells and ignores
      # ~/.bashrc; Terminal opens login shells. Prefer an existing
      # ~/.bash_profile so the line is somewhere that is actually sourced.
      if [ "$(uname -s 2>/dev/null)" = "Darwin" ] && [ -f "$HOME/.bash_profile" ]; then
        rc="$HOME/.bash_profile"
      else
        rc="$HOME/.bashrc"
      fi
      ;;
    *)     rc="$HOME/.profile" ;;
  esac
  [ -e "$rc" ] || : > "$rc"
  printf '%s' "$rc"
}

say "Kannaka installer"

# ───────────────────────────────────────────────────────────────────────────
# 1. CORE: the kannaka binary → ~/.local/bin
#    The product. Needs nothing but a download — no Node, no Claude. Failure
#    here is fatal; everything after is best-effort enhancement.
# ───────────────────────────────────────────────────────────────────────────
set -eu
DEST="$HOME/.local/bin"; mkdir -p "$DEST"
os=$(uname -s); arch=$(uname -m)
case "$os" in Linux*) o=linux ;; Darwin*) o=macos ;; *) warn "unsupported OS: $os"; exit 1 ;; esac
case "$arch" in x86_64|amd64) a=x86_64 ;; aarch64|arm64) a=aarch64 ;; *) warn "unsupported arch: $arch"; exit 1 ;; esac
base="https://github.com/$RELEASE_REPO/releases/latest/download"

# sha256_of <file>  ->  lowercase hex digest on stdout; returns 1 (and warns)
# when no sha256 tool exists, so a caller can fail closed.
sha256_of() {
  if have sha256sum; then sha256sum "$1" | awk '{print $1}'
  elif have shasum; then shasum -a 256 "$1" | awk '{print $1}'
  else warn "no sha256 tool (sha256sum/shasum) available — cannot verify"; return 1
  fi
}

# Download one release asset and refuse to install it unverified.
#
# Was inline for the single binary; a second one (the TUI) made copying it the
# obvious move and the wrong one — a checksum check that exists twice is a
# checksum check that gets weakened once.
#
# THE TEMP+MV RULE: never curl onto the destination path. Download to a
# per-destination temp file ("$dest.download.$$"), verify THAT, chmod it, and
# `mv -f` it over the destination. rename(2) replaces a busy inode atomically —
# processes already running the old binary keep it, and a new invocation gets
# the new one. Every failure path removes only the temp file and never touches
# an existing destination, so a refused install leaves nothing executable
# behind AND leaves whatever was already installed exactly as it was.
#
# Why: on 2026-09-11 a real user re-ran this installer while `kannaka` was
# running. Linux refuses to open an executing binary for write (ETXTBSY), curl
# exited 23, and the failure path's `rm -f "$dest"` deleted the user's working
# binary — there was no partial download to clean up, only the install itself.
# (Per-destination temp names also matter on their own: a shared one raced when
# two installs ran at once and would verify the wrong file against the wrong
# digest.)
#
#   fetch_verified <repo> <asset-name> <destination-path> <label>
fetch_verified() {
  fv_repo="$1"; fv_asset="$2"; fv_dest="$3"; fv_label="$4"
  fv_base="https://github.com/$fv_repo/releases/latest/download"
  fv_tmp="${fv_dest}.download.$$"
  fv_sha="${fv_tmp}.sha"

  say "Downloading $fv_label ($fv_asset)…"
  if ! curl -fSL "$fv_base/$fv_asset" -o "$fv_tmp"; then
    warn "Failed to download $fv_asset from $fv_base — check your internet connection."
    rm -f "$fv_tmp"; return 1
  fi
  # The release always publishes a per-file .sha256 (Sigstore + checksums
  # trust). A MISSING checksum means we cannot verify — fail closed rather than
  # install an unverified binary. (Verification used to be nested inside the
  # download's `if`, so a missing .sha256 silently skipped it.)
  if ! curl -fsSL "$fv_base/$fv_asset.sha256" -o "$fv_sha"; then
    warn "checksum $fv_asset.sha256 could not be downloaded — refusing to install an unverified binary"
    rm -f "$fv_tmp" "$fv_sha"; return 1
  fi
  fv_want=$(awk '{print $1}' "$fv_sha"); rm -f "$fv_sha"
  if [ -z "$fv_want" ]; then
    warn "checksum $fv_asset.sha256 was empty — refusing to install unverified"
    rm -f "$fv_tmp"; return 1
  fi
  if ! fv_got=$(sha256_of "$fv_tmp"); then
    rm -f "$fv_tmp"; return 1
  fi
  if [ "$fv_want" != "$fv_got" ]; then
    warn "$fv_label sha256 mismatch (want $fv_want got $fv_got)"
    rm -f "$fv_tmp"; return 1
  fi
  say "sha256 verified"
  if ! chmod +x "$fv_tmp" || ! mv -f "$fv_tmp" "$fv_dest"; then
    warn "could not move the verified $fv_label into place at $fv_dest"
    rm -f "$fv_tmp"; return 1
  fi
  ok "$fv_label installed → $fv_dest"
}

# Download a component the manifest pinned: an exact URL and an exact sha256,
# neither of them derived from a repo name or from "latest". Falls back to the
# release-latest path when the component is not in the manifest, so a new
# component works before the manifest knows about it. Same temp+mv rule as
# fetch_verified (see there for why); and when the installed file already
# matches the pinned sha256 there is nothing to download at all.
fetch_pinned() {
  fp_comp="$1"; fp_repo="$2"; fp_asset="$3"; fp_dest="$4"; fp_label="$5"
  if fp_row=$(manifest_asset "$fp_comp" "${o}-${a}" 2>/dev/null) && [ -n "$fp_row" ]; then
    fp_url=$(printf '%s' "$fp_row" | cut -f1)
    fp_want=$(printf '%s' "$fp_row" | cut -f2)
    fp_ver=$(manifest_version "$fp_comp" 2>/dev/null || printf 'pinned')
    if [ -n "$fp_url" ] && [ "$fp_url" != "-" ] && [ -n "$fp_want" ] && [ "$fp_want" != "-" ]; then
      # Short-circuit: the pinned bytes are already on disk. The 2026-09-11
      # incident was a same-version re-install — the download was a no-op that
      # still destroyed the install. Now it is a no-op that does nothing.
      if [ -f "$fp_dest" ] && fp_have=$(sha256_of "$fp_dest" 2>/dev/null) && [ "$fp_have" = "$fp_want" ]; then
        chmod +x "$fp_dest" 2>/dev/null || true
        ok "$fp_label $fp_ver already installed and verified → $fp_dest"
        return 0
      fi
      fp_tmp="${fp_dest}.download.$$"
      say "Downloading $fp_label $fp_ver (pinned)…"
      if ! curl -fSL "$fp_url" -o "$fp_tmp"; then
        warn "Failed to download $fp_label from $fp_url"; rm -f "$fp_tmp"; return 1
      fi
      if ! fp_got=$(sha256_of "$fp_tmp"); then
        rm -f "$fp_tmp"; return 1
      fi
      if [ "$fp_want" != "$fp_got" ]; then
        warn "$fp_label sha256 mismatch against the manifest (want $fp_want got $fp_got)"
        rm -f "$fp_tmp"; return 1
      fi
      say "sha256 verified against the manifest"
      if ! chmod +x "$fp_tmp" || ! mv -f "$fp_tmp" "$fp_dest"; then
        warn "could not move the verified $fp_label into place at $fp_dest"
        rm -f "$fp_tmp"; return 1
      fi
      ok "$fp_label $fp_ver installed → $fp_dest"
      return 0
    fi
  fi
  fetch_verified "$fp_repo" "$fp_asset" "$fp_dest" "$fp_label"
}

if [ "$CLAIM_ONLY" != "1" ]; then
  set +e; load_manifest; set -e
fi

[ "$CLAIM_ONLY" = "1" ] || fetch_pinned "kannaka" "$RELEASE_REPO" "kannaka-${o}-${a}" "$DEST/kannaka" "kannaka" || exit 1

# ───────────────────────────────────────────────────────────────────────────
# 2. PATH: make sure ~/.local/bin is reachable, or `kannaka` looks like it
#    "did nothing" on a fresh machine (the #1 silent-failure cause).
# ───────────────────────────────────────────────────────────────────────────
case ":$PATH:" in
  *":$DEST:"*) ;;  # already there
  *)
    # Persist to the user's shell rc (guarded + idempotent), and export for now.
    rc="$(shell_rc)"
    if ! grep -qs '\.local/bin' "$rc" 2>/dev/null; then
      printf '\n# kannaka\ncase ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac\n' >> "$rc"
      say "Added ~/.local/bin to PATH in $rc — open a NEW terminal for 'kannaka' to be found."
    fi
    export PATH="$DEST:$PATH"
    ;;
esac

# Verify it runs (surface a broken download instead of silence).
if ver=$("$DEST/kannaka" --version 2>/dev/null | head -1); then
  [ -n "$ver" ] && ok "kannaka is working: $ver"
else
  warn "kannaka installed but '--version' failed to run."
fi

# ───────────────────────────────────────────────────────────────────────────
# 2b. THE DASHBOARD: kannaka-tui → ~/.local/bin
#
# Its own repo and its own releases since the binary was extracted at v0.5.12,
# with the same asset naming, so it rides the same verified download. Not fatal
# if it fails: the engine is the product and a missing dashboard must not cost
# somebody a working install.
#
# (consciousness-core is deliberately NOT here. It is a LIBRARY — no [[bin]],
# no main.rs — compiled into the kannaka binary above, so anyone who has
# kannaka already has its physics. There is nothing separate to install.)
# ───────────────────────────────────────────────────────────────────────────
if [ "$SKIP_TUI" != "1" ] && [ "$CLAIM_ONLY" != "1" ]; then
  set +e
  fetch_pinned "kannaka-tui" "$TUI_REPO" "kannaka-tui-${o}-${a}" "$DEST/kannaka-tui" "kannaka-tui"
  tui_rc=$?
  set -e
  [ "$tui_rc" -eq 0 ] || warn "kannaka-tui was not installed — the engine is fine; re-run to retry."
fi

# ───────────────────────────────────────────────────────────────────────────
# 2b-ii. THE LANGUAGE: kannaka-hdl → ~/.local/bin
#
# KannakaHDL grows an architecture against a registry of what a machine
# actually has, and refuses when a part has no honest answer. It is what the
# `mind` app runs to ask "is this citizen whole?", so it belongs in the same
# install as the engine rather than in a separate errand. Not fatal.
# ───────────────────────────────────────────────────────────────────────────
if [ "$SKIP_HDL" != "1" ] && [ "$CLAIM_ONLY" != "1" ]; then
  set +e
  fetch_pinned "kannaka-hdl" "kannaka-labs/kannaka-hdl" "kannaka-hdl-${o}-${a}" "$DEST/kannaka-hdl" "kannaka-hdl"
  hdl_rc=$?
  set -e
  [ "$hdl_rc" -eq 0 ] || warn "kannaka-hdl was not installed — the engine is fine; re-run to retry."
fi

# ───────────────────────────────────────────────────────────────────────────
# 2c. CONSTELLATION PASS: authenticated swarm credentials.
#
# `kannaka swarm serve` and `listen --auto-sync` need an AUTHENTICATED NATS
# connection; anonymous is read-only. The binary reads `NATS_USER` /
# `NATS_PASSWORD` from the ENVIRONMENT (src/nats.rs, precedence: explicit >
# env > url), and the documented home for them is ~/.kannaka-nats.env.
#
# Nothing ever put them in the environment for a person. The systemd units and
# the auth cron `source` that file explicitly; an interactive shell never did.
# So a subscriber could write their credentials in exactly the documented place
# and still connect anonymously — paying for a tier their terminal could not
# reach. Writing the file is only half the job; the shell has to load it.
# ───────────────────────────────────────────────────────────────────────────
CREDS="$HOME/.kannaka-nats.env"

# Collect credentials without ever putting one on a command line.
#
# `--nats-user U --nats-password P` works and is kept, but it writes both
# secrets into shell history and into the process table. `--claim` asks the
# portal for a claim, shows a SHORT code, and waits while the subscriber
# approves that code on their pass page. Nothing secret is typed here and
# nothing secret is echoed.
#
# Best-effort by design: a portal that is down, a person who wanders off, a
# box with no `curl` — none of that should cost somebody a working engine, so
# every failure warns and falls through to the anonymous read-only swarm.
claim_credentials() {
  have curl || { warn "--claim needs curl"; return 1; }
  cl_start=$(curl -fsS -X POST -H 'content-type: application/json' -d '{}' \
    "$PORTAL_API/api/claim/start" 2>/dev/null) || { warn "could not reach $PORTAL_API"; return 1; }

  # sed rather than a JSON parser: `jq` is not a reasonable prerequisite for an
  # installer, and these three fields are flat strings the portal emits itself.
  cl_id=$(printf '%s' "$cl_start" | sed -n 's/.*"claim_id" *: *"\([a-f0-9]*\)".*/\1/p')
  cl_code=$(printf '%s' "$cl_start" | sed -n 's/.*"user_code" *: *"\([A-Z0-9-]*\)".*/\1/p')
  cl_url=$(printf '%s' "$cl_start" | sed -n 's/.*"verify_url" *: *"\([^"]*\)".*/\1/p')
  [ -n "$cl_id" ] && [ -n "$cl_code" ] || { warn "the portal did not return a claim"; return 1; }

  printf '\n'
  say "To link your Constellation Pass, open:"
  say "    ${cl_url:-$PORTAL_API/link}"
  say "and enter this code:"
  printf '\n        \033[1m%s\033[0m\n\n' "$cl_code"
  say "Waiting for approval (Ctrl-C to skip)…"

  # ~10 minutes at 5s, matching the claim's own TTL, so the loop and the
  # server stop caring at the same moment rather than one outliving the other.
  cl_n=0
  while [ "$cl_n" -lt 120 ]; do
    sleep 5
    cl_n=$((cl_n + 1))
    cl_poll=$(curl -fsS -X POST -H 'content-type: application/json' \
      -d "{\"claim_id\":\"$cl_id\"}" "$PORTAL_API/api/claim/poll" 2>/dev/null) || continue
    case "$cl_poll" in
      *'"status":"approved"'*|*'"status": "approved"'*)
        NATS_USER_ARG=$(printf '%s' "$cl_poll" | sed -n 's/.*"nats_user" *: *"\([^"]*\)".*/\1/p')
        NATS_PASS_ARG=$(printf '%s' "$cl_poll" | sed -n 's/.*"nats_password" *: *"\([^"]*\)".*/\1/p')
        [ -n "$NATS_USER_ARG" ] && [ -n "$NATS_PASS_ARG" ] || { warn "approval returned no credentials"; return 1; }
        ok "Pass linked as $NATS_USER_ARG"
        return 0 ;;
      *'"status":"expired"'*|*'"status": "expired"'*)
        warn "that claim expired before it was approved — re-run to try again"; return 1 ;;
    esac
  done
  warn "no approval within ten minutes — re-run with --claim to try again"
  return 1
}

if [ "$CLAIM" = "1" ] && { [ -z "$NATS_USER_ARG" ] || [ -z "$NATS_PASS_ARG" ]; }; then
  set +e; claim_credentials; set -e
fi

# Quote a value so that sourcing the file assigns it verbatim.
#
# This file is `.`-sourced by the user's shell, so an unquoted value is not a
# string — it is SHELL INPUT. A generated password containing a space assigns
# the first word and then RUNS the rest as a command; one containing `$(...)`
# or a backtick is arbitrary execution out of a 0600 file the user was told to
# trust. Single quotes disable every expansion, and the `'\''` dance is the
# POSIX way to carry a literal single quote through them.
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

if [ -n "$NATS_USER_ARG" ] && [ -n "$NATS_PASS_ARG" ]; then
  # 0600 BEFORE the secret goes in, not after: created with a default umask the
  # file is world-readable for the moment in between, which is the window that
  # matters on a shared box.
  ( umask 077; : > "$CREDS" )
  printf '# Kannaka Constellation Pass — swarm credentials.\n# Written by the installer. Sourced by your shell rc; keep it 0600.\nexport NATS_USER=%s\nexport NATS_PASSWORD=%s\n' \
    "$(shq "$NATS_USER_ARG")" "$(shq "$NATS_PASS_ARG")" > "$CREDS"
  chmod 600 "$CREDS"
  ok "Constellation Pass credentials written → $CREDS"
elif [ -f "$CREDS" ]; then
  say "Constellation Pass credentials already present → $CREDS"
else
  # ── The double-clickable way to link a pass ──────────────────────────────
  #
  # The .pkg runs this script from a postinstall, where there is no terminal:
  # a claim shows a code and then polls, and neither can happen inside a
  # graphical installer. So the engine installs, and the LINKING is left as one
  # thing to double-click.
  #
  # `.command` is the macOS extension that opens in Terminal on double-click —
  # it exists precisely for this. On Linux the same file is a normal executable
  # script; desktop environments vary too much to promise a double-click there,
  # so the file says how to run it.
  #
  # Written to the Desktop because a setup step nobody can find is a setup step
  # nobody performs. It removes itself once the pass is linked, so it is litter
  # for exactly as long as it is useful.
  desk="$HOME/Desktop"
  [ -d "$desk" ] || desk="$HOME"
  launcher="$desk/Link Kannaka.command"
  cat > "$launcher" <<LAUNCHER
#!/bin/sh
# Links your Constellation Pass to this machine. Double-click me.
# Deletes itself once the pass is linked.
cd "\$(dirname "\$0")" 2>/dev/null || true
printf '\n  Linking your Constellation Pass…\n\n'
if curl -fsSL "$INSTALL_URL" | sh -s -- --claim-only; then
  printf '\n  Done. You can close this window.\n\n'
  rm -f "\$0"
else
  printf '\n  That did not complete. You can double-click this again to retry.\n\n'
fi
printf '  Press return to close.'
read _ignored
LAUNCHER
  chmod +x "$launcher"
  printf '\n'
  ok "Engine installed. One step left: your Constellation Pass is not linked yet."
  say "Double-click \"Link Kannaka.command\" on your Desktop to finish."
  say "(or run:  curl -fsSL $INSTALL_URL | sh -s -- --claim-only)"
fi

# Make an interactive shell actually load them. Guarded and idempotent, same
# shape as the PATH block above, and pointed at the file rather than carrying
# the secret itself — so rotating credentials is one file write and no rc edit.
if [ -f "$CREDS" ]; then
  crc="$(shell_rc)"
  if ! grep -qs 'kannaka-nats.env' "$crc" 2>/dev/null; then
    printf '\n# kannaka swarm credentials\n[ -f "$HOME/.kannaka-nats.env" ] && . "$HOME/.kannaka-nats.env"\n' >> "$crc"
    say "Shell will load your swarm credentials from $crc — open a NEW terminal."
  fi
  # Load them for the rest of THIS run too, so the check below is about the
  # credentials rather than about which terminal we happen to be in.
  # shellcheck disable=SC1090
  . "$CREDS" 2>/dev/null || true
fi


# ───────────────────────────────────────────────────────────────────────────
# 2d. THE BRAIN: what `kannaka ask` answers with.
#
# Kannaka's own model — Qwen2.5 with LoRA adapters trained on her words — runs
# two ways, and the choice is a config rather than a fork:
#
#   --brain local    open weights under ollama. Free, offline, ~4.7 GB.
#   --brain hosted   a budgeted key against ninja-portal.com/v1, mailed to
#                    --email. The gateway meters it; nothing here can overspend.
#
# Neither happens unless asked for: a 4.7 GB pull nobody requested is not a
# courtesy, and a key is tied to an email address the user has to choose to
# give. With no --brain, this prints the two commands and moves on.
#
# The result is the [llm] section of ~/.kannaka/config.toml, which is what
# `kannaka ask` reads. An existing [llm] block is left alone unless --brain was
# explicitly passed, so re-running the installer cannot silently repoint a
# machine that was already configured.
# ───────────────────────────────────────────────────────────────────────────
KCONF="$HOME/.kannaka/config.toml"

# Replace (or append) the [llm] table. Written to a temp file and moved into
# place so an interrupted write cannot leave a half-config that the binary
# then refuses to parse.
write_llm_config() {
  wl_provider="$1"; wl_model="$2"; wl_key="$3"; wl_base="$4"
  mkdir -p "$(dirname "$KCONF")"
  wl_tmp="$KCONF.tmp.$$"
  if [ -f "$KCONF" ]; then
    awk '
      /^\[llm\][[:space:]]*$/ { skip=1; next }
      /^\[/ { skip=0 }
      !skip { print }
    ' "$KCONF" > "$wl_tmp"
  else
    : > "$wl_tmp"
  fi
  {
    printf '\n[llm]\nprovider = "%s"\nmodel = "%s"\napi_key = "%s"\nbase_url = "%s"\n' \
      "$wl_provider" "$wl_model" "$wl_key" "$wl_base"
  } >> "$wl_tmp"
  ( umask 077; mv "$wl_tmp" "$KCONF" )
  chmod 600 "$KCONF" 2>/dev/null || true
}

brain_local() {
  if ! have ollama; then
    warn "--brain local needs ollama (https://ollama.com/download); skipping."
    return 1
  fi
  bl_model=$(manifest_field local brain 3 2>/dev/null || printf 'kannaka-brain')
  bl_from=$(manifest_field local brain 4 2>/dev/null || printf 'hf.co/flaukowski/kannaka-brain-7b-v1-GGUF')
  [ -n "$bl_model" ] && [ "$bl_model" != "-" ] || bl_model="kannaka-brain"
  [ -n "$bl_from" ] && [ "$bl_from" != "-" ] || bl_from="hf.co/flaukowski/kannaka-brain-7b-v1-GGUF"
  if ollama list 2>/dev/null | awk '{print $1}' | grep -q "^${bl_model}:"; then
    ok "ollama already has $bl_model"
  else
    say "Pulling $bl_from as $bl_model (about 4.7 GB — this takes a while)…"
    if ! ollama pull "$bl_from" >/dev/null 2>&1; then
      warn "ollama could not pull $bl_from; skipping the local brain."
      return 1
    fi
    ollama cp "$bl_from" "$bl_model" >/dev/null 2>&1 || true
    ok "local brain ready: $bl_model"
  fi
  write_llm_config openai "$bl_model" "ollama" "${OLLAMA_HOST:-http://127.0.0.1:11434}/v1"
  ok "kannaka ask → local $bl_model"
}

brain_hosted() {
  if [ -z "$BRAIN_EMAIL" ]; then
    warn "--brain hosted needs --email you@example.com (the key is mailed there); skipping."
    return 1
  fi
  have curl || { warn "--brain hosted needs curl"; return 1; }
  bh_base=$(manifest_field hosted brain 3 2>/dev/null || printf '%s/v1' "$PORTAL_API")
  [ -n "$bh_base" ] && [ "$bh_base" != "-" ] || bh_base="$PORTAL_API/v1"
  say "Requesting a hosted brain key for $BRAIN_EMAIL…"
  bh_body=$(printf '{"email":"%s","purpose":"installer"}' "$BRAIN_EMAIL")
  bh_out=$(curl -fsS -X POST -H 'content-type: application/json' -d "$bh_body" "$PORTAL_API/api/brain/key" 2>/dev/null) || bh_out=""
  bh_key=$(printf '%s' "$bh_out" | sed -n 's/.*"key" *: *"\([^"]*\)".*/\1/p')
  if [ -z "$bh_key" ]; then
    case "$bh_out" in
      *"already holds an active key"*)
        warn "That email already has an active key — it was mailed when issued. Re-run with --brain none and paste it into $KCONF." ;;
      *) warn "The portal did not issue a key. Get one at $PORTAL_API/brain" ;;
    esac
    return 1
  fi
  bh_model=$(manifest_field hosted brain 5 2>/dev/null | cut -d, -f1)
  [ -n "$bh_model" ] && [ "$bh_model" != "-" ] || bh_model="kannaka-brain-7b-v1"
  write_llm_config openai "$bh_model" "$bh_key" "$bh_base"
  ok "kannaka ask → hosted $bh_model at $bh_base"
  say "The key is budgeted and rate-limited by the gateway; usage at $PORTAL_API/brain#key"
}

if [ "$CLAIM_ONLY" != "1" ]; then
  set +e
  case "$BRAIN" in
    local)  brain_local ;;
    hosted) brain_hosted ;;
    none|"")
      if grep -qs '^\[llm\]' "$KCONF" 2>/dev/null; then
        say "Brain: leaving the [llm] section of $KCONF as it is."
      else
        printf '\n'
        say "No brain configured yet. 'kannaka ask' needs one:"
        say "    re-run with  --brain local                  (open weights under ollama, free)"
        say "    re-run with  --brain hosted --email you@…   (a budgeted key on our gateway)"
      fi ;;
    *) warn "unknown --brain '$BRAIN' (local | hosted | none)" ;;
  esac
  set -e
fi

# ───────────────────────────────────────────────────────────────────────────
# 3. OPTIONAL: Claude Code integration. Detect-and-enhance. Never fatal.
# ───────────────────────────────────────────────────────────────────────────
set +e

if ! have claude && [ "$WITH_CLAUDE" = "1" ]; then
  say "--with-claude set — installing Node.js + Claude Code…"
  if ! have node; then
    if have brew; then brew install node
    elif have apt-get; then curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - && sudo apt-get install -y nodejs
    elif have dnf; then sudo dnf install -y nodejs
    else warn "Could not auto-install Node.js — get it from https://nodejs.org/ then re-run with --with-claude."; fi
  fi
  have npm && npm install -g @anthropic-ai/claude-code
fi

if have claude; then
  say "Claude Code detected — registering marketplace + installing plugin…"
  claude plugin marketplace add kannaka-labs/kannaka-plugin >/dev/null 2>&1 || true
  claude plugin install kannaka@kannaka >/dev/null 2>&1 || true
  ok "kannaka plugin installed into Claude Code"
  if [ "${SKIP_STATUSLINE:-0}" != "1" ]; then
    setup=$(find "$HOME/.claude/plugins/cache/kannaka" -name setup.sh 2>/dev/null | sort -V | tail -1)
    if [ -n "$setup" ] && have bash; then say "Enabling statusline…"; bash "$setup" on || true
    else say "Statusline: run '/kannaka statusline on' inside Claude Code to enable."; fi
  fi
else
  printf '\n'
  ok "Kannaka is installed and works standalone — no Claude Code required."
  say "Try it:"
  say "    kannaka remember \"wave interference is how memory computes\" --importance 0.8"
  say "    kannaka recall \"how does memory work\""
  say "    kannaka dream --mode deep"
  printf '\n'
  say "Want the Claude Code plugin + live statusline too? Install Claude Code, then re-run"
  say "this installer (or pass --with-claude), or inside Claude run:"
  say "    claude plugin marketplace add kannaka-labs/kannaka-plugin"
  say "    claude plugin install kannaka@kannaka"
fi

printf '\n'
ok "Done. kannaka → $DEST/kannaka"
[ -x "$DEST/kannaka-tui" ] && ok "     kannaka-tui → $DEST/kannaka-tui"
[ -x "$DEST/kannaka-hdl" ] && ok "     kannaka-hdl → $DEST/kannaka-hdl"
if [ "$MANIFEST_STATE" != "none" ]; then
  ok "     versions pinned by the constellation manifest ($MANIFEST_STATE)"
fi
[ -n "${MANIFEST:-}" ] && rm -f "$MANIFEST"
if [ -n "${NATS_USER:-}" ]; then
  ok "     Constellation Pass: authenticated as $NATS_USER"
else
  printf '\n'
  say "Swarm access is ANONYMOUS (read-only). A Constellation Pass unlocks"
  say "'kannaka swarm serve' and 'listen --auto-sync'."
  if [ -n "${launcher:-}" ] && [ -f "${launcher:-}" ]; then
    # Point at the thing that was just put in front of them, not at a command
    # they would have to retype. The curl form stays as the second line for
    # anyone who would rather paste it.
    say "To link yours: double-click \"$(basename "$launcher")\" on your Desktop."
  else
    say "To link yours:  curl -fsSL $INSTALL_URL | sh -s -- --claim"
  fi
  say "It shows a short code to approve on your pass page — no password typed"
  say "into a terminal, and nothing secret left in your shell history."
fi
