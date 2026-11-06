// Timeout budgets for the HRM tools in kannaka-mcp.mjs.
// Run: node --test test/   (Node >= 20, no dependencies)
//
// The stand-in "kannaka binary" is node itself (KANNAKA_BIN = process.execPath)
// started in a temp dir holding scripts named after the subcommands, so
// `kannaka status` runs ./status. No real binary or HRM store is touched.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const MCP = join(HERE, "..", "plugins", "kannaka", "mcp", "kannaka-mcp.mjs");

function fakeBinDir(scripts) {
  const dir = mkdtempSync(join(tmpdir(), "kannaka-fake-"));
  for (const [name, body] of Object.entries(scripts)) writeFileSync(join(dir, name), body);
  return dir;
}

// Start the server, call one tool, return its result.
function callTool(dir, name, args, env = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [MCP], {
      cwd: dir,
      env: { ...process.env, KANNAKA_BIN: process.execPath, ...env },
      stdio: ["pipe", "pipe", "pipe"],
    });
    let buf = "";
    const done = setTimeout(() => { child.kill(); reject(new Error("no tool reply within 20s")); }, 20000);
    child.stdout.on("data", (d) => {
      buf += d;
      for (const line of buf.split("\n")) {
        let msg; try { msg = JSON.parse(line); } catch { continue; }
        if (msg.id === 2) { clearTimeout(done); child.stdin.end(); child.kill(); resolve(msg.result); }
      }
    });
    const send = (m) => child.stdin.write(JSON.stringify(m) + "\n");
    send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "0" } } });
    send({ jsonrpc: "2.0", method: "notifications/initialized" });
    send({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name, arguments: args } });
  });
}

const SLOW = "setTimeout(() => { console.log('{\"ok\":true}'); }, 3000);\n";
const FAST = "console.log('{\"active_memories\":1}');\n";

test("a slow status succeeds under the default budget", async () => {
  // 3 s here; real stores take 30-54 s, which the old flat 20 s always killed.
  const dir = fakeBinDir({ status: SLOW });
  const r = await callTool(dir, "kannaka_status", {});
  assert.equal(r.isError, undefined, JSON.stringify(r));
  assert.match(r.content[0].text, /"ok":true/);
});

test("KANNAKA_MCP_TIMEOUT_MS overrides the budget and the error names it", async () => {
  const dir = fakeBinDir({ status: SLOW });
  const r = await callTool(dir, "kannaka_status", {}, { KANNAKA_MCP_TIMEOUT_MS: "500" });
  assert.equal(r.isError, true);
  assert.match(r.content[0].text, /^kannaka timed out after 1s/);
  // a read does not carry the write warning
  assert.doesNotMatch(r.content[0].text, /may still have landed/);
});

test("a timed-out remember warns that the write may have landed", async () => {
  const dir = fakeBinDir({ remember: SLOW });
  const r = await callTool(dir, "kannaka_remember", { text: "hello" }, { KANNAKA_MCP_TIMEOUT_MS: "500" });
  assert.equal(r.isError, true);
  assert.match(r.content[0].text, /may still have landed/);
  assert.match(r.content[0].text, /kannaka_recall/);
});

test("fast commands still succeed", async () => {
  const dir = fakeBinDir({ status: FAST });
  assert.ok(existsSync(join(dir, "status")));
  const r = await callTool(dir, "kannaka_status", {});
  assert.match(r.content[0].text, /active_memories/);
});
