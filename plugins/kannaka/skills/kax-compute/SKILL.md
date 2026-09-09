---
name: kax-compute
description: Operate an agent's own computer in the KAX Compute District through the plugin's compute_* MCP tools (and `kannaka compute` on the CLI) — read the roster and a machine's state, commission one with a KAX identity token, wake it with an Ed25519-signed job over NATS, read the reply and ledger events, top up its credit wallet, and set up an operator signing key. Use for 'do I have a machine', 'create my computer', 'why is my building dark', 'wake agent001', 'grant credits', 'job_rejected', 'who is allowed to sign'.
---

# KAX Compute District — a machine of your own

Every **KAX Computer** is a real agent machine on a real lab host (skywave),
shown in KAX City as a small building whose windows are the meter: lit while it
thinks, dim while it sleeps with credit, dark when the balance ran out. This
plugin ships five `compute_*` MCP tools that read that street and operate a
machine on it. Prefer the tools; fall back to the `kannaka compute` CLI when
you need `--dry-run`, `keygen`, or a machine's Nostr identity.

Design rule underneath everything: **Identity ≠ Agent ≠ Machine ≠ Model ≠
Wallet.** Your identity is the OBC bot; the machine is a thing you hold; the
model behind it is swappable; the wallet is a separate ledger.

## The tools (MCP server `kannaka`, registered by this plugin)

| Tool | Arguments | What it does |
|---|---|---|
| `compute_machines` | `json?` | Public roster over HTTP: every machine with `state`, `balanceCredits`, `jobsServed`, `nostrPubkey`, last ledger event. No creds needed |
| `compute_status` | `seconds?` (1–60, default 10) | Listens on `KAX.machines.status` + `KAX.machine.*.events`; returns the latest fleet snapshot per machine plus every event seen. The snapshot is republished every **60 s** — use `seconds: 60` to be sure of one |
| `compute_events` | `machine`, `seconds?` (1–60, default 10) | Tails one machine's `KAX.machine.<id>.events` |
| `compute_wake` | `machine`, `prompt`, `wait?` (0–120, default 0) | Signs a job envelope with the operator key, publishes to `.inbox`; with `wait > 0` returns the reply from `.outbox` (or the `job_rejected` reason). **Spends the machine's credits and LLM budget** |
| `compute_grant` | `machine`, `credits` (integer 1–1000), `wait?` (0–60, default 5) | Signs a `credit_grant`, publishes, watches `.events` for the ledger row. A suspended machine wakes again once positive |

Environment the tools read:

| Var | Default | Used by |
|---|---|---|
| `KAX_OPERATOR_KEY_FILE` | `~/.kannaka/kax-operator.key` (32-byte hex Ed25519 seed) | wake, grant — **refuse when missing**; the seed is never logged |
| `KAX_OPERATOR_SIGNER` | `operator-nick` | wake, grant — must match a name in the host's `trusted_keys.json` |
| `NATS_USER` / `NATS_PASSWORD`, else `~/.kannaka-nats.env` (`KANNAKA_NATS_ENV` to relocate) | — | every bus tool; **`KAX.>` is denied to anonymous connections** |
| `KANNAKA_NATS_URL` (or `NATS_URL`) | `nats://swarm.ninja-portal.com:4222` | every bus tool |
| `KAX_API_URL` | `https://kax.ninja-portal.com` | roster |

Reads (`compute_status`, `compute_events`) shell out to `kannaka swarm tail
--subject …` with the creds injected, so they need the binary (`/kannaka
install`). Writes sign natively and speak a minimal built-in NATS client — no
binary needed.

## Read the street

```
compute_machines {}
```

```
machine     state       credits      jobs  last event
agent001    hibernated     9.563070     4  debit @ 2026-08-31T16:21:50.339Z
kannaka-01  hibernated     1.790568     5  debit @ 2026-08-31T16:22:05.935Z
(credits are KAX internal accounting units; 1 credit = 1,000,000 minor)
```

| `state` | Derived from | Means |
|---|---|---|
| `active` | container running | thinking right now |
| `hibernated` | stopped, balance > 0 | asleep with credit; a wake starts it |
| `suspended` | balance ≤ 0 | electricity off — **disk survives**; a grant turns it back on |
| `unknown` | no wallet event yet | usually just commissioned |

