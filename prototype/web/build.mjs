#!/usr/bin/env node
// Builds prototype/web/aepm.html from the app's own captured frames.
// Source of truth: tests/golden/*.txt, the same fixtures src/tui/render.rs
// asserts byte for byte. A frame is embedded verbatim, never redrawn.
// The behaviour lives in app.js; this file only inlines it and the frames.
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const golden = join(here, '..', '..', 'tests', 'golden');

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
    [w, h] = name.split('x').map(Number);
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
  ((frames[name] ??= {})[`${w}x${h}`] ??= {})[ascii ? 1 : 0] = text;
  count++;
}

if (count === 0) throw new Error(`no frames found in ${golden}`);
for (const [scene, sizes] of Object.entries(frames)) {
  if (!sizes['80x24'] && !sizes['120x40']) throw new Error(`${scene}: no usable size`);
}

const app = readFileSync(join(here, 'app.js'), 'utf8');
if (!app.includes('__FRAMES__')) throw new Error('app.js lost its __FRAMES__ placeholder');

const SHELL = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>aepm · TUI demo</title>
<style>
  :root {
    --fg: #c8c8c8; --bg: #101010; --muted: #6b6b6b; --accent: #3fb7c9;
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
  /* Palette constants from src/tui/render.rs: PLANNED=Blue, ACTIVE=Yellow,
     DONE=Green, DIM=DarkGray, FAILURE=Red, cursor=Cyan+bold. */
  .planned { color: #6f9bea; }
  .active { color: #d9b53f; }
  .done { color: #3fbf5f; }
  .failed { color: #e05252; }
  .dim { color: var(--muted); }
  .cursor { color: var(--accent); font-weight: 700; }
  .warn { color: #6f9bea; }
  #exit { display: none; padding: 20px 0; color: #8a8a8a; }
  .legend { color: #6a6a6a; font: 400 11px/1.7 system-ui, sans-serif; margin-top: 10px; max-width: 70ch; }
  .legend kbd { color: #b8b8b8; font: inherit; border: 1px solid #262626; border-radius: 3px; padding: 0 4px; }
</style>
</head>
<body>
<div id="chrome">
  <b>aepm</b>
  <span id="where"></span>
  <span id="size"></span>
  <select id="pick" title="jump to any captured screen"></select>
  <button data-key="F">F fetch</button>
  <button data-key="i">i install</button>
  <button data-key="l">l log</button>
  <button data-key="g">g ledger</button>
  <button data-key="x">x failure replay</button>
  <button data-key="Escape">esc</button>
  <button id="ascii">ascii</button>
  <span id="note"></span>
</div>
<div id="crt"><pre id="screen"></pre></div>
<div id="exit">Session ended. The real app restores the terminal and exits 0. Reload to boot again.</div>
<div class="legend">
  App keys: <kbd>F</kbd> fetch · <kbd>i</kbd> install (modal gate) · <kbd>l</kbd> log after a fetch ·
  <kbd>g</kbd> ledger toggle · <kbd>r</kbd> refresh · <kbd>j</kbd><kbd>k</kbd> cursor ·
  <kbd>?</kbd> help · <kbd>esc</kbd> close or end · <kbd>q</kbd> quit.
  Demo-only: <kbd>x</kbd> replays the failing fetch, <kbd>ctrl</kbd>+<kbd>a</kbd> the ascii tier,
  <kbd>ctrl</kbd>+<kbd>v</kbd> a self-check that reads the DOM.
  Colour follows render.rs's palette constants; the golden fixtures store text only.
</div>
<script>
__APP__
</script>
</body>
</html>
`;

const html = SHELL.replace('__APP__', () => app.replaceAll('__FRAMES__', () => JSON.stringify(frames)));
writeFileSync(join(here, 'aepm.html'), html);
const scenes = Object.keys(frames).sort();
console.log(`frames: ${count} in ${scenes.length} scenes -> ${join(here, 'aepm.html')}`);
console.log(scenes.map((s) => `${s}(${Object.keys(frames[s]).join('/')})`).join(' '));
