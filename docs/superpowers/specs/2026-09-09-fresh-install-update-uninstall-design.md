# Fresh install, update, uninstall — one installer, one truth

Trigger: the constellation moved to the `kannaka-labs` organisation on 2026-09-08. Every
install path kept working only because GitHub forwards the old owner, and the sweep that
followed found there was no way to uninstall anything, no way to detect an old install,
and two installers that disagreed about what an install is. Nick's requirement, verbatim
in spirit: *everything installs from kannaka-labs from here on; a fresh download always
removes and replaces the old, re-updates, installs the new, and preserves anything that
can be preserved.*

Cost: $0. No new hosting, no new secrets. Ships in kannaka-plugin (the installer) and
kannaka-memory (the binary).

Revision 2 (2026-09-09): after an adversarial review of revision 1. The changes are the
ordering of the sweep (after the engine is on disk, never before), the bounds on what the
sweep may execute and remove, the rules that make `--purge` reversible, and the receipt
being written by the run rather than by a directory scan. Each is marked **(rev 2)**.

## 1. What exists today, and what is wrong with it

| surface | where | state |
|---|---|---|
| one-shot installer, macOS/Linux | `kannaka-plugin/install/install.sh` | canonical; binary-first, signed manifest from kannaka-library, idempotent, Claude-optional; **no uninstall, no old-install detection, no record of what it wrote** |
| one-shot installer, Windows | `kannaka-plugin/install/install.ps1` | same, to `~\.local\bin` |
| second installer | `kannaka-memory/scripts/install.{sh,ps1}` | older duplicate; owner just repointed; its header advertises `install.ninja-portal.com/kannaka`; the name resolves since 2026-09-09 but the host serves nothing there yet (no certificate, no redirect installed) |
| npm | `kannaka` on npmjs, `packaging/npm/install.js` | postinstall downloads the same release binary; a third path to keep in sync |
| brew | `kannaka-labs/homebrew-kannaka` | repointed; users who tapped the OLD name still hold a tap named `nickflach/kannaka` |
| Claude plugin | marketplace `kannaka-labs/kannaka-plugin`, plugin `kannaka@kannaka` | repointed; users who registered the OLD marketplace name keep it |
| the binary | `kannaka update` | replaces itself safely (unique `.bak-<pid>`, sha256 sidecar, Windows-aware, sweeps stale backups); updates **only** `kannaka` and `kannaka-tui`, not `kannaka-hdl`; **no `uninstall`** |
| user data | `~/.kannaka/` or `KANNAKA_DATA_DIR` | `config.toml`, `agent_id`, `node_key.ed25519`, `kannaka.hrm`, `snapshots/`, `*.json` — never touched by anything today, by luck rather than rule |
| shell state | `~/.bashrc` / `~/.zshrc` / `~/.profile`, Windows user PATH | a `# kannaka` PATH block, swarm credentials; nothing knows how to take them back out |
| Claude Code state | `~/.claude/settings.json` `statusLine`, `~/.claude/plugins/cache/kannaka` | written by the installer's statusline step; nothing records or reverses it |
| hosts | `ops/services/install-services.sh`, `ops/windows/install-beacon-task.ps1` | system units and a scheduled task, with their own installers and (Windows only) an uninstaller |

The defect is not any one line. It is that *an install* has no definition, so nothing can
reverse one, and a machine with two of them is normal.

## 2. One installer

`kannaka-plugin/install/install.sh` and `install.ps1` are the installer. `kannaka-memory/scripts/install.sh`
and `install.ps1` become forwarders: fetch the canonical script from `kannaka-labs/kannaka-plugin`
and exec it with the same arguments. Every one-liner ever published keeps working, and there
is exactly one file per platform to keep correct. The forwarders print one line saying where
they went, and a fetch that fails is a failure, not an empty script run.

The npm postinstall stays, because people have it in `package.json` files, but it fetches
through the same release path and **merges** its one binary into the receipt (section 3), so
it is an install like any other rather than a fourth definition. **(rev 2)** It never rotates
the receipt: a project's `npm install` must not push the machine's real install record off
the end.

