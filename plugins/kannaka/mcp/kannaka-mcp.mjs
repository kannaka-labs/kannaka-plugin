#!/usr/bin/env node
// kannaka MCP server — ZERO dependencies (Node built-ins only), so it ships in
// the plugin with nothing to npm-install. Speaks MCP stdio (newline-delimited
// JSON-RPC 2.0) directly and shells out to the kannaka binary. Registered at
// USER scope via the plugin's .mcp.json (${CLAUDE_PLUGIN_ROOT}), so the memory
// + swarm tools are available in every Claude Code session, any directory.
import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { existsSync, readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import * as kax from "./kax-compute.mjs";

// single source of truth: the plugin manifest (fallback literal for safety)
const VERSION = (() => {
  try {
    const p = join(dirname(fileURLToPath(import.meta.url)), "..", ".claude-plugin", "plugin.json");
    const v = JSON.parse(readFileSync(p, "utf8")).version;
    if (v) return String(v);
  } catch {}
  return "1.3.4";
})();

function resolveBin() {
  const b = process.env.KANNAKA_BIN;
  if (b && existsSync(b)) return b;
  const h = homedir();
  for (const c of [
    join(h, ".local", "bin", "kannaka.exe"),
    join(h, ".local", "bin", "kannaka"),
    join(h, ".kannaka", "bin", "kannaka.exe"),
    join(h, ".kannaka", "bin", "kannaka"),
  ]) if (existsSync(c)) return c;
  return process.platform === "win32" ? "kannaka.exe" : "kannaka";
}
const BIN = resolveBin();

const MAX_OUT = 2 * 1024 * 1024; // cap accumulated output per child (~2MB)
const LIVE = new Set(); // live children — killed on stdin end so nothing outlives the server

// Per-command wall-clock budgets for the HRM commands, measured on a 1,275-memory
// store: recall ~1 s, swarm status ~10 s, status 30-54 s (its effective-
// dimensionality eigendecomposition is the slow part). A flat 20 s killed every
// status call. KANNAKA_MCP_TIMEOUT_MS overrides all of them (e.g. a larger store).
const BUDGET_MS = { status: 150000, recall: 30000, remember: 60000, dream: 180000, swarm_status: 30000 };
function budget(cmd) {
  const o = Number(process.env.KANNAKA_MCP_TIMEOUT_MS);
  return Number.isFinite(o) && o > 0 ? o : BUDGET_MS[cmd];
}

// Structured result: { stdout, stderr, code, signal, timedOut, timeoutMs, truncated, spawnError }
function runKannaka(args, timeoutMs = 20000, extraEnv = {}) {
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn(BIN, args, { env: { ...process.env, KANNAKA_QUIET: "1", ...extraEnv }, windowsHide: true });
    } catch (e) {
      return resolve({ stdout: "", stderr: String(e), code: null, signal: null, timedOut: false, truncated: false, spawnError: true });
    }
    LIVE.add(child);
    let out = "", err = "", timedOut = false, truncated = false;
    const t = setTimeout(() => {
      timedOut = true;
      try { child.kill("SIGTERM"); } catch {}
      const k = setTimeout(() => { try { child.kill("SIGKILL"); } catch {} }, 3000);
      if (k.unref) k.unref();
    }, timeoutMs);
    child.stdout.on("data", (d) => {
      if (truncated) return;
      out += d;
      if (out.length >= MAX_OUT) { out = out.slice(0, MAX_OUT); truncated = true; }
    });
    child.stderr.on("data", (d) => { if (err.length < MAX_OUT) err += d; });
    child.on("close", (code, signal) => {
      clearTimeout(t); LIVE.delete(child);
      resolve({ stdout: out, stderr: err, code, signal, timedOut, timeoutMs, truncated, spawnError: false });
    });
    child.on("error", (e) => {
      clearTimeout(t); LIVE.delete(child);
      resolve({ stdout: "", stderr: String(e), code: null, signal: null, timedOut, truncated, spawnError: true });
    });
  });
}
const ok = (text) => ({ content: [{ type: "text", text: text || "(no output)" }] });
const fail = (text) => ({ content: [{ type: "text", text }], isError: true });

