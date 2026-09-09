# Fresh install, receipt and sweep — installer implementation plan (kannaka-plugin)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `install/install.sh` and `install/install.ps1` the one definition of a kannaka install: they remove every recognised previous copy first, write a receipt last, and are proven to do both by tests that actually run them.

**Architecture:** Both installers stay single files (they are run by `curl | sh` and `irm | iex`, so they cannot source helpers). New behaviour is added as named functions the tests lift out with `sed` / a PowerShell regex, the way `tests/installer-checksum.sh` and `tests/installer-manifest.ps1` already do. The sweep runs before any download, never deletes by path, and logs into the receipt; the receipt is written atomically as the very last act. The binary side (`kannaka uninstall`, the widened `kannaka update`, the forwarders, npm) is the sibling plan in kannaka-memory: `docs/superpowers/plans/2026-09-09-fresh-install-binary.md` there.

**Tech Stack:** POSIX sh (`install.sh` is run by `sh`, not bash — no arrays, no `[[`, no `local`), Windows PowerShell 5.1-compatible PowerShell, bash test scripts with stubbed `curl`/`uname`/`sha256sum`/`brew`/`npm`/`claude`, GitHub Actions (`ubuntu-latest`, `windows-latest`).

**Spec:** `docs/superpowers/specs/2026-09-09-fresh-install-update-uninstall-design.md` (this repo, PR #19). Sections referenced below as §N.

## Global Constraints

- `install.sh` must stay valid POSIX sh: no bash-isms. Every new function uses the two-letter local-variable prefix convention the file already uses (`fv_`, `fp_`, `wl_` …), because POSIX sh has no `local`.
- **Never delete by path, only by identity** (§4): a file is removed only when its `--version` banner names a kannaka component. A file that does not identify is left in place and named in the output.
- **The receipt is written last and atomically** (§3): temp file in the same directory, then `mv`. Nothing else writes `install.json`. On any failure before the end, no receipt is written and the previous one is untouched.
- **The preserve set is never touched** (§5): `~/.kannaka/**` (or `KANNAKA_DATA_DIR`) other than `install.json` and, only with `--brain`, the `[llm]` section of `config.toml`; the `# kannaka` rc blocks; `~/.kannaka-nats.env`; services and scheduled tasks.
- Receipt path: `${KANNAKA_DATA_DIR:-$HOME/.kannaka}/install.json`, rotated to `install.json.1`, `.2`, `.3` (Ruling 2).
- Component names are exactly `kannaka`, `kannaka-tui`, `kannaka-hdl`. Real banners: `kannaka 0.16.0 (consciousness-core 0.6.0)`, `kannaka-tui 0.5.9`, `kannaka-hdl <ver>`. The first whitespace-separated word of the first line is the component; the second must start with a digit.
- The old owner may appear in this repo's install code in exactly two places, both inside the sweep: the brew tap `nickflach/kannaka` and the marketplace source `github:NickFlach/kannaka-plugin`, matched case-insensitively. Nowhere else.
- Every guard gets a mutation that is actually run (§9).
- Commit messages end with the trailer block the session uses (Co-Authored-By + Claude-Session).

## Rulings (decisions the spec leaves open, made here so every task agrees)

1. **The sweep runs before the download but does not unlink the three target paths** (`$DEST/kannaka`, `$DEST/kannaka-tui`, `$DEST/kannaka-hdl`). The download replaces them. Reason: unlinking first and then failing the download would leave a machine with no engine, worse than where it started. The sweep still *identity-checks* the targets: a target that exists and does **not** identify as its component aborts the install with exit 3 (`refusing to overwrite <path>: it is not kannaka`), because §4 says we never destroy something because of where it is. The targets are recorded in the receipt's `removed` with reason `replaced`.
2. **`previous` is three rotated files, not inline JSON.** POSIX sh has no JSON parser, and nesting three receipts inline would need one. `install.json` → `install.json.1` → `.2` → `.3` (oldest dropped) at receipt-write time; the new receipt's `"previous"` lists the rotated file names that exist. The spec's promise (the last three receipts, verbatim, readable) is kept with `mv`.
3. **`installer` is the script's canonical path plus a hand-bumped `INSTALLER_VERSION`**: `kannaka-labs/kannaka-plugin/install/install.sh@2`. A piped script cannot know its own commit. Bump the constant whenever the receipt's shape or the sweep table changes.
4. **The marketplace is re-registered by name.** Both the old and the new marketplace are named `kannaka` (plugin `kannaka@kannaka`), so the old one is detected by the old owner appearing in `claude plugin marketplace list`, removed with `claude plugin marketplace remove kannaka`, and the new one added by the existing code, which then runs `claude plugin install kannaka@kannaka` as today.
5. **A locked exe on Windows is parked, not skipped.** When `Remove-Item` fails on a recognised binary (it is running), rename it to `<name>.bak-<pid>`; the next `kannaka` or installer sweeps it (§6 already relies on that). Logged as removed with reason `parked`.
6. **The banner check has a timeout.** A foreign binary named `kannaka` could hang on `--version`. POSIX: `timeout 5` when available, plain otherwise; PowerShell: `Start-Process -PassThru` + `WaitForExit(5000)`.
7. **The PowerShell sweep covers both Windows install dirs.** The canonical target is `$HOME\.local\bin` (install.ps1 line 60); the OLD memory installer used `%LOCALAPPDATA%\Programs\kannaka`. Both are swept, and a user-PATH entry pointing at a directory that held a recognised binary and holds none afterwards is removed.
8. **Windows credentials are user-environment variables, not a file**, so the Windows receipt records `{"kind":"user-env","names":["NATS_USER","NATS_PASSWORD"]}` under `credentials`. The binary's receipt reader must accept both the file shape and this shape; that requirement is carried into the binary plan.

## File map

| file | responsibility |
|---|---|
| `install/install.sh` | flag `--keep-others`; functions `banner_component`, `file_sha256`, `json_str`, `log_removed`, `log_kept`, `remove_ours`, `remove_stale_beside`, `sweep_previous`, `write_receipt`; sweep called before the §1 download; receipt written at the end |
| `install/install.ps1` | switch `-KeepOthers`; functions `Invoke-VersionBanner`, `Get-BannerComponent`, `Get-FileSha256`, `Remove-Ours`, `Remove-StaleBeside`, `Get-UserPath`, `Set-UserPath`, `Invoke-Sweep`, `Write-Receipt`; same call sites |
| `tests/installer-lifecycle.sh` | executed fixtures: helpers, fresh-over-old with impostor, impostor-at-target aborts, `--keep-others`, receipt last and complete, rotation, preserve, identity-guard mutation |
| `tests/installer-lifecycle.ps1` | the same against the lifted PowerShell functions, plus the locked-exe case |
| `.github/workflows/ci.yml` | run both |
| `README.md` | document `--keep-others`, the receipt, and where `kannaka uninstall` lives |

---

### Task 1: Identity, hashing and JSON helpers in `install.sh`

**Files:**
- Modify: `install/install.sh` (insert after `have()` at line 77)
- Test: `tests/installer-lifecycle.sh` (create; this task adds the helper cases only)

**Interfaces:**
- Produces (POSIX sh functions, all lifted by tests with `sed -n '/^name() {/,/^}/p'`):
  - `banner_component <path>` → prints `kannaka` | `kannaka-tui` | `kannaka-hdl` and returns 0, or prints nothing and returns 1
  - `file_sha256 <path>` → prints 64 hex chars; returns 1 if no tool
  - `json_str <string>` → prints the string JSON-escaped **with** surrounding quotes

- [ ] **Step 1: Write the failing helper tests**

Create `tests/installer-lifecycle.sh`:

```bash
#!/usr/bin/env bash
# installer-lifecycle.sh — the installer removes what is ours, keeps what is
# not, never touches ~/.kannaka, and writes a receipt last. Every case RUNS
# install.sh (or a helper lifted out of it) against a throwaway HOME with
# curl/uname/sha256sum/brew/npm/claude stubbed. No network, no real machine.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALL_SH="$HERE/../install/install.sh"
FAILS=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected: $2, actual: $3)"; fi
}
lift() { sed -n "/^$1() {/,/^}/p" "$INSTALL_SH"; }

# A stub binary that answers --version like the real component does.
mk_ours() { # mk_ours <path> <component> <version>
  printf '#!/bin/sh\n[ "$1" = "--version" ] && echo "%s %s (stub)"\n' "$2" "$3" > "$1"; chmod +x "$1"
}
# A file at a kannaka path that is NOT kannaka.
mk_impostor() { printf '#!/bin/sh\necho "definitely-not-kannaka 9.9"\n' > "$1"; chmod +x "$1"; }

echo "helpers"
work="$(mktemp -d)"
mk_ours "$work/k" kannaka 0.16.2
mk_ours "$work/t" kannaka-tui 0.5.9
mk_impostor "$work/x"
printf 'not executable' > "$work/plain"
got=$(sh -c "$(lift have); $(lift banner_component); banner_component '$work/k'")
check "banner_component recognises kannaka" "kannaka" "$got"
got=$(sh -c "$(lift have); $(lift banner_component); banner_component '$work/t'")
check "banner_component recognises kannaka-tui" "kannaka-tui" "$got"
sh -c "$(lift have); $(lift banner_component); banner_component '$work/x'" >/dev/null 2>&1 && fail "impostor accepted" || ok "banner_component rejects an impostor"
sh -c "$(lift have); $(lift banner_component); banner_component '$work/plain'" >/dev/null 2>&1 && fail "non-executable accepted" || ok "banner_component rejects a non-executable"
sh -c "$(lift have); $(lift banner_component); banner_component '$work/missing'" >/dev/null 2>&1 && fail "missing file accepted" || ok "banner_component rejects a missing file"
printf 'abc' > "$work/h"
got=$(sh -c "$(lift have); $(lift file_sha256); file_sha256 '$work/h'")
check "file_sha256" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" "$got"
got=$(sh -c "$(lift json_str); json_str 'a\"b\\c'")
check "json_str escapes quote and backslash" '"a\"b\\c"' "$got"
rm -rf "$work"

[ "$FAILS" -eq 0 ] && echo "installer-lifecycle.sh: all cases passed" || { echo "installer-lifecycle.sh: $FAILS failed"; exit 1; }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/installer-lifecycle.sh`
Expected: the `banner_component`, `file_sha256` and `json_str` cases FAIL (functions not found), no "all cases passed".

- [ ] **Step 3: Add the helpers to `install/install.sh`**

Insert directly after line 77 (`have() { ... }`):

```sh
# ───────────────────────────────────────────────────────────────────────────
# IDENTITY. The installer never removes a file because of where it is, only
# because of what it says it is. `--version` on every kannaka component prints
# "<component> <version> ..." as its first line, and that first word is the
# only identity we trust. A foreign binary that happens to be called kannaka
# does not answer that way, so it is left alone.
# ───────────────────────────────────────────────────────────────────────────
# banner_component <path>  -> prints the component name, or returns 1
banner_component() {
  bc_path="$1"
  [ -f "$bc_path" ] && [ -x "$bc_path" ] || return 1
  if have timeout; then
    bc_line=$(timeout 5 "$bc_path" --version 2>/dev/null | head -1)
  else
    bc_line=$("$bc_path" --version 2>/dev/null | head -1)
  fi
  bc_name=${bc_line%% *}
  case "$bc_name" in
    kannaka|kannaka-tui|kannaka-hdl)
      # the second word must look like a version, or "kannaka" alone is a
      # coincidence rather than a banner
      bc_rest=${bc_line#* }
      case "$bc_rest" in [0-9]*) printf '%s' "$bc_name"; return 0 ;; esac ;;
  esac
  return 1
}

# file_sha256 <path> -> 64 hex chars on stdout
file_sha256() {
  if have sha256sum; then sha256sum "$1" | awk '{print $1}'
  elif have shasum; then shasum -a 256 "$1" | awk '{print $1}'
  else return 1; fi
}

# json_str <s> -> the string as a JSON literal, quotes included. Only the two
# characters that can appear in a path and break JSON are escaped; control
# characters do not occur in the paths this installer writes.
json_str() {
  printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
}
```

- [ ] **Step 4: Run the tests**

Run: `bash tests/installer-lifecycle.sh && bash -n install/install.sh && sh -n install/install.sh`
Expected: all helper cases `ok`, "all cases passed", both syntax checks silent.

- [ ] **Step 5: Commit**

```bash
git add install/install.sh tests/installer-lifecycle.sh
git commit -m "install.sh: identity, sha256 and json helpers for the receipt and sweep"
```

---

### Task 2: The sweep in `install.sh`

**Files:**
- Modify: `install/install.sh` — flag parsing (lines 45-72), new functions after Task 1's helpers, a call site immediately after `DEST=` (line 208)
- Test: `tests/installer-lifecycle.sh` (append the fixture cases)

**Interfaces:**
- Consumes: `banner_component`, `have`, `say`, `warn`, `ok`.
- Produces:
  - variable `KEEP_OTHERS` (0/1) from `--keep-others`
  - `REMOVED_LOG` and `KEPT_LOG`: temp files, one TAB-separated line each, `path<TAB>component<TAB>reason` and `path<TAB>reason`; Task 3 reads `REMOVED_LOG` into the receipt
  - `log_removed <path> <component> <reason>`; `log_kept <path> <reason>`
  - `remove_ours <path> <reason>` → unlinks iff `banner_component` succeeds; logs either way; returns 0 if removed
  - `remove_stale_beside <binary-path>`
  - `sweep_previous` → runs the whole §4 table; exits 3 on an impostor at a target path
  - `EXPECTED_COMPONENTS="kannaka kannaka-tui kannaka-hdl"`

- [ ] **Step 1: Append the fixture cases to the test**

Append to `tests/installer-lifecycle.sh` before the final `[ "$FAILS" -eq 0 ]` line:

```bash
# ── a full run of install.sh with everything stubbed ────────────────────────
# run_install <home> <extra args...>; stubs live in $home/../stub, logs in $home/../log
run_install() {
  ri_home="$1"; shift
  ri_root="$(dirname "$ri_home")"; ri_stub="$ri_root/stub"; ri_log="$ri_root/log"
  mkdir -p "$ri_stub" "$ri_log"
  cat > "$ri_stub/curl" <<'EOF'
#!/bin/sh
dest=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) dest="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
case "$url" in
  *constellation.tsv*|*manifest.pub*|*.sig) exit 22 ;;                       # no manifest: latest path
  *.sha256) printf '%s  x\n' "$FAKE_SHA" > "$dest" ;;
  *) [ -n "$dest" ] && printf '#!/bin/sh\n[ "$1" = "--version" ] && echo "%s 9.9.9 (downloaded)"\n' "$(basename "$url" | sed 's/-linux-x86_64$//')" > "$dest" ;;
esac
exit 0
EOF
  cat > "$ri_stub/uname" <<'EOF'
#!/bin/sh
case "$1" in -m) echo x86_64 ;; *) echo Linux ;; esac
EOF
  # sha256sum must agree with the .sha256 the curl stub serves, whatever the bytes
  cat > "$ri_stub/sha256sum" <<'EOF'
#!/bin/sh
printf '%s  %s\n' "$FAKE_SHA" "$1"
EOF
  cat > "$ri_stub/brew" <<'EOF'
#!/bin/sh
echo "brew $*" >> "$STUB_LOG/brew"
case "$1" in list) printf '%s\n' $FAKE_BREW_LIST ;; tap) printf '%s\n' $FAKE_BREW_TAPS ;; esac
EOF
  cat > "$ri_stub/npm" <<'EOF'
#!/bin/sh
echo "npm $*" >> "$STUB_LOG/npm"
case "$1" in ls) printf '/usr/lib\n'; for p in $FAKE_NPM_GLOBALS; do printf '+-- %s@1.0.0\n' "$p"; done ;; esac
EOF
  cat > "$ri_stub/claude" <<'EOF'
#!/bin/sh
echo "claude $*" >> "$STUB_LOG/claude"
case "$*" in "plugin marketplace list") printf '%s\n' "$FAKE_MARKETPLACES" ;; esac
EOF
  chmod +x "$ri_stub"/*
  rm -f "$ri_log/brew" "$ri_log/npm" "$ri_log/claude"
  # PATH: stubs first, then the two "earlier than target" dirs a shadow can hide in
  HOME="$ri_home" PATH="$ri_stub:$ri_home/shadow:$ri_home/.cargo/bin:$ri_home/.local/bin:/usr/bin:/bin" \
    STUB_LOG="$ri_log" FAKE_SHA="${FAKE_SHA:-abc}" SHELL=/bin/bash SKIP_STATUSLINE=1 \
    FAKE_BREW_LIST="${FAKE_BREW_LIST:-}" FAKE_BREW_TAPS="${FAKE_BREW_TAPS:-}" \
    FAKE_NPM_GLOBALS="${FAKE_NPM_GLOBALS:-}" FAKE_MARKETPLACES="${FAKE_MARKETPLACES:-}" \
    sh "$INSTALL_SH" "$@" > "$ri_log/out" 2>&1
  echo $? > "$ri_log/rc"
}

# Populate every location in the spec's §4 table, plus one impostor.
populate_old() { # populate_old <home>
  po="$1"
  mkdir -p "$po/.local/bin" "$po/.cargo/bin" "$po/shadow" "$po/.kannaka" "$po/Desktop"
  mk_ours "$po/.local/bin/kannaka"     kannaka     0.15.0
  mk_ours "$po/.local/bin/kannaka-tui" kannaka-tui 0.5.0
  mk_ours "$po/.cargo/bin/kannaka"     kannaka     0.9.0
  mk_ours "$po/shadow/kannaka"         kannaka     0.14.0
  mk_impostor "$po/.cargo/bin/kannaka-hdl"
  printf 'stale' > "$po/.local/bin/kannaka.bak-123"
  printf 'stale' > "$po/.local/bin/kannaka-tui.old"
  printf '[llm]\nprovider = "openai"\n' > "$po/.kannaka/config.toml"
  printf 'IDENTITY' > "$po/.kannaka/node_key.ed25519"
  printf 'HRM' > "$po/.kannaka/kannaka.hrm"
  printf '\n# kannaka\nexport PATH="$HOME/.local/bin:$PATH"\n' > "$po/.bashrc"
  printf 'export NATS_USER=u\n' > "$po/.kannaka-nats.env"
}

echo "fresh over old"
root="$(mktemp -d)"; home="$root/home"; populate_old "$home"
FAKE_BREW_LIST="kannaka" FAKE_BREW_TAPS="nickflach/kannaka homebrew/core" \
FAKE_NPM_GLOBALS="kannaka kannaktopus" FAKE_MARKETPLACES="kannaka  github:NickFlach/kannaka-plugin" \
  run_install "$home"
check "exit 0" "0" "$(cat "$root/log/rc")"
[ -e "$home/.cargo/bin/kannaka" ]     && fail "cargo copy survived"         || ok "cargo copy removed"
[ -e "$home/shadow/kannaka" ]         && fail "PATH shadow survived"        || ok "PATH shadow removed"
[ -e "$home/.local/bin/kannaka.bak-123" ] && fail "stale .bak survived"     || ok "stale .bak-* removed"
[ -e "$home/.local/bin/kannaka-tui.old" ] && fail "stale .old survived"     || ok "stale .old removed"
[ -e "$home/.cargo/bin/kannaka-hdl" ] && ok "impostor untouched"            || fail "IMPOSTOR DELETED"
grep -q "kannaka-hdl" "$root/log/out" && grep -qi "not kannaka" "$root/log/out" && ok "impostor named in output" || fail "impostor not named"
grep -q "^brew uninstall kannaka" "$root/log/brew" && ok "brew uninstall" || fail "brew uninstall not run"
grep -q "^brew untap nickflach/kannaka" "$root/log/brew" && ok "brew untap old tap" || fail "old tap not untapped"
grep -q "^npm rm -g kannaka$" "$root/log/npm" && ok "npm rm kannaka" || fail "npm global not removed"
grep -q "^npm rm -g kannaktopus$" "$root/log/npm" && ok "npm rm kannaktopus" || fail "legacy npm global not removed"
grep -q "^claude plugin marketplace remove kannaka" "$root/log/claude" && ok "old marketplace removed" || fail "old marketplace kept"
grep -q "^claude plugin marketplace add kannaka-labs/kannaka-plugin" "$root/log/claude" && ok "new marketplace added" || fail "new marketplace not added"
got=$("$home/.local/bin/kannaka" --version | cut -d' ' -f2)
check "target replaced by the download" "9.9.9" "$got"
rm -rf "$root"

echo "impostor at a target path aborts"
root="$(mktemp -d)"; home="$root/home"; mkdir -p "$home/.local/bin"
mk_impostor "$home/.local/bin/kannaka"
run_install "$home"
check "exit 3" "3" "$(cat "$root/log/rc")"
grep -q "refusing to overwrite" "$root/log/out" && ok "refusal printed" || fail "no refusal"
got=$("$home/.local/bin/kannaka" 2>/dev/null | head -1)
check "impostor still there" "definitely-not-kannaka 9.9" "$got"
[ -e "$home/.kannaka/install.json" ] && fail "receipt written on abort" || ok "no receipt on abort"
rm -rf "$root"

echo "--keep-others skips the sweep"
root="$(mktemp -d)"; home="$root/home"; populate_old "$home"
FAKE_BREW_LIST="kannaka" run_install "$home" --keep-others
check "exit 0" "0" "$(cat "$root/log/rc")"
[ -e "$home/.cargo/bin/kannaka" ] && ok "cargo copy kept" || fail "cargo copy removed despite --keep-others"
[ -e "$home/shadow/kannaka" ]     && ok "shadow kept"     || fail "shadow removed despite --keep-others"
if [ -f "$root/log/brew" ] && grep -q uninstall "$root/log/brew"; then fail "brew uninstall ran"; else ok "brew untouched"; fi
rm -rf "$root"
```

- [ ] **Step 2: Run to verify these fail**

Run: `bash tests/installer-lifecycle.sh`
Expected: "fresh over old" cases FAIL (cargo copy survived, brew uninstall not run, …); "impostor at a target" expects rc 3 and gets 0.

- [ ] **Step 3: Add the flag, the logs and the sweep**

In the flag loop, after line 58 (`--skip-hdl) SKIP_HDL=1 ;;`) add:

```sh
    # A machine that deliberately runs two versions. Skips the sweep of
    # previous installs (§4 of the fresh-install spec); the receipt still
    # records only what THIS run wrote.
    --keep-others) KEEP_OTHERS=1 ;;
```

and beside `SKIP_HDL=0` (line 42) add `KEEP_OTHERS=0`.

After Task 1's helpers, add:

```sh
# ───────────────────────────────────────────────────────────────────────────
# THE SWEEP. A fresh install removes every previous kannaka it can prove is
# kannaka, before it lays down anything, so a machine never ends up with two.
# What was removed is logged and ends up in the receipt; what was declined is
# logged and named in the output. Never by path, only by identity.
# ───────────────────────────────────────────────────────────────────────────
EXPECTED_COMPONENTS="kannaka kannaka-tui kannaka-hdl"
REMOVED_LOG="${TMPDIR:-/tmp}/kannaka-removed.$$"
KEPT_LOG="${TMPDIR:-/tmp}/kannaka-kept.$$"
: > "$REMOVED_LOG"; : > "$KEPT_LOG"

log_removed() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$REMOVED_LOG"; }
log_kept()    { printf '%s\t%s\n' "$1" "$2" >> "$KEPT_LOG"; warn "left alone: $1 ($2)"; }

# remove_ours <path> <reason>: unlink iff the file identifies as a component.
remove_ours() {
  ro_path="$1"; ro_reason="$2"
  [ -e "$ro_path" ] || return 1
  if ro_comp=$(banner_component "$ro_path"); then
    rm -f "$ro_path" && log_removed "$ro_path" "$ro_comp" "$ro_reason" && say "removed previous $ro_comp: $ro_path ($ro_reason)"
    return 0
  fi
  log_kept "$ro_path" "not kannaka"
  return 1
}

# Stale swap leftovers beside a binary: <name>.bak-*, <name>.old, <name>.new.
# These are never executables we can identity-check (a .old may be locked or
# half-written), so the rule is narrower: only names that a kannaka component
# itself produces, and only beside a path that is one of ours.
remove_stale_beside() { # remove_stale_beside <binary-path>
  rs_dir=$(dirname "$1"); rs_name=$(basename "$1")
  for rs_f in "$rs_dir/$rs_name".bak-* "$rs_dir/$rs_name.old" "$rs_dir/$rs_name.new"; do
    [ -e "$rs_f" ] || continue
    rm -f "$rs_f" && log_removed "$rs_f" "$rs_name" "stale swap leftover"
  done
}

sweep_previous() {
  if [ "$KEEP_OTHERS" = "1" ]; then say "Keeping other installs (--keep-others)."; return 0; fi
  say "Looking for previous installs…"

  # 1. The targets themselves: identity-checked, recorded as replaced, never
  #    unlinked here (the download replaces them; a failed download must leave
  #    the old engine in place). An impostor at a target is fatal.
  for sp_c in $EXPECTED_COMPONENTS; do
    sp_t="$DEST/$sp_c"
    [ -e "$sp_t" ] || continue
    if sp_got=$(banner_component "$sp_t"); then
      log_removed "$sp_t" "$sp_got" "replaced"
    else
      warn "refusing to overwrite $sp_t: it is not kannaka (its --version does not identify it). Move it aside and re-run."
      rm -f "$REMOVED_LOG" "$KEPT_LOG"
      exit 3
    fi
    remove_stale_beside "$sp_t"
  done

  # 2. The cargo-install era.
  for sp_f in "$HOME/.cargo/bin"/kannaka*; do
    [ -e "$sp_f" ] || continue
    case "$sp_f" in *.bak-*|*.old|*.new) continue ;; esac
    remove_ours "$sp_f" "cargo install era" || true
  done

  # 3. Anything on PATH earlier than the target directory: it would shadow
  #    the binary we are about to install.
  sp_ifs=$IFS; IFS=:
  for sp_d in $PATH; do
    IFS=$sp_ifs
    [ -n "$sp_d" ] || continue
    [ "$sp_d" = "$DEST" ] && break
    case "$sp_d" in "$HOME/.cargo/bin") continue ;; esac   # done above
    for sp_c in $EXPECTED_COMPONENTS; do
      [ -e "$sp_d/$sp_c" ] || continue
      if remove_ours "$sp_d/$sp_c" "earlier on PATH than $DEST"; then
        say "  it would have shadowed the new $sp_c"
      fi
    done
    IFS=:
  done
  IFS=$sp_ifs

  # 4. Package managers. Best-effort: a manager that is not installed, or
  #    that does not list kannaka, is silently skipped.
  if have brew; then
    if brew list --formula 2>/dev/null | grep -qx kannaka; then
      brew uninstall kannaka >/dev/null 2>&1 && log_removed "brew:kannaka" "kannaka" "brew formula" && say "removed brew formula kannaka"
    fi
    if brew tap 2>/dev/null | grep -qi '^nickflach/kannaka$'; then
      brew untap nickflach/kannaka >/dev/null 2>&1 && log_removed "brew-tap:nickflach/kannaka" "-" "old tap name" && say "untapped nickflach/kannaka (now kannaka-labs/kannaka)"
    fi
  fi
  if have npm; then
    sp_globals=$(npm ls -g --depth=0 2>/dev/null || true)
    for sp_p in kannaka kannaktopus; do
      if printf '%s' "$sp_globals" | grep -q " $sp_p@"; then
        npm rm -g "$sp_p" >/dev/null 2>&1 && log_removed "npm:$sp_p" "$sp_p" "npm global" && say "removed npm global $sp_p"
      fi
    done
  fi
  # 5. The old marketplace registration (same name, old source).
  if have claude; then
    if claude plugin marketplace list 2>/dev/null | grep -qi 'nickflach/kannaka-plugin'; then
      claude plugin marketplace remove kannaka >/dev/null 2>&1 && log_removed "claude-marketplace:github:NickFlach/kannaka-plugin" "-" "old marketplace source" && say "removed old marketplace registration"
    fi
  fi
}
```

Call it. Replace line 208 (`DEST="$HOME/.local/bin"; mkdir -p "$DEST"`) with:

```sh
DEST="$HOME/.local/bin"; mkdir -p "$DEST"
[ "$CLAIM_ONLY" = "1" ] || sweep_previous
```

- [ ] **Step 4: Run the tests**

Run: `bash tests/installer-lifecycle.sh && sh -n install/install.sh`
Expected: every case `ok`, "all cases passed".

- [ ] **Step 5: Commit**

```bash
git add install/install.sh tests/installer-lifecycle.sh
git commit -m "install.sh: sweep previous installs by identity before installing (--keep-others to skip)"
```

---

### Task 3: The receipt in `install.sh`

**Files:**
- Modify: `install/install.sh` — constants near line 18, `write_receipt` after `sweep_previous`, call before line 666 (`ok "Done…"`), and one-line records inside the existing sections that write files
- Test: `tests/installer-lifecycle.sh` (append)

**Interfaces:**
- Consumes: `REMOVED_LOG`, `json_str`, `file_sha256`, `MANIFEST`, `DEST`, `CREDS`, `KCONF`, `o`, `a`
- Produces:
  - `INSTALLER_VERSION=2`, `INSTALLER_ID="kannaka-labs/kannaka-plugin/install/install.sh@$INSTALLER_VERSION"`
  - `RECEIPT="${KANNAKA_DATA_DIR:-$HOME/.kannaka}/install.json"`
  - tracking variables: `RC_EDITS` (space-separated `file|sentinel` pairs), `CONFIG_EDITED` (0/1), `CREDS_WRITTEN` (0/1), `REGISTRATIONS` (0/1)
  - `write_receipt` → rotates and writes the receipt atomically; returns 1 if it cannot

- [ ] **Step 1: Append the receipt and preserve tests**

```bash
echo "receipt"
root="$(mktemp -d)"; home="$root/home"; populate_old "$home"
FAKE_BREW_LIST="kannaka" run_install "$home"
R="$home/.kannaka/install.json"
[ -f "$R" ] && ok "receipt exists" || fail "no receipt"
python3 - "$R" "$home" <<'PY' && ok "receipt fields" || fail "receipt content"
import json, sys
r = json.load(open(sys.argv[1])); home = sys.argv[2]
assert r["schema"] == 1, r
assert r["installer"].startswith("kannaka-labs/kannaka-plugin/install/install.sh@"), r["installer"]
assert r["manifest"] == "latest", r["manifest"]
assert r["platform"] == "linux-x86_64", r["platform"]
paths = {f["path"] for f in r["files"]}
assert paths == {home + "/.local/bin/kannaka", home + "/.local/bin/kannaka-tui", home + "/.local/bin/kannaka-hdl"}, paths
for f in r["files"]:
    assert len(f["sha256"]) == 64 and f["component"] in f["path"] and f["version"] == "9.9.9", f
assert {e["file"] for e in r["rc_edits"]} == set(), r["rc_edits"]   # PATH line pre-existed in .bashrc
assert r["config_edits"] == [], r["config_edits"]          # no --brain: nothing written to config.toml
assert r["credentials"] == [], r["credentials"]            # creds pre-existed: not written by this run
removed = {(x["path"], x["reason"]) for x in r["removed"]}
assert (home + "/.cargo/bin/kannaka", "cargo install era") in removed, removed
assert (home + "/shadow/kannaka", "earlier on PATH than " + home + "/.local/bin") in removed, removed
assert (home + "/.local/bin/kannaka", "replaced") in removed, removed
assert ("brew:kannaka", "brew formula") in removed, removed
assert all(p != home + "/.cargo/bin/kannaka-hdl" for p, _ in removed), "impostor in removed"
assert r["previous"] == [], r["previous"]
PY
# the receipt is written LAST: nothing it lists is newer than it
newest=$(ls -t "$home/.local/bin" | head -1)
[ "$home/.local/bin/$newest" -nt "$R" ] && fail "a binary is newer than the receipt" || ok "receipt written after the binaries"
# a second install rotates
run_install "$home"
[ -f "$R.1" ] && ok "previous receipt rotated to .1" || fail "no rotation"
python3 -c "import json,sys; r=json.load(open(sys.argv[1])); assert r['previous']==['install.json.1'], r['previous']" "$R" && ok "previous lists .1" || fail "previous wrong"
run_install "$home"; run_install "$home"; run_install "$home"
[ -f "$R.3" ] && [ ! -f "$R.4" ] && ok "at most three deep" || fail "rotation depth wrong"
rm -rf "$root"

echo "rc edit is recorded when the installer makes one"
root="$(mktemp -d)"; home="$root/home"; mkdir -p "$home/.local/bin"
run_install "$home"     # fresh HOME: no .bashrc, so the installer writes the PATH block
python3 -c "import json,sys; r=json.load(open(sys.argv[1])); assert r['rc_edits']==[{'file': sys.argv[2]+'/.bashrc', 'sentinel': '# kannaka'}], r['rc_edits']" "$home/.kannaka/install.json" "$home" && ok "rc_edits names .bashrc" || fail "rc_edits wrong"
rm -rf "$root"

echo "preserve"
root="$(mktemp -d)"; home="$root/home"; populate_old "$home"
before=$(cd "$home/.kannaka" && find . -type f ! -name 'install.json*' | sort | xargs sha256sum)
run_install "$home"
after=$(cd "$home/.kannaka" && find . -type f ! -name 'install.json*' | sort | xargs sha256sum)
check "~/.kannaka byte-identical after a fresh install" "$before" "$after"
check "swarm credentials untouched" "export NATS_USER=u" "$(cat "$home/.kannaka-nats.env")"
[ "$(grep -c '^# kannaka$' "$home/.bashrc")" = "1" ] && ok "rc block not duplicated" || fail "rc block duplicated"
rm -rf "$root"
```

- [ ] **Step 2: Run to verify these fail**

Run: `bash tests/installer-lifecycle.sh`
Expected: "no receipt" and everything after it in the receipt section FAIL; the preserve cases already pass (they guard a regression).

- [ ] **Step 3: Implement**

Near line 18 (`INSTALL_URL=...`) add:

```sh
# What THIS run wrote, so that `kannaka uninstall` can reverse exactly it.
# Bump INSTALLER_VERSION whenever the receipt's shape or the sweep table changes.
INSTALLER_VERSION=2
INSTALLER_ID="kannaka-labs/kannaka-plugin/install/install.sh@$INSTALLER_VERSION"
RECEIPT="${KANNAKA_DATA_DIR:-$HOME/.kannaka}/install.json"
RC_EDITS=""; CONFIG_EDITED=0; CREDS_WRITTEN=0; REGISTRATIONS=0
```

Record the writes the script already makes (one line each, inside the existing block):
- after line 309 (the PATH block `printf ... >> "$rc"`): `RC_EDITS="$RC_EDITS $rc|# kannaka"`
- after line 500 (the credentials rc block): `RC_EDITS="$RC_EDITS $crc|# kannaka swarm credentials"`
- after line 449 (`chmod 600 "$CREDS"`): `CREDS_WRITTEN=1`
- inside `write_llm_config` after the `mv` (line 551): `CONFIG_EDITED=1`
- after line 644 (`claude plugin install kannaka@kannaka …`): `REGISTRATIONS=1`

Add after `sweep_previous`:

```sh
# ───────────────────────────────────────────────────────────────────────────
# THE RECEIPT. Written LAST and atomically: every path this run wrote, every
# rc edit, every registration, and everything the sweep removed. It is the
# definition of "an install" on this machine and the only thing
# `kannaka uninstall` needs. The last three receipts are kept beside it.
# ───────────────────────────────────────────────────────────────────────────
write_receipt() {
  wr_dir=$(dirname "$RECEIPT"); mkdir -p "$wr_dir"
  wr_tmp="$RECEIPT.tmp.$$"
  wr_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  wr_manifest="latest"
  [ -n "${MANIFEST:-}" ] && [ -f "$MANIFEST" ] && wr_manifest="library@$(head -1 "$MANIFEST" | awk -F'\t' '{print $3}')"
  wr_tab=$(printf '\t')
  {
    printf '{\n  "schema": 1,\n'
    printf '  "installed_at": %s,\n' "$(json_str "$wr_now")"
    printf '  "installer": %s,\n' "$(json_str "$INSTALLER_ID")"
    printf '  "manifest": %s,\n' "$(json_str "$wr_manifest")"
    printf '  "platform": %s,\n' "$(json_str "${o}-${a}")"
    printf '  "files": ['
    wr_sep=""
    for wr_c in $EXPECTED_COMPONENTS; do
      wr_p="$DEST/$wr_c"
      [ -x "$wr_p" ] || continue
      wr_ver=$("$wr_p" --version 2>/dev/null | head -1 | awk '{print $2}')
      printf '%s\n    {"path": %s, "sha256": %s, "component": %s, "version": %s}' \
        "$wr_sep" "$(json_str "$wr_p")" "$(json_str "$(file_sha256 "$wr_p")")" "$(json_str "$wr_c")" "$(json_str "${wr_ver:-unknown}")"
      wr_sep=","
    done
    printf '\n  ],\n  "rc_edits": ['
    wr_sep=""
    for wr_e in $RC_EDITS; do
      printf '%s\n    {"file": %s, "sentinel": %s}' "$wr_sep" "$(json_str "${wr_e%%|*}")" "$(json_str "${wr_e#*|}")"
      wr_sep=","
    done
    printf '\n  ],\n  "config_edits": ['
    [ "$CONFIG_EDITED" = "1" ] && printf '\n    {"file": %s, "sections": ["llm"]}' "$(json_str "$KCONF")"
    printf '\n  ],\n  "credentials": ['
    [ "$CREDS_WRITTEN" = "1" ] && printf '\n    {"file": %s}' "$(json_str "$CREDS")"
    printf '\n  ],\n  "registrations": ['
    [ "$REGISTRATIONS" = "1" ] && printf '\n    {"kind": "claude-marketplace", "name": "kannaka-labs/kannaka-plugin"},\n    {"kind": "claude-plugin", "name": "kannaka@kannaka"}'
    printf '\n  ],\n  "removed": ['
    wr_sep=""
    while IFS="$wr_tab" read -r wr_p wr_c wr_r; do
      [ -n "$wr_p" ] || continue
      printf '%s\n    {"path": %s, "component": %s, "reason": %s}' "$wr_sep" "$(json_str "$wr_p")" "$(json_str "$wr_c")" "$(json_str "$wr_r")"
      wr_sep=","
    done < "$REMOVED_LOG"
    printf '\n  ],\n  "previous": ['
    # rotate: .2 -> .3, .1 -> .2, current -> .1 (three deep, oldest dropped)
    [ -f "$RECEIPT.2" ] && mv -f "$RECEIPT.2" "$RECEIPT.3"
    [ -f "$RECEIPT.1" ] && mv -f "$RECEIPT.1" "$RECEIPT.2"
    [ -f "$RECEIPT" ]   && mv -f "$RECEIPT"   "$RECEIPT.1"
    wr_sep=""
    for wr_n in 1 2 3; do
      [ -f "$RECEIPT.$wr_n" ] || continue
      printf '%s%s' "$wr_sep" "$(json_str "install.json.$wr_n")"; wr_sep=", "
    done
    printf ']\n}\n'
  } > "$wr_tmp" || { warn "could not write the install receipt"; rm -f "$wr_tmp"; return 1; }
  mv -f "$wr_tmp" "$RECEIPT"
  rm -f "$REMOVED_LOG" "$KEPT_LOG"
  ok "Install receipt → $RECEIPT"
}
```

The `RC_EDITS` pairs are `file|sentinel` and the sentinel `# kannaka swarm credentials` contains spaces; the `for wr_e in $RC_EDITS` split is on whitespace, so store the pairs with the spaces replaced: use `RC_EDITS="$RC_EDITS $crc|#_kannaka_swarm_credentials"` and `RC_EDITS="$RC_EDITS $rc|#_kannaka"` at the two record sites, and in `write_receipt` render the sentinel with `printf '%s' "${wr_e#*|}" | tr '_' ' '` before `json_str`. (The test asserts the rendered `# kannaka`.)

Call it: immediately before line 666 (`ok "Done. kannaka → $DEST/kannaka"`) add

```sh
[ "$CLAIM_ONLY" = "1" ] || write_receipt
```

A `--claim-only` run installs nothing and must not rotate the receipt.

- [ ] **Step 4: Run the tests**

Run: `bash tests/installer-lifecycle.sh && sh -n install/install.sh && bash tests/installer-checksum.sh && bash test/shell-rc.test.sh`
Expected: all `ok`, "all cases passed" for the lifecycle suite; the other two unchanged.

- [ ] **Step 5: Commit**

```bash
git add install/install.sh tests/installer-lifecycle.sh
git commit -m "install.sh: write an install receipt last, atomically, three deep"
```

---

### Task 4: The mutation that proves the identity guard is load-bearing, and CI

**Files:**
- Test: `tests/installer-lifecycle.sh` (append)
- Modify: `.github/workflows/ci.yml`

**Interfaces:** consumes `run_install`, `populate_old`, `INSTALL_SH`.

- [ ] **Step 1: Append the mutation case**

```bash
echo "mutation: without the identity check the impostor dies (so the fixture is real)"
root="$(mktemp -d)"; home="$root/home"; populate_old "$home"
mutant="$root/install-mutant.sh"
# Replace the guard with one that says everything is kannaka.
sed '/^banner_component() {/,/^}/c\
banner_component() { printf kannaka; return 0; }' "$INSTALL_SH" > "$mutant"
grep -q 'printf kannaka; return 0' "$mutant" || fail "mutant not produced"
saved="$INSTALL_SH"; INSTALL_SH="$mutant"
run_install "$home"
INSTALL_SH="$saved"
[ -e "$home/.cargo/bin/kannaka-hdl" ] && fail "mutant kept the impostor — the fixture does not exercise the guard" || ok "mutant deleted the impostor: the guard is what protects it"
rm -rf "$root"
```

- [ ] **Step 2: Run**

Run: `bash tests/installer-lifecycle.sh`
Expected: the mutation line is `ok`. If it FAILS, the fixture is not reaching the guard — fix the fixture, not the mutant.

- [ ] **Step 3: Wire into CI and commit**

In `.github/workflows/ci.yml` after the `installer checksum hard-fail (install.sh)` step add:

```yaml
      - name: installer lifecycle — sweep by identity, preserve set, receipt last (install.sh)
        run: bash tests/installer-lifecycle.sh
```

```bash
git add tests/installer-lifecycle.sh .github/workflows/ci.yml
git commit -m "tests: mutation proves the installer's identity guard; run the lifecycle suite in CI"
```

---

### Task 5: Identity, sweep and receipt in `install.ps1`

**Files:**
- Modify: `install/install.ps1` — `param()` (lines 17-42), functions after `Have` (line 49), call sites after `$dest` (line 61) and before `Ok "Done…"` (line 548), one-line records at lines 347, 425, 515
- Test: `tests/installer-lifecycle.ps1` (create)

**Interfaces:**
- Produces (PowerShell; the test lifts each `function` block by regex and dot-evaluates it):
  - `-KeepOthers` switch
  - `$script:InstallerVersion = 2`; `$script:Receipt` = `<KANNAKA_DATA_DIR or $HOME\.kannaka>\install.json`
  - `Invoke-VersionBanner([string]$Path)` → first line of `--version` with a 5 s timeout, or `$null`. **The only function that spawns a process; the test replaces exactly it.**
  - `Get-BannerComponent([string]$Path)` → `kannaka` | `kannaka-tui` | `kannaka-hdl` | `$null`
  - `Get-FileSha256([string]$Path)` → lowercase hex
  - `$script:Removed`, `$script:Kept` (ArrayLists of hashtables `path/component/reason`), `$script:RcEdits`, `$script:ConfigEdited`, `$script:CredsWritten`, `$script:Registrations`
  - `Remove-Ours([string]$Path, [string]$Reason)` → `$true` if removed or parked
  - `Remove-StaleBeside([string]$Binary)`
  - `Get-UserPath` / `Set-UserPath([string]$v)` → isolate the user-PATH registry access so the test can substitute it
  - `Invoke-Sweep([string]$Dest)` → throws `refusing to overwrite …` for an impostor at a target
  - `Write-Receipt([string]$Dest, [string]$Platform)`

- [ ] **Step 1: Write the failing test**

Create `tests/installer-lifecycle.ps1`:

```powershell
# installer-lifecycle.ps1 — the Windows installer sweeps by identity, keeps the
# preserve set, parks a locked exe, and writes the receipt last. Runs the REAL
# functions lifted out of install.ps1 against a throwaway HOME; the one process
# spawn (Invoke-VersionBanner) is replaced by a table lookup so no exe is needed.
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$installer = Join-Path $here "..\install\install.ps1"
$fails = 0
function Check($label, $expected, $actual) {
  if ("$expected" -eq "$actual") { Write-Host "  ok   $label" } else { Write-Host "  FAIL $label (expected: $expected, actual: $actual)"; $script:fails++ }
}
# Lift one function definition out of the installer, verbatim.
function Lift([string]$Name) {
  $src = Get-Content $installer -Raw
  if ($src -notmatch "(?ms)^function $([regex]::Escape($Name))\b.*?^\}\r?$") { throw "function $Name not found in install.ps1" }
  $Matches[0]
}
foreach ($f in 'Say','Warn','Ok','Have','Get-BannerComponent','Get-FileSha256','Remove-Ours','Remove-StaleBeside','Invoke-Sweep','Write-Receipt') {
  Invoke-Expression (Lift $f)
}
$KeepOthers = $false
$script:Removed = [System.Collections.ArrayList]@(); $script:Kept = [System.Collections.ArrayList]@()
$script:RcEdits = @(); $script:ConfigEdited = $false; $script:CredsWritten = $false; $script:Registrations = $false
$script:InstallerVersion = 2; $script:Manifest = $null
$script:Banners = @{}
function Invoke-VersionBanner([string]$Path) { if ($script:Banners.ContainsKey($Path)) { $script:Banners[$Path] } else { $null } }
function Ours([string]$Path, [string]$Component, [string]$Version) {
  New-Item -ItemType File -Force -Path $Path | Out-Null; $script:Banners[$Path] = "$Component $Version (stub)"
}
function Impostor([string]$Path) { Set-Content -Path $Path -Value "nope"; $script:Banners[$Path] = "definitely-not-kannaka 9.9" }

Write-Host "identity"
$root = Join-Path $env:TEMP ("kl-" + [guid]::NewGuid().ToString("N")); New-Item -ItemType Directory -Path $root | Out-Null
Ours "$root\k.exe" kannaka 0.16.2; Impostor "$root\x.exe"
Check "recognises kannaka" "kannaka" (Get-BannerComponent "$root\k.exe")
Check "rejects impostor" "" (Get-BannerComponent "$root\x.exe")
Check "rejects missing" "" (Get-BannerComponent "$root\missing.exe")
Set-Content -NoNewline -Path "$root\h" -Value "abc"
Check "sha256" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" (Get-FileSha256 "$root\h")

Write-Host "sweep"
$home_ = Join-Path $root "home"; $dest = "$home_\.local\bin"; $old = "$home_\AppData\Local\Programs\kannaka"
foreach ($d in $dest, $old, "$home_\.cargo\bin", "$home_\.kannaka") { New-Item -ItemType Directory -Force -Path $d | Out-Null }
$homeSaved = $HOME; Set-Variable -Name HOME -Value $home_ -Force -Scope Global
$lapSaved = $env:LOCALAPPDATA; $env:LOCALAPPDATA = "$home_\AppData\Local"
$pathSaved = $env:Path; $env:Path = "$old;$dest;$pathSaved"
Ours "$dest\kannaka.exe" kannaka 0.15.0
Ours "$old\kannaka.exe" kannaka 0.12.0; Ours "$old\kannaka-tui.exe" kannaka-tui 0.4.0
Ours "$home_\.cargo\bin\kannaka.exe" kannaka 0.9.0
Impostor "$home_\.cargo\bin\kannaka-hdl.exe"
Set-Content -Path "$dest\kannaka.exe.bak-123" -Value "stale"
Set-Content -Path "$home_\.kannaka\node_key.ed25519" -Value "IDENTITY"
$script:UserPath = "C:\Windows;$old;$dest"
function Get-UserPath { $script:UserPath }
function Set-UserPath([string]$v) { $script:UserPath = $v }
Invoke-Sweep -Dest $dest
Check "old programs dir kannaka removed" $false (Test-Path "$old\kannaka.exe")
Check "old programs dir tui removed" $false (Test-Path "$old\kannaka-tui.exe")
Check "cargo copy removed" $false (Test-Path "$home_\.cargo\bin\kannaka.exe")
Check "impostor untouched" $true (Test-Path "$home_\.cargo\bin\kannaka-hdl.exe")
Check "impostor named" $true (@($script:Kept | ForEach-Object { $_.path }) -contains "$home_\.cargo\bin\kannaka-hdl.exe")
Check "stale .bak removed" $false (Test-Path "$dest\kannaka.exe.bak-123")
Check "target recorded as replaced" $true (@($script:Removed | Where-Object { $_.path -eq "$dest\kannaka.exe" -and $_.reason -eq "replaced" }).Count -eq 1)
Check "target itself not unlinked" $true (Test-Path "$dest\kannaka.exe")
Check "old dir dropped from user PATH" "C:\Windows;$dest" $script:UserPath
Check "identity untouched" "IDENTITY" ((Get-Content "$home_\.kannaka\node_key.ed25519") -join "")

Write-Host "locked exe is parked, not skipped"
Ours "$old\kannaka.exe" kannaka 0.12.0
$fs = [System.IO.File]::Open("$old\kannaka.exe", 'Open', 'Read', 'None')   # lock it, the way a running exe is locked
try { $parked = Remove-Ours -Path "$old\kannaka.exe" -Reason "test" } finally { $fs.Close() }
Check "reported removed" $true $parked
Check "parked as .bak-<pid>" 1 (@(Get-ChildItem $old -Filter "kannaka.exe.bak-*").Count)
Check "reason parked" "parked" (@($script:Removed | Where-Object { $_.path -eq "$old\kannaka.exe" })[-1].reason)

Write-Host "impostor at the target aborts"
Impostor "$dest\kannaka-tui.exe"
$threw = $false; try { Invoke-Sweep -Dest $dest } catch { $threw = ("$_" -match "refusing to overwrite") }
Check "throws refusing to overwrite" $true $threw
Remove-Item "$dest\kannaka-tui.exe" -Force

Write-Host "receipt"
Ours "$dest\kannaka.exe" kannaka 9.9.9; Ours "$dest\kannaka-tui.exe" kannaka-tui 9.9.9
$script:Registrations = $true
$script:Receipt = "$home_\.kannaka\install.json"
Write-Receipt -Dest $dest -Platform "windows-x86_64"
$r = Get-Content "$home_\.kannaka\install.json" -Raw | ConvertFrom-Json
Check "schema" 1 $r.schema
Check "installer" "kannaka-labs/kannaka-plugin/install/install.ps1@2" $r.installer
Check "two files" 2 @($r.files).Count
Check "file version from banner" "9.9.9" (@($r.files | Where-Object { $_.component -eq "kannaka" })[0].version)
Check "registrations recorded" 2 @($r.registrations).Count
Check "removed carries the sweep" $true (@($r.removed).Count -ge 4)
Check "previous empty first time" 0 @($r.previous).Count
Write-Receipt -Dest $dest -Platform "windows-x86_64"
Check "rotated to .1" $true (Test-Path "$home_\.kannaka\install.json.1")
Write-Receipt -Dest $dest -Platform "windows-x86_64"; Write-Receipt -Dest $dest -Platform "windows-x86_64"; Write-Receipt -Dest $dest -Platform "windows-x86_64"
Check "three deep" $true ((Test-Path "$home_\.kannaka\install.json.3") -and -not (Test-Path "$home_\.kannaka\install.json.4"))

Write-Host "mutation: an identity guard that accepts everything deletes the impostor"
Impostor "$home_\.cargo\bin\kannaka-hdl.exe"
function Get-BannerComponent([string]$Path) { "kannaka" }
Invoke-Sweep -Dest $dest
Check "mutant deleted the impostor (fixture reaches the guard)" $false (Test-Path "$home_\.cargo\bin\kannaka-hdl.exe")

Set-Variable -Name HOME -Value $homeSaved -Force -Scope Global; $env:LOCALAPPDATA = $lapSaved; $env:Path = $pathSaved
Remove-Item -Recurse -Force $root
if ($fails -gt 0) { Write-Host "installer-lifecycle.ps1: $fails failed"; exit 1 } else { Write-Host "installer-lifecycle.ps1: all cases passed" }
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh ./tests/installer-lifecycle.ps1`
Expected: throws at `Lift 'Get-BannerComponent'` ("function … not found").

- [ ] **Step 3: Implement in `install.ps1`**

Add to `param()` after `[switch]$SkipHdl,`:

```powershell
  # A machine that deliberately runs two versions: skip the sweep of previous installs.
  [switch]$KeepOthers,
```

After `function Have` (line 49) add:

```powershell
# ───────────────────────────────────────────────────────────────────────────
# IDENTITY. Nothing is removed because of where it is, only because of what
# its --version banner says it is: "<component> <version> ...". The spawn is
# isolated in Invoke-VersionBanner so the tests can replace exactly that.
# ───────────────────────────────────────────────────────────────────────────
$script:InstallerVersion = 2
$script:Receipt = Join-Path $(if ($env:KANNAKA_DATA_DIR) { $env:KANNAKA_DATA_DIR } else { Join-Path $HOME ".kannaka" }) "install.json"
$script:Removed = [System.Collections.ArrayList]@()
$script:Kept = [System.Collections.ArrayList]@()
$script:RcEdits = @()            # Windows has no rc file; kept for schema parity
$script:ConfigEdited = $false
$script:CredsWritten = $false
$script:Registrations = $false

function Invoke-VersionBanner([string]$Path) {
  $out = Join-Path $env:TEMP "kannaka-banner-$PID.txt"
  try {
    $p = Start-Process -FilePath $Path -ArgumentList "--version" -NoNewWindow -PassThru -RedirectStandardOutput $out -ErrorAction Stop
    if (-not $p.WaitForExit(5000)) { try { $p.Kill() } catch {}; return $null }
    Get-Content $out -TotalCount 1 -ErrorAction SilentlyContinue
  } catch { $null } finally { Remove-Item $out -Force -ErrorAction SilentlyContinue }
}

function Get-BannerComponent([string]$Path) {
  if (-not (Test-Path -PathType Leaf $Path)) { return $null }
  $line = Invoke-VersionBanner $Path
  if (-not $line) { return $null }
  $parts = "$line".Trim() -split '\s+', 2
  if ($parts.Count -lt 2 -or $parts[1] -notmatch '^\d') { return $null }
  if ($parts[0] -in 'kannaka','kannaka-tui','kannaka-hdl') { return $parts[0] }
  $null
}

function Get-FileSha256([string]$Path) { (Get-FileHash $Path -Algorithm SHA256).Hash.ToLower() }

# Remove-Ours: delete iff the file identifies as a component. A locked exe (it
# is running) is parked as <name>.bak-<pid>; the next kannaka or installer
# sweeps it. Returns $true when removed or parked.
function Remove-Ours([string]$Path, [string]$Reason) {
  if (-not (Test-Path $Path)) { return $false }
  $c = Get-BannerComponent $Path
  if (-not $c) { [void]$script:Kept.Add(@{ path = $Path; reason = "not kannaka" }); Warn "left alone: $Path (not kannaka)"; return $false }
  try {
    Remove-Item -Force -ErrorAction Stop $Path
    [void]$script:Removed.Add(@{ path = $Path; component = $c; reason = $Reason }); Say "removed previous ${c}: $Path ($Reason)"
  } catch {
    $bak = "$Path.bak-$PID"
    Move-Item -Force -ErrorAction Stop $Path $bak
    [void]$script:Removed.Add(@{ path = $Path; component = $c; reason = "parked" }); Say "previous $c was in use — parked as $(Split-Path $bak -Leaf)"
  }
  $true
}

function Remove-StaleBeside([string]$Binary) {
  $dir = Split-Path $Binary -Parent; $name = Split-Path $Binary -Leaf
  foreach ($f in @(Get-ChildItem -Path $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$name.bak-*" -or $_.Name -eq "$name.old" -or $_.Name -eq "$name.new" })) {
    try { Remove-Item -Force -ErrorAction Stop $f.FullName; [void]$script:Removed.Add(@{ path = $f.FullName; component = $name; reason = "stale swap leftover" }) } catch {}
  }
}

# User-PATH access is isolated so the test can substitute it.
function Get-UserPath { [Environment]::GetEnvironmentVariable("Path", "User") }
function Set-UserPath([string]$v) { [Environment]::SetEnvironmentVariable("Path", $v, "User") }

function Invoke-Sweep([string]$Dest) {
  if ($KeepOthers) { Say "Keeping other installs (-KeepOthers)."; return }
  Say "Looking for previous installs…"
  $components = 'kannaka','kannaka-tui','kannaka-hdl'
  # 1. targets: identity-checked, recorded as replaced, not unlinked (the download replaces them)
  foreach ($c in $components) {
    $t = Join-Path $Dest "$c.exe"
    if (-not (Test-Path $t)) { continue }
    $got = Get-BannerComponent $t
    if (-not $got) { throw "refusing to overwrite ${t}: it is not kannaka (its --version does not identify it). Move it aside and re-run." }
    [void]$script:Removed.Add(@{ path = $t; component = $got; reason = "replaced" })
    Remove-StaleBeside $t
  }
  # 2. the old memory-installer directory and the cargo era
  $oldDirs = @((Join-Path $env:LOCALAPPDATA "Programs\kannaka"), (Join-Path $HOME ".cargo\bin"))
  $emptied = @()
  foreach ($d in $oldDirs) {
    if (-not (Test-Path $d)) { continue }
    $had = $false
    foreach ($f in @(Get-ChildItem -Path $d -Filter "kannaka*.exe" -File -ErrorAction SilentlyContinue)) {
      if (Remove-Ours -Path $f.FullName -Reason "previous install dir $d") { $had = $true; Remove-StaleBeside $f.FullName }
    }
    if ($had -and -not @(Get-ChildItem -Path $d -Filter "kannaka*.exe" -File -ErrorAction SilentlyContinue).Count) { $emptied += $d }
  }
  # 3. anything on PATH earlier than $Dest that would shadow the new binary
  foreach ($d in @($env:Path -split ';' | Where-Object { $_ })) {
    if ($d -eq $Dest) { break }
    if ($oldDirs -contains $d) { continue }
    foreach ($c in $components) {
      $p = Join-Path $d "$c.exe"
      if ((Test-Path $p) -and (Remove-Ours -Path $p -Reason "earlier on PATH than $Dest")) { Say "  it would have shadowed the new $c" }
    }
  }
  # 4. a user-PATH entry for a directory that held ours and now holds none
  if ($emptied.Count -gt 0) {
    $keep = @((Get-UserPath) -split ';' | Where-Object { $_ -and ($emptied -notcontains $_) })
    Set-UserPath ($keep -join ';')
    foreach ($d in $emptied) { [void]$script:Removed.Add(@{ path = "user-path:$d"; component = "-"; reason = "PATH entry for an emptied install dir" }) }
  }
  # 5. npm globals and the old marketplace registration
  if (Have npm) {
    $globals = (& npm ls -g --depth=0 2>$null) -join "`n"
    foreach ($p in 'kannaka','kannaktopus') {
      if ($globals -match " $p@") { & npm rm -g $p *> $null; [void]$script:Removed.Add(@{ path = "npm:$p"; component = $p; reason = "npm global" }); Say "removed npm global $p" }
    }
  }
  if (Have claude) {
    $mk = (& claude plugin marketplace list 2>$null) -join "`n"
    if ($mk -imatch 'nickflach/kannaka-plugin') { & claude plugin marketplace remove kannaka *> $null; [void]$script:Removed.Add(@{ path = "claude-marketplace:github:NickFlach/kannaka-plugin"; component = "-"; reason = "old marketplace source" }); Say "removed old marketplace registration" }
  }
}