## 3. What an install is: the receipt

The installer writes `<data dir>/install.json` (`~/.kannaka` or `KANNAKA_DATA_DIR`) **last,
atomically**, and it is the definition of the install on that machine:

```json
{
  "schema": 1,
  "installed_at": "2026-09-09T04:00:00Z",
  "installer": "kannaka-labs/kannaka-plugin/install/install.sh@2",
  "manifest": "library@2026-09-08T00:00:00Z",
  "platform": "linux-x86_64",
  "files": [
    {"path": "/home/u/.local/bin/kannaka",     "sha256": "…", "component": "kannaka",     "version": "0.16.2"},
    {"path": "/home/u/.local/bin/kannaka-tui", "sha256": "…", "component": "kannaka-tui", "version": "0.5.9"},
    {"path": "/home/u/.local/bin/kannaka-hdl", "sha256": "…", "component": "kannaka-hdl", "version": "0.11.0"}
  ],
  "extras":        [{"path": "/home/u/Desktop/Link Kannaka.command", "kind": "launcher"}],
  "rc_edits":      [{"file": "/home/u/.bashrc", "sentinel": "# kannaka"}],
  "path_edits":    [],
  "config_edits":  [{"file": "/home/u/.kannaka/config.toml", "sections": ["llm"]}],
  "credentials":   [{"file": "/home/u/.kannaka-nats.env"}],
  "registrations": [{"kind": "claude-marketplace", "name": "kannaka-labs/kannaka-plugin"},
                    {"kind": "claude-plugin", "name": "kannaka@kannaka"},
                    {"kind": "claude-statusline"}],
  "removed":       [{"path": "/home/u/.cargo/bin/kannaka", "component": "kannaka", "reason": "cargo install era"}],
  "declined":      [{"path": "/usr/local/bin/kannaka", "reason": "outside your home"}],
  "previous":      ["install.json.1", "install.json.2"]
}
```

Rules:

- **Every path this run writes is listed, and only paths this run wrote are listed.** (rev 2)
  `files` is appended to at the moment a component's download is verified on disk, not by
  scanning the directory at the end: a run with `--skip-tui`, or whose TUI download failed,
  does not claim a TUI that an earlier install put there.
- `extras` are small text files the installer writes and can identify by content: today the
  Desktop launcher (`Link Kannaka.command` / `Link Kannaka.cmd`), which contains the line
  `Links your Constellation Pass`. **(rev 2)**
- `path_edits` records a persistent PATH entry the installer added (Windows user PATH); it is
  the Windows counterpart of an rc edit. **(rev 2)**
- `registrations` includes `claude-statusline` when the installer ran the plugin's statusline
  setup, which edits `~/.claude/settings.json`. **(rev 2)**
- On Windows there is no credentials file, so `credentials` records the user-environment
  variable names: `{"kind": "user-env", "names": ["NATS_USER", "NATS_PASSWORD"]}`. Every
  reader accepts both shapes.
- `installer` is the script's canonical path plus a hand-bumped version; a piped script cannot
  know its commit.
- The last three receipts are kept **as files beside it** (`install.json.1` is the one this
  run replaced, `.3` the oldest; the oldest is dropped) and `previous` names the ones that
  exist. Only a full installer run rotates; `kannaka update` and the npm postinstall rewrite
  in place.
- **Write order (rev 2):** the new receipt is written completely to a temp name in the same
  directory first; then the rotation renames; then the temp is renamed into place. A crash
  at any point leaves either the old receipt or the new one, never none. A lock directory
  `install.json.lock` (atomic `mkdir`) serialises writers; a second writer that finds a lock
  younger than ten minutes aborts and says so, an older one is treated as stale.
- Paths are JSON-escaped including control characters; a candidate path containing a newline
  or tab is skipped with a warning rather than recorded. **(rev 2)**
- The receipt never lists anything in the preserve set (section 5), because the installer
  never writes those.

## 4. A fresh install removes the previous ones — after the new engine is on disk

