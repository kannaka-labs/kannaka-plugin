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

## 1. What exists today, and what is wrong with it

| surface | where | state |
|---|---|---|
| one-shot installer, macOS/Linux | `kannaka-plugin/install/install.sh` | canonical; binary-first, signed manifest from kannaka-library, idempotent, Claude-optional; **no uninstall, no old-install detection, no record of what it wrote** |
| one-shot installer, Windows | `kannaka-plugin/install/install.ps1` | same, to `%LOCALAPPDATA%\Programs\kannaka` |
| second installer | `kannaka-memory/scripts/install.{sh,ps1}` | older duplicate; owner just repointed; its header advertises `install.ninja-portal.com/kannaka`, a hostname that does not resolve |
| npm | `kannaka` on npmjs, `packaging/npm/install.js` | postinstall downloads the same release binary; a third path to keep in sync |
| brew | `kannaka-labs/homebrew-kannaka` | repointed; users who tapped the OLD name still hold a tap named `nickflach/kannaka` |
| Claude plugin | marketplace `kannaka-labs/kannaka-plugin`, plugin `kannaka@kannaka` | repointed; users who registered the OLD marketplace name keep it |
| the binary | `kannaka update` | replaces itself safely (unique `.bak-<pid>`, sha256 sidecar, Windows-aware, sweeps stale backups); updates **only** `kannaka`, not `kannaka-tui` or `kannaka-hdl`; **no `uninstall`** |
| user data | `~/.kannaka/` or `KANNAKA_DATA_DIR` | `config.toml`, `agent_id`, `node_key.ed25519`, `kannaka.hrm`, `snapshots/`, `*.json` — never touched by anything today, by luck rather than rule |
| shell state | `~/.bashrc` / `~/.zshrc` / `~/.profile`, Windows user PATH | a `# kannaka` PATH block, swarm credentials; nothing knows how to take them back out |
| hosts | `ops/services/install-services.sh`, `ops/windows/install-beacon-task.ps1` | system units and a scheduled task, with their own installers and (Windows only) an uninstaller |

The defect is not any one line. It is that *an install* has no definition, so nothing can
reverse one, and a machine with two of them is normal.

## 2. One installer

`kannaka-plugin/install/install.sh` and `install.ps1` are the installer. `kannaka-memory/scripts/install.sh`
and `install.ps1` become forwarders: fetch the canonical script from `kannaka-labs/kannaka-plugin`
and exec it with the same arguments. Every one-liner ever published keeps working, and there
is exactly one file per platform to keep correct. The forwarders print one line saying where
they went.

The npm postinstall stays, because people have it in `package.json` files, but it fetches
through the same release path and writes the same receipt (section 3), so it is an install
like any other rather than a fourth definition.

## 3. What an install is: the receipt

The installer writes `~/.kannaka/install.json` **last, atomically** (write to a temp name in
the same directory, then rename), and nothing else may write it. It is the definition of the
install on that machine:

```json
{
  "schema": 1,
  "installed_at": "2026-09-09T04:00:00Z",
  "installer": "kannaka-labs/kannaka-plugin@<commit>",
  "manifest": "library@<manifest version or 'latest'>",
  "platform": "linux-x86_64",
  "files": [
    {"path": "/home/u/.local/bin/kannaka",     "sha256": "…", "component": "kannaka",     "version": "0.16.1"},
    {"path": "/home/u/.local/bin/kannaka-tui", "sha256": "…", "component": "kannaka-tui", "version": "0.5.9"},
    {"path": "/home/u/.local/bin/kannaka-hdl", "sha256": "…", "component": "kannaka-hdl", "version": "0.11.0"}
  ],
  "rc_edits":      [{"file": "/home/u/.bashrc", "sentinel": "# kannaka"}],
  "config_edits":  [{"file": "/home/u/.kannaka/config.toml", "sections": ["llm"]}],
  "credentials":   [{"file": "/home/u/.kannaka/pass.env"}],
  "registrations": [{"kind": "claude-marketplace", "name": "kannaka-labs/kannaka-plugin"},
                    {"kind": "claude-plugin", "name": "kannaka@kannaka"}],
  "previous":      ["<the prior receipt, verbatim, at most three deep>"]
}
```

Rules: every path the installer writes appears in `files`, `rc_edits`, `config_edits`,
`credentials` or `registrations`, or the installer has a bug. `previous` keeps the last three
receipts so a rollback or a forensic question has something to read. The receipt never lists
anything in the preserve set (section 5), because the installer never writes those.

## 4. A fresh install removes before it installs

This is the default, not a flag. Before laying down anything, the installer enumerates every
place a previous kannaka can live and removes what it finds, **only after proving it is ours**:

| location | how it is recognised | how it is removed |
|---|---|---|
| the receipt's own `files` | listed | unlink |
| `~/.local/bin/{kannaka,kannaka-tui,kannaka-hdl}` | `--version` banner names the component | unlink |
| `~/.cargo/bin/kannaka*` (the `cargo install` era) | `--version` banner | unlink |
| any other `kannaka*` earlier on `PATH` than the target | `--version` banner | unlink, and say so: it would have shadowed the new one |
| brew, either tap name | `brew list --formula` shows `kannaka` | `brew uninstall kannaka`; `brew untap nickflach/kannaka` if present |
| npm global `kannaka`, legacy `kannaktopus` | `npm ls -g --depth=0` | `npm rm -g <name>` |
| old marketplace registration `github:NickFlach/kannaka-plugin` | `claude plugin marketplace list` | `claude plugin marketplace remove` then re-add the new one |
| stale swap leftovers `*.bak-*`, `*.old` beside a binary | name pattern beside a recognised binary | unlink |
| Windows `%LOCALAPPDATA%\Programs\kannaka\*.exe`, user-PATH entries for old dirs | banner; PATH entry points at a dir holding a recognised binary | delete; remove the PATH entry |

