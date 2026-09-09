# Fresh install, receipt and sweep — installer implementation plan (kannaka-plugin)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `install/install.sh` and `install/install.ps1` the one definition of a kannaka install: they remove every recognised previous copy once the new engine is on disk, write a receipt last, and are proven to do both by tests that actually run them.

**Architecture:** Both installers stay single files (they are run by `curl | sh` and `irm | iex`, so they cannot source helpers). New behaviour is added as named functions the tests lift out with `sed` / a PowerShell regex, the way `tests/installer-checksum.sh` and `tests/installer-manifest.ps1` already do. The sweep runs after the engine is downloaded, verified and on `PATH`; it never deletes by path, never runs anything outside `$HOME`, and logs into the receipt; the receipt is written atomically as the very last act and lists only what this run wrote. The binary side (`kannaka uninstall`, the widened `kannaka update`, the forwarders, npm) is the sibling plan in kannaka-memory: `docs/superpowers/plans/2026-09-09-fresh-install-binary.md` there.

**Tech Stack:** POSIX sh (`install.sh` is run by `sh`, not bash — no arrays, no `[[`, no `local`), Windows PowerShell 5.1-compatible PowerShell, bash test scripts with stubbed `curl`/`uname`/`sha256sum`/`brew`/`npm`/`claude`, GitHub Actions (`ubuntu-latest`, `windows-latest`).