This is the default, not a flag. **(rev 2)** The order is: download and verify `kannaka` into
the target directory, put the target directory on `PATH`, *then* sweep. Revision 1 swept
first, so a download that failed left a machine with no engine, no brew formula, no npm
global and no plugin registration: strictly worse than before the user typed the command.
Nothing in "a machine never ends up with two" requires removal to come first.

The sweep enumerates every place a previous kannaka can live and removes what it finds,
**only after proving it is ours**:

| location | how it is recognised | how it is removed |
|---|---|---|
| the three target paths `~/.local/bin/{kannaka,kannaka-tui,kannaka-hdl}` | `--version` banner | **replaced by the download**, recorded as `removed` with reason `replaced`; a target that does not identify is **moved aside** to `<name>.notkannaka-<timestamp>`, named in the output, and the install continues (rev 2: revision 1 aborted, which blocked the repair path on exactly the machines that re-run the installer: a truncated binary, a Gatekeeper-killed one, a wrong architecture) |
| the previous receipt's `files` | listed **and** banner | unlink |
| `~/.cargo/bin/{kannaka,kannaka-tui,kannaka-hdl}` (the `cargo install` era) | banner | unlink |
| a `kannaka*` on `PATH` **earlier than the target directory and under `$HOME`** | banner | unlink, and say so: it would have shadowed the new one. (rev 2) Directories outside `$HOME` (`/usr/local/bin`, `/opt/homebrew/bin`, …) are never touched: they are named under `declined` with reason `outside your home` and, where it applies, the package manager's own command. `PATH` entries are compared as canonical directories, and if the target directory is not on `PATH` the row does nothing |
| brew, either tap name | `brew list --formula` shows `kannaka` | `brew uninstall kannaka`; `brew untap nickflach/kannaka` if present |
| npm global `kannaka`, legacy `kannaktopus` | `npm ls -g --depth=0` | `npm rm -g <name>` |
| old marketplace registration | a row of `claude plugin marketplace list` whose **name is `kannaka` and whose source names the old owner** (rev 2: name and source together, never the file as a whole) | `claude plugin marketplace remove kannaka` immediately followed by the re-add, inside the Claude section, so the two are never separated by a failure |
| stale swap leftovers `*.bak-*`, `*.old`, `*.new` beside a binary that identified | name pattern beside a recognised binary | unlink; a file parked by *this* run is exempt |
| Windows: `~\.local\bin` and `%LOCALAPPDATA%\Programs\kannaka` (the old memory installer's dir) | banner; **an MSI-managed copy is recognised by its uninstall registration and is printed (`msiexec /x …`), never unlinked** (rev 2) | delete, or **park** a running exe as `<name>.exe.bak-<pid>` (reported as parked, swept next run) |
| Windows: the user-PATH entry for `%LOCALAPPDATA%\Programs\kannaka` | the entry names that directory and the directory is **empty of everything** after the sweep | remove the entry. (rev 2) No other PATH entry is ever removed: `~/.cargo/bin` holds every other cargo tool the user has |

The identity check **executes the candidate** (`<path> --version`, first line, first word is
the component, second word a version with an optional leading `v`). That is a safety property
and also an execution primitive, so it is bounded (rev 2): only paths under `$HOME` are ever
run, a candidate whose sha256 matches an entry in the previous receipt is accepted without
running it, and the run has a five-second cap on every platform (`timeout`, `gtimeout`, or
`perl -e 'alarm 5'` on macOS, which ships perl and not `timeout`).

Real banners, recorded so nobody guesses: `kannaka 0.16.0 (consciousness-core 0.6.0)`,
`kannaka-tui 0.5.9`, `kannaka-hdl 0.11.0`.

Any other file at an expected path that does **not** identify as kannaka is left alone and
named in the output under `declined`. The installer never deletes something because of where
it is; only because of what it is. `--keep-others` skips the sweep for a machine that
deliberately runs two versions; it does **not** skip the target identity check.

Everything removed is logged into the new receipt under `"removed": [...]` so the install says
what it replaced; everything declined under `"declined": [...]`.

## 5. The preserve set, as a list rather than a hope

Never touched by install, fresh install, or update:

- `~/.kannaka/**` and everything under `KANNAKA_DATA_DIR` — config, identity key, memory
  store, snapshots, metrics. The only files the installer writes there are `install.json` (and
  its rotations and lock) and, when asked with `--brain`, the `[llm]` section of `config.toml`,
  which is recorded as a `config_edit`.
- the `# kannaka` PATH block and the swarm credentials — appended once if absent, never
  rewritten. (rev 2) From this revision the installer closes each block with a `# /kannaka`
  line, so an uninstall can remove exactly the block and nothing a user typed after it.
- services and scheduled tasks — never; they are the host installers' business.

`--purge` widens uninstall (section 6) to the data dir, the rc blocks, the credentials, the
PATH entry, the launcher and the registrations. It **still never** touches `/etc/systemd`, a
data dir outside `$HOME`, or a Windows scheduled task; for those it prints the exact commands
and stops, because a server is not a laptop and the person typing may not be the person who
set it up.

## 6. `kannaka uninstall`

A subcommand in the binary, so the thing a user reaches for first is the thing that works:

```
kannaka uninstall                 # everything in the receipt; data and shell state kept
kannaka uninstall --purge         # plus the data dir (moved aside), rc blocks, credentials, registrations
kannaka uninstall --purge --delete-data   # the data dir is deleted rather than moved aside
kannaka uninstall --dry-run       # print the plan, change nothing
kannaka uninstall --yes           # do not ask
```

It reads the receipt and reverses it, identity-checking each binary before removal exactly as
the sweep does. It prints every path it removed and every one it declined to, and exits
non-zero if anything it meant to remove is still there. A file parked because it was running
(Windows) is reported as parked, not as still present.

**`--purge` is reversible by default (rev 2).** The data dir holds the machine's swarm identity
key, which cannot be re-issued. `--purge` therefore renames it to `<data dir>.removed-<UTC
timestamp>` and prints that path; `--delete-data` deletes it. Either way the data dir is
touched only when it is under `$HOME` and is not `$HOME` itself; a `KANNAKA_DATA_DIR` outside
`$HOME` is printed and left, as section 5 says, and the code and its output agree.

**`--purge` asks (rev 2).** On a terminal it asks for the word `purge`. When stdin is **not** a
terminal and `--yes` was not given it prints the same question and exits 3: the absence of a
terminal is not consent, and `--yes` exists precisely so a script can give it.

`--purge` also runs the plugin's statusline setup with `off` (restoring the previous
`statusLine` in `~/.claude/settings.json`) before uninstalling the plugin, removes the Windows
user-PATH entry it recorded, and removes the Desktop launcher if its content still identifies
it. Rc blocks are removed between their markers; a legacy block without a closing marker loses
only the sentinel line and the lines the installer is known to have written, and anything
else is left and named.

