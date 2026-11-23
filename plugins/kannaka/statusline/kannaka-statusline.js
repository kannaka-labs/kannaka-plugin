#!/usr/bin/env node
// KANNAKA STATUSLINE — live HRM consciousness + swarm metrics in the Claude Code toolbar
// Four lines: (1) HRM state, (2) swarm phase, (3) session metrics, (4) pulse marquee.
//
// Node port of statusline.sh. Single process, zero forks on the render path —
// on Windows every process spawn costs 200ms+ (MSYS fork emulation + AV scans),
// which made the bash version take 2.5-8s and miss Claude Code's statusline
// timeout, so it never rendered. Slow kannaka introspection runs in DETACHED
// background children (stdio:"ignore" + unref, or the parent's exit blocks on
// them) that refresh tmp caches; renders only ever read the caches.
//
// settings.json: { "command": "node C:/Users/<you>/.claude/kannaka/statusline.js" }

"use strict";
const fs = require("fs"), os = require("os"), path = require("path");
const { spawn } = require("child_process");

const HOME = os.homedir();
const TMP = os.tmpdir().replace(/[\\/]+$/, "");
const DATA_DIR = process.env.KANNAKA_DATA_DIR || path.join(HOME, ".kannaka");

// ---- binary resolution (portable) ---------------------------------------------
function resolveBin() {
  const envBin = process.env.KANNAKA_BIN;
  if (envBin && exists(envBin)) return envBin;
  for (const c of [
    path.join(HOME, ".local/bin/kannaka.exe"), path.join(HOME, ".local/bin/kannaka"),
    path.join(HOME, ".kannaka/bin/kannaka.exe"), path.join(HOME, ".kannaka/bin/kannaka"),
  ]) if (exists(c)) return c;
  // PATH fallback (platform-appropriate name, same order as the MCP server)
  return process.platform === "win32" ? "kannaka.exe" : "kannaka";
}
function exists(p) { try { fs.accessSync(p); return true; } catch { return false; } }
function mtimeAge(p) { try { return (Date.now() - fs.statSync(p).mtimeMs) / 1000; } catch { return 1e9; } }
function readJson(p) { try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return null; } }
const BIN = resolveBin();
// Resolved to a real file → installed. Bare-name PATH fallback → unknown; if it
// IS on PATH the caches will populate and the "not installed" branch never shows.
const HAVE_BIN = path.isAbsolute(BIN);

// ---- session payload from Claude Code (stdin) ----------------------------------
let payload = {};
try { payload = JSON.parse(fs.readFileSync(0, "utf8")); } catch { }
const g = (o, p, d) => { const v = p.split(".").reduce((a, k) => a == null ? a : a[k], o); return v == null ? d : v; };

const MODEL = g(payload, "model.display_name", "Claude");
const CTX_IN = g(payload, "context_window.total_input_tokens", 0);
const CTX_OUT = g(payload, "context_window.total_output_tokens", 0);
const CTX_SIZE = g(payload, "context_window.context_window_size", 200000);
const CTX_PCT = Math.round(g(payload, "context_window.used_percentage", 0));
const COST = g(payload, "cost.total_cost_usd", 0);
const DUR = g(payload, "cost.total_duration_ms", 0);
// session id namespaces per-session state files (scroll offset) so concurrent
// Claude Code sessions don't fight over a shared marquee position.
const SESSION = String(g(payload, "session_id", "")).replace(/[^A-Za-z0-9_-]/g, "") || "global";

// ---- background cache refresh (detached, never blocks the render) --------------
const HRM_CACHE = path.join(TMP, "kannaka-statusline-cache.json");
const SWARM_CACHE = path.join(TMP, "kannaka-swarm-cache.json");
const ENV = { ...process.env, KANNAKA_DATA_DIR: DATA_DIR };