**Spec:** `docs/superpowers/specs/2026-09-09-fresh-install-update-uninstall-design.md` **revision 2** (this repo, PR #19). Sections referenced below as §N.

## Global Constraints

- `install.sh` must stay valid POSIX sh: no bash-isms. Every new function uses the two-letter local-variable prefix convention the file already uses (`fv_`, `fp_`, `wl_` …), because POSIX sh has no `local`.
- **The sweep runs only after `kannaka` is downloaded, verified and `$DEST` is on `PATH`** (§4). A failed download must leave every previous copy in place and write no receipt.
- **Never delete by path, only by identity** (§4): a file is removed only when its `--version` banner names a kannaka component, or its sha256 matches a `files` entry of the previous receipt. A file that does not identify is left in place and named under `declined`.
- **Never execute or remove anything outside `$HOME`** (§4). A kannaka in a PATH directory outside `$HOME` is declined with reason `outside your home`.
- **The receipt lists what this run wrote** (§3): `files` is appended at download-verified time, never by scanning `$DEST`.
- **The receipt is written last and atomically** (§3): temp file fully written → rotation → rename; a `install.json.lock` directory serialises writers.
- **The preserve set is never touched** (§5): `~/.kannaka/**` (or `KANNAKA_DATA_DIR`) other than `install.json*`, and, only with `--brain`, the `[llm]` section of `config.toml`; the `# kannaka` rc blocks; `~/.kannaka-nats.env`; services and scheduled tasks.
- Receipt path: `${KANNAKA_DATA_DIR:-$HOME/.kannaka}/install.json`, rotated to `install.json.1`, `.2`, `.3`.
- Component names are exactly `kannaka`, `kannaka-tui`, `kannaka-hdl`. Real banners: `kannaka 0.16.0 (consciousness-core 0.6.0)`, `kannaka-tui 0.5.9`, `kannaka-hdl 0.11.0`. The first whitespace-separated word of the first line is the component; the second must be a version with an optional leading `v`.
- Rc blocks written from now on are closed with a `# /kannaka` line (§5).
- The old owner may appear in this repo's install code in exactly two places, both inside the sweep: the brew tap `nickflach/kannaka` and the marketplace-row match `nickflach/kannaka-plugin` (case-insensitive). Nowhere else.
- Every guard gets a mutation that is actually run (§9).
- Commit messages end with the trailer block the session uses (Co-Authored-By + Claude-Session).

## Rulings (decisions the spec leaves open, made here so every task agrees)

1. **Call site of the sweep**: immediately after the `--version` check of the freshly installed engine (`install.sh` line 321 today; `install.ps1` line 234), i.e. after the PATH block has exported `$DEST` for this run. The three target paths are identity-checked before the download (Task 2's `guard_targets`): a target that does not identify is renamed to `<name>.notkannaka-<UTC timestamp>` and named under `declined`; the download then proceeds. `--keep-others` skips the sweep, not the target guard.
2. **`previous` is three rotated files.** `install.json` → `.1` → `.2` → `.3` at receipt-write time, after the temp file is complete; `"previous"` lists the rotated names that exist.
3. **`installer` is the script's canonical path plus a hand-bumped `INSTALLER_VERSION`**: `kannaka-labs/kannaka-plugin/install/install.sh@2`.
4. **The marketplace row match** is a line of `claude plugin marketplace list` that contains both the word `kannaka` as the marketplace name (start of line, or after whitespace) and `nickflach/kannaka-plugin` (case-insensitive). The remove and the re-add live together in the Claude section.
5. **A locked exe on Windows is parked** as `<name>.exe.bak-<pid>`, recorded under `removed` with reason `parked`, reported as parked in the summary, and exempt from the stale-leftover sweep of the same run.
6. **The banner check has a five-second cap on every platform**: `timeout`, else `gtimeout`, else `perl -e 'alarm shift; exec @ARGV' 5 …` (macOS ships perl), else plain. PowerShell: `Start-Process -PassThru` + `WaitForExit(5000)`.
7. **The PowerShell sweep covers both Windows install dirs** (`~\.local\bin`, `%LOCALAPPDATA%\Programs\kannaka`) and removes exactly one kind of user-PATH entry: the one naming `%LOCALAPPDATA%\Programs\kannaka`, and only when that directory is empty of everything afterwards. An MSI-managed copy (an `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\*` key whose `DisplayName` starts with `Kannaka`) is printed as `msiexec /x <ProductCode>` and skipped.
8. **Windows credentials are user-environment variables**, recorded as `{"kind":"user-env","names":["NATS_USER","NATS_PASSWORD"]}`; the Windows PATH addition at `install.ps1` line 225 is recorded under `path_edits` as `{"scope":"user","entry":"<dest>"}`.
9. **Previous-receipt sha match skips execution**: before running a candidate, its sha256 is looked up in the current `install.json` (the previous install's receipt); a match yields that entry's component without spawning anything.
10. **Logs and temp files** live in one `mktemp -d` directory removed at exit; nothing predictable is created in `/tmp`.

## File map

| file | responsibility |
|---|---|
| `install/install.sh` | flag `--keep-others`; functions `run_capped`, `banner_component`, `file_sha256`, `json_str`, `loggable`, `log_file`, `log_removed`, `log_declined`, `identify`, `remove_ours`, `remove_stale_beside`, `canon_dir`, `guard_targets`, `sweep_previous`, `swap_old_marketplace`, `json_list`, `write_receipt`; `# /kannaka` closers |
| `install/install.ps1` | switch `-KeepOthers`; functions `Invoke-VersionBanner`, `Get-BannerComponent`, `Get-FileSha256`, `Get-Identity`, `Remove-Ours`, `Remove-StaleBeside`, `Get-UserPath`, `Set-UserPath`, `Get-MsiProduct`, `Test-TargetGuard`, `Invoke-Sweep`, `Remove-OldMarketplace`, `Write-Receipt`; same call sites |
| `tests/installer-lifecycle.sh` | executed fixtures: helpers, fresh-over-old with impostor and outside-home copy, download fails, impostor at target moved aside, `--keep-others`, sha match skips execution, receipt last and complete, only-what-was-written, rc/launcher/closers, rotation, lock, preserve, identity-guard mutation |
| `tests/installer-lifecycle.ps1` | the same against the lifted PowerShell functions, plus the locked-exe, MSI and PATH-entry cases |
| `tests/fixtures/receipt-from-install-sh.json` | a receipt a real run produced; kannaka-memory parses the same file |
| `.github/workflows/ci.yml` | run both suites |
| `README.md` | document `--keep-others`, the receipt, and where `kannaka uninstall` lives |

---

### Task 1: Identity, hashing and JSON helpers in `install.sh`

**Files:**
- Modify: `install/install.sh` (insert after `have()` at line 77)
- Test: `tests/installer-lifecycle.sh` (create; this task adds the helper cases only)

**Interfaces:**
- Produces (POSIX sh functions, all lifted by tests with `sed -n '/^name() {/,/^}/p'`):
  - `run_capped <seconds> <cmd...>` → runs the command under a time cap; stdout passes through
  - `banner_component <path>` → prints `kannaka` | `kannaka-tui` | `kannaka-hdl` and returns 0, or prints nothing and returns 1. Requires the path to be under `$HOME`.
  - `file_sha256 <path>` → prints 64 hex chars; returns 1 if no tool
  - `json_str <string>` → prints the string JSON-escaped **with** surrounding quotes, control characters included

- [ ] **Step 1: Write the failing helper tests**

Create `tests/installer-lifecycle.sh`:

```bash
#!/usr/bin/env bash
# installer-lifecycle.sh — the installer removes what is ours, keeps what is
# not, never runs or removes anything outside $HOME, never touches ~/.kannaka,
# and writes a receipt last that lists what it wrote. Every case RUNS
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
# python3 on Linux/macOS CI; plain `python` on a Windows dev box (Git Bash)
PY=$(command -v python3 2>/dev/null || command -v python)

# A stub binary that answers --version like the real component does, and
# leaves a marker file so a test can tell whether it was RUN.
mk_ours() { # mk_ours <path> <component> <version>
  printf '#!/bin/sh\n: > "$0.ran"\n[ "$1" = "--version" ] && echo "%s %s (stub)"\n' "$2" "$3" > "$1"; chmod +x "$1"
}
# A file at a kannaka path that is NOT kannaka.
mk_impostor() { printf '#!/bin/sh\n: > "$0.ran"\necho "definitely-not-kannaka 9.9"\n' > "$1"; chmod +x "$1"; }
# A binary that hangs on --version.
mk_hanger() { printf '#!/bin/sh\nsleep 30\n' > "$1"; chmod +x "$1"; }

echo "helpers"
work="$(mktemp -d)"; mkdir -p "$work/home"
mk_ours "$work/home/k" kannaka 0.16.2
mk_ours "$work/home/t" kannaka-tui 0.5.9
mk_ours "$work/home/v" kannaka-hdl v0.11.0
mk_impostor "$work/home/x"
printf 'not executable' > "$work/home/plain"
mk_hanger "$work/home/hang"
mk_ours "$work/outside" kannaka 0.16.2
H="HOME='$work/home'; $(lift have); $(lift run_capped); $(lift banner_component)"
got=$(sh -c "$H; banner_component '$work/home/k'")
check "banner_component recognises kannaka" "kannaka" "$got"
got=$(sh -c "$H; banner_component '$work/home/t'")
check "banner_component recognises kannaka-tui" "kannaka-tui" "$got"
got=$(sh -c "$H; banner_component '$work/home/v'")
check "banner_component accepts a leading v" "kannaka-hdl" "$got"
sh -c "$H; banner_component '$work/home/x'" >/dev/null 2>&1 && fail "impostor accepted" || ok "banner_component rejects an impostor"
sh -c "$H; banner_component '$work/home/plain'" >/dev/null 2>&1 && fail "non-executable accepted" || ok "banner_component rejects a non-executable"
sh -c "$H; banner_component '$work/home/missing'" >/dev/null 2>&1 && fail "missing file accepted" || ok "banner_component rejects a missing file"
sh -c "$H; banner_component '$work/outside'" >/dev/null 2>&1 && fail "outside HOME was accepted" || ok "banner_component refuses a path outside HOME"
[ -e "$work/outside.ran" ] && fail "outside-HOME binary was executed" || ok "outside-HOME binary was never executed"
start=$(date +%s); sh -c "$H; banner_component '$work/home/hang'" >/dev/null 2>&1; el=$(( $(date +%s) - start ))
[ "$el" -lt 15 ] && ok "hanging binary is cut off (${el}s)" || fail "hanging binary was not cut off (${el}s)"
printf 'abc' > "$work/h"
got=$(sh -c "$(lift have); $(lift file_sha256); file_sha256 '$work/h'")
check "file_sha256" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" "$got"
got=$(sh -c "$(lift json_str); json_str 'a\"b\\c'")
check "json_str escapes quote and backslash" '"a\"b\\c"' "$got"
got=$(sh -c "$(lift json_str); json_str \"\$(printf 'x\ty')\"")
check "json_str escapes a tab" '"x\ty"' "$got"
rm -rf "$work"

[ "$FAILS" -eq 0 ] && echo "installer-lifecycle.sh: all cases passed" || { echo "installer-lifecycle.sh: $FAILS failed"; exit 1; }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/installer-lifecycle.sh`
Expected: the helper cases FAIL (functions not found), no "all cases passed".

- [ ] **Step 3: Add the helpers to `install/install.sh`**

Insert directly after line 77 (`have() { ... }`):

```sh
# ───────────────────────────────────────────────────────────────────────────
# IDENTITY. The installer never removes a file because of where it is, only
# because of what it says it is. `--version` on every kannaka component prints
# "<component> <version> ..." as its first line, and that first word is the
# only identity we trust. A foreign binary that happens to be called kannaka
# does not answer that way, so it is left alone.
#
# The check EXECUTES the candidate, so it is bounded: only paths under $HOME
# are ever run, and never for longer than five seconds.
# ───────────────────────────────────────────────────────────────────────────
# run_capped <seconds> <cmd...>: run under a time cap on every platform.
# macOS has no `timeout` in the base system; it has perl.
run_capped() {
  rc_secs="$1"; shift
  if have timeout; then timeout "$rc_secs" "$@"
  elif have gtimeout; then gtimeout "$rc_secs" "$@"
  elif have perl; then perl -e 'alarm shift; exec @ARGV' "$rc_secs" "$@"
  else "$@"; fi
}

# banner_component <path>  -> prints the component name, or returns 1
banner_component() {
  bc_path="$1"
  case "$bc_path" in "$HOME"/*) ;; *) return 1 ;; esac
  [ -f "$bc_path" ] && [ -x "$bc_path" ] || return 1
  bc_line=$(run_capped 5 "$bc_path" --version 2>/dev/null | head -1)
  bc_name=${bc_line%% *}
  case "$bc_name" in
    kannaka|kannaka-tui|kannaka-hdl)
      # the second word must look like a version (optional leading v), or
      # "kannaka" alone is a coincidence rather than a banner
      bc_rest=${bc_line#* }
      case "$bc_rest" in [0-9]*|v[0-9]*) printf '%s' "$bc_name"; return 0 ;; esac ;;
  esac
  return 1
}

# file_sha256 <path> -> 64 hex chars on stdout
file_sha256() {
  if have sha256sum; then sha256sum "$1" | awk '{print $1}'
  elif have shasum; then shasum -a 256 "$1" | awk '{print $1}'
  else return 1; fi
}

# json_str <s> -> the string as a JSON literal, quotes included. Backslash,
# quote and the control characters a path could carry are escaped; anything
# else a path can contain is legal JSON as-is.
json_str() {
  printf '"%s"' "$(printf '%s' "$1" | awk 'BEGIN{ORS=""} {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\t/,"\\t"); gsub(/\r/,"\\r"); if (NR>1) printf "\\n"; print}')"
}
```

- [ ] **Step 4: Run the tests**

Run: `bash tests/installer-lifecycle.sh && bash -n install/install.sh && sh -n install/install.sh`
Expected: all helper cases `ok`, "all cases passed", both syntax checks silent.

- [ ] **Step 5: Commit**

```bash
git add install/install.sh tests/installer-lifecycle.sh
git commit -m "install.sh: bounded identity check, sha256 and json helpers for the receipt and sweep"
```

---

### Task 2: The target guard and the sweep in `install.sh`

**Files:**
- Modify: `install/install.sh` — flag parsing (lines 45-72), new functions after Task 1's helpers, `guard_targets` call before the download (line 297), `sweep_previous` call after the `--version` check (line 321), marketplace swap in the Claude section (line 643), `log_file` calls in `fetch_verified` and `fetch_pinned`
- Test: `tests/installer-lifecycle.sh` (append the fixture cases)

**Interfaces:**
- Consumes: `banner_component`, `file_sha256`, `have`, `say`, `warn`, `ok`.
- Produces:
  - variable `KEEP_OTHERS` (0/1) from `--keep-others`
  - `WORK` (a `mktemp -d` directory, removed on exit) holding `removed.log` (`path<TAB>component<TAB>reason`), `declined.log` (`path<TAB>reason`), `files.log` (`path<TAB>component`), `rc.log` (`file|sentinel`), `extras.log` (`path|kind`)
  - `RECEIPT` (path of the previous/next receipt)
  - `log_removed <path> <component> <reason>`; `log_declined <path> <reason>`; `log_file <path> <component>`
  - `identify <path>` → component via previous-receipt sha match (Ruling 9) or `banner_component`
  - `remove_ours <path> <reason>` → unlinks iff `identify` succeeds; returns 0 if removed
  - `remove_stale_beside <binary-path>`; `canon_dir <dir>`
  - `guard_targets` → moves a non-identifying target aside; never fatal
  - `sweep_previous` → the §4 table minus the marketplace row
  - `swap_old_marketplace` → the marketplace row, called from the Claude section
  - `EXPECTED_COMPONENTS="kannaka kannaka-tui kannaka-hdl"`

- [ ] **Step 1: Append the fixture cases to the test**

Append to `tests/installer-lifecycle.sh` before the final `[ "$FAILS" -eq 0 ]` line:

```bash
# ── a full run of install.sh with everything stubbed ────────────────────────
# run_install <home> <extra args...>; stubs live in $home/../stub, logs in $home/../log
run_install() {
  ri_home="$1"; shift
  ri_root="$(dirname "$ri_home")"; ri_stub="$ri_root/stub"; ri_log="$ri_root/log"
  mkdir -p "$ri_stub" "$ri_log" "$ri_root/outside-bin"
  cat > "$ri_stub/curl" <<'EOF'
#!/bin/sh
dest=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) dest="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
[ "${FAKE_DOWNLOAD_FAILS:-0}" = "1" ] && exit 22
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
  # sha256sum must agree with the .sha256 the curl stub serves, whatever the
  # bytes -- except for ONE path a test may name, which gets its real digest.
  cat > "$ri_stub/sha256sum" <<'EOF'
#!/bin/sh
if [ -n "${FAKE_SHA_FOR:-}" ] && [ "$1" = "$FAKE_SHA_FOR" ]; then "$REAL_SHA256SUM" "$1"; exit; fi
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
case "$*" in "plugin marketplace list") printf '%b\n' "$FAKE_MARKETPLACES" ;; esac
EOF
  chmod +x "$ri_stub"/*
  rm -f "$ri_log/brew" "$ri_log/npm" "$ri_log/claude"
  # PATH: stubs first, then a shadow dir under HOME, a dir OUTSIDE home, cargo, then the target.
  # NO_DEST_ON_PATH=1 leaves ~/.local/bin off PATH so the installer has to write its rc block.
  ri_path="$ri_stub:$ri_home/shadow:$ri_root/outside-bin:$ri_home/.cargo/bin:$ri_home/.local/bin:/usr/bin:/bin"
  [ "${NO_DEST_ON_PATH:-0}" = "1" ] && ri_path="$ri_stub:$ri_home/shadow:$ri_root/outside-bin:$ri_home/.cargo/bin:/usr/bin:/bin"
  HOME="$ri_home" PATH="$ri_path" \
    STUB_LOG="$ri_log" FAKE_SHA="${FAKE_SHA:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" SHELL=/bin/bash SKIP_STATUSLINE=1 \
    FAKE_SHA_FOR="${FAKE_SHA_FOR:-}" REAL_SHA256SUM="$(command -v sha256sum)" \
    FAKE_DOWNLOAD_FAILS="${FAKE_DOWNLOAD_FAILS:-0}" \
    FAKE_BREW_LIST="${FAKE_BREW_LIST:-}" FAKE_BREW_TAPS="${FAKE_BREW_TAPS:-}" \
    FAKE_NPM_GLOBALS="${FAKE_NPM_GLOBALS:-}" FAKE_MARKETPLACES="${FAKE_MARKETPLACES:-}" \
    sh "$INSTALL_SH" "$@" > "$ri_log/out" 2>&1
  echo $? > "$ri_log/rc"
}

# Populate every location in the spec's §4 table, plus one impostor and one
# kannaka OUTSIDE home.
populate_old() { # populate_old <home>
  po="$1"; po_root="$(dirname "$po")"
  mkdir -p "$po/.local/bin" "$po/.cargo/bin" "$po/shadow" "$po/.kannaka" "$po/Desktop" "$po_root/outside-bin"
  mk_ours "$po/.local/bin/kannaka"     kannaka     0.15.0
  mk_ours "$po/.local/bin/kannaka-tui" kannaka-tui 0.5.0
  mk_ours "$po/.cargo/bin/kannaka"     kannaka     0.9.0
  mk_ours "$po/shadow/kannaka"         kannaka     0.14.0
  mk_ours "$po_root/outside-bin/kannaka" kannaka   0.13.0
  mk_impostor "$po/.cargo/bin/kannaka-hdl"
  printf 'stale' > "$po/.local/bin/kannaka.bak-123"
  printf 'stale' > "$po/.local/bin/kannaka-tui.old"
  printf '[llm]\nprovider = "openai"\n' > "$po/.kannaka/config.toml"
  printf 'IDENTITY' > "$po/.kannaka/node_key.ed25519"
  printf 'HRM' > "$po/.kannaka/kannaka.hrm"
  printf '\n# kannaka\nexport PATH="$HOME/.local/bin:$PATH"\n# /kannaka\n' > "$po/.bashrc"
  printf 'export NATS_USER=u\n' > "$po/.kannaka-nats.env"
}

echo "fresh over old"
root="$(mktemp -d)"; home="$root/home"; populate_old "$home"
FAKE_BREW_LIST="kannaka" FAKE_BREW_TAPS="nickflach/kannaka homebrew/core" \
FAKE_NPM_GLOBALS="kannaka kannaktopus" FAKE_MARKETPLACES="kannaka  github:NickFlach/kannaka-plugin\nother  github:someone/kannaka-fork" \
  run_install "$home"
check "exit 0" "0" "$(cat "$root/log/rc")"
[ -e "$home/.cargo/bin/kannaka" ]     && fail "cargo copy survived"         || ok "cargo copy removed"
[ -e "$home/shadow/kannaka" ]         && fail "PATH shadow survived"        || ok "PATH shadow removed"
[ -e "$root/outside-bin/kannaka" ]    && ok "outside-HOME kannaka untouched" || fail "OUTSIDE-HOME KANNAKA DELETED"
[ -e "$root/outside-bin/kannaka.ran" ] && fail "outside-HOME kannaka was executed" || ok "outside-HOME kannaka never executed"
grep -q "outside-bin/kannaka" "$root/log/out" && grep -qi "outside your home" "$root/log/out" && ok "outside-HOME copy named" || fail "outside-HOME copy not named"
[ -e "$home/.local/bin/kannaka.bak-123" ] && fail "stale .bak survived"     || ok "stale .bak-* removed"
[ -e "$home/.local/bin/kannaka-tui.old" ] && fail "stale .old survived"     || ok "stale .old removed"
[ -e "$home/.cargo/bin/kannaka-hdl" ] && ok "impostor untouched"            || fail "IMPOSTOR DELETED"
grep -q "kannaka-hdl" "$root/log/out" && grep -qi "not kannaka" "$root/log/out" && ok "impostor named in output" || fail "impostor not named"
grep -q "^brew uninstall kannaka" "$root/log/brew" && ok "brew uninstall" || fail "brew uninstall not run"
grep -q "^brew untap nickflach/kannaka" "$root/log/brew" && ok "brew untap old tap" || fail "old tap not untapped"
grep -q "^npm rm -g kannaka$" "$root/log/npm" && ok "npm rm kannaka" || fail "npm global not removed"
grep -q "^npm rm -g kannaktopus$" "$root/log/npm" && ok "npm rm kannaktopus" || fail "legacy npm global not removed"
grep -q "^claude plugin marketplace remove kannaka$" "$root/log/claude" && ok "old marketplace removed" || fail "old marketplace kept"
grep -q "remove other" "$root/log/claude" && fail "a differently named marketplace was removed" || ok "the fork's marketplace was left alone"
grep -q "^claude plugin marketplace add kannaka-labs/kannaka-plugin" "$root/log/claude" && ok "new marketplace added" || fail "new marketplace not added"
got=$("$home/.local/bin/kannaka" --version | cut -d' ' -f2)
check "target replaced by the download" "9.9.9" "$got"
[ -n "${KEEP_FIXTURE:-}" ] && mkdir -p "$HERE/fixtures" && cp "$home/.kannaka/install.json" "$HERE/fixtures/receipt-from-install-sh.json"
rm -rf "$root"

echo "download fails: nothing is swept, no receipt"
root="$(mktemp -d)"; home="$root/home"; populate_old "$home"
FAKE_DOWNLOAD_FAILS=1 FAKE_BREW_LIST="kannaka" FAKE_NPM_GLOBALS="kannaka" run_install "$home"
[ "$(cat "$root/log/rc")" != "0" ] && ok "exit non-zero" || fail "exit 0 on a failed download"
[ -e "$home/.cargo/bin/kannaka" ] && ok "cargo copy still there" || fail "cargo copy removed before the download"
[ -e "$home/shadow/kannaka" ]     && ok "shadow still there"     || fail "shadow removed before the download"
got=$("$home/.local/bin/kannaka" --version | cut -d' ' -f2); check "old engine still at the target" "0.15.0" "$got"
if [ -f "$root/log/brew" ] && grep -q uninstall "$root/log/brew"; then fail "brew uninstall ran"; else ok "brew untouched"; fi
if [ -f "$root/log/npm" ] && grep -q "rm -g" "$root/log/npm"; then fail "npm rm ran"; else ok "npm untouched"; fi
[ -e "$home/.kannaka/install.json" ] && fail "receipt written on failure" || ok "no receipt on failure"
rm -rf "$root"

echo "impostor at a target path is moved aside, install continues"
root="$(mktemp -d)"; home="$root/home"; mkdir -p "$home/.local/bin"
mk_impostor "$home/.local/bin/kannaka"
run_install "$home"
check "exit 0" "0" "$(cat "$root/log/rc")"
aside=$(ls "$home/.local/bin"/kannaka.notkannaka-* 2>/dev/null | head -1)
[ -n "$aside" ] && ok "moved aside as $(basename "$aside")" || fail "impostor not moved aside"
got=$("$aside" 2>/dev/null | head -1); check "impostor content intact" "definitely-not-kannaka 9.9" "$got"
grep -q "notkannaka" "$root/log/out" && ok "named in output" || fail "not named"
got=$("$home/.local/bin/kannaka" --version | cut -d' ' -f2); check "new engine installed" "9.9.9" "$got"
rm -rf "$root"

echo "--keep-others skips the sweep but not the target guard"
root="$(mktemp -d)"; home="$root/home"; populate_old "$home"
mk_impostor "$home/.local/bin/kannaka-hdl"
FAKE_BREW_LIST="kannaka" run_install "$home" --keep-others
check "exit 0" "0" "$(cat "$root/log/rc")"
[ -e "$home/.cargo/bin/kannaka" ] && ok "cargo copy kept" || fail "cargo copy removed despite --keep-others"
[ -e "$home/shadow/kannaka" ]     && ok "shadow kept"     || fail "shadow removed despite --keep-others"
if [ -f "$root/log/brew" ] && grep -q uninstall "$root/log/brew"; then fail "brew uninstall ran"; else ok "brew untouched"; fi
ls "$home/.local/bin"/kannaka-hdl.notkannaka-* >/dev/null 2>&1 && ok "impostor at target still moved aside" || fail "target guard skipped"
rm -rf "$root"

echo "previous-receipt sha match skips execution"
root="$(mktemp -d)"; home="$root/home"; populate_old "$home"
mkdir -p "$home/.kannaka"
sha=$(sha256sum "$home/.cargo/bin/kannaka" | awk '{print $1}')
printf '{\n  "schema": 1,\n  "files": [\n    {"path": "%s", "sha256": "%s", "component": "kannaka", "version": "0.9.0"}\n  ]\n}\n' "$home/.cargo/bin/kannaka" "$sha" > "$home/.kannaka/install.json"
FAKE_SHA_FOR="$home/.cargo/bin/kannaka" run_install "$home"
[ -e "$home/.cargo/bin/kannaka" ] && fail "receipt-listed copy survived" || ok "receipt-listed copy removed"
[ -e "$home/.cargo/bin/kannaka.ran" ] && fail "receipt-listed copy was executed" || ok "receipt-listed copy was not executed"
rm -rf "$root"
```

- [ ] **Step 2: Run to verify these fail**

Run: `bash tests/installer-lifecycle.sh`
Expected: "fresh over old" cases FAIL (cargo copy survived, brew uninstall not run, …); "download fails" mostly passes vacuously; "impostor", "--keep-others" and "sha match" FAIL.

- [ ] **Step 3: Add the flag, the logs, the guard and the sweep**

In the flag loop, after line 58 (`--skip-hdl) SKIP_HDL=1 ;;`) add:

```sh
    # A machine that deliberately runs two versions. Skips the sweep of
    # previous installs (§4 of the fresh-install spec) but not the identity
    # check of the three target paths; the receipt still records only what
    # THIS run wrote.
    --keep-others) KEEP_OTHERS=1 ;;
```

and beside `SKIP_HDL=0` (line 42) add `KEEP_OTHERS=0`.

After Task 1's helpers, add:

```sh
# ───────────────────────────────────────────────────────────────────────────
# THE SWEEP. A fresh install removes every previous kannaka it can prove is
# kannaka, ONCE THE NEW ENGINE IS ON DISK, so a machine never ends up with two
# and a failed download never leaves it with none. What was removed and what
# was declined are logged and end up in the receipt. Never by path, only by
# identity; never outside $HOME.
# ───────────────────────────────────────────────────────────────────────────
EXPECTED_COMPONENTS="kannaka kannaka-tui kannaka-hdl"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kannaka-install.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
: > "$WORK/removed.log"; : > "$WORK/declined.log"; : > "$WORK/files.log"; : > "$WORK/rc.log"; : > "$WORK/extras.log"
RECEIPT="${KANNAKA_DATA_DIR:-$HOME/.kannaka}/install.json"

# A path with a tab or newline cannot be logged (the logs are tab-separated,
# the receipt is JSON): skip it and say so.
loggable() { case "$1" in *"$(printf '\t')"*|*"$(printf '\n')"*) warn "skipping a path with a tab or newline in it"; return 1 ;; esac; }
log_removed()  { loggable "$1" && printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$WORK/removed.log"; }
log_declined() { loggable "$1" && printf '%s\t%s\n' "$1" "$2" >> "$WORK/declined.log"; warn "left alone: $1 ($2)"; }
log_file()     { loggable "$1" && printf '%s\t%s\n' "$1" "$2" >> "$WORK/files.log"; }

# identify <path> -> component. A sha256 that the PREVIOUS receipt lists is
# accepted without running anything (Ruling 9); otherwise the banner.
identify() {
  id_path="$1"
  if [ -f "$RECEIPT" ] && id_sha=$(file_sha256 "$id_path" 2>/dev/null) && [ -n "$id_sha" ]; then
    id_comp=$(grep -F "\"sha256\": \"$id_sha\"" "$RECEIPT" 2>/dev/null | sed -n 's/.*"component": "\([^"]*\)".*/\1/p' | head -1)
    case "$id_comp" in kannaka|kannaka-tui|kannaka-hdl) printf '%s' "$id_comp"; return 0 ;; esac
  fi
  banner_component "$id_path"
}

# remove_ours <path> <reason>: unlink iff the file identifies as a component.
remove_ours() {
  ro_path="$1"; ro_reason="$2"
  [ -e "$ro_path" ] || return 1
  if ro_comp=$(identify "$ro_path"); then
    rm -f "$ro_path" && log_removed "$ro_path" "$ro_comp" "$ro_reason" && say "removed previous $ro_comp: $ro_path ($ro_reason)"
    return 0
  fi
  log_declined "$ro_path" "not kannaka"
  return 1
}

# Stale swap leftovers beside a binary that is ours: <name>.bak-*, .old, .new.
remove_stale_beside() { # remove_stale_beside <binary-path>
  rs_dir=$(dirname "$1"); rs_name=$(basename "$1")
  for rs_f in "$rs_dir/$rs_name".bak-* "$rs_dir/$rs_name.old" "$rs_dir/$rs_name.new"; do
    [ -e "$rs_f" ] || continue
    rm -f "$rs_f" && log_removed "$rs_f" "$rs_name" "stale swap leftover"
  done
}

# Canonical directory, or empty if it does not exist.
canon_dir() { (cd "$1" 2>/dev/null && pwd -P); }

# guard_targets: the three paths the download is about to overwrite. One that
# is ours is recorded as replaced; one that is NOT kannaka is moved aside and
# named, and the install goes on -- a truncated or foreign file at the target
# is exactly the state a re-run is meant to repair.
guard_targets() {
  gt_ts=$(date -u +%Y%m%dT%H%M%SZ)
  for gt_c in $EXPECTED_COMPONENTS; do
    gt_t="$DEST/$gt_c"
    [ -e "$gt_t" ] || continue
    if gt_got=$(identify "$gt_t"); then
      log_removed "$gt_t" "$gt_got" "replaced"
      remove_stale_beside "$gt_t"
    else
      mv -f "$gt_t" "$gt_t.notkannaka-$gt_ts" && log_declined "$gt_t.notkannaka-$gt_ts" "was at $gt_t and is not kannaka; moved aside"
    fi
  done
}

sweep_previous() {
  if [ "$KEEP_OTHERS" = "1" ]; then say "Keeping other installs (--keep-others)."; return 0; fi
  say "Looking for previous installs…"
  sp_home=$(canon_dir "$HOME"); sp_dest=$(canon_dir "$DEST")

  # 1. The cargo-install era (under $HOME by construction).
  for sp_c in $EXPECTED_COMPONENTS; do
    remove_ours "$HOME/.cargo/bin/$sp_c" "cargo install era" || true
  done

  # 2. Anything on PATH earlier than the target directory: it would shadow the
  #    binary just installed. Only directories under $HOME are touched; one
  #    outside is named and left. If the target is not on PATH, nothing can
  #    shadow it and this row does nothing.
  sp_ifs=$IFS; IFS=:
  for sp_d in $PATH; do
    IFS=$sp_ifs
    [ -n "$sp_d" ] || continue
    sp_cd=$(canon_dir "$sp_d"); [ -n "$sp_cd" ] || continue
    [ "$sp_cd" = "$sp_dest" ] && break
    [ "$sp_cd" = "$sp_home/.cargo/bin" ] && continue   # done above
    for sp_c in $EXPECTED_COMPONENTS; do
      [ -e "$sp_cd/$sp_c" ] || continue
      case "$sp_cd" in
        "$sp_home"/*)
          if remove_ours "$sp_cd/$sp_c" "earlier on PATH than $DEST"; then say "  it would have shadowed the new $sp_c"; fi ;;
        *) log_declined "$sp_cd/$sp_c" "outside your home; it is earlier on PATH than $DEST and will shadow the new $sp_c" ;;
      esac
    done
    IFS=:
  done
  IFS=$sp_ifs

  # 3. Package managers. Best-effort: a manager that is not installed, or
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
}

# The old marketplace registration: the row whose NAME is kannaka and whose
# SOURCE names the old owner. Lives beside the re-add in the Claude section so
# the two are never separated by a failure.
swap_old_marketplace() {
  if claude plugin marketplace list 2>/dev/null | grep -Ei '(^|[[:space:]])kannaka[[:space:]].*nickflach/kannaka-plugin' | grep -q .; then
    claude plugin marketplace remove kannaka >/dev/null 2>&1 && log_removed "claude-marketplace:github:NickFlach/kannaka-plugin" "-" "old marketplace source" && say "removed old marketplace registration"
  fi
}
```

Call sites:
- replace line 297 (`[ "$CLAIM_ONLY" = "1" ] || fetch_pinned "kannaka" …`) with
  ```sh
  [ "$CLAIM_ONLY" = "1" ] || guard_targets
  [ "$CLAIM_ONLY" = "1" ] || fetch_pinned "kannaka" "$RELEASE_REPO" "kannaka-${o}-${a}" "$DEST/kannaka" "kannaka" || exit 1
  ```
- after the `--version` check block (line 321, the `fi`) add
  ```sh
  [ "$CLAIM_ONLY" = "1" ] || sweep_previous
  ```
- in the Claude section, before line 643 (`claude plugin marketplace add …`) add `swap_old_marketplace`.
- record downloads: in `fetch_verified` after `chmod +x "$fv_dest"` add `log_file "$fv_dest" "$fv_label"`; in `fetch_pinned` after its `chmod +x "$fp_dest"` add `log_file "$fp_dest" "$fp_label"` (the labels are the component names).

Note: `WORK`, `RECEIPT` and the logs are defined before `set -eu` (line 207) is reached, and `trap … EXIT` must stay above the `set -e` line so a failed download still cleans the temp directory.

- [ ] **Step 4: Run the tests**

Run: `bash tests/installer-lifecycle.sh && sh -n install/install.sh`
Expected: every case `ok` except the receipt-related lines Task 3 delivers ("no receipt on failure" passes trivially now); "all cases passed" once Task 3 lands.

- [ ] **Step 5: Commit**

```bash
git add install/install.sh tests/installer-lifecycle.sh
git commit -m "install.sh: guard the targets, then sweep previous installs by identity once the engine is on disk"
```

---

### Task 3: The receipt in `install.sh`

**Files:**
- Modify: `install/install.sh` — constants near line 18, `json_list` and `write_receipt` after `swap_old_marketplace`, call before line 666 (`ok "Done…"`), records inside the sections that write files, `# /kannaka` closers at lines 309 and 500
- Test: `tests/installer-lifecycle.sh` (append)

**Interfaces:**
- Consumes: `$WORK/*.log`, `json_str`, `file_sha256`, `MANIFEST`, `DEST`, `CREDS`, `KCONF`, `o`, `a`, `launcher`
- Produces:
  - `INSTALLER_VERSION=2`, `INSTALLER_ID="kannaka-labs/kannaka-plugin/install/install.sh@$INSTALLER_VERSION"`
  - `CONFIG_EDITED` (0/1), `CREDS_WRITTEN` (0/1), `REGISTRATIONS` (0/1), `STATUSLINE` (0/1)
  - `json_list <file> <fields>`; `write_receipt` → temp file complete → lock → rotate → rename; returns 1 if it cannot

- [ ] **Step 1: Append the receipt and preserve tests**

```bash
echo "receipt"
root="$(mktemp -d)"; home="$root/home"; populate_old "$home"
FAKE_BREW_LIST="kannaka" run_install "$home"
R="$home/.kannaka/install.json"
[ -f "$R" ] && ok "receipt exists" || fail "no receipt"
"$PY" - "$R" "$home" "$root" <<'PY' && ok "receipt fields" || fail "receipt content"
import json, sys
r = json.load(open(sys.argv[1])); home = sys.argv[2]; root = sys.argv[3]
assert r["schema"] == 1, r
assert r["installer"].startswith("kannaka-labs/kannaka-plugin/install/install.sh@"), r["installer"]
assert r["manifest"] == "latest", r["manifest"]
assert r["platform"] == "linux-x86_64", r["platform"]
paths = {f["path"] for f in r["files"]}
assert paths == {home + "/.local/bin/kannaka", home + "/.local/bin/kannaka-tui", home + "/.local/bin/kannaka-hdl"}, paths
for f in r["files"]:
    assert len(f["sha256"]) == 64 and f["component"] in f["path"] and f["version"] == "9.9.9", f
# the PATH line pre-existed in .bashrc (not recorded); the credentials block did not (recorded)
assert [(e["file"], e["sentinel"]) for e in r["rc_edits"]] == [(home + "/.bashrc", "# kannaka swarm credentials")], r["rc_edits"]
assert r["path_edits"] == [], r["path_edits"]
assert r["config_edits"] == [], r["config_edits"]          # no --brain: nothing written to config.toml
assert r["credentials"] == [], r["credentials"]            # creds pre-existed: not written by this run
assert r["extras"] == [], r["extras"]                      # creds present: no launcher written
assert {x["kind"] for x in r["registrations"]} == {"claude-marketplace", "claude-plugin"}, r["registrations"]
removed = {(x["path"], x["reason"]) for x in r["removed"]}
assert (home + "/.cargo/bin/kannaka", "cargo install era") in removed, removed
assert (home + "/shadow/kannaka", "earlier on PATH than " + home + "/.local/bin") in removed, removed
assert (home + "/.local/bin/kannaka", "replaced") in removed, removed
assert ("brew:kannaka", "brew formula") in removed, removed
assert all(p != home + "/.cargo/bin/kannaka-hdl" for p, _ in removed), "impostor in removed"
declined = {x["path"]: x["reason"] for x in r["declined"]}
assert declined[home + "/.cargo/bin/kannaka-hdl"] == "not kannaka", declined
assert "outside your home" in declined[root + "/outside-bin/kannaka"], declined
assert r["previous"] == [], r["previous"]
PY
# the receipt is written LAST: nothing it lists is newer than it
newest=$(ls -t "$home/.local/bin" | head -1)
[ "$home/.local/bin/$newest" -nt "$R" ] && fail "a binary is newer than the receipt" || ok "receipt written after the binaries"
[ -e "$R.lock" ] && fail "lock left behind" || ok "lock released"
# a second install rotates
run_install "$home"
[ -f "$R.1" ] && ok "previous receipt rotated to .1" || fail "no rotation"
"$PY" -c "import json,sys; r=json.load(open(sys.argv[1])); assert r['previous']==['install.json.1'], r['previous']" "$R" && ok "previous lists .1" || fail "previous wrong"
run_install "$home"; run_install "$home"; run_install "$home"
[ -f "$R.3" ] && [ ! -f "$R.4" ] && ok "at most three deep" || fail "rotation depth wrong"
rm -rf "$root"

echo "receipt lists only what this run wrote"
root="$(mktemp -d)"; home="$root/home"; populate_old "$home"
run_install "$home" --skip-tui --skip-hdl
"$PY" -c "import json,sys; r=json.load(open(sys.argv[1])); assert [f['component'] for f in r['files']]==['kannaka'], r['files']" "$home/.kannaka/install.json" && ok "--skip-tui: the old tui beside the engine is not claimed" || fail "receipt claims a file this run did not write"
rm -rf "$root"

echo "rc edit, launcher and closers are recorded when the installer writes them"
root="$(mktemp -d)"; home="$root/home"; mkdir -p "$home/.local/bin" "$home/Desktop"
NO_DEST_ON_PATH=1 run_install "$home"     # fresh HOME, dest not on PATH, no creds: PATH block + launcher written
"$PY" - "$home/.kannaka/install.json" "$home" <<'PY' && ok "rc_edits and extras" || fail "rc_edits/extras wrong"
import json, sys
r = json.load(open(sys.argv[1])); home = sys.argv[2]
assert r["rc_edits"] == [{"file": home + "/.bashrc", "sentinel": "# kannaka"}], r["rc_edits"]
assert r["extras"] == [{"path": home + "/Desktop/Link Kannaka.command", "kind": "launcher"}], r["extras"]
PY
grep -qx '# /kannaka' "$home/.bashrc" && ok "PATH block is closed with # /kannaka" || fail "no closing marker"
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

echo "a fresh lock aborts the receipt (install still succeeds), a stale one is ignored"
root="$(mktemp -d)"; home="$root/home"; populate_old "$home"; mkdir -p "$home/.kannaka/install.json.lock"
run_install "$home"
[ -f "$home/.kannaka/install.json" ] && fail "receipt written past a fresh lock" || ok "fresh lock: no receipt"
check "exit 0 despite the lock" "0" "$(cat "$root/log/rc")"
grep -qi "lock" "$root/log/out" && ok "lock named in output" || fail "lock not mentioned"
touch -d '20 minutes ago' "$home/.kannaka/install.json.lock" 2>/dev/null || touch -t "$(date -v-20M +%Y%m%d%H%M)" "$home/.kannaka/install.json.lock"
run_install "$home"
[ -f "$home/.kannaka/install.json" ] && ok "stale lock ignored" || fail "stale lock still blocks"
rm -rf "$root"
```

- [ ] **Step 2: Run to verify these fail**

Run: `bash tests/installer-lifecycle.sh`
Expected: "no receipt" and everything after it in the receipt sections FAIL; the preserve cases already pass (they guard a regression).

- [ ] **Step 3: Implement**

Near line 18 (`INSTALL_URL=...`) add:

```sh
# What THIS run wrote, so that `kannaka uninstall` can reverse exactly it.
# Bump INSTALLER_VERSION whenever the receipt's shape or the sweep table changes.
INSTALLER_VERSION=2
INSTALLER_ID="kannaka-labs/kannaka-plugin/install/install.sh@$INSTALLER_VERSION"
CONFIG_EDITED=0; CREDS_WRITTEN=0; REGISTRATIONS=0; STATUSLINE=0
```

Records and closers (each inside the existing block):
- line 309, the PATH block: change the `printf` to end the block with a closer and record it:
  ```sh
  printf '\n# kannaka\ncase ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac\n# /kannaka\n' >> "$rc"
  printf '%s|# kannaka\n' "$rc" >> "$WORK/rc.log"
  ```
- line 500, the credentials block: likewise
  ```sh
  printf '\n# kannaka swarm credentials\n[ -f "$HOME/.kannaka-nats.env" ] && . "$HOME/.kannaka-nats.env"\n# /kannaka\n' >> "$crc"
  printf '%s|# kannaka swarm credentials\n' "$crc" >> "$WORK/rc.log"
  ```
- after line 449 (`chmod 600 "$CREDS"`): `CREDS_WRITTEN=1`
- after line 487 (`chmod +x "$launcher"`): `printf '%s|launcher\n' "$launcher" >> "$WORK/extras.log"`
- inside `write_llm_config` after the `mv` (line 551): `CONFIG_EDITED=1`
- after line 644 (`claude plugin install kannaka@kannaka …`): `REGISTRATIONS=1`
- line 648, the statusline: `bash "$setup" on && STATUSLINE=1 || true`

Add after `swap_old_marketplace`:

```sh
# ───────────────────────────────────────────────────────────────────────────
# THE RECEIPT. Written LAST and atomically: every path this run wrote, every
# rc edit, every registration, everything the sweep removed and declined. It is
# the definition of "an install" on this machine and the only thing
# `kannaka uninstall` needs. The last three receipts are kept beside it.
#
# Order: the new document is COMPLETE in a temp file first, then the rotation
# renames, then the temp is renamed into place. A crash anywhere leaves either
# the old receipt or the new one, never none. A lock directory serialises
# writers; a lock older than ten minutes is a crashed writer's and is ignored.
# ───────────────────────────────────────────────────────────────────────────
json_list() { # json_list <file> <fields> : one JSON object per TAB-separated line
  jl_tab=$(printf '\t'); jl_sep=""
  while IFS="$jl_tab" read -r jl_a jl_b jl_c; do
    [ -n "$jl_a" ] || continue
    case "$2" in
      path,component,reason) printf '%s\n    {"path": %s, "component": %s, "reason": %s}' "$jl_sep" "$(json_str "$jl_a")" "$(json_str "$jl_b")" "$(json_str "$jl_c")" ;;
      path,reason)           printf '%s\n    {"path": %s, "reason": %s}' "$jl_sep" "$(json_str "$jl_a")" "$(json_str "$jl_b")" ;;
    esac
    jl_sep=","
  done < "$1"
}

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
    while IFS="$wr_tab" read -r wr_p wr_c; do
      [ -n "$wr_p" ] && [ -x "$wr_p" ] || continue
      wr_ver=$("$wr_p" --version 2>/dev/null | head -1 | awk '{print $2}')
      printf '%s\n    {"path": %s, "sha256": %s, "component": %s, "version": %s}' \
        "$wr_sep" "$(json_str "$wr_p")" "$(json_str "$(file_sha256 "$wr_p")")" "$(json_str "$wr_c")" "$(json_str "${wr_ver:-unknown}")"
      wr_sep=","
    done < "$WORK/files.log"
    printf '\n  ],\n  "extras": ['
    wr_sep=""
    while IFS='|' read -r wr_p wr_k; do
      [ -n "$wr_p" ] || continue
      printf '%s\n    {"path": %s, "kind": %s}' "$wr_sep" "$(json_str "$wr_p")" "$(json_str "$wr_k")"; wr_sep=","
    done < "$WORK/extras.log"
    printf '\n  ],\n  "rc_edits": ['
    wr_sep=""
    while IFS='|' read -r wr_f wr_s; do
      [ -n "$wr_f" ] || continue
      printf '%s\n    {"file": %s, "sentinel": %s}' "$wr_sep" "$(json_str "$wr_f")" "$(json_str "$wr_s")"; wr_sep=","
    done < "$WORK/rc.log"
    printf '\n  ],\n  "path_edits": [],\n  "config_edits": ['
    [ "$CONFIG_EDITED" = "1" ] && printf '\n    {"file": %s, "sections": ["llm"]}' "$(json_str "$KCONF")"
    printf '\n  ],\n  "credentials": ['
    [ "$CREDS_WRITTEN" = "1" ] && printf '\n    {"file": %s}' "$(json_str "$CREDS")"
    printf '\n  ],\n  "registrations": ['
    wr_sep=""
    if [ "$REGISTRATIONS" = "1" ]; then
      printf '\n    {"kind": "claude-marketplace", "name": "kannaka-labs/kannaka-plugin"},\n    {"kind": "claude-plugin", "name": "kannaka@kannaka"}'; wr_sep=","
    fi
    [ "$STATUSLINE" = "1" ] && printf '%s\n    {"kind": "claude-statusline"}' "$wr_sep"
    printf '\n  ],\n  "removed": ['
    json_list "$WORK/removed.log" path,component,reason
    printf '\n  ],\n  "declined": ['
    json_list "$WORK/declined.log" path,reason
    printf '\n  ],\n  "previous": [__PREVIOUS__]\n}\n'
  } > "$wr_tmp" || { warn "could not write the install receipt"; rm -f "$wr_tmp"; return 1; }

  # Lock, rotate, fill in "previous", rename. The lock is a directory because
  # mkdir is atomic on every filesystem we install onto.
  wr_lock="$RECEIPT.lock"
  if ! mkdir "$wr_lock" 2>/dev/null; then
    if [ -n "$(find "$wr_lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
      rmdir "$wr_lock" 2>/dev/null; mkdir "$wr_lock" 2>/dev/null || { warn "another installer holds $wr_lock; receipt not written"; rm -f "$wr_tmp"; return 1; }
    else
      warn "another installer is writing $RECEIPT (its lock is younger than ten minutes); receipt not written"; rm -f "$wr_tmp"; return 1
    fi
  fi
  [ -f "$RECEIPT.2" ] && mv -f "$RECEIPT.2" "$RECEIPT.3"
  [ -f "$RECEIPT.1" ] && mv -f "$RECEIPT.1" "$RECEIPT.2"
  [ -f "$RECEIPT" ]   && mv -f "$RECEIPT"   "$RECEIPT.1"
  wr_prev=""; wr_sep=""
  for wr_n in 1 2 3; do
    [ -f "$RECEIPT.$wr_n" ] || continue
    wr_prev="$wr_prev$wr_sep$(json_str "install.json.$wr_n")"; wr_sep=", "
  done
  sed "s|__PREVIOUS__|$wr_prev|" "$wr_tmp" > "$wr_tmp.2" && mv -f "$wr_tmp.2" "$RECEIPT"
  rm -f "$wr_tmp"; rmdir "$wr_lock" 2>/dev/null
  ok "Install receipt → $RECEIPT"
}
```

Call it: immediately before line 666 (`ok "Done. kannaka → $DEST/kannaka"`) add

```sh
[ "$CLAIM_ONLY" = "1" ] || write_receipt || true
```

A `--claim-only` run installs nothing and must not rotate the receipt; a receipt that cannot be written (the lock case) is a warning, not a failed install.

- [ ] **Step 4: Run the tests**

Run: `bash tests/installer-lifecycle.sh && sh -n install/install.sh && bash tests/installer-checksum.sh && bash test/shell-rc.test.sh`
Expected: all `ok`, "all cases passed" for the lifecycle suite; the other two unchanged.

- [ ] **Step 5: Commit**

```bash
git add install/install.sh tests/installer-lifecycle.sh
git commit -m "install.sh: write an install receipt last (complete, then rotate, then rename, under a lock)"
```

---

### Task 4: The mutation that proves the identity guard is load-bearing, and CI

**Files:**
- Test: `tests/installer-lifecycle.sh` (append)
- Modify: `.github/workflows/ci.yml`

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
      - name: installer lifecycle — sweep by identity after the download, preserve set, receipt last (install.sh)
        run: bash tests/installer-lifecycle.sh
```

```bash
git add tests/installer-lifecycle.sh .github/workflows/ci.yml
git commit -m "tests: mutation proves the installer's identity guard; run the lifecycle suite in CI"
```

---

### Task 5: Identity, target guard, sweep and receipt in `install.ps1`

**Files:**
- Modify: `install/install.ps1` — `param()` (lines 17-42), functions after `Have` (line 49), `Test-TargetGuard` before `Install-Pinned` (line 216), `Invoke-Sweep` after the `--version` check (line 234), marketplace swap before line 514, records at lines 225, 347, 391, 425, 515, 528, receipt before line 548
- Test: `tests/installer-lifecycle.ps1` (create)

**Interfaces:**
- Produces (PowerShell; the test lifts each `function` block by regex and dot-evaluates it; every new function closes with `}` on its own line at column 0):
  - `-KeepOthers` switch
  - `$script:InstallerVersion = 2`; `$script:HomeDir = $HOME` (every new function reads this, never `$HOME`, because `$HOME` is read-only and the test points `HomeDir` at a temp dir); `$script:Receipt` = `<KANNAKA_DATA_DIR or HomeDir\.kannaka>\install.json`
  - `Invoke-VersionBanner([string]$Path)` → first line of `--version` with a 5 s timeout, or `$null`. **The only function that spawns a process; the test replaces exactly it.**
  - `Get-BannerComponent([string]$Path)` → `kannaka` | `kannaka-tui` | `kannaka-hdl` | `$null`; `$null` for any path not under `$script:HomeDir`
  - `Get-Identity([string]$Path)` → previous-receipt sha match first, then the banner
  - `Get-FileSha256([string]$Path)` → lowercase hex
  - `$script:Removed`, `$script:Declined`, `$script:Files`, `$script:Extras`, `$script:PathEdits`, `$script:Parked` (ArrayLists), `$script:ConfigEdited`, `$script:CredsWritten`, `$script:Registrations`, `$script:Statusline`
  - `Remove-Ours([string]$Path, [string]$Reason)` → `$true` if removed or parked
  - `Remove-StaleBeside([string]$Binary)` (skips a file parked this run)
  - `Get-UserPath` / `Set-UserPath([string]$v)`; `Get-MsiProduct` → the ProductCode of an installed Kannaka MSI or `$null` (the test replaces it)
  - `Test-TargetGuard([string]$Dest)` → moves non-identifying targets aside; never throws
  - `Invoke-Sweep([string]$Dest)`; `Remove-OldMarketplace`
  - `Write-Receipt([string]$Dest, [string]$Platform)`

- [ ] **Step 1: Write the failing test**

Create `tests/installer-lifecycle.ps1`:

```powershell
# installer-lifecycle.ps1 — the Windows installer sweeps by identity, keeps the
# preserve set, parks a locked exe, never touches a PATH entry but its own, and
# writes the receipt last. Runs the REAL functions lifted out of install.ps1
# against a throwaway HOME; the one process spawn (Invoke-VersionBanner) is
# replaced by a table lookup so no exe is needed.
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$installer = Join-Path $here "..\install\install.ps1"
$fails = 0
function Check($label, $expected, $actual) {
  if ("$expected" -eq "$actual") { Write-Host "  ok   $label" } else { Write-Host "  FAIL $label (expected: $expected, actual: $actual)"; $script:fails++ }
}
function Lift([string]$Name) {
  $src = Get-Content $installer -Raw
  if ($src -notmatch "(?ms)^function $([regex]::Escape($Name))\b.*?^\}\r?$") { throw "function $Name not found in install.ps1" }
  $Matches[0]
}
foreach ($f in 'Say','Warn','Ok','Have','Get-BannerComponent','Get-Identity','Get-FileSha256','Remove-Ours','Remove-StaleBeside','Test-TargetGuard','Invoke-Sweep','Write-Receipt') {
  Invoke-Expression (Lift $f)
}
$KeepOthers = $false
function Reset-State {
  $script:Removed = [System.Collections.ArrayList]@(); $script:Declined = [System.Collections.ArrayList]@()
  $script:Files = [System.Collections.ArrayList]@(); $script:Extras = [System.Collections.ArrayList]@()
  $script:PathEdits = [System.Collections.ArrayList]@(); $script:Parked = [System.Collections.ArrayList]@()
  $script:ConfigEdited = $false; $script:CredsWritten = $false; $script:Registrations = $false; $script:Statusline = $false
}
Reset-State
$script:InstallerVersion = 2; $script:Manifest = $null; $script:HomeDir = $env:TEMP
$script:Banners = @{}
function Invoke-VersionBanner([string]$Path) { if ($script:Banners.ContainsKey($Path)) { $script:Banners[$Path] } else { $null } }
function Get-MsiProduct { $script:Msi }
function Ours([string]$Path, [string]$Component, [string]$Version) {
  New-Item -ItemType File -Force -Path $Path | Out-Null; Set-Content -Path $Path -Value "$Component-$Version"; $script:Banners[$Path] = "$Component $Version (stub)"
}
function Impostor([string]$Path) { Set-Content -Path $Path -Value "nope"; $script:Banners[$Path] = "definitely-not-kannaka 9.9" }

Write-Host "identity"
$root = Join-Path $env:TEMP ("kl-" + [guid]::NewGuid().ToString("N")); New-Item -ItemType Directory -Path $root | Out-Null
$home_ = Join-Path $root "home"; New-Item -ItemType Directory -Path $home_ | Out-Null
$script:HomeDir = $home_
Ours "$home_\k.exe" kannaka 0.16.2; Impostor "$home_\x.exe"; Ours "$root\outside.exe" kannaka 0.16.2
Check "recognises kannaka" "kannaka" (Get-BannerComponent "$home_\k.exe")
Check "rejects impostor" "" (Get-BannerComponent "$home_\x.exe")
Check "rejects missing" "" (Get-BannerComponent "$home_\missing.exe")
Check "refuses a path outside home" "" (Get-BannerComponent "$root\outside.exe")
Set-Content -NoNewline -Path "$home_\h" -Value "abc"
Check "sha256" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" (Get-FileSha256 "$home_\h")

Write-Host "sweep"
$dest = "$home_\.local\bin"; $old = "$home_\AppData\Local\Programs\kannaka"; $outside = "$root\outside-bin"
foreach ($d in $dest, $old, "$home_\.cargo\bin", "$home_\.kannaka", "$home_\shadow", $outside) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
$lapSaved = $env:LOCALAPPDATA; $env:LOCALAPPDATA = "$home_\AppData\Local"
$pathSaved = $env:Path; $env:Path = "$home_\shadow;$outside;$old;$dest;$pathSaved"
$script:Receipt = "$home_\.kannaka\install.json"
Ours "$dest\kannaka.exe" kannaka 0.15.0
Ours "$old\kannaka.exe" kannaka 0.12.0; Ours "$old\kannaka-tui.exe" kannaka-tui 0.4.0
Ours "$home_\.cargo\bin\kannaka.exe" kannaka 0.9.0
Ours "$home_\shadow\kannaka-tui.exe" kannaka-tui 0.3.0
Ours "$outside\kannaka.exe" kannaka 0.13.0
Impostor "$home_\.cargo\bin\kannaka-hdl.exe"
Set-Content -Path "$dest\kannaka.exe.bak-123" -Value "stale"
Set-Content -Path "$home_\.kannaka\node_key.ed25519" -Value "IDENTITY"
Set-Content -Path "$home_\.cargo\bin\rg.exe" -Value "ripgrep"      # another cargo tool: its dir must keep its PATH entry
$script:UserPath = "C:\Windows;$old;$home_\.cargo\bin;$dest"
function Get-UserPath { $script:UserPath }
function Set-UserPath([string]$v) { $script:UserPath = $v }
$script:Msi = $null
Test-TargetGuard -Dest $dest
Invoke-Sweep -Dest $dest
Check "old programs dir kannaka removed" $false (Test-Path "$old\kannaka.exe")
Check "old programs dir tui removed" $false (Test-Path "$old\kannaka-tui.exe")
Check "cargo copy removed" $false (Test-Path "$home_\.cargo\bin\kannaka.exe")
Check "shadow under home removed" $false (Test-Path "$home_\shadow\kannaka-tui.exe")
Check "outside-home copy untouched" $true (Test-Path "$outside\kannaka.exe")
Check "outside-home copy declined and named" $true (@($script:Declined | Where-Object { $_.path -eq "$outside\kannaka.exe" -and $_.reason -like "*outside your home*" }).Count -eq 1)
Check "impostor untouched" $true (Test-Path "$home_\.cargo\bin\kannaka-hdl.exe")
Check "impostor named" $true (@($script:Declined | ForEach-Object { $_.path }) -contains "$home_\.cargo\bin\kannaka-hdl.exe")
Check "stale .bak removed" $false (Test-Path "$dest\kannaka.exe.bak-123")
Check "target recorded as replaced" $true (@($script:Removed | Where-Object { $_.path -eq "$dest\kannaka.exe" -and $_.reason -eq "replaced" }).Count -eq 1)
Check "target itself not unlinked" $true (Test-Path "$dest\kannaka.exe")
Check "only the old install dir dropped from user PATH" "C:\Windows;$home_\.cargo\bin;$dest" $script:UserPath
Check "identity untouched" "IDENTITY" ((Get-Content "$home_\.kannaka\node_key.ed25519") -join "")

Write-Host "an old install dir that is not empty keeps its PATH entry"
Reset-State
Ours "$old\kannaka.exe" kannaka 0.12.0; Set-Content -Path "$old\notes.txt" -Value "mine"
$script:UserPath = "C:\Windows;$old;$dest"
Invoke-Sweep -Dest $dest
Check "kannaka removed" $false (Test-Path "$old\kannaka.exe")
Check "PATH entry kept because the dir still holds something" "C:\Windows;$old;$dest" $script:UserPath
Remove-Item "$old\notes.txt"

Write-Host "an MSI-managed copy is printed, not unlinked"
Reset-State
Ours "$old\kannaka.exe" kannaka 0.12.0
$script:Msi = "{11111111-2222-3333-4444-555555555555}"
Invoke-Sweep -Dest $dest
Check "msi copy still there" $true (Test-Path "$old\kannaka.exe")
Check "msiexec line declined-with-command" $true (@($script:Declined | Where-Object { $_.reason -like "*msiexec /x {11111111*" }).Count -eq 1)
$script:Msi = $null; Remove-Item "$old\kannaka.exe"

Write-Host "locked exe is parked, not skipped, and not re-swept"
Reset-State
Ours "$old\kannaka.exe" kannaka 0.12.0
$fs = [System.IO.File]::Open("$old\kannaka.exe", 'Open', 'Read', 'None')
try { $parked = Remove-Ours -Path "$old\kannaka.exe" -Reason "test"; Remove-StaleBeside "$old\kannaka.exe" } finally { $fs.Close() }
Check "reported removed" $true $parked
Check "parked as .bak-<pid>" 1 (@(Get-ChildItem $old -Filter "kannaka.exe.bak-*").Count)
Check "reason parked" "parked" (@($script:Removed | Where-Object { $_.path -eq "$old\kannaka.exe" })[-1].reason)
Check "listed under Parked" 1 @($script:Parked).Count
Get-ChildItem $old -Filter "kannaka.exe.bak-*" | Remove-Item -Force

Write-Host "impostor at the target is moved aside, install continues"
Reset-State
Impostor "$dest\kannaka-tui.exe"
Test-TargetGuard -Dest $dest
Check "moved aside" 1 (@(Get-ChildItem $dest -Filter "kannaka-tui.exe.notkannaka-*").Count)
Check "target path free" $false (Test-Path "$dest\kannaka-tui.exe")
Check "named under Declined" $true (@($script:Declined | Where-Object { $_.path -like "*notkannaka-*" }).Count -eq 1)
Get-ChildItem $dest -Filter "kannaka-tui.exe.notkannaka-*" | Remove-Item -Force

Write-Host "previous-receipt sha match skips the spawn"
Reset-State
Ours "$home_\.cargo\bin\kannaka.exe" kannaka 0.9.0
$sha = Get-FileSha256 "$home_\.cargo\bin\kannaka.exe"
$script:Banners.Remove("$home_\.cargo\bin\kannaka.exe")     # the banner lookup would now fail
New-Item -ItemType Directory -Force -Path "$home_\.kannaka" | Out-Null
Set-Content -Path $script:Receipt -Value ('{"schema":1,"files":[{"path":"' + ("$home_\.cargo\bin\kannaka.exe" -replace '\\','\\\\') + '","sha256":"' + $sha + '","component":"kannaka","version":"0.9.0"}]}')
Check "identified from the receipt without a banner" "kannaka" (Get-Identity "$home_\.cargo\bin\kannaka.exe")
Remove-Item $script:Receipt

Write-Host "receipt"
Reset-State
Ours "$dest\kannaka.exe" kannaka 9.9.9; Ours "$dest\kannaka-tui.exe" kannaka-tui 9.9.9
[void]$script:Files.Add(@{ path = "$dest\kannaka.exe"; component = "kannaka" })     # only what THIS run wrote
[void]$script:PathEdits.Add(@{ scope = "user"; entry = $dest })
[void]$script:Extras.Add(@{ path = "$home_\Desktop\Link Kannaka.cmd"; kind = "launcher" })
$script:Registrations = $true; $script:Statusline = $true; $script:CredsWritten = $true
Write-Receipt -Dest $dest -Platform "windows-x86_64"
$r = Get-Content $script:Receipt -Raw | ConvertFrom-Json
Check "schema" 1 $r.schema
Check "installer" "kannaka-labs/kannaka-plugin/install/install.ps1@2" $r.installer
Check "one file: the one this run wrote" 1 @($r.files).Count
Check "file version from banner" "9.9.9" (@($r.files)[0].version)
Check "path edit recorded" $dest (@($r.path_edits)[0].entry)
Check "launcher recorded" "launcher" (@($r.extras)[0].kind)
Check "credentials as user-env" "user-env" (@($r.credentials)[0].kind)
Check "registrations incl. statusline" 3 @($r.registrations).Count
Check "previous empty first time" 0 @($r.previous).Count
Write-Receipt -Dest $dest -Platform "windows-x86_64"
Check "rotated to .1" $true (Test-Path "$($script:Receipt).1")
Check "lock released" $false (Test-Path "$($script:Receipt).lock")
Write-Receipt -Dest $dest -Platform "windows-x86_64"; Write-Receipt -Dest $dest -Platform "windows-x86_64"; Write-Receipt -Dest $dest -Platform "windows-x86_64"
Check "three deep" $true ((Test-Path "$($script:Receipt).3") -and -not (Test-Path "$($script:Receipt).4"))
New-Item -ItemType Directory -Path "$($script:Receipt).lock" | Out-Null
$before = (Get-Item $script:Receipt).LastWriteTimeUtc
Write-Receipt -Dest $dest -Platform "windows-x86_64"
Check "fresh lock: receipt not rewritten" $before (Get-Item $script:Receipt).LastWriteTimeUtc
Remove-Item "$($script:Receipt).lock"

Write-Host "mutation: an identity guard that accepts everything deletes the impostor"
Reset-State
Impostor "$home_\.cargo\bin\kannaka-hdl.exe"
function Get-BannerComponent([string]$Path) { "kannaka" }
Invoke-Sweep -Dest $dest
Check "mutant deleted the impostor (fixture reaches the guard)" $false (Test-Path "$home_\.cargo\bin\kannaka-hdl.exe")

$env:LOCALAPPDATA = $lapSaved; $env:Path = $pathSaved
Remove-Item -Recurse -Force $root
if ($fails -gt 0) { Write-Host "installer-lifecycle.ps1: $fails failed"; exit 1 } else { Write-Host "installer-lifecycle.ps1: all cases passed" }
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh ./tests/installer-lifecycle.ps1` (on this box: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/installer-lifecycle.ps1`)
Expected: throws at `Lift 'Get-BannerComponent'` ("function … not found").

- [ ] **Step 3: Implement in `install.ps1`**

Add to `param()` after `[switch]$SkipHdl,`:

```powershell
  # A machine that deliberately runs two versions: skip the sweep of previous installs (not the target guard).
  [switch]$KeepOthers,
```

After `function Have` (line 49) add:

```powershell
# ───────────────────────────────────────────────────────────────────────────
# IDENTITY. Nothing is removed because of where it is, only because of what
# its --version banner says it is: "<component> <version> ...". The check runs
# the candidate, so it is bounded to paths under the home directory and to
# five seconds. The spawn is isolated in Invoke-VersionBanner so the tests can
# replace exactly that.
# ───────────────────────────────────────────────────────────────────────────
$script:InstallerVersion = 2
# $HOME is a read-only automatic variable; new code reads this copy so the
# tests can point it at a throwaway directory.
$script:HomeDir = $HOME
$script:Receipt = Join-Path $(if ($env:KANNAKA_DATA_DIR) { $env:KANNAKA_DATA_DIR } else { Join-Path $script:HomeDir ".kannaka" }) "install.json"
$script:Removed = [System.Collections.ArrayList]@()
$script:Declined = [System.Collections.ArrayList]@()
$script:Files = [System.Collections.ArrayList]@()        # what THIS run wrote, appended at download time
$script:Extras = [System.Collections.ArrayList]@()
$script:PathEdits = [System.Collections.ArrayList]@()
$script:Parked = [System.Collections.ArrayList]@()
$script:ConfigEdited = $false
$script:CredsWritten = $false
$script:Registrations = $false
$script:Statusline = $false

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
  $full = [System.IO.Path]::GetFullPath($Path)
  $homeFull = [System.IO.Path]::GetFullPath($script:HomeDir).TrimEnd('\') + '\'
  if (-not $full.StartsWith($homeFull, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
  $line = Invoke-VersionBanner $Path
  if (-not $line) { return $null }
  $parts = "$line".Trim() -split '\s+', 2
  if ($parts.Count -lt 2 -or $parts[1] -notmatch '^v?\d') { return $null }
  if ($parts[0] -in 'kannaka','kannaka-tui','kannaka-hdl') { return $parts[0] }
  $null
}

function Get-FileSha256([string]$Path) {
  (Get-FileHash $Path -Algorithm SHA256).Hash.ToLower()
}

# Get-Identity: a sha256 the PREVIOUS receipt lists is accepted without a
# spawn; otherwise the banner decides.
function Get-Identity([string]$Path) {
  if ((Test-Path -PathType Leaf $Path) -and (Test-Path $script:Receipt)) {
    try {
      $sha = Get-FileSha256 $Path
      $prev = Get-Content $script:Receipt -Raw | ConvertFrom-Json
      $hit = @($prev.files | Where-Object { $_.sha256 -eq $sha -and $_.component -in 'kannaka','kannaka-tui','kannaka-hdl' })
      if ($hit.Count -gt 0) { return $hit[0].component }
    } catch {}
  }
  Get-BannerComponent $Path
}

# Remove-Ours: delete iff the file identifies as a component. A locked exe (it
# is running) is parked as <name>.bak-<pid>; the next kannaka or installer
# sweeps it. Returns $true when removed or parked.
function Remove-Ours([string]$Path, [string]$Reason) {
  if (-not (Test-Path $Path)) { return $false }
  $c = Get-Identity $Path
  if (-not $c) { [void]$script:Declined.Add(@{ path = $Path; reason = "not kannaka" }); Warn "left alone: $Path (not kannaka)"; return $false }
  try {
    Remove-Item -Force -ErrorAction Stop $Path
    [void]$script:Removed.Add(@{ path = $Path; component = $c; reason = $Reason }); Say "removed previous ${c}: $Path ($Reason)"
  } catch {
    $bak = "$Path.bak-$PID"
    Move-Item -Force -ErrorAction Stop $Path $bak
    [void]$script:Removed.Add(@{ path = $Path; component = $c; reason = "parked" })
    [void]$script:Parked.Add($bak)
    Say "previous $c was in use — parked as $(Split-Path $bak -Leaf) (swept on the next run)"
  }
  $true
}

function Remove-StaleBeside([string]$Binary) {
  $dir = Split-Path $Binary -Parent; $name = Split-Path $Binary -Leaf
  foreach ($f in @(Get-ChildItem -Path $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$name.bak-*" -or $_.Name -eq "$name.old" -or $_.Name -eq "$name.new" })) {
    if ($script:Parked -contains $f.FullName) { continue }
    try { Remove-Item -Force -ErrorAction Stop $f.FullName; [void]$script:Removed.Add(@{ path = $f.FullName; component = $name; reason = "stale swap leftover" }) } catch {}
  }
}

# User-PATH access and the MSI lookup are isolated so the tests can substitute them.
function Get-UserPath {
  [Environment]::GetEnvironmentVariable("Path", "User")
}
function Set-UserPath([string]$v) {
  [Environment]::SetEnvironmentVariable("Path", $v, "User")
}
function Get-MsiProduct {
  foreach ($k in @(Get-ChildItem "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall" -ErrorAction SilentlyContinue)) {
    $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
    if ($p.DisplayName -like "Kannaka*" -and $p.PSChildName -match '^\{[0-9A-F-]+\}$') { return $p.PSChildName }
  }
  $null
}

# Test-TargetGuard: the three paths the download is about to overwrite. Ours
# is recorded as replaced; a file that is NOT kannaka is moved aside and named,
# and the install goes on.
function Test-TargetGuard([string]$Dest) {
  $ts = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
  foreach ($c in 'kannaka','kannaka-tui','kannaka-hdl') {
    $t = Join-Path $Dest "$c.exe"
    if (-not (Test-Path $t)) { continue }
    $got = Get-Identity $t
    if ($got) {
      [void]$script:Removed.Add(@{ path = $t; component = $got; reason = "replaced" }); Remove-StaleBeside $t
    } else {
      $aside = "$t.notkannaka-$ts"
      try { Move-Item -Force -ErrorAction Stop $t $aside; [void]$script:Declined.Add(@{ path = $aside; reason = "was at $t and is not kannaka; moved aside" }); Warn "moved aside: $t is not kannaka -> $(Split-Path $aside -Leaf)" }
      catch { [void]$script:Declined.Add(@{ path = $t; reason = "not kannaka and could not be moved aside: $_" }) }
    }
  }
}

function Invoke-Sweep([string]$Dest) {
  if ($KeepOthers) { Say "Keeping other installs (-KeepOthers)."; return }
  Say "Looking for previous installs…"
  $components = 'kannaka','kannaka-tui','kannaka-hdl'
  $homeFull = [System.IO.Path]::GetFullPath($script:HomeDir).TrimEnd('\') + '\'
  $destFull = [System.IO.Path]::GetFullPath($Dest).TrimEnd('\')
  # 1. the old memory-installer directory and the cargo era
  $oldDir = Join-Path $env:LOCALAPPDATA "Programs\kannaka"
  $cargo = Join-Path $script:HomeDir ".cargo\bin"
  $msi = Get-MsiProduct
  foreach ($d in @($oldDir, $cargo)) {
    if (-not (Test-Path $d)) { continue }
    foreach ($f in @(Get-ChildItem -Path $d -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -in @('kannaka.exe','kannaka-tui.exe','kannaka-hdl.exe') })) {
      if ($d -eq $oldDir -and $msi) {
        [void]$script:Declined.Add(@{ path = $f.FullName; reason = "installed by the Kannaka MSI; remove it with: msiexec /x $msi" }); Warn "left alone: $($f.FullName) (MSI-managed; run: msiexec /x $msi)"; continue
      }
      if (Remove-Ours -Path $f.FullName -Reason "previous install dir $d") { Remove-StaleBeside $f.FullName }
    }
  }
  # 2. the user-PATH entry for the old install dir, only when the dir is now empty of EVERYTHING
  if ((Test-Path $oldDir) -and -not @(Get-ChildItem -Path $oldDir -Force -ErrorAction SilentlyContinue).Count) {
    $up = Get-UserPath
    if ($up) {
      $entries = @($up -split ';' | Where-Object { $_ })
      $keep = @($entries | Where-Object { $_.TrimEnd('\') -ne $oldDir.TrimEnd('\') })
      if ($keep.Count -ne $entries.Count) {
        Set-UserPath ($keep -join ';')
        [void]$script:Removed.Add(@{ path = "user-path:$oldDir"; component = "-"; reason = "PATH entry for the emptied old install dir" }); Say "removed $oldDir from your PATH (it is empty now)"
      }
    }
  }
  # 3. anything on PATH earlier than $Dest that would shadow the new binary; only under home
  foreach ($d in @($env:Path -split ';' | Where-Object { $_ })) {
    $dFull = try { [System.IO.Path]::GetFullPath($d).TrimEnd('\') } catch { continue }
    if ($dFull -eq $destFull) { break }
    if ($dFull -eq $oldDir.TrimEnd('\') -or $dFull -eq $cargo.TrimEnd('\')) { continue }
    foreach ($c in $components) {
      $p = Join-Path $dFull "$c.exe"
      if (-not (Test-Path $p)) { continue }
      if (($dFull + '\').StartsWith($homeFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        if (Remove-Ours -Path $p -Reason "earlier on PATH than $Dest") { Say "  it would have shadowed the new $c" }
      } else {
        [void]$script:Declined.Add(@{ path = $p; reason = "outside your home; it is earlier on PATH than $Dest and will shadow the new $c" }); Warn "left alone: $p (outside your home; it will shadow the new $c)"
      }
    }
  }
  # 4. npm globals
  if (Have npm) {
    $globals = (& npm ls -g --depth=0 2>$null) -join "`n"
    foreach ($p in 'kannaka','kannaktopus') {
      if ($globals -match " $p@") { & npm rm -g $p *> $null; [void]$script:Removed.Add(@{ path = "npm:$p"; component = $p; reason = "npm global" }); Say "removed npm global $p" }
    }
  }
}