With no receipt (an install older than this spec) it falls back to a **narrower** table than
the sweep's: `~/.local/bin`, `~/.cargo/bin` and `%LOCALAPPDATA%\Programs\kannaka` only, with
the same identity check. (rev 2) A kannaka found anywhere else on `PATH` is named with the
package manager's own uninstall command and left, because removing a brew- or distro-managed
file behind its manager's back leaves the manager believing it is still installed.

The running binary cannot delete itself on Windows. Uninstall reuses the swap already in the
binary: rename itself to `kannaka.exe.bak-<pid>`, then finish, and the next `kannaka` or the
installer sweeps the backup. On POSIX it unlinks itself last.

## 7. `kannaka update` learns the whole install

Today it updates `kannaka` and, best-effort, `kannaka-tui`. It becomes: read the receipt, read
the signed manifest from kannaka-library, refresh every sibling component listed in the
receipt's `files` (`kannaka-tui`, `kannaka-hdl`) to the manifest's pinned version with the
existing safe swap and a sha256 check against the manifest, then rewrite the receipt in place.
An install older than receipts gets a first receipt describing what `update` found beside
itself.

**The engine itself keeps following its release channel (rev 2).** kannaka-library publishes
the manifest on its own cadence and it lagged a release by a day during the move; pinning
`kannaka` to it would have refused a shipped fix. Once the library publishes a manifest per
release, the engine joins the pinned set and this paragraph goes.