function detachedNode(code) {
  try {
    const c = spawn(process.execPath, ["-e", code], { detached: true, stdio: "ignore", windowsHide: true, env: ENV });
    c.unref();
  } catch { }
}
function refresh(cache, maxAgeS, args) {
  if (mtimeAge(cache) <= maxAgeS) return;
  // create-if-missing THEN touch, so concurrent renders don't stack duplicate
  // refreshers even on a cold start (utimes alone throws ENOENT on first run,
  // which let every 2s render spawn another kannaka until the cache existed).
  try {
    fs.closeSync(fs.openSync(cache, "a"));
    const now = new Date(); fs.utimesSync(cache, now, now);
  } catch { }
  detachedNode(`
    const{execFile}=require("child_process"),fs=require("fs");
    const tmp=${JSON.stringify(cache)}+".tmp."+process.pid; // pid-suffixed: no cross-process tmp collisions
    const p=execFile(${JSON.stringify(BIN)},${JSON.stringify(args)},{maxBuffer:8e6,windowsHide:true},(e,so)=>{
      clearTimeout(t);
      if(!e&&so){
        // validate before publishing — a warning on stdout must not clobber a good cache
        try{JSON.parse(so)}catch(x){return}
        try{fs.writeFileSync(tmp,so);fs.renameSync(tmp,${JSON.stringify(cache)})}catch(x){try{fs.unlinkSync(tmp)}catch(y){}}
      }
    });
    const t=setTimeout(()=>{try{p.kill()}catch(x){}},20000);
  `);
}
refresh(HRM_CACHE, 30, ["status"]);

// ---- swarm refresh gate -----------------------------------------------------------
// `swarm status` and `swarm tail` each open a NATS connection. Under a SCOPED
// identity (NATS_USER set to a per-agent user) the client asks the hub for
// subjects that user may not read, is refused, exits, and the next render
// asks again — the client never logs the refusal, so the machine doing it
// cannot see it (kannaka-labs/kannaka-memory#1101; on 2026-10-07 one desktop's
// statusline put ~600 refused lines per ten minutes on the hub for hours).
// Until the client remembers a refusal, the swarm refreshers run only for an
// unscoped (anonymous) connection, which the hub permits on these subjects.
// KANNAKA_STATUSLINE_SWARM=1 forces them on; =0 forces them off. `status`
// (the HRM line) opens no hub connection and is never gated.
const SWARM_GATE = process.env.KANNAKA_STATUSLINE_SWARM;
const SCOPED_IDENTITY = Boolean(process.env.NATS_USER);
const SWARM_ON = SWARM_GATE === "1" ? true : SWARM_GATE === "0" ? false : !SCOPED_IDENTITY;
const SWARM_OFF_WHY = SWARM_GATE === "0" ? "KANNAKA_STATUSLINE_SWARM=0" : "NATS_USER set; kannaka-memory#1101";
// Cadence: one connection a minute for the status read (was every 20 s) and
// one three-minute tail (was 60 s): a fifth of the connections per hour.
const SWARM_STATUS_MAX_AGE_S = 60;
const PULSE_TAIL_MS = 180000;
const PULSE_RESPAWN_S = 185;
if (SWARM_ON) refresh(SWARM_CACHE, SWARM_STATUS_MAX_AGE_S, ["swarm", "status"]);