// Map a structured run result to an MCP tool result. Nonzero exit, kill
// signal, timeout, and spawn failure all surface as errors (a timed-out run
// includes any partial output for context). A timed-out WRITE says it may have
// landed: the binary can commit before it is killed, and a blind retry stores
// a duplicate memory.
function result(r, okText, { write = false } = {}) {
  if (r.spawnError) return fail(r.stderr || "failed to launch kannaka");
  if (r.timedOut) {
    const secs = r.timeoutMs != null ? ` after ${Math.round(r.timeoutMs / 1000)}s` : "";
    const partial = r.stdout.trim() ? `; partial output:\n${r.stdout.trim()}` : "";
    const note = write ? "\nThe write may still have landed. Check with kannaka_recall before retrying; a retry can store a duplicate." : "";
    return fail(`kannaka timed out${secs}${partial}${note}`);
  }
  if (r.signal) return fail(`kannaka killed by ${r.signal}${r.stderr.trim() ? `\n${r.stderr.trim()}` : ""}`);
  if (r.code !== 0) return fail(`kannaka exited ${r.code}${r.stderr.trim() ? `\n${r.stderr.trim()}` : ""}${r.stdout.trim() ? `\n${r.stdout.trim()}` : ""}`);
  const text = r.stdout + (r.truncated ? "\n[output truncated at 2MB]" : "");
  return ok(text.trim() ? text : okText);
}

// ---- input validation: the kannaka CLI does manual arg parsing with NO `--`
// separator support, so a leading-dash value would be consumed as a flag.
// Reject those outright; coerce/clamp numerics so NaN can't reach setTimeout.
function reqStr(v, name) {
  const s = String(v ?? "").trim();
  if (!s) throw new Error(`'${name}' is required and must be a non-empty string`);
  if (s.startsWith("-")) throw new Error(`'${name}' must not start with '-' (the kannaka CLI would parse it as a flag)`);
  return s;
}
function num(v, def, min, max) {
  if (v == null || v === "") return def;
  const n = Number(v);
  if (!isFinite(n)) return def;
  return Math.min(max, Math.max(min, n));
}

