"use strict";
/* The demo's whole behaviour. build.mjs inlines this file, with __FRAMES__
   replaced by the captured golden frames, into one self-contained HTML file.

   Fidelity rules that shape it:
   - screens are the app's captured output, never redrawn;
   - the palette mirrors src/tui/render.rs (PLANNED blue, ACTIVE yellow, DONE
     green, DIM dark gray, FAILURE red, cursor cyan bold), and --ascii disables
     colour entirely, as use_color() does;
   - keys follow src/tui/mod.rs, including which screens are modal. */
const FRAMES = __FRAMES__;

/* Runs. F is the success path; x replays the failure the repair card explains.
   showcase is excluded: render.rs builds it under #[cfg(test)], so no real
   fetch can display it. */
const FETCH_RUN = ["gates", "live-fetch", "live-progress", "live-progress-unknown",
  "live-window", "live-roots", "live-diamond", "live-subsecond"];
const FAIL_RUN = ["gates", "live-fetch", "live-failure", "repair"];
const STEP_MS = 700;

const LABEL = {
  prefetch: "Progress · dependency forest", tree: "tree (v1 capture)",
  gates: "Fetch · PRE-FLIGHT", "live-fetch": "Fetch · streaming",
  "live-progress": "Fetch · bytes", "live-progress-unknown": "Fetch · no total known",
  "live-window": "Fetch · viewport, 200 packages", "live-roots": "Fetch · roots",
  "live-diamond": "Fetch · diamond", "live-subsecond": "Fetch · sub-second",
  showcase: "Fetch · mixed states (synthetic test frame)", "live-failure": "Fetch · failure",
  repair: "Fetch · repair card", ledger: "Fetch · g ledger", log: "Fetch · l log",
  "install-gate": "Install · gate", "post-install": "Install · receipt"
};

const S = {
  scene: "prefetch", ascii: false, under: null, session: false,
  run: null, timer: null, attested: false, norum: false, tamper: false
};

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
  const want = forced && frames[forced] ? forced : (window.innerWidth >= 1080 ? "120x40" : "80x24");
  const size = frames[want] ? want : (frames["80x24"] ? "80x24" : "120x40");
  const variants = frames[size];
  const ascii = !!variants[1];
  const text = variants[S.ascii ? 1 : 0] || variants[1] || variants[0];
  const [w, h] = size.split("x").map(Number);
  return { text, w, h, size, ascii, want, fellBack: size !== want };
}

/* Colour rules, ordered: the first alternative that matches at a position wins.
   Sources: render.rs:37-41 (the palette), 1295-1297 (gate glyphs), 1991-1995
   (live states), 2238/2267-2271 (artifact badges, bars, percent). */
const RULES = [
  // Filled and empty bar cells before the single-glyph rules: this build draws
  // byte bars with the block glyph, and a run is a bar where one is a gate.
  ["[■█◧◨]{2,}", "active"], ["[□░]{2,}", "dim"],
  ["[▸>]", "cursor"],
  ["\\[√\\]", "done"], ["✓", "done"],
  ["\\[ \\]", "planned"],
  ["\\[\\|\\]|◐", "active"],
  ["\\[×\\]|✗|×", "failed"],
  ["▲", "warn"],
  ["⏱|·", "dim"],
  ["\\b(?:done|built|cached|prefetched|ready|success|attested|no lock file)\\b", "done"],
  ["\\b(?:failed|error|refused|denied|not found)\\b|exit \\d+", "failed"],
  ["\\b(?:stale|partial|downloading|building|fetching|pulling)\\b|\\b\\d+(?:\\.\\d+)?%", "active"],
  ["\\b(?:missing|build-pending|planned)\\b", "planned"],
  ["\\b(?:blocked|skipped|unknown|waiting|pending|no state written)\\b", "dim"],
  ["\\b\\d+[smh] ago\\b|/var/\\S+|/etc/\\S+|\\bline \\d+\\b", "dim"],
  ["(?:Dependency Graph:|Ledger:|PRE-FLIGHT|COMMAND|Install ·|Post-install ·|fetch log)", "bold"]
];
const RX = new RegExp(RULES.map(([re]) => "(" + re + ")").join("|"), "g");
const CLASSES = RULES.map(([, cls]) => cls);

