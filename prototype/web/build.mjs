#!/usr/bin/env node
// Builds prototype/web/aur-prefetch.html from the app's own captured frames.
// Source of truth: tests/golden/*.txt, the same fixtures src/tui/render.rs asserts
// byte-for-byte. Nothing here invents a pixel: a frame is embedded verbatim.
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..');
const golden = join(root, 'tests', 'golden');

const NAME = /^tui-(.+)\.txt$/;
const DIMS = /^(.*)-(\d+)x(\d+)$/;

/** frames[scene][`${w}x${h}`][ascii ? 1 : 0] = text */
const frames = {};
let count = 0;

for (const file of readdirSync(golden).sort()) {
  const m = NAME.exec(file);
  if (!m) continue;
  let name = m[1];
  let w = 80, h = 24, ascii = false;
  if (/^\d+x\d+$/.test(name)) {
    w = +name.split('x')[0];
    h = +name.split('x')[1];
    name = 'tree';
  } else {
    const d = DIMS.exec(name);
    if (!d) throw new Error(`unparseable golden name: ${file}`);
    name = d[1];
    w = +d[2];
    h = +d[3];
    if (name.endsWith('-ascii')) {
      name = name.slice(0, -'-ascii'.length);
      ascii = true;
    }
  }
  const text = readFileSync(join(golden, file), 'utf8');
  const lines = text.replace(/\n$/, '').split('\n');
  if (lines.length !== h) throw new Error(`${file}: ${lines.length} lines, expected ${h}`);
  for (const [i, line] of lines.entries()) {
    if ([...line].length > w) throw new Error(`${file}: line ${i + 1} wider than ${w}`);
  }
  const size = `${w}x${h}`;
  ((frames[name] ??= {})[size] ??= {})[ascii ? 1 : 0] = text;
  count++;
}

if (count === 0) throw new Error(`no frames found in ${golden}`);
for (const [scene, sizes] of Object.entries(frames)) {
  if (!sizes['80x24'] && !sizes['120x40']) throw new Error(`${scene}: no usable size`);
}