function Write-Receipt([string]$Dest, [string]$Platform) {
  $dir = Split-Path $script:Receipt -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $files = @()
  foreach ($c in 'kannaka','kannaka-tui','kannaka-hdl') {
    $p = Join-Path $Dest "$c.exe"
    if (-not (Test-Path $p)) { continue }
    $ver = "unknown"; $b = Invoke-VersionBanner $p; if ($b) { $ver = ("$b".Trim() -split '\s+')[1] }
    $files += [ordered]@{ path = $p; sha256 = (Get-FileSha256 $p); component = $c; version = $ver }
  }
  $regs = @(); if ($script:Registrations) { $regs = @([ordered]@{ kind = "claude-marketplace"; name = "kannaka-labs/kannaka-plugin" }, [ordered]@{ kind = "claude-plugin"; name = "kannaka@kannaka" }) }
  $cfg = @(); if ($script:ConfigEdited) { $cfg = @([ordered]@{ file = (Join-Path $HOME ".kannaka\config.toml"); sections = @("llm") }) }
  $creds = @(); if ($script:CredsWritten) { $creds = @([ordered]@{ kind = "user-env"; names = @("NATS_USER", "NATS_PASSWORD") }) }
  # rotate three deep, then list what exists
  if (Test-Path "$($script:Receipt).2") { Move-Item -Force "$($script:Receipt).2" "$($script:Receipt).3" }
  if (Test-Path "$($script:Receipt).1") { Move-Item -Force "$($script:Receipt).1" "$($script:Receipt).2" }
  if (Test-Path $script:Receipt)        { Move-Item -Force $script:Receipt "$($script:Receipt).1" }
  $prev = @(); foreach ($n in 1, 2, 3) { if (Test-Path "$($script:Receipt).$n") { $prev += "install.json.$n" } }
  $manifest = "latest"; if ($script:Manifest) { $manifest = "library@" + $script:Manifest.generated }
  $doc = [ordered]@{
    schema = 1; installed_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    installer = "kannaka-labs/kannaka-plugin/install/install.ps1@$($script:InstallerVersion)"
    manifest = $manifest; platform = $Platform
    files = @($files); rc_edits = @($script:RcEdits); config_edits = @($cfg); credentials = @($creds); registrations = @($regs)
    removed = @($script:Removed | ForEach-Object { [ordered]@{ path = $_.path; component = $_.component; reason = $_.reason } })
    previous = @($prev)
  }
  $tmp = "$($script:Receipt).tmp.$PID"
  $doc | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding utf8
  Move-Item -Force $tmp $script:Receipt
  Ok "Install receipt → $($script:Receipt)"
}
```

Call sites and records:
- after line 61 (`New-Item -ItemType Directory -Force -Path $dest | Out-Null`): `if (-not $ClaimOnly) { Invoke-Sweep -Dest $dest }`
- after line 347 (`[Environment]::SetEnvironmentVariable("NATS_PASSWORD", …)`): `$script:CredsWritten = $true`
- inside `Write-LlmConfig` after `Set-Content` (line 425): `$script:ConfigEdited = $true`
- after line 515 (`claude plugin install kannaka@kannaka …`): `$script:Registrations = $true`
- before line 548 (`Ok "Done. kannaka.exe → $exe"`): `if (-not $ClaimOnly) { Write-Receipt -Dest $dest -Platform "windows-x86_64" }`
- after the `Done.` block: `if ($script:Kept.Count -gt 0) { Warn "$($script:Kept.Count) file(s) at kannaka paths were NOT kannaka and were left alone (listed above)." }`

PowerShell 5.1 note: `ConvertTo-Json` turns a single-element array into a scalar unless wrapped in `@()` at the property, which is why every list above is `@(...)`.

- [ ] **Step 4: Run the tests**

Run: `pwsh ./tests/installer-lifecycle.ps1; pwsh ./tests/installer-checksum.ps1; pwsh ./tests/installer-manifest.ps1`
Expected: all three report all cases passed. The lock case uses a real `FileStream`, which is what makes the "parked" branch executed rather than believed.

- [ ] **Step 5: Wire into CI and commit**

In `.github/workflows/ci.yml` under `installer-win` after the `installer-manifest.ps1` step:

```yaml
      - name: installer lifecycle — sweep by identity, parked exe, receipt last (install.ps1)
        shell: pwsh
        run: ./tests/installer-lifecycle.ps1