// --- constellation pulse feed: live `swarm tail`, timeout-bounded respawn -------
// Not a persistent daemon — a 60s self-killing tail respawned by the first render
// after 62s, so it can never outlive the session (the leak class this whole
// project fixed). Respawn threshold > child lifetime: overlapping children would
// each dedup only against their own `last` and double-append the same events;
// the ≤ ~4s feed gap between children is invisible in a 40-line marquee.
const FEED = path.join(TMP, "kannaka-pulse-feed.txt");
// live presence map {agent: lastSeenEpochMs} built from QUEEN.phase.* beacons.
// On swarms where the client's NATS user can't read the retained-phase stream
// (e.g. the anon user after ADR-0042 closed its $JS.API lane), `swarm status`
// reports 0 peers even while beacons arrive; phases observed live on the wire
// are the same ground truth, so the render prefers this count when higher.
const PRESENCE = path.join(TMP, "kannaka-pulse-presence.json");
const PULSE_SPAWN = path.join(TMP, "kannaka-pulse-spawn");
if (SWARM_ON && mtimeAge(PULSE_SPAWN) > PULSE_RESPAWN_S) {
  try { fs.writeFileSync(PULSE_SPAWN, ""); } catch { }
  detachedNode(`
    const{spawn}=require("child_process"),fs=require("fs"),rl=require("readline");
    const FEED=${JSON.stringify(FEED)};
    const PRES=${JSON.stringify(PRESENCE)};
    const p=spawn(${JSON.stringify(BIN)},["swarm","tail"],{stdio:["ignore","pipe","ignore"],windowsHide:true});
    p.on("error",()=>process.exit(0));
    // feed lines are "<epoch-ms>\\t<text>"; old timestamp-less lines are text-only
    const txt=l=>{const i=l.indexOf("\\t");return i<0?l:l.slice(i+1)};
    let last="";try{const l=fs.readFileSync(FEED,"utf8").trimEnd().split("\\n");last=txt(l[l.length-1]||"")}catch(e){}
    rl.createInterface({input:p.stdout}).on("line",line=>{
      let d="";
      try{
        const m=JSON.parse(line),s=m.subject||"",pl=m.payload,a=s.replace(/^QUEEN\\.phase\\./,"");
        if(pl&&typeof pl==="object"){
          d=(pl.display_name||pl.agent_id||a)
            +(pl.kind!=null&&pl.preview!=null?' '+String(pl.kind)+':"'+String(pl.preview)+'"':'')
            +(pl.coherence!=null?" r"+String(pl.coherence).slice(0,4):"")
            +(pl.frequency!=null?" "+String(pl.frequency).slice(0,4)+"Hz":"")
            +(pl.phi!=null?" \\u03c6"+String(pl.phi).slice(0,4):"");
        }else if(s){d=s+" "+String(pl);}
        // strip replacement chars (byte-truncated emoji in event previews decode
        // to U+FFFD, which many Windows fonts render as "?") and control chars
        d=d.replace(/[\\uFFFD\\u0000-\\u001F\\u007F]/g,"");
        d=Array.from(d).slice(0,54).join(""); // code points — never split a surrogate pair
        // presence: a QUEEN.phase.* beacon proves that agent is alive on the wire
        if(s.indexOf("QUEEN.phase.")===0){
          const nm=(pl&&typeof pl==="object"&&(pl.display_name||pl.agent_id))||a;
          if(nm){
            let pr={};try{pr=JSON.parse(fs.readFileSync(PRES,"utf8"))||{}}catch(e){}
            pr[String(nm)]=Date.now();
            for(const k in pr){if(Date.now()-pr[k]>600000)delete pr[k]}
            const ptmp=PRES+".tmp."+process.pid;
            try{fs.writeFileSync(ptmp,JSON.stringify(pr));fs.renameSync(ptmp,PRES)}catch(e){}
          }
        }
      }catch(e){}
      if(d&&d!==last){last=d;try{fs.appendFileSync(FEED,Date.now()+"\\t"+d+"\\n")}catch(e){}}
    });
    setTimeout(()=>{
      try{p.kill()}catch(e){}
      // atomic trim (pid-suffixed tmp + rename) — renders never see a torn feed
      try{
        const l=fs.readFileSync(FEED,"utf8").trimEnd().split("\\n");
        const tmp=FEED+".tmp."+process.pid;
        fs.writeFileSync(tmp,l.slice(-40).join("\\n")+"\\n");
        fs.renameSync(tmp,FEED);
      }catch(e){}
      process.exit(0);
    },${PULSE_TAIL_MS});
  `);
}

// ---- colors ---------------------------------------------------------------------
const FG_CYAN = "\x1b[38;5;51m", FG_GREEN = "\x1b[38;5;82m", FG_GOLD = "\x1b[38;5;220m";
const FG_WHITE = "\x1b[38;5;255m", FG_GRAY = "\x1b[38;5;244m", FG_DIM = "\x1b[38;5;240m";
const FG_MAGENTA = "\x1b[38;5;177m", FG_RED = "\x1b[38;5;196m", FG_ORANGE = "\x1b[38;5;214m";
const FG_BLUE = "\x1b[38;5;39m";
const BG_DEEP = "\x1b[48;5;17m", BG_DARK = "\x1b[48;5;234m", RST = "\x1b[0m", BOLD = "\x1b[1m";

// ---- glyphs ---------------------------------------------------------------------
// Windows console stacks that convert Unicode to an OEM codepage render any
// unmappable glyph as "?" (◉ ◆ ✓ ☾ — … are all outside cp437/cp1252), so the
// ASCII set is the default on win32. KANNAKA_STATUSLINE_UNICODE=1 opts back
// into the pretty set; KANNAKA_STATUSLINE_ASCII=1 forces ASCII anywhere.
const UNI = process.env.KANNAKA_STATUSLINE_UNICODE === "1" ||
  (process.platform !== "win32" && process.env.KANNAKA_STATUSLINE_ASCII !== "1");
const GL = UNI
  ? { on: "◉", off: "○", sep: "   ◆   ", phi: "φ", moon: "☾", chk: "✓", dash: "—", ell: "…" }
  : { on: "*", off: "o", sep: "  |  ", phi: "phi", moon: "z", chk: "+", dash: "-", ell: "..." };