# The old marketplace registration: the row whose NAME is kannaka and whose
# SOURCE names the old owner; lives beside the re-add in the Claude section.
function Remove-OldMarketplace {
  $rows = @(& claude plugin marketplace list 2>$null)
  if (@($rows | Where-Object { $_ -match '(^|\s)kannaka\s' -and $_ -imatch 'nickflach/kannaka-plugin' }).Count -gt 0) {
    & claude plugin marketplace remove kannaka *> $null
    [void]$script:Removed.Add(@{ path = "claude-marketplace:github:NickFlach/kannaka-plugin"; component = "-"; reason = "old marketplace source" }); Say "removed old marketplace registration"
  }
}

function Write-Receipt([string]$Dest, [string]$Platform) {
  $dir = Split-Path $script:Receipt -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $files = @()
  foreach ($e in $script:Files) {
    if (-not (Test-Path $e.path)) { continue }
    $ver = "unknown"; $b = Invoke-VersionBanner $e.path; if ($b) { $ver = ("$b".Trim() -split '\s+')[1] }
    $files += [ordered]@{ path = $e.path; sha256 = (Get-FileSha256 $e.path); component = $e.component; version = $ver }
  }
  $regs = @()
  if ($script:Registrations) { $regs += [ordered]@{ kind = "claude-marketplace"; name = "kannaka-labs/kannaka-plugin" }; $regs += [ordered]@{ kind = "claude-plugin"; name = "kannaka@kannaka" } }
  if ($script:Statusline) { $regs += [ordered]@{ kind = "claude-statusline" } }
  $cfg = @(); if ($script:ConfigEdited) { $cfg = @([ordered]@{ file = (Join-Path $script:HomeDir ".kannaka\config.toml"); sections = @("llm") }) }
  $creds = @(); if ($script:CredsWritten) { $creds = @([ordered]@{ kind = "user-env"; names = @("NATS_USER", "NATS_PASSWORD") }) }
  $manifest = "latest"; if ($script:Manifest) { $manifest = "library@" + $script:Manifest.generated }
  $doc = [ordered]@{
    schema = 1; installed_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    installer = "kannaka-labs/kannaka-plugin/install/install.ps1@$($script:InstallerVersion)"
    manifest = $manifest; platform = $Platform
    files = @($files)
    extras = @($script:Extras | ForEach-Object { [ordered]@{ path = $_.path; kind = $_.kind } })
    rc_edits = @()
    path_edits = @($script:PathEdits | ForEach-Object { [ordered]@{ scope = $_.scope; entry = $_.entry } })
    config_edits = @($cfg); credentials = @($creds); registrations = @($regs)
    removed = @($script:Removed | ForEach-Object { [ordered]@{ path = $_.path; component = $_.component; reason = $_.reason } })
    declined = @($script:Declined | ForEach-Object { [ordered]@{ path = $_.path; reason = $_.reason } })
    previous = @()
  }
  # complete temp first, then lock, rotate, fill previous, rename
  $tmp = "$($script:Receipt).tmp.$PID"
  $doc | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding utf8
  $lock = "$($script:Receipt).lock"
  if (Test-Path $lock) {
    if ((Get-Item $lock).LastWriteTimeUtc -lt (Get-Date).ToUniversalTime().AddMinutes(-10)) { Remove-Item $lock -Force -Recurse }
    else { Warn "another installer is writing $($script:Receipt) (its lock is younger than ten minutes); receipt not written"; Remove-Item $tmp -Force; return }
  }
  New-Item -ItemType Directory -Path $lock | Out-Null
  try {
    if (Test-Path "$($script:Receipt).2") { Move-Item -Force "$($script:Receipt).2" "$($script:Receipt).3" }
    if (Test-Path "$($script:Receipt).1") { Move-Item -Force "$($script:Receipt).1" "$($script:Receipt).2" }
    if (Test-Path $script:Receipt)        { Move-Item -Force $script:Receipt "$($script:Receipt).1" }
    $prev = @(); foreach ($n in 1, 2, 3) { if (Test-Path "$($script:Receipt).$n") { $prev += "install.json.$n" } }
    $doc.previous = @($prev)
    $doc | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding utf8
    Move-Item -Force $tmp $script:Receipt
  } finally { Remove-Item $lock -Force -Recurse -ErrorAction SilentlyContinue }
  Ok "Install receipt → $($script:Receipt)"
}
```

Call sites and records:
- before line 216 (`Install-Pinned -Component "kannaka" …`), inside the same `if (-not $ClaimOnly)`: `Test-TargetGuard -Dest $dest`
- in `Install-Pinned` and `Install-Verified`, after the final `Move-Item -Force $tmp $Target` succeeds (both branches of each try/catch): `[void]$script:Files.Add(@{ path = $Target; component = $Label })`
- after line 225 (`[Environment]::SetEnvironmentVariable("Path", …)`): `[void]$script:PathEdits.Add(@{ scope = "user"; entry = $dest })`
- after the `--version` check (line 234): `if (-not $ClaimOnly) { Invoke-Sweep -Dest $dest }`
- after line 347 (`SetEnvironmentVariable("NATS_PASSWORD", …)`): `$script:CredsWritten = $true`
- after line 391 (the launcher `Set-Content`): `[void]$script:Extras.Add(@{ path = $launcher; kind = "launcher" })`
- inside `Write-LlmConfig` after `Set-Content` (line 425): `$script:ConfigEdited = $true`
- before line 514 (`claude plugin marketplace add …`): `Remove-OldMarketplace`
- after line 515 (`claude plugin install kannaka@kannaka …`): `$script:Registrations = $true`
- line 528 (`bash ($setup.FullName …) on`): `if ($LASTEXITCODE -eq 0) { $script:Statusline = $true }` on the next line
- before line 548 (`Ok "Done. kannaka.exe → $exe"`): `if (-not $ClaimOnly) { Write-Receipt -Dest $dest -Platform "windows-x86_64" }`
- after the `Done.` block: `if ($script:Declined.Count -gt 0) { Warn "$($script:Declined.Count) file(s) were left alone (listed above)." }` and `if ($script:Parked.Count -gt 0) { Say "$($script:Parked.Count) running file(s) were parked and will be swept on the next run." }`

PowerShell 5.1 note: `ConvertTo-Json` turns a single-element array into a scalar unless wrapped in `@()` at the property, which is why every list above is `@(...)`.

- [ ] **Step 4: Run the tests**

Run: `pwsh ./tests/installer-lifecycle.ps1; pwsh ./tests/installer-checksum.ps1; pwsh ./tests/installer-manifest.ps1` (on this box use `powershell -NoProfile -ExecutionPolicy Bypass -File <test>`)
Expected: all three report all cases passed. The lock case uses a real `FileStream`, which is what makes the "parked" branch executed rather than believed.

- [ ] **Step 5: Wire into CI and commit**

In `.github/workflows/ci.yml` under `installer-win` after the `installer-manifest.ps1` step:

```yaml
      - name: installer lifecycle — target guard, sweep by identity after the download, parked exe, receipt last (install.ps1)
        shell: pwsh
        run: ./tests/installer-lifecycle.ps1