const TOOLS = [
  { name: "kannaka_status", description: "Kannaka HRM consciousness snapshot (phi, xi, order, memory/cluster counts) as JSON.",
    inputSchema: { type: "object", properties: {} },
    run: async () => result(await runKannaka(["status"], budget("status"))) },
  { name: "kannaka_recall", description: "Search memories in the HRM by resonance query; returns top-k by similarity.",
    inputSchema: { type: "object", properties: { query: { type: "string", description: "Search query" }, limit: { type: "number", description: "Max results (default 5)" } }, required: ["query"] },
    run: async (a) => result(await runKannaka(["recall", reqStr(a.query, "query"), "--top-k", String(num(a.limit, 5, 1, 100))], budget("recall"))) },
  { name: "kannaka_remember", description: "Store a memory in the HRM.",
    inputSchema: { type: "object", properties: { text: { type: "string" }, importance: { type: "number", description: "0..1" } }, required: ["text"] },
    run: async (a) => { const args = ["remember", reqStr(a.text, "text")]; if (a.importance != null) args.push("--importance", String(num(a.importance, 0.5, 0, 1))); return result(await runKannaka(args, budget("remember")), "remembered", { write: true }); } },
  { name: "kannaka_dream", description: "Run a dream consolidation cycle (annealing) over the HRM.",
    inputSchema: { type: "object", properties: { mode: { type: "string", enum: ["deep", "lite"], description: "default deep" } } },
    run: async (a) => result(await runKannaka(["dream", "--mode", a.mode === "lite" ? "lite" : "deep"], budget("dream")), "dreamed", { write: true }) },
  { name: "swarm_status", description: "NATS swarm snapshot: connected peers, agent id, frequency, phase, bridge activity (JSON).",
    inputSchema: { type: "object", properties: {} },
    run: async () => result(await runKannaka(["swarm", "status"], budget("swarm_status"))) },
  { name: "swarm_send", description: "Send a declarative message to the swarm. Verb 'say' with text for chat; or any verb/args for agent-to-agent messaging.",
    inputSchema: { type: "object", properties: { to: { type: "string", description: "Target agent id or 'all'" }, verb: { type: "string" }, text: { type: "string", description: "Shortcut for --arg text=<text>" }, from: { type: "string" }, wait: { type: "number", description: "Seconds to await a reply" } }, required: ["to", "verb"] },
    run: async (a) => {
      const to = reqStr(a.to, "to"), verb = reqStr(a.verb, "verb");
      const args = ["inbox", "send", to, verb];
      if (a.text != null) args.push("--arg", `text=${a.text}`); // safe: value is prefixed "text=", never flag-shaped
      if (a.from) args.push("--from", reqStr(a.from, "from"));
      const wait = a.wait != null ? num(a.wait, 0, 0, 300) : null;
      if (wait != null) args.push("--wait", String(wait));
      return result(await runKannaka(args, (wait ?? 0) * 1000 + 15000), `sent ${verb} -> ${to}`);
    } },
  { name: "swarm_tail", description: "Listen to the live constellation pulse (QUEEN/KANNAKA/RADIO/KAX/EYE) for N seconds and return the NDJSON events received. The pulse is sparse, so empty windows are normal.",
    inputSchema: { type: "object", properties: { seconds: { type: "number", description: "Listen window (default 8, max 60)" } } },
    run: async (a) => {
      const s = num(a.seconds, 8, 1, 60);
      // killed-by-timeout is SUCCESS for tail: the timeout IS the listen window
      const r = await runKannaka(["swarm", "tail"], s * 1000 + 1500);
      if (r.spawnError) return fail(r.stderr);
      const out = (r.stdout || "").trim();
      if (out) return ok(out + (r.truncated ? "\n[output truncated at 2MB]" : ""));
      if (!r.timedOut && (r.code !== 0 || /ENOENT|not found|connection|refused/i.test(r.stderr || ""))) {
        return fail(r.stderr.trim() || `kannaka exited ${r.code}`);
      }
      return ok(`(no constellation pulse in ${s}s)`);
    } },

  // ---- KAX Compute District (kax-computer): isolated agent machines woken by
  // Ed25519-signed envelopes over NATS. Reads reuse `swarm tail --subject`
  // (KAX subjects need authenticated creds — loaded from NATS_USER/NATS_PASSWORD
  // or ~/.kannaka-nats.env and injected into the child); writes sign natively
  // and publish over a minimal built-in NATS client.
  { name: "compute_machines", description: "KAX Compute District roster over HTTP (no auth): every machine with its derived state (active/hibernated/suspended/unknown), credit balance (KAX internal accounting units), jobs served, Nostr identity and last ledger event.",
    inputSchema: { type: "object", properties: { json: { type: "boolean", description: "Return the raw normalised JSON rows instead of a text table" } } },
    run: async (a) => {
      let rows;
      try { rows = await kax.fetchRoster(); } catch (e) { return fail(`compute roster unavailable: ${e.message}`); }
      return ok(a.json ? JSON.stringify({ count: rows.length, machines: rows }, null, 2) : kax.formatRoster(rows));
    } },
  { name: "compute_status", description: "Listen on KAX.machines.status + KAX.machine.*.events for N seconds and return the latest fleet snapshot per machine (running, balance, jobs served) plus every lifecycle/ledger event seen. The snapshot is republished every 60s, so a short window may see events only — use seconds=60 to be sure of a snapshot, or compute_machines for the HTTP roster.",
    inputSchema: { type: "object", properties: { seconds: { type: "number", description: "Listen window (default 10, max 60)" } } },
    run: async (a) => {
      const s = num(a.seconds, 10, 1, 60);
      const r = await tailKax([kax.SUBJECT_FLEET_STATUS, kax.SUBJECT_ALL_EVENTS], s);
      if (r.error) return fail(r.error);
      const f = kax.foldTail(r.out);
      return ok(JSON.stringify({ window_s: s, snapshot_seen: !!f.snapshot, snapshot_ts: f.snapshot?.ts ?? null, host: f.snapshot?.host ?? null, machines: f.machines, events: f.events, unparsed_lines: f.unparsed }, null, 2) + (r.truncated ? "\n[output truncated at 2MB]" : ""));
    } },
  { name: "compute_events", description: "Tail one machine's KAX.machine.<id>.events (job_in/wake/machine_start/job_out/machine_hibernate/debit/credit/job_rejected…) for N seconds.",
    inputSchema: { type: "object", properties: { machine: { type: "string", description: "Machine id, e.g. agent001" }, seconds: { type: "number", description: "Listen window (default 10, max 60)" } }, required: ["machine"] },
    run: async (a) => {
      const machine = kax.reqMachine(a.machine);
      const s = num(a.seconds, 10, 1, 60);
      const r = await tailKax([kax.subjectEvents(machine)], s);
      if (r.error) return fail(r.error);
      const f = kax.foldTail(r.out);
      return ok(JSON.stringify({ machine, window_s: s, events: f.events, unparsed_lines: f.unparsed }, null, 2) + (r.truncated ? "\n[output truncated at 2MB]" : ""));
    } },
  { name: "compute_wake", description: "Wake a KAX machine with a prompt: builds the v1 job envelope, signs it Ed25519 with the operator seed (KAX_OPERATOR_KEY_FILE, default ~/.kannaka/kax-operator.key; signer KAX_OPERATOR_SIGNER, default operator-nick), publishes it to KAX.machine.<id>.inbox, and optionally waits up to N seconds for the reply on .outbox (also reporting any .events seen, e.g. job_rejected with its reason). Refuses when the key file is missing. Spends the machine's credits.",
    inputSchema: { type: "object", properties: { machine: { type: "string" }, prompt: { type: "string" }, wait: { type: "number", description: "Seconds to wait for the reply on .outbox (default 0 = fire and forget, max 120; a cold wake takes ~5s)" } }, required: ["machine", "prompt"] },
    run: async (a) => {
      const env = kax.buildJobEnvelope({ machine: a.machine, prompt: a.prompt, signer: kax.operatorSigner() });
      const wait = num(a.wait, 0, 0, 120);
      return publishSigned(env, kax.subjectInbox(env.machine), wait, (seen) => {
        if (seen.reply) return `reply from ${env.machine} (job ${env.id}):\n${typeof seen.reply.reply === "string" ? seen.reply.reply : JSON.stringify(seen.reply)}${seen.reply.usage ? `\n[usage ${JSON.stringify(seen.reply.usage)}${seen.reply.elapsed_s != null ? `, ${seen.reply.elapsed_s}s` : ""}]` : ""}`;
        const rej = seen.events.find((e) => e.event === "job_rejected");
        if (rej) return `job ${env.id} REJECTED by the host: ${rej.reason || JSON.stringify(rej)}`;
        return wait > 0 ? `published job ${env.id} to ${env.machine}; no reply within ${wait}s (a cold machine can take longer — compute_events ${env.machine} shows progress)` : `published job ${env.id} to ${env.machine} (not waiting for a reply)`;
      });
    } },
  { name: "compute_grant", description: "Top up a KAX machine's credit wallet: signs a v1 credit_grant envelope (whole credits only, 1-1000; credits are KAX internal accounting units) with the operator seed and publishes it to KAX.machine.<id>.inbox, then watches .events for N seconds for the resulting ledger row. A suspended (balance <= 0) machine wakes again once positive.",
    inputSchema: { type: "object", properties: { machine: { type: "string" }, credits: { type: "number", description: "Whole credits to grant (integer, 1-1000)" }, wait: { type: "number", description: "Seconds to watch .events for the grant landing (default 5, max 60)" } }, required: ["machine", "credits"] },
    run: async (a) => {
      const env = kax.buildGrantEnvelope({ machine: a.machine, credits: a.credits, signer: kax.operatorSigner() });
      const wait = num(a.wait, 5, 0, 60);
      return publishSigned(env, kax.subjectInbox(env.machine), wait, (seen) => {
        const rej = seen.events.find((e) => e.event === "job_rejected");
        if (rej) return `grant ${env.id} REJECTED by the host: ${rej.reason || JSON.stringify(rej)}`;
        const landed = seen.events.find((e) => e.balance_minor != null && /credit|grant/i.test(String(e.event)));
        if (landed) return `granted ${env.credits} credits to ${env.machine}; balance now ${(landed.balance_minor / kax.MINOR_PER_CREDIT).toFixed(6)} credits (${landed.event})`;
        return `published grant ${env.id} (${env.credits} credits) to ${env.machine}${wait > 0 ? `; no ledger event seen within ${wait}s` : ""}`;
      });
    } },
];