```

```bash
git add install/install.ps1 tests/installer-lifecycle.ps1 .github/workflows/ci.yml
git commit -m "install.ps1: sweep previous installs by identity, park locked exes, write the receipt last"
```

---

### Task 6: README and the summary line

**Files:**
- Modify: `README.md` (the install section), `install/install.sh` (summary lines 665-671), `install/install.ps1` (summary lines 547-551)

- [ ] **Step 1: Summary lines**

In both installers, after the `Done.` lines, add one line naming the receipt and the way back:

```sh
[ "$CLAIM_ONLY" = "1" ] || say "     receipt: $RECEIPT   (uninstall with: kannaka uninstall)"
```

```powershell
if (-not $ClaimOnly) { Say "     receipt: $($script:Receipt)   (uninstall with: kannaka uninstall)" }
```

- [ ] **Step 2: README**

Add under the install section:

```markdown
### A fresh install replaces the old one

The installer looks for every previous kannaka on the machine — `~/.local/bin`,
`~/.cargo/bin`, anything earlier on `PATH`, the brew formula (either tap name), the npm
global, the old marketplace registration — and removes what **identifies itself** as kannaka
(`--version` says so). A file at one of those paths that is not kannaka is left alone and
named. Pass `--keep-others` (`-KeepOthers` on Windows) to skip this on a machine that
deliberately runs two versions.