function esc(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function style(line) {
  if (S.ascii) return esc(line); // use_color() is false in ascii mode: no spans
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
  return text.replace(/\n$/, "").split("\n");
}

function note(msg, bad) {
  noteEl.textContent = msg ? "· " + msg : "";
  noteEl.className = bad ? "bad" : "";
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
  whereEl.textContent = LABEL[S.scene] || S.scene;
  sizeEl.textContent = f.size + (S.ascii ? " · ascii (no colour)" : "");
  pick.value = S.scene;
  asciiBtn.classList.toggle("on", S.ascii);
  // A substitution is never silent: say which capture is actually on screen.
  const caveats = [];
  if (f.fellBack) caveats.push("no " + f.want + " capture; showing " + f.size);
  if (S.ascii && !f.ascii) caveats.push("no ascii capture; unicode text shown monochrome");
  if (caveats.length) note(caveats.join(" · "), true);
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
    note(label + " running · esc ends the session, the app exits the TUI");
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

/* Ctrl-V: compare what is on screen, read back from the DOM, with the capture.
   It must be able to fail, so it never reads the FRAMES entry directly. */
function selfCheck() {
  const f = resolve(S.scene);
  if (!f) { note("self-check: nothing captured for " + S.scene, true); return; }
  const shown = Array.from(screenEl.querySelectorAll(".r")).map((el) => el.textContent);
  const same = shown.join("\n") === rows(f.text).join("\n");
  note(same ? "self-check: DOM matches " + S.scene + " " + f.size
            : "self-check: MISMATCH on " + S.scene, !same);
}

function onKey(e) {
  if (e.ctrlKey && (e.key === "a" || e.key === "A")) {
    e.preventDefault();
    S.ascii = !S.ascii;
    paint();
    note(S.ascii ? "ascii tier: the app's --ascii flag, demo-only key" : "unicode tier");
    return;
  }
  if (e.ctrlKey && (e.key === "v" || e.key === "V")) { e.preventDefault(); selfCheck(); return; }
  if (e.ctrlKey && (e.key === "c" || e.key === "C")) { quit(); return; }

  // The receipt is read-only and modal: esc/enter close it, q quits, nothing else.
  if (S.scene === "post-install") {
    if (e.key === "Escape" || e.key === "Enter") { show(S.under || "prefetch"); note(""); }
    else if (e.key === "q") quit();
    return;
  }
  // The gate is modal: attest, the armed install, cancel, quit.
  if (S.scene === "install-gate") {
    if (e.key === "Escape") { show(S.under || "prefetch"); note(""); }
    else if (e.key === "q") quit();
    else if (e.key === " ") {
      e.preventDefault();
      S.attested = true;
      note("attested for this session · enter is armed");
    } else if (e.key === "n") {
      // TUI.md gives the gate an n key that opens the news page.
      note("n opens the news page; there is no browser to open here", true);
    } else if (e.key === "Enter") {
      // render.rs arms the action only on an attested news gate.
      if (!S.attested) { note("refused: press space to attest after reading the news", true); return; }
      show("post-install");
      note("receipt · read-only");
    }
    return;
  }

  if (e.key === "q") { quit(); return; }

  if (e.key === "F") {
    if (S.run) { note("one fetch at a time; esc ends the session", true); return; }
    S.session = true;
    startRun(FETCH_RUN, "fetch");
    return;
  }
  if (e.key === "x") { // demo-only: the failing fetch the repair card explains
    if (S.run) { note("one fetch at a time; esc ends the session", true); return; }
    S.session = true;
    startRun(FAIL_RUN, "failing fetch");
    return;
  }
  if (e.key === "i") {
    if (S.run) { note("install blocked: the fetch owns pacman's lock", true); return; }
    S.under = S.scene;
    S.attested = false;
    show("install-gate");
    note("gate · space attests, enter is armed only after that");
    return;
  }
  if (e.key === "l") {
    if (!S.session) return; // the log exists only after a fetch session starts
    if (S.scene === "log") { show(S.under || "prefetch"); return; }
    S.under = S.scene;
    show("log");
    note("captured log · esc closes the log first");
    return;
  }
  if (e.key === "g") {
    if (S.scene === "ledger") { show(S.under || "prefetch"); return; }
    S.under = S.scene;
    show("ledger");
    note("ledger · a view toggle, nothing is written");
    return;
  }
  if (e.key === "j" || e.key === "k") {
    note("cursor movement has no capture: tests/golden stores no moved-selection frame", true);
    return;
  }
  if (e.key === "r") {
    if (S.run) { note("the live poll owns the refresh while the fetch runs"); return; }
    show("prefetch");
    note("refreshed · the same captured frame");
    return;
  }
  if (e.key === "?") {
    note("help has no capture in tests/golden, so it is not shown", true);
    return;
  }
  if (e.key === "Escape") {
    if (S.scene === "log") { show(S.under || "prefetch"); return; }
    if (S.scene === "ledger") { note("esc does nothing on the ledger; g toggles back"); return; }
    if (S.run) { quit(); return; } // mod.rs breaks out of the TUI while a fetch runs
    note(""); // at top level the app clears a notice and nothing else
  }
}

function quit() {
  stopRun();
  document.getElementById("crt").style.display = "none";
  document.getElementById("chrome").style.display = "none";
  document.querySelector(".legend").style.display = "none";
  exitEl.style.display = "block";
}

pick.addEventListener("change", () => { stopRun(); show(pick.value); note(""); });
asciiBtn.addEventListener("click", () => { S.ascii = !S.ascii; paint(); });
for (const b of document.querySelectorAll("#chrome button[data-key]")) {
  b.addEventListener("click", () => onKey({ key: b.dataset.key, ctrlKey: false, preventDefault() {} }));
}
document.addEventListener("keydown", onKey);
window.addEventListener("resize", paint);

/* Deep links, for the verifier and for sharing one screen:
   ?scene=gates&size=120x40&ascii=1&keys=F,l&norum=1&tamper=1 */
const qs = new URLSearchParams(location.search);
if (qs.get("ascii") === "1") S.ascii = true;
S.norum = qs.get("norum") === "1";
S.tamper = qs.get("tamper") === "1";
show(qs.get("scene") && FRAMES[qs.get("scene")] ? qs.get("scene") : "prefetch");
if (S.tamper) screenEl.firstChild.textContent = "X"; // proves Ctrl-V can fail
if (qs.get("keys")) {
  for (const token of qs.get("keys").split(",")) {
    const ctrl = token.startsWith("ctrl-");
    const key = ctrl ? token.slice(5) : token === "escape" ? "Escape"
      : token === "enter" ? "Enter" : token === "space" ? " " : token;
    onKey({ key, ctrlKey: ctrl, preventDefault() {} });
  }
}