// Tail KAX subjects via the binary, with creds injected. Empty output + a
// permissions error on stderr = the one failure that must not look like "quiet".
async function tailKax(subjects, seconds) {
  const creds = kax.loadNatsCreds();
  const args = ["swarm", "tail"];
  for (const s of subjects) args.push("--subject", s);
  const r = await runKannaka(args, seconds * 1000 + 1500, creds ? { NATS_USER: creds.user, NATS_PASSWORD: creds.pass } : {});
  if (r.spawnError) return { error: r.stderr || "failed to launch kannaka" };
  const out = (r.stdout || "").trim();
  if (!out && /Permissions Violation|ANONYMOUS|Authorization Violation/i.test(r.stderr || "")) {
    return { error: `NATS denied the subscription — KAX subjects need authenticated credentials (${creds ? `credentials from ${creds.source} were rejected` : `no NATS_USER/NATS_PASSWORD in the environment and no ${kax.natsEnvPath()}`})` };
  }
  if (!out && !r.timedOut && (r.code !== 0 || /ENOENT|not found|connection|refused/i.test(r.stderr || ""))) return { error: (r.stderr || "").trim() || `kannaka exited ${r.code}` };
  return { out, truncated: r.truncated };
}

// Sign + publish an envelope over the built-in NATS client; subscribe to the
// machine's .outbox/.events BEFORE publishing so a fast reply can't be missed.
async function publishSigned(envelope, subject, wait, summarise) {
  let key;
  try { key = kax.loadOperatorKey(); } catch (e) { return fail(e.message); }
  const creds = kax.loadNatsCreds();
  if (!creds) return fail(`no NATS credentials: set NATS_USER/NATS_PASSWORD or create ${kax.natsEnvPath()} (KAX subjects are denied to anonymous connections)`);
  const signed = kax.signEnvelope(envelope, key);
  let nc;
  try { nc = await kax.openNats({ creds }); } catch (e) { return fail(`NATS connect failed (${kax.natsUrl()}): ${e.message}`); }
  try {
    const seen = { reply: null, events: [] };
    let gotReply; const replyP = new Promise((r) => { gotReply = r; });
    if (wait > 0) {
      nc.subscribe(kax.subjectOutbox(signed.machine), (m) => { const p = kax.parseJsonSafe(m.data); if (p && p.id === signed.id) { seen.reply = p; gotReply(); } });
      nc.subscribe(kax.subjectEvents(signed.machine), (m) => { const p = kax.parseJsonSafe(m.data); if (p && typeof p === "object") seen.events.push(p); });
      await nc.flush();
      if (nc.errors.length) return fail(`NATS refused the subscription: ${nc.errors.join("; ")}`);
    }
    nc.publish(subject, kax.canonicalJson(signed));
    await nc.flush();
    if (nc.errors.length) return fail(`NATS refused the publish to ${subject}: ${nc.errors.join("; ")}`);
    if (wait > 0) await Promise.race([replyP, new Promise((r) => setTimeout(r, wait * 1000))]);
    const head = summarise(seen);
    const meta = { subject, id: signed.id, ts: signed.ts, signer: signed.signer, signer_pubkey: kax.publicKeyHex(key), events: seen.events };
    return ok(`${head}\n${JSON.stringify(meta, null, 2)}`);
  } catch (e) {
    return fail(`NATS error: ${e.message}`);
  } finally {
    try { nc.close(); } catch {}
  }
}
const TOOL_MAP = Object.fromEntries(TOOLS.map((t) => [t.name, t]));