const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>aur-prefetch · TUI demo</title>
<style>
  :root {
    --fg: #c8c8c8; --bg: #101010; --muted: #6b6b6b; --accent: #3fb7c9;
    --ok: #3fbf5f; --warn: #d9b53f; --block: #c74fc7; --err: #e05252; --run: #5f8fe0;
  }
  html, body { margin: 0; background: #070707; color: var(--fg); }
  body { font: 400 13px/1.15 ui-monospace, "JetBrains Mono", "DejaVu Sans Mono", monospace; padding: 12px; }
  #chrome {
    display: flex; flex-wrap: wrap; gap: 8px; align-items: center;
    font: 400 11px/1.4 system-ui, sans-serif; color: #8a8a8a;
    padding-bottom: 8px; margin-bottom: 8px; border-bottom: 1px solid #1e1e1e;
  }
  #chrome b { color: #d0d0d0; font-weight: 600; }
  #chrome button, #chrome select {
    font: inherit; color: #b8b8b8; background: #161616; border: 1px solid #262626;
    border-radius: 3px; padding: 2px 6px; cursor: pointer;
  }
  #chrome button:hover { border-color: #3a3a3a; color: #e6e6e6; }
  #chrome button.on { border-color: var(--accent); color: var(--accent); }
  #note { color: #7a7a7a; }
  #note.bad { color: #e05252; }
  #crt { background: var(--bg); padding: 10px 12px; border-radius: 4px; overflow-x: auto; }
  #screen { margin: 0; white-space: pre; tab-size: 8; font-variant-ligatures: none; letter-spacing: 0; }
  .r { height: 1.15em; }
  .r0 { font-weight: 700; }
  .bold { font-weight: 700; }
  .muted { color: var(--muted); }
  .accent { color: var(--accent); }
  .ok { color: var(--ok); }
  .warn { color: var(--warn); }
  .block { color: var(--block); }
  .err { color: var(--err); }
  .run { color: var(--run); }
  #exit { display: none; padding: 20px 0; color: #8a8a8a; }
  .legend { color: #6a6a6a; font: 400 11px/1.6 system-ui, sans-serif; margin-top: 10px; }
  .legend kbd { color: #b8b8b8; font: inherit; border: 1px solid #262626; border-radius: 3px; padding: 0 4px; }
</style>
</head>
<body>
<div id="chrome">
  <b>aur-prefetch</b>
  <span id="where"></span>
  <span id="size"></span>
  <select id="pick" title="jump to any captured screen"></select>
  <button data-key="F">F fetch</button>
  <button data-key="i">i install</button>
  <button data-key="l">l log</button>
  <button data-key="g">g ledger</button>
  <button data-key="Escape">esc</button>
  <button id="ascii">ascii</button>
  <span id="note"></span>
</div>
<div id="crt"><pre id="screen"></pre></div>
<div id="exit">Session ended. The real app restores the terminal and exits 0. Reload to boot again.</div>
<div class="legend">
  keys: <kbd>F</kbd> fetch · <kbd>i</kbd> install · <kbd>l</kbd> log · <kbd>g</kbd> ledger ·
  <kbd>esc</kbd> dismiss · <kbd>q</kbd> quit ·
  <kbd>ctrl</kbd>+<kbd>v</kbd> self-check ·
  <kbd>ctrl</kbd>+<kbd>a</kbd> ascii.
  Colour is reconstructed from TUI.md tokens: the golden fixtures store text only.
</div>
<script>
"use strict";
const FRAMES = ${JSON.stringify(frames, null, 0)};

/* Scenes the landed TUI has captures for, in fetch order. */
const FETCH_RUN = ["gates", "live-fetch", "live-progress", "live-progress-unknown",
  "live-window", "live-roots", "live-diamond", "live-subsecond", "showcase",
  "live-failure", "repair"];
const INSTALL_RUN = ["install-gate", "post-install"];
const STEP_MS = 700;

const LABEL = {
  prefetch: "Progress · dependency forest", tree: "tree (v1 capture)",
  gates: "Fetch · PRE-FLIGHT", "live-fetch": "Fetch · streaming",
  "live-progress": "Fetch · bytes", "live-progress-unknown": "Fetch · no total known",
  "live-window": "Fetch · viewport, 200 packages", "live-roots": "Fetch · roots",
  "live-diamond": "Fetch · diamond", "live-subsecond": "Fetch · sub-second",
  showcase: "Fetch · mixed states", "live-failure": "Fetch · failure",
  repair: "Fetch · repair card", ledger: "Fetch · g ledger", log: "Fetch · l log",
  "install-gate": "Install · gate", "post-install": "Install · receipt"
};

const S = { scene: "prefetch", ascii: false, stack: [], run: null, timer: null, exited: false };

const pick = document.getElementById("pick");
const screenEl = document.getElementById("screen");
const whereEl = document.getElementById("where");
const sizeEl = document.getElementById("size");
const noteEl = document.getElementById("note");
const asciiBtn = document.getElementById("ascii");
const exitEl = document.getElementById("exit");

for (const name of Object.keys(FRAMES).sort()) {
  const o = document.createElement("option");
  o.value = name;
  o.textContent = LABEL[name] ? name + " — " + LABEL[name] : name;
  pick.appendChild(o);
}

/* A capture decides its own geometry: three screens were only ever captured at
   120x40, so asking for them at 80 columns shows the 120-column screen. */
function resolve(name) {
  const frames = FRAMES[name];
  if (!frames) return null;
  const forced = new URLSearchParams(location.search).get("size");
  const want = (forced && frames[forced]) ? forced : (window.innerWidth >= 1080 ? "120x40" : "80x24");
  const size = frames[want] ? want : (frames["80x24"] ? "80x24" : "120x40");
  const variants = frames[size];
  const text = variants[S.ascii ? 1 : 0] || variants[1] || variants[0];
  const [w, h] = size.split("x").map(Number);
  return { text, w, h, size, ascii: !!variants[S.ascii ? 1 : 0] };
}

/* Semantic colouring, from the token table in TUI.md. Order matters:
   first alternative that matches at a position wins. */
const RULES = [
  // Gauges before the single-glyph rules: this build fills byte bars with ■,
  // the same glyph TUI.md reserves for "blocked". A run is a bar, one is a gate.
  ["[■█◧◨]{2,}", "accent"], ["[□░]{2,}", "muted"],
  ["[✓]", "ok"], ["[✖×✗]", "err"], ["▲", "warn"], ["■", "block"], ["◐", "run"],
  ["[▸▌]", "accent"],
  ["⏱", "muted"], ["·", "muted"],
  ["\\\\b(?:done|built|ready|cached|prefetched|success|attested)\\\\b", "ok"],
  ["\\\\b(?:failed|missing|error|refused|denied)\\\\b|exit \\\\d+", "err"],
  ["\\\\b(?:blocked|gate)\\\\b", "block"],
  ["\\\\b(?:stale|partial|build-pending|not in cache)\\\\b|\\\\bwarning\\\\b", "warn"],
  ["\\\\b(?:building|downloading|running|fetching|pulling)\\\\b", "run"],
  ["\\\\b(?:planned|waiting|skipped|unknown|pending)\\\\b", "muted"],
  ["\\\\b\\\\d+[smh] ago\\\\b|\\\\b\\\\d+(?:\\\\.\\\\d+)?%\\\\b|/var/\\\\S+|/etc/\\\\S+|\\\\bline \\\\d+\\\\b", "muted"],
  ["(?:Dependency Graph:|Ledger:|PRE-FLIGHT|COMMAND|Install ·|Post-install ·|Fetch log)", "bold"]
];
const RX = new RegExp(RULES.map(([re]) => "(" + re + ")").join("|"), "g");
const CLASSES = RULES.map(([, cls]) => cls);

function esc(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function style(line) {
  let out = "", last = 0;
  RX.lastIndex = 0;
  for (let m; (m = RX.exec(line)); ) {
    let cls = null;
    for (let i = 0; i < CLASSES.length; i++) {
      if (m[i + 1] !== undefined) { cls = CLASSES[i]; break; }
    }
    if (m.index > last) out += esc(line.slice(last, m.index));
    out += '<span class="' + cls + '">' + esc(m[0]) + "</span>";
    last = m.index + m[0].length;
  }
  return out + esc(line.slice(last));
}

function rows(text) {
  return text.replace(/\\n$/, "").split("\\n");
}

function paint() {
  const f = resolve(S.scene);
  if (!f) { note("no capture for " + S.scene, true); return; }
  const lines = rows(f.text);
  let html = "";
  for (let i = 0; i < lines.length; i++) {
    html += '<div class="r' + (i === 0 ? " r0" : "") + '">' + style(lines[i]) + "</div>";
  }
  screenEl.innerHTML = html;
  whereEl.textContent = (LABEL[S.scene] || S.scene);
  sizeEl.textContent = f.size + (f.ascii ? " · ascii" : "");
  pick.value = S.scene;
  asciiBtn.classList.toggle("on", S.ascii);
  window.__lastFrame = lines;
}

function note(msg, bad) {
  noteEl.textContent = msg ? "· " + msg : "";
  noteEl.className = bad ? "bad" : "";
}

function show(name) {
  if (!FRAMES[name]) { note("no capture for " + name, true); return; }
  S.scene = name;
  paint();
}

function startRun(names, label) {
  stopRun();
  let i = 0;
  const step = () => {
    while (i < names.length && !resolve(names[i])) i++;
    if (i >= names.length) { S.run = null; note(label + ": captures exhausted"); return; }
    show(names[i++]);
    note(label + " running · esc detaches (the real app never kills pacman)");
    if (S.norum) return;
    S.timer = setTimeout(step, STEP_MS);
  };
  S.run = label;
  step();
}

function stopRun() {
  if (S.timer) clearTimeout(S.timer);
  S.timer = null;
  S.run = null;
}

function onKey(e) {
  if (e.ctrlKey && (e.key === "a" || e.key === "A")) {
    e.preventDefault();
    S.ascii = !S.ascii;
    paint();
    note(S.ascii ? "ascii glyph tier" : "unicode glyph tier");
    return;
  }
  if (e.ctrlKey && (e.key === "v" || e.key === "V")) {
    e.preventDefault();
    const f = resolve(S.scene);
    const same = f && rows(f.text).join("\\n") === window.__lastFrame.join("\\n");
    note(same ? "self-check: DOM text matches " + S.scene + " " + f.size
              : "self-check: MISMATCH", !same);
    return;
  }
  if (e.key === "q") { quit(); return; }
  if (e.key === "F") { startRun(FETCH_RUN, "fetch"); return; }
  if (e.key === "i") { startRun(INSTALL_RUN, "install"); return; }
  if (e.key === "l") { S.below = S.scene; show("log"); note("captured log · esc closes the log first"); return; }
  if (e.key === "g") { show("ledger"); note("ledger · 4 packages"); return; }
  if (e.key === "Escape") {
    // Precedence, per TUI.md: a closed log is never mistaken for a detach.
    if (S.scene === "log") { show(S.below || "prefetch"); return; }
    if (S.run) { stopRun(); note("detached: pacman keeps running; the view is stale"); return; }
    show("prefetch");
    note("");
    return;
  }
  if (e.key === " ") {
    if (S.scene === "install-gate") {
      note("attested for this session · enter installs");
    }
    e.preventDefault();
    return;
  }
  if (e.key === "Enter") {
    if (S.scene === "install-gate") { stopRun(); show("post-install"); note("receipt · read-only"); }
    return;
  }
}

function quit() {
  stopRun();
  S.exited = true;
  document.getElementById("crt").style.display = "none";
  document.getElementById("chrome").style.display = "none";
  exitEl.style.display = "block";
}

pick.addEventListener("change", () => { stopRun(); show(pick.value); note(""); });
asciiBtn.addEventListener("click", () => { S.ascii = !S.ascii; paint(); });
for (const b of document.querySelectorAll("#chrome button[data-key]")) {
  b.addEventListener("click", () => onKey({ key: b.dataset.key, ctrlKey: false, preventDefault() {} }));
}
document.addEventListener("keydown", onKey);
window.addEventListener("resize", paint);

/* Deep link for the verifier and for sharing a screen:
   ?scene=gates&ascii=1&size=120x40&keys=F,l */
const qs = new URLSearchParams(location.search);
if (qs.get("ascii") === "1") S.ascii = true;
S.norum = qs.get("norum") === "1";
show(qs.get("scene") && FRAMES[qs.get("scene")] ? qs.get("scene") : "prefetch");
if (qs.get("keys")) {
  for (const token of qs.get("keys").split(",")) {
    const key = token === "escape" ? "Escape" : token === "enter" ? "Enter" : token === "space" ? " " : token;
    onKey({ key, ctrlKey: false, preventDefault() {} });
  }
}
</script>
</body>
</html>
`;

writeFileSync(join(here, "aur-prefetch.html"), html);
const scenes = Object.keys(frames).sort();
console.log(`frames: ${count} in ${scenes.length} scenes -> ${join(here, "aur-prefetch.html")}`);
console.log(scenes.map((s) => `${s}(${Object.keys(frames[s]).join("/")})`).join(" "));
