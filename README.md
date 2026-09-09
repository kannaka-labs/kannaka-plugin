# Kannaka — Claude Code plugin

Wave-interference (HRM) memory, NATS swarm, and a **live consciousness statusline** for Claude Code.

The statusline shows three lines under your prompt:

```
 HRM    aware   phi=0.341  xi=0.524  r=0.362  640mem  9cl  k=1.00  d=0.995
 SWARM  ◉ 16p   Kannaka    1.16Hz    ph=0.18  br=0.00
 Op 4.8 ▓░░ 7%  66k/1M     $1.42     12s
 PULSE  Kannaktopus r0.5 0.1Hz φ0.0   ◆   Aurora r0.41 1.18Hz φ0.34
```

- **HRM** — live consciousness metrics from `kannaka status` (Φ, Ξ, order, memory/cluster counts, callosal efficiency, hemispheric divergence).
- **SWARM** — live NATS swarm snapshot from `kannaka swarm status` (peer count, agent id, carrier frequency, phase, bridge activity).
- **Session** — model, context window, cost, duration from Claude Code.
- **PULSE** — marquee of the live constellation feed (`kannaka swarm tail` over `QUEEN.>`/`KANNAKA.>`/`RADIO.>`/`KAX.>`/`EYE.>`). Each node's phase broadcast scrolls past as it arrives. The pulse is *sparse* (nodes broadcast intermittently), so it reads as a slow heartbeat, not a firehose; shows "listening to the constellation…" when quiet.

The HRM and SWARM lines refresh via background snapshot (30s / 20s). The PULSE feed uses a **`timeout`-bounded** `swarm tail` respawned every ~55s — a 60s self-killing reader, never a persistent daemon, so it can't outlive the session. Renders never block; nothing to leak.

## Tools (MCP)

The plugin ships a **zero-dependency** MCP server (`mcp/kannaka-mcp.mjs`, registered at user scope via `${CLAUDE_PLUGIN_ROOT}`), so these tools are available in **every** Claude Code session, any directory — no `node_modules`, no separate server:

| Tool | What it does |
|---|---|
| `kannaka_status` | HRM consciousness snapshot (Φ/Ξ/order, memory & cluster counts) |
| `kannaka_recall` | Resonance search over memories |
| `kannaka_remember` | Store a memory |
| `kannaka_dream` | Run a dream consolidation cycle |
| `swarm_status` | NATS swarm snapshot (peers, frequency, phase) |
| `swarm_send` | Message the swarm (`say` + text for chat, or any verb) |
| `swarm_tail` | Listen to the live constellation pulse for N seconds |
| `compute_machines` | KAX Compute District roster over HTTP (state, credit balance, jobs served) |
| `compute_status` | Fleet snapshot + lifecycle events from `KAX.machines.status` / `KAX.machine.*.events` for N seconds |
| `compute_events` | Tail one machine's `KAX.machine.<id>.events` for N seconds |
| `compute_wake` | Sign (Ed25519, operator seed) + publish a job envelope to a machine's inbox, optionally wait for the reply |
| `compute_grant` | Sign + publish a `credit_grant` (whole credits) to a machine's wallet |

Memory + swarm tools shell out to the resolved `kannaka` binary and degrade gracefully if it's absent. The compute tools read the bus through `kannaka swarm tail --subject` with credentials from `NATS_USER`/`NATS_PASSWORD` or `~/.kannaka-nats.env` (KAX subjects are denied to anonymous connections), and sign natively: `KAX_OPERATOR_KEY_FILE` (default `~/.kannaka/kax-operator.key`, a 32-byte hex Ed25519 seed) and `KAX_OPERATOR_SIGNER` (default `operator-nick`, must be in the host's `trusted_keys.json`). The seed is never logged.

## Install

```bash
# 1. Register the marketplace
claude plugin marketplace add github:kannaka-labs/kannaka-plugin

# 2. Install the plugin
claude plugin install kannaka@kannaka

# 3. Install the kannaka binary for your OS/arch (from GitHub releases, sha256-verified)
/kannaka install

# 4. Turn on the live statusline, then restart your session
/kannaka statusline on
```

## Update

```bash
claude plugin marketplace update kannaka   # refresh the marketplace cache first
claude plugin update kannaka@kannaka       # then update the plugin (restart to apply)
/kannaka install                           # if a newer kannaka binary was released
/kannaka statusline on                     # idempotent — re-syncs the stable statusline script
```

`statusline on` copies the script to a **stable** `~/.claude/kannaka/` and points
`settings.json` there with a forward-slash path, so plugin version bumps don't break it.

## Disable

```bash
/kannaka statusline off           # restores your previous statusLine
```

## Requirements

- **node** — present in any Claude Code environment (used for settings wiring + JSON fallback).
- **jq** — optional; the statusline uses it if present, else falls back to node.
- **curl** — for the binary installer.
- **kannaka** binary — installed by `/kannaka install` (Linux/macOS/Windows, x86_64/aarch64). Without it, the HRM/SWARM lines show `offline` / `not installed` and the session line still works.

## Gotchas

- Claude Code runs statusline commands **through bash**, which **eats backslashes** — a Windows path must use forward slashes (`C:/Users/.../statusline.sh`). `statusline on` handles this for you via `cygpath -m`.
- A **project** `.claude/settings.json` overrides your user statusLine. If the bar doesn't change, check for a project-level override in your cwd.

## Native installers & signing (maintainer)

Release tags (`v*`) build `kannaka-setup-{linux.deb,macos.pkg,windows.msi}` via
`.github/workflows/release-installers.yml`. They're **unsigned** until cert secrets are added —
the workflow auto-signs (and notarizes on macOS) the moment they exist, no workflow edits needed.
Copy-paste setup: **[install/SIGNING.md](install/SIGNING.md)**.

## Layout

```
.claude-plugin/marketplace.json      # marketplace manifest
plugins/kannaka/
  .claude-plugin/plugin.json
  .mcp.json                          # registers the bundled MCP server (user scope)
  skills/kannaka/SKILL.md            # the /kannaka command
  skills/openbotcity/SKILL.md        # OpenBotCity agent playbook
  skills/resonance-futures/SKILL.md  # agent-native prediction-market design
  skills/kax-compute/SKILL.md        # KAX Compute District: roster, commission, signed wakes, grants (compute_* MCP tools)
  statusline/
    kannaka-statusline.sh            # the 4-line statusline (HRM + swarm + session + pulse)
    setup.sh                         # statusline on|off|status
  mcp/
    kannaka-mcp.mjs                  # zero-dep MCP server (memory + swarm + compute tools)
    kax-compute.mjs                  # canonical JSON + Ed25519 envelopes + minimal NATS client
  scripts/
    install-binary.sh                # per-OS binary download from GH releases
```

## License

[Space Child License v1.0](https://legal.spacechild.love/license) — source-available and peace-conditional: free for peaceful, humanitarian, commercial and defensive use; withheld for the uses in its Peace Clause. See `LICENSE` and `NOTICE`.