```

```bash
git add install/install.ps1 tests/installer-lifecycle.ps1 .github/workflows/ci.yml
git commit -m "install.ps1: target guard, sweep by identity after the download, park locked exes, receipt last"
```

---

### Task 6: README, the summary lines, and the receipt fixture for kannaka-memory

**Files:**
- Modify: `README.md` (the install section), `install/install.sh` (summary lines 665-671), `install/install.ps1` (summary lines 547-551)
- Create: `tests/fixtures/receipt-from-install-sh.json` (a receipt produced by the lifecycle test's "fresh over old" run; kannaka-memory's tests parse this same file, §9)

- [ ] **Step 1: Summary lines**

In both installers, after the `Done.` lines, add one line naming the receipt and the way back:

```sh
[ "$CLAIM_ONLY" = "1" ] || say "     receipt: $RECEIPT   (uninstall with: kannaka uninstall)"
```

```powershell
if (-not $ClaimOnly) { Say "     receipt: $($script:Receipt)   (uninstall with: kannaka uninstall)" }
```

- [ ] **Step 2: The fixture**

The "fresh over old" case already copies its receipt out when `KEEP_FIXTURE` is set. Run:

```bash
KEEP_FIXTURE=1 bash tests/installer-lifecycle.sh && ls -l tests/fixtures/receipt-from-install-sh.json
```

and commit the file. It contains temp-dir paths; that is fine, it is a document to parse, not a machine to act on.

- [ ] **Step 3: README**

Add under the install section:

```markdown
### A fresh install replaces the old one