Nothing under `~/.kannaka` (or `KANNAKA_DATA_DIR`) is touched except `install.json`, the
**receipt**: what this install wrote, what it removed, and the last three receipts beside it.
`kannaka uninstall` reads it and reverses exactly that; `kannaka uninstall --purge` also
removes `~/.kannaka`, the shell rc blocks and the credentials.
```

- [ ] **Step 3: Run everything, commit**

Run: `bash tests/installer-lifecycle.sh && bash tests/installer-checksum.sh && bash test/shell-rc.test.sh && sh -n install/install.sh`

```bash
git add README.md install/install.sh install/install.ps1
git commit -m "docs: the fresh-install sweep, the receipt, and where uninstall lives"
```

---

## Self-review

**Spec coverage.** §2 forwarders and npm → binary plan (kannaka-memory). §3 receipt → Tasks 3, 5 (rotation per Ruling 2; `removed` included). §4 sweep table → Task 2 (POSIX rows: the receipt's own files are the targets here, `~/.local/bin`, `~/.cargo/bin`, PATH shadows, brew both taps, npm both names, marketplace, stale leftovers) and Task 5 (Windows rows: both install dirs, user-PATH entries, parked exes, npm, marketplace). `--keep-others` → Tasks 2, 5. §5 preserve set → Task 3's preserve fixture; the installer writes nothing new under `~/.kannaka` beyond the receipt. §6, §7 → binary plan. §8 → Nick's decision, not planned. §9 fixtures: fresh-over-old with impostor (Tasks 2, 5), preserve (3), receipt round trip: the install half here, the uninstall half in the binary plan, no-receipt fallback → binary plan, Windows including the lock → Task 5, mutation → Tasks 4, 5. §10 order: this plan is step 2.

**Placeholders.** None: every step carries its code and its command.

**Type consistency.** `REMOVED_LOG` lines are `path<TAB>component<TAB>reason` in Task 2 and read in that order in Task 3. `RC_EDITS` pairs are `file|sentinel` with underscores for spaces at both record sites and rendered back in `write_receipt`. `Invoke-VersionBanner` is the only spawn in Task 5 and the test overrides exactly it. `INSTALLER_VERSION` / `$script:InstallerVersion` are both `2` and the receipt strings match the test assertions (`…install.sh@`, `…install.ps1@2`).

**Known gaps, stated.** (1) The Windows `credentials` shape differs from the POSIX one (Ruling 8) and the binary's reader must accept both. (2) The brew and npm rows are exercised only through stubs; the real commands' output formats (`brew list --formula`, `npm ls -g --depth=0`, `claude plugin marketplace list`) are matched loosely (`grep -qx kannaka`, `" kannaka@"`, case-insensitive owner) on purpose, so a format change degrades to "not found, skipped" rather than to a wrong deletion.
