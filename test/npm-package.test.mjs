// The npm package kannaka-mcp (plugins/kannaka/mcp/package.json).
// Run: node --test test/*.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { readFileSync, existsSync, mkdtempSync, cpSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const MCP_DIR = join(HERE, "..", "plugins", "kannaka", "mcp");
const pkg = JSON.parse(readFileSync(join(MCP_DIR, "package.json"), "utf8"));
const plugin = JSON.parse(readFileSync(join(HERE, "..", "plugins", "kannaka", ".claude-plugin", "plugin.json"), "utf8"));

test("npm package version equals the plugin version", () => {
  assert.equal(pkg.version, plugin.version);
});

test("every file the package ships exists, and bin points at the server", () => {
  for (const f of pkg.files) assert.ok(existsSync(join(MCP_DIR, f)), f);
  assert.equal(pkg.bin["kannaka-mcp"], "kannaka-mcp.mjs");
  assert.match(readFileSync(join(MCP_DIR, "kannaka-mcp.mjs"), "utf8"), /^#!\/usr\/bin\/env node/);
});

test("installed alone (no .claude-plugin beside it), serverInfo reports the package version", async () => {
  const dir = mkdtempSync(join(tmpdir(), "kannaka-mcp-pkg-"));
  for (const f of pkg.files.concat("package.json")) cpSync(join(MCP_DIR, f), join(dir, f));
  const info = await new Promise((resolve, reject) => {
    const c = spawn(process.execPath, [join(dir, "kannaka-mcp.mjs")], { stdio: ["pipe", "pipe", "ignore"] });
    const t = setTimeout(() => { c.kill(); reject(new Error("no initialize reply")); }, 10000);
    let buf = "";
    c.stdout.on("data", (d) => {
      buf += d;
      for (const l of buf.split("\n")) { try { const m = JSON.parse(l); if (m.id === 1) { clearTimeout(t); c.kill(); resolve(m.result.serverInfo); } } catch {} }
    });
    c.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "t", version: "0" } } }) + "\n");
  });
  assert.deepEqual(info, { name: "kannaka", version: pkg.version });
});