Once the new engine is downloaded and verified, the installer looks for every previous
kannaka under your home — `~/.local/bin`, `~/.cargo/bin`, anything earlier on `PATH` — plus
the brew formula (either tap name), the npm global and the old marketplace registration, and
removes what **identifies itself** as kannaka (`--version` says so). A file at one of those
paths that is not kannaka is left alone and named; a kannaka outside your home is named with
the command that removes it and left alone. Pass `--keep-others` (`-KeepOthers` on Windows)
to skip this on a machine that deliberately runs two versions.

Nothing under `~/.kannaka` (or `KANNAKA_DATA_DIR`) is touched except `install.json`, the
**receipt**: what this install wrote, what it removed and declined, and the last three
receipts beside it. `kannaka uninstall` reads it and reverses exactly that; `kannaka
uninstall --purge` also moves `~/.kannaka` aside and removes the shell rc blocks, the
credentials and the Claude registrations.
```

- [ ] **Step 4: Run everything, commit**

Run: `bash tests/installer-lifecycle.sh && bash tests/installer-checksum.sh && bash test/shell-rc.test.sh && sh -n install/install.sh`

```bash
git add README.md install/install.sh install/install.ps1 tests/fixtures/receipt-from-install-sh.json
git commit -m "docs: the fresh-install sweep, the receipt, where uninstall lives; a real receipt as a fixture"
```

---

## Self-review

**Spec coverage (rev 2).** §3: `files` from `files.log` at download time (T2/T3/T5), `extras`, `path_edits`, `declined`, `claude-statusline`, both credential shapes, rotated files, write-then-rotate-then-rename with lock, control-character escaping and skip (T1/T3/T5). §4: sweep after the download and PATH block (T2 call site, T5), target guard moves aside (T2/T5), PATH shadow bounded to `$HOME` and to entries before the target with canonical comparison (T2/T5), receipt sha match skips execution (T2 `identify`, T5 `Get-Identity`), five-second cap on every platform (T1 `run_capped`), marketplace row match beside the re-add (T2 `swap_old_marketplace`, T5 `Remove-OldMarketplace`), Windows: both dirs, MSI printed, park + exempt, PATH entry only for the old dir when empty (T5). `--keep-others` keeps the guard (T2/T5). §5: closers `# /kannaka` (T3). §9 fixtures: fresh-over-old with impostor and outside-home (T2/T5), download fails (T2), outside home (T1/T2/T5), preserve (T3), receipt only what was written (T3/T5), rotation and lock (T3/T5), mutation (T4/T5), cross-repo fixture (T2 hook + T6). §6/§7 → binary plan.

**Placeholders.** None.

**Type consistency.** `files.log` is `path<TAB>component`; `rc.log` and `extras.log` are `|`-separated (paths may contain spaces, never `|`); `removed.log`/`declined.log` are tab-separated and read by `json_list` with the field lists it names. `identify` is what both `remove_ours` and `guard_targets` call; `banner_component` is what the mutation replaces, and `identify` falls through to it whenever the receipt has no matching sha, which is the mutation fixture's situation (no receipt). `$script:Files` entries are `@{path;component}` and `Write-Receipt` reads exactly those keys.

**Known gaps, stated.** (1) `identify`'s receipt lookup greps the previous receipt line-by-line and relies on our writer's one-entry-per-line layout; a hand-edited receipt degrades to the banner path, never to a wrong deletion. (2) The `--claim-only` path writes no receipt and records nothing; it installs nothing, so there is nothing to record. (3) `Get-MsiProduct` reads HKCU only; a per-machine MSI (HKLM) is not detected, and a per-machine MSI does not install under `%LOCALAPPDATA%`, so the case does not arise. (4) The shadow scan compares canonical directories, so a `PATH` entry with a trailing slash or a symlink resolves correctly; a `PATH` entry that does not exist is skipped.