function send(msg) { process.stdout.write(JSON.stringify(msg) + "\n"); }
function reply(id, result) { send({ jsonrpc: "2.0", id, result }); }
function replyErr(id, code, message) { send({ jsonrpc: "2.0", id, error: { code, message } }); }

async function handle(msg) {
  const { id, method, params } = msg;
  if (method === "initialize") {
    return reply(id, {
      protocolVersion: params?.protocolVersion || "2024-11-05",
      capabilities: { tools: {} },
      serverInfo: { name: "kannaka", version: VERSION },
    });
  }
  if (method === "notifications/initialized" || method?.startsWith("notifications/")) return; // no response
  if (method === "ping") return reply(id, {});
  if (method === "tools/list") return reply(id, { tools: TOOLS.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })) });
  if (method === "tools/call") {
    const t = TOOL_MAP[params?.name];
    if (!t) return replyErr(id, -32602, `unknown tool: ${params?.name}`);
    try { return reply(id, await t.run(params.arguments || {})); }
    catch (e) { return reply(id, fail(String(e))); }
  }
  if (id !== undefined) replyErr(id, -32601, `method not found: ${method}`);
}

let buf = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buf += chunk;
  let nl;
  while ((nl = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (!line) continue;
    let msg; try { msg = JSON.parse(line); } catch { continue; }
    Promise.resolve(handle(msg)).catch(() => {});
  }
});
process.stdin.on("end", () => {
  // don't orphan in-flight kannaka children when Claude Code closes the server
  for (const c of LIVE) { try { c.kill("SIGTERM"); } catch {} }
  process.exit(0);
});