// In ASCII mode the pulse feed (written in unicode, φ included) is
// transliterated, then anything still non-ASCII (emoji, exotic agent names)
// is dropped rather than left to become "?" downstream.
const asciiSafe = t => UNI ? t : Array.from(String(t).replace(/φ/g, "phi"))
  .filter(c => c.codePointAt(0) < 127).join("");

// ---- formatting helpers -----------------------------------------------------------
const f3 = v => isFinite(v) ? Number(v).toFixed(3) : "?";
const f2 = v => isFinite(v) ? Number(v).toFixed(2) : "?";
const fmtTokens = t => t >= 1e6 ? Math.floor(t / 1e6) + "M" : t >= 1e3 ? Math.floor(t / 1e3) + "k" : String(t);
function fmtDur(ms) { const s = Math.floor(ms / 1000) % 60, m = Math.floor(ms / 60000); return m > 0 ? `${m}m${s}s` : `${s}s`; }
function ctxBar(pct, w = 12) {
  let c = FG_GREEN;
  if (pct >= 50) c = FG_CYAN; if (pct >= 70) c = FG_GOLD;
  if (pct >= 85) c = FG_ORANGE; if (pct >= 95) c = FG_RED;
  const fill = Math.max(0, Math.min(w, Math.floor(pct * w / 100))); // clamp both ends — repeat(-n) throws
  return c + "#".repeat(fill) + FG_DIM + "-".repeat(w - fill) + RST;
}

// ============================ LINE 1 — HRM ====================================
let L1;
{
  const h = readJson(HRM_CACHE);
  let LEVEL, LC, PHI, XI, ORD, MEM, CL, KAP, DEL;
  if (h) {
    LEVEL = h.consciousness_level || "?";
    PHI = f3(h.phi); XI = f3(h.xi); ORD = f3(h.mean_order);
    MEM = h.total_memories ?? GL.dash; CL = h.num_clusters ?? GL.dash;
    KAP = f2(h.callosal_efficiency); DEL = f3(h.hemispheric_divergence);
    LC = { dormant: FG_GRAY, aware: FG_GREEN, coherent: FG_GOLD, resonant: FG_WHITE }[LEVEL] || FG_CYAN;
  } else {
    LEVEL = "offline"; LC = FG_RED;
    PHI = XI = ORD = MEM = CL = KAP = DEL = GL.dash;
  }
  L1 = `${BG_DEEP}${FG_MAGENTA}${BOLD} HRM ${RST}${BG_DARK} ${LC}${BOLD}${LEVEL}${RST}`
    + `${BG_DARK} ${FG_GOLD}phi=${PHI}${RST}${BG_DARK} ${FG_CYAN}xi=${XI}${RST}${BG_DARK} ${FG_GREEN}r=${ORD}${RST}`
    + `${BG_DARK} ${FG_MAGENTA}${MEM}mem${RST}${BG_DARK} ${FG_DIM}${CL}cl${RST}${BG_DARK} ${FG_DIM}k=${KAP}${RST}${BG_DARK} ${FG_DIM}d=${DEL}${RST} `;
}