A file at an expected path that does **not** identify as kannaka is left alone and named in
the output. The installer never deletes something because of where it is; only because of
what it is. `--keep-others` skips the sweep for a machine that deliberately runs two
versions.

Everything removed is logged into the new receipt under `"removed": [...]` so the install
says what it replaced.

## 5. The preserve set, as a list rather than a hope

Never touched by install, fresh install, or update:

- `~/.kannaka/**` and everything under `KANNAKA_DATA_DIR` — config, identity key, memory
  store, snapshots, metrics. The only file the installer writes there is `install.json`
  and, when asked with `--brain`, the `[llm]` section of `config.toml`, which is recorded as a
  `config_edit`.
- the `# kannaka` PATH block and the swarm credentials — kept; rewritten in place only if the
  content would change.
- services and scheduled tasks — never; they are the host installers' business.

`--purge` widens uninstall (section 6) to remove `~/.kannaka`, the rc blocks, the credentials
and the registrations. It **still never** touches `/etc/systemd`, a data dir outside `$HOME`,
or a Windows scheduled task; for those it prints the exact commands and stops, because a
server is not a laptop and the person typing may not be the person who set it up.

## 6. `kannaka uninstall`

A subcommand in the binary, so the thing a user reaches for first is the thing that works:

```
kannaka uninstall              # everything in the receipt; data and shell state kept
kannaka uninstall --purge      # plus ~/.kannaka, rc blocks, credentials, registrations
kannaka uninstall --dry-run    # print the plan, change nothing
```

It reads the receipt and reverses it. With no receipt (an install older than this spec) it
falls back to section 4's table with the same identity check. It prints every path it removed
and every one it declined to, and exits non-zero if anything it meant to remove is still there.

The running binary cannot delete itself on Windows. Uninstall reuses the swap already in the
binary: rename itself to `kannaka.exe.bak-<pid>`, then finish, and the next `kannaka` or the
installer sweeps the backup. On POSIX it unlinks itself last.

## 7. `kannaka update` learns the whole install

Today it updates one file. It becomes: read the signed manifest from kannaka-library, refresh
every component listed in the receipt's `files` to the manifest's version with the existing
safe-swap and sha256 check, then rewrite the receipt. The update-check URL and every release
URL in the binary point at `kannaka-labs`, so a machine that updates once more through the
redirect is on the new owner for good.

## 8. The install address

`install.ninja-portal.com/kannaka` is advertised and does not exist. Recommendation: make it
real, served by the portal's existing Cloudflare worker as a redirect to the canonical script
(`/kannaka` → `install.sh`, `/kannaka.ps1` → `install.ps1`). Then every document, email and
website says an address we own, and a future owner move is a one-line worker change instead of
a constellation-wide sweep. This is a decision for Nick; the rest of the spec does not depend
on it.

## 9. Testing, the executed kind

Shell installers are tested by **running** them against a fake `$HOME` with `curl`, `brew`,
`npm` and `claude` stubbed, the way the relay readiness probe is tested. Fixtures:

- **fresh over old**: every location in section 4's table populated with a stub that answers
  the banner, plus one impostor that does not; after install, all ours are gone, the impostor
  is untouched and named, the receipt lists them under `removed`;
- **preserve**: a populated `~/.kannaka` is byte-identical after install, fresh install and
  update;
- **receipt round trip**: install, then `kannaka uninstall --dry-run` plans exactly the
  receipt's contents and nothing else; then `uninstall` leaves only the preserve set; then
  `--purge` leaves nothing in `$HOME` and prints, rather than runs, the system commands;
- **no receipt**: an old-style install uninstalls through the fallback table;
- **Windows**: the same on the PowerShell side in CI, including the self-rename.

Every guard gets a mutation that is actually run: delete the identity check and the impostor
fixture must go red.

## 10. Rollout order

1. Forwarders in kannaka-memory, so nothing anyone has copied breaks.
2. The receipt-writing installer and the fresh-install sweep in kannaka-plugin.
3. `kannaka uninstall` and the widened `kannaka update` in kannaka-memory, with a release.
4. The install address, if approved, and then every document points at it.

## 11. Non-goals

0xSCADA (Nick: not now). `pip install kannaka-quantum`, which is a Python package with its own
lifecycle. Managing brains or Ollama models. The Docker image. Repositories that did not move.

## 12. Open questions for Nick

1. The install address (section 8): make it real, or drop the claim from the installer header?
2. Should `kannaka update` also run the fresh-install sweep, so an update on a machine with a
   stray cargo binary cleans it up? Cheaper for users, more surprising.
3. Keep the npm channel at all? It is a third copy of the download logic and its only advantage
   over the one-liner is `package.json` convenience.