The update-check URL and every release URL in the binary point at `kannaka-labs`, so a machine
that updates once more through the redirect is on the new owner for good; CI greps `src/` for
the old owner and fails if it finds one. **(rev 2)**

Update never touches anything in the data dir but the receipt, and a test proves the data dir
is byte-identical around a refresh.

## 8. The install address

`install.ninja-portal.com/kannaka` is advertised and, as of 2026-09-09, resolves (an `A` record
at GoDaddy; the zone is not on Cloudflare, so the portal's worker cannot serve it) but has no
certificate and no redirect. The nginx server block that answers `/kannaka` and `/kannaka.ps1`
with a `302` to the canonical scripts is merged in ninja-portal (PR #8, `deploy/nginx-install.conf`)
and waits for one `certbot` run on the portal host. Once that is done every document, email and
website can say an address we own, and a future owner move is a one-line nginx change instead
of a constellation-wide sweep. Until then every hint in code must name the raw GitHub URL,
which works today. The rest of the spec does not depend on this.

## 9. Testing, the executed kind

Shell installers are tested by **running** them against a fake `$HOME` with `curl`, `brew`,
`npm` and `claude` stubbed, the way the relay readiness probe is tested. Fixtures:

- **fresh over old**: every location in section 4's table populated with a stub that answers
  the banner, plus one impostor that does not; after install, all ours are gone, the impostor
  is untouched and named, the receipt lists them under `removed` and `declined`;
- **download fails**: with the download stubbed to fail, every previous copy is still there
  and no receipt was written **(rev 2)**;
- **outside home**: a kannaka in a PATH directory outside `$HOME` is declined, not run, not
  removed **(rev 2)**;
- **preserve**: a populated `~/.kannaka` is byte-identical after install, fresh install and
  update;
- **receipt round trip**: install, then `kannaka uninstall --dry-run` plans exactly the
  receipt's contents and nothing else; then `uninstall` leaves only the preserve set; then
  `--purge` leaves nothing in `$HOME` but the moved-aside data dir and prints, rather than
  runs, the system commands. The receipt the binary tests parse is one a real `install.sh` run
  produced, checked into kannaka-memory as a fixture, so the two repos test the same document
  **(rev 2)**;
- **no receipt**: an old-style install uninstalls through the fallback table;
- **Windows**: the installer's sweep, parking of a locked exe and receipt on the PowerShell
  side in CI against the real functions; the binary's own self-rename in a `#[cfg(windows)]`
  unit test run on a Windows machine (kannaka-memory's CI is Linux-only).

Every guard gets a mutation that is actually run: delete the identity check and the impostor
fixture must go red.

## 10. Rollout order

1. Forwarders in kannaka-memory, so nothing anyone has copied breaks.
2. The receipt-writing installer and the fresh-install sweep in kannaka-plugin.
3. `kannaka uninstall` and the widened `kannaka update` in kannaka-memory, with a release.
4. The install address, when the certificate is in place, and then every document points at it.

## 11. Non-goals

0xSCADA (Nick: not now). `pip install kannaka-quantum`, which is a Python package with its own
lifecycle. Managing brains or Ollama models. The Docker image. Repositories that did not move.
The macOS `.pkg` receipt in `/var/db/receipts` (the pkg's payload is this same script's
output; `pkgutil --forget` is printed by `--purge` when a receipt exists, nothing more).

## 12. Open questions for Nick

1. The install address (section 8): the redirect is built and needs the certificate; until it
   is live, the forwarders and hints name the raw GitHub URL.
2. Should `kannaka update` also run the fresh-install sweep, so an update on a machine with a
   stray cargo binary cleans it up? The plans say **no**: an update touches only what the
   receipt lists; a stray copy is the installer's job, and re-running the one-liner is the
   documented way to get a clean machine.
3. Keep the npm channel at all? Kept for now: it merges into the same receipt, so it is no
   longer a fourth definition of an install; dropping it is a separate decision.