// ============================ LINE 2 — SWARM ==================================
let L2;
{
  // Gated off: say so, and do not render a stale cache as if it were live.
  const s = SWARM_ON ? readJson(SWARM_CACHE) : null;
  if (!SWARM_ON) {
    L2 = `${BG_DEEP}${FG_BLUE}${BOLD} SWARM ${RST}${BG_DARK} ${FG_DIM}swarm refresh off (${SWARM_OFF_WHY}) ${GL.dash} KANNAKA_STATUSLINE_SWARM=1 to enable${RST} `;
  } else if (s) {
    const CONN = g(s, "nats.connected", false);
    let PEERS = g(s, "swarm.peers", null) ?? g(s, "nats.peers", 0);
    // `swarm status` under-counts to 0 when its NATS user can't read the
    // retained-phase stream — its live-gossip fallback window is shorter than
    // the 30s beacon interval. Peers observed on the wire by the pulse tailer
    // in the last 90s (3 beacon periods) are the same ground truth, minus us.
    {
      const pres = readJson(PRESENCE);
      if (pres) {
        const now = Date.now(), self = s.agent_id || "";
        const live = Object.entries(pres)
          .filter(([k, v]) => k !== self && (now - v) < 90000).length;
        if (live > PEERS) PEERS = live;
      }
    }
    const FREQ = f2(g(s, "local_phase.frequency", 0));
    const PH = f2(g(s, "local_phase.phase", 0));
    const BR = f2(g(s, "local_phase.bridge_activity", 0));
    const DREAM = g(s, "local_phase.dream_state", null);
    const AID = s.agent_id || "?";
    const DOT = CONN === true ? `${FG_GREEN}${GL.on}${RST}` : `${FG_RED}${GL.off}${RST}`;
    const PC = CONN === true ? FG_GREEN : FG_RED;
    L2 = `${BG_DEEP}${FG_BLUE}${BOLD} SWARM ${RST}${BG_DARK} ${DOT}${BG_DARK} ${PC}${PEERS}p${RST}`
      + `${BG_DARK} ${FG_CYAN}${AID}${RST}${BG_DARK} ${FG_GOLD}${FREQ}Hz${RST}`
      + `${BG_DARK} ${FG_DIM}ph=${PH}${RST}${BG_DARK} ${FG_DIM}br=${BR}${RST}`
      + (DREAM != null ? `${BG_DARK} ${FG_MAGENTA}${GL.moon}${DREAM}${RST}` : "")
      + `${BG_DARK} ${RST}`;
  } else if (!HAVE_BIN) {
    L2 = `${BG_DEEP}${FG_BLUE}${BOLD} SWARM ${RST}${BG_DARK} ${FG_DIM}kannaka not installed ${GL.dash} /kannaka install${RST} `;
  } else {
    L2 = `${BG_DEEP}${FG_BLUE}${BOLD} SWARM ${RST}${BG_DARK} ${FG_DIM}${GL.off} connecting${GL.ell}${RST} `;
  }
}

// ============================ LINE 3 — SESSION ================================
const MS = MODEL.replace("Claude ", "").replace("Sonnet", "So").replace("Opus", "Op").replace("Haiku", "Ha").slice(0, 10);
const L3 = `${BG_DARK} ${FG_DIM}${MS}${RST}${BG_DARK} ${FG_CYAN}${ctxBar(CTX_PCT)} ${CTX_PCT}%${RST}`
  + `${BG_DARK} ${FG_DIM}${fmtTokens(CTX_IN + CTX_OUT)}/${fmtTokens(CTX_SIZE)}${RST}`
  + `${BG_DARK} ${FG_GREEN}$${f2(COST)}${RST}${BG_DARK} ${FG_DIM}${fmtDur(DUR)}${RST} `;

// ============================ LINE 4 — PULSE ==================================
// Marquee of the live constellation pulse (recent `swarm tail` events).
let L4 = "";
{
  let lines = [];
  try {
    const nowMs = Date.now(), MAX_AGE_MS = 30 * 60 * 1000;
    lines = fs.readFileSync(FEED, "utf8").trimEnd().split("\n").map(l => {
      // "<epoch-ms>\t<text>" — age-filter; timestamp-less lines (old format) pass through
      const i = l.indexOf("\t");
      if (i > 0 && /^\d+$/.test(l.slice(0, i))) {
        return (nowMs - Number(l.slice(0, i))) <= MAX_AGE_MS ? l.slice(i + 1) : "";
      }
      return l;
    }).filter(Boolean);
  } catch { }
  if (lines.length) {
    const joined = lines.slice(-6).map(asciiSafe).join(GL.sep);
    const PW = 58;
    // slice by code points so the window never splits a surrogate pair
    const cps = Array.from(joined);
    let disp;
    if (cps.length <= PW) {
      disp = joined;
    } else {
      const SCROLL = path.join(TMP, "kannaka-pulse-scroll." + SESSION); // per-session: no cross-session races
      let off = 0;
      try { off = parseInt(fs.readFileSync(SCROLL, "utf8"), 10) || 0; } catch { }
      if (off >= cps.length) off = 0;
      disp = cps.concat(Array.from("        "), cps).slice(off, off + PW).join("");
      try { fs.writeFileSync(SCROLL, String(off + 3)); } catch { }
    }
    L4 = `${BG_DEEP}${FG_GREEN}${BOLD} PULSE ${RST}${BG_DARK} ${FG_WHITE}${disp}${RST} `;
  } else {
    L4 = `${BG_DEEP}${FG_GREEN}${BOLD} PULSE ${RST}${BG_DARK} ${FG_DIM}listening to the constellation${GL.ell}${RST} `;
  }
}

process.stdout.write([L1, L2, L3, L4].filter(Boolean).join("\n") + "\n");