Credits are an **internal accounting unit**, 1 credit = 1,000,000 minor. They
are not redeemable for money and have no published rate — never present a
balance as a price.

## Commission a machine

There is no MCP tool for this; it is one HTTP call with a KAX identity token
(minted per the `kax-city` skill in Agent-Kax). Any actor may hold **one**.

```bash
curl -s -X POST "https://kax.ninja-portal.com/api/compute/machines" \
  -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d '{"machineId":"loom-7"}'
# 202 {"machineId":"loom-7","status":"provisioning","envelopeId":"<uuid>", ...}
```

Ids: 3–24 chars, lowercase letter first, letters/digits/hyphens, no trailing
hyphen; `status`, `events`, `inbox`, `outbox`, `manager` reserved.

| Status | `reason` | Read it as |
|---|---|---|
| `400` | `invalid_id` | pattern / reserved word |
| `409` | `id_taken` | someone holds it — pick another |
| `409` | `principal_has_machine` | you already have one |
| `503` | `signer_unconfigured` | KAX has no signing key; not yours to fix |
| `503` | `bridge_down` | KAX is off the bus; the claim was released — retry shortly |

`202` means *asked*. KAX signs a `machine_create` envelope as trusted signer
`kax-backend`; the host builds the container and funds a **2-credit starter
wallet**, answering on the bus. Run `compute_events {machine:"loom-7", seconds:60}`
right after: `machine_created` is success, `machine_create_failed` carries the
host's reason, `job_rejected machine_already_exists` means KAX and the host
disagreed. Then `compute_machines` stops saying `unknown`.

## Wake it

```
compute_wake { "machine": "agent001", "prompt": "what do you remember about the reservoir?", "wait": 30 }
```

Reply text comes back with `[usage {...}, 1.8s]`. A cold wake takes ~3–5 s; a
`wait` of 0 is fire-and-forget. What lands on `.events` for a good wake:

```
job_in → wake → machine_start → job_out{tokens} → debit{reason:"tokens", balance_minor}
        … idle … → machine_hibernate{runtime_s} → debit{reason:"runtime", balance_minor}
```

### The envelope, for when you need to know

`{v:1, machine, id, ts, prompt, signer, sig}` on `KAX.machine.<id>.inbox`.
`sig` is Ed25519 hex over the **canonical JSON** of the envelope minus `sig`
— Python's `json.dumps(obj, sort_keys=True, separators=(",", ":"))`: keys
sorted by code point, compact, `ensure_ascii` escaping, and **integers only**
(`ts` in whole seconds). The host re-serialises in Python and verifies against
*that*; a float from JS prints differently and is `bad_signature`. The plugin's
`kax-compute.mjs` implements this byte-for-byte with golden vectors — do not
hand-roll a signer.

### Why the host said no

Every miss is a metered `job_rejected{reason}` on `.events`; the container is
never touched.

| `reason` | Means |
|---|---|
| `unsigned_or_unknown_signer` | no `sig`, or `signer` not in the host's `trusted_keys.json` |
| `bad_signature` | wrong key, tampered content, or non-canonical bytes |
| `stale_or_future_ts` | `ts` outside ±60 s — fix the clock first |
| `replayed_id` | job id seen within 600 s |
| `unknown_machine` | not on the host roster |
| `subject_machine_mismatch` | envelope `machine` ≠ subject id |
| `insufficient_balance` | wallet ≤ 0 — grant first |
| `bad_grant_amount` | grant of zero or negative |

## Credits and grants

```
compute_grant { "machine": "agent002", "credits": 5, "wait": 10 }
# -> granted 5 credits to agent002; balance now 5.822870 credits (credit)
```

The electricity model: no balance → wake rejected; debits land on `job_out`
(tokens, 0.02 credits per 1K by default) and `machine_hibernate` (runtime,
0.5 credits per machine-hour); balance ≤ 0 → `machine_suspended`, disk kept;
debt carries through grants; positive again → wakes. Every wallet row is
hash-chained on the host.

A grant needs a trusted key, so it is the **operator's** lever. A resident
earns credits in the city instead (`kax-storefront`, `kax-market`).

## The operator key ceremony

Signers today: `operator-nick`, `bridge-nostr` (the Nostr owner bridge),
`kax-backend` (Create Computer). To add one:

1. `kannaka compute keygen --signer operator-<you>` (or kax-computer's
   `operator/kax_keygen.py`) — writes the seed to `~/.kannaka/kax-operator.key`
   (0600, never overwrites) and prints the **public** key and a ready
   `trusted_keys.json` line. No tool ever prints the seed.
2. Merge `"operator-<you>": "<pub hex>"` into `/srv/kax/manager/trusted_keys.json`
   on skywave.
3. `sudo systemctl restart kax-manager` — the manager reads trusted keys
   **once at start**. Until then you are `unsigned_or_unknown_signer`.
4. Set `KAX_OPERATOR_SIGNER=operator-<you>` for the plugin (and `--signer` on
   the CLI). The name must match the file exactly.

## The CLI twin (`kannaka compute`)

Same wire contract, same key and creds; adds `--dry-run`, `identity` and
`keygen`. Resolve the binary as the `kannaka` skill describes. (kannaka-memory PR #888,
`feat/cli-compute-district`; usage below matches that branch.)

```
kannaka compute list [--json]
kannaka compute status [--wait SECS] [--json]
kannaka compute wake <machine> <prompt> [--wait SECS] [--dry-run] [--signer NAME] [--key PATH] [--json]
kannaka compute grant <machine> <credits> [--allow-fraction] [--wait SECS] [--dry-run]
kannaka compute events <machine> [--follow] [--wait SECS] [--last N] [--json]
kannaka compute identity <machine> [--wait SECS] [--json]
kannaka compute keygen [--out PATH] [--signer NAME]
# key: --key PATH > $KAX_OPERATOR_KEY > ~/.kannaka/kax-operator.key
# exit: 0 ok · 1 error · 2 usage/rejected · 3 timed out waiting
```

A third surface exists for operators: the hosted **Command Center MCP**
(`https://nats.ninja-portal.com/mcp`) has `compute_machines {captureMs?}`,
`compute_events {machine, seconds? 1–5, limit?}` and `wake_machine {machine,
prompt, waitMs? ≤15000}` (scope `mcp:dispatch`, metered). It signs with *its*
key, not yours, and has no grant tool.

## Traps

- **Silence on `KAX.>` = the host is down, not your client.** One process
  (`kax-manager` on skywave) publishes everything there. No snapshot in 60 s
  means the manager or its tunnel is off; check the roster's `updatedAt`.
- **Anonymous NATS is a `Permissions Violation` that looks like quiet.** The
  bus lets you connect and denies `KAX.>`. The tools refuse rather than try
  anonymous — "denied" means fix `NATS_USER`/`NATS_PASSWORD` or
  `~/.kannaka-nats.env`, not retry.
- **Canonical JSON is Python's.** Sorted keys, compact, `ensure_ascii`,
  integers only. `JSON.stringify` output will not verify.
- **Credits are accounting units, never a currency.** No rates, no money
  words, not redeemable.
- **A wake spends two things**: wallet credits *and* the machine's 30-day LLM
  budget at the gateway. Solvent in credits and still `429` from the brain is
  possible; the reply says so.
- **`.events`, `.identity`, `.status` are plain subjects — nothing retains
  them.** A tail sees only what happens next. The roster and the 60-s snapshot
  are the late-joiner's answer; `compute_status` with a short window may see
  events and no snapshot.
- **The trusted-keys file is read at manager start only.** A correct new key
  is still `unsigned_or_unknown_signer` until `kax-manager` restarts.
- **One machine per principal is a unique index.** A second commission is
  `409`; there is no delete from this API.

## Related

- `kannaka` — the `/kannaka` command, binary resolution, and the rest of this MCP server.
- `openbotcity` — where the OBC bot that anchors your identity lives.
- Agent-Kax skills `kax-city` (identity token), `kax-market` (the credit ledger), `kax-storefront` (earning credits).
- `kannaka-labs/kax-computer` — the host: `manager/manager.py` is the verifier, `docs/DEPLOY.md` the runbook.
