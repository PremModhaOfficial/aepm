#!/usr/bin/env node
// Turing check for prototype/web/aepm.html.
//  1. Every capture renders with DOM text byte-equal to its golden fixture.
//  2. Key paths follow src/tui/mod.rs, including modal screens and refusals.
//  3. Colour classes follow the palette constants in src/tui/render.rs.
//  4. sub-second paths: the install gate never auto-advances; a failing fetch
//     reaches the repair card; ctrl-v self-check can fail; sizing is declared.
// Fails loudly: a missing chromium, a crashed page, or one differing byte.
import { readdirSync, readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import { execFileSync } from 'node:child_process';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..');
const golden = join(root, 'tests', 'golden');
const page = join(here, 'aepm.html');
const chrome = process.env.CHROMIUM || 'chromium';
const profile = mkdtempSync(join(tmpdir(), 'aepm-verify-'));

// A stale generated file must not pass: rebuild from app.js and tests/golden
// first, then prove the build consumed every fixture.
const built = execFileSync(process.execPath, [join(here, 'build.mjs')], { encoding: 'utf8' });
const counted = /frames: (\d+) in (\d+) scenes/.exec(built);
const fixtures = readdirSync(golden).filter((f) => f.endsWith('.txt'));
if (!counted) throw new Error('build.mjs did not report its frame count: ' + built.trim());
if (+counted[1] !== fixtures.length) {
  throw new Error(`build used ${counted[1]} frames, ${fixtures.length} fixtures exist`);
}

function parseName(file) {
  const name = file.replace(/^tui-/, '').replace(/\.txt$/, '');
  if (/^\d+x\d+$/.test(name)) return { scene: 'tree', size: name, ascii: false };
  const m = /^(.*)-(\d+)x(\d+)$/.exec(name);
  if (!m) throw new Error(`unparseable golden name: ${file}`);
  let scene = m[1];
  const ascii = scene.endsWith('-ascii');
  if (ascii) scene = scene.slice(0, -'-ascii'.length);
  return { scene, size: `${m[2]}x${m[3]}`, ascii };
}

function dom(query, { window = '1400,1200', budget = 800 } = {}) {
  return execFileSync(chrome, [
    '--headless=new', '--disable-gpu', '--no-sandbox', '--hide-scrollbars',
    `--virtual-time-budget=${budget}`, `--user-data-dir=${profile}`,
    `--window-size=${window}`, '--dump-dom', `file://${page}?${query}`
  ], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 30000 });
}

const ENTITIES = { amp: '&', lt: '<', gt: '>', quot: '"', '#39': "'", nbsp: ' ' };
const decode = (s) => s.replace(/&(amp|lt|gt|quot|#39|nbsp);/g, (_, e) => ENTITIES[e]);

function rowsOf(html) {
  const pre = /<pre id="screen">([\s\S]*?)<\/pre>/.exec(html);
  if (!pre) throw new Error('no #screen in DOM');
  return decode(pre[1].replace(/<\/div>/g, '\n').replace(/<[^>]+>/g, ''))
    .replace(/\n$/, '').split('\n');
}

function noteOf(html) {
  const m = /<span id="note"[^>]*>([\s\S]*?)<\/span>/.exec(html);
  return m ? decode(m[1].replace(/<[^>]+>/g, '')) : '';
}

const failures = [];
let pass = 0;
let scheduled = 0;
const fail = (msg) => failures.push(msg);

function guarded(label, fn) {
  try { fn(); } catch (e) { fail(`${label}: ${String(e.message).split('\n')[0]}`); }
}

// Text for one screen, compared with the fixture it claims to be.
function check(label, query, wantFile, opts) {
  scheduled++;
  const want = readFileSync(join(golden, wantFile), 'utf8').replace(/\n$/, '').split('\n');
  guarded(label, () => {
    const html = dom(query, opts);
    if (html.includes('class="null"')) fail(`${label}: tokenizer emitted class="null"`);
    const got = rowsOf(html);
    if (got.length !== want.length) {
      return fail(`${label}: ${got.length} rows rendered, expected ${want.length}`);
    }
    const bad = want.findIndex((line, i) => got[i] !== line);
    if (bad === -1) return void pass++;
    fail(`${label}: row ${bad + 1}\n  want ${JSON.stringify(want[bad])}\n  got  ${JSON.stringify(got[bad])}`);
  });
}

function checkDom(label, query, pred, opts) {
  scheduled++;
  guarded(label, () => {
    if (pred(dom(query, opts))) return void pass++;
    fail(`${label}: DOM assertion failed`);
  });
}

// 1. Every fixture, at its own size, colour and ascii tier.
for (const file of readdirSync(golden).sort()) {
  if (!file.endsWith('.txt')) continue;
  const { scene, size, ascii } = parseName(file);
  check(file, `scene=${scene}&size=${size}${ascii ? '&ascii=1' : ''}`, file);
}

// 2. Key paths, per mod.rs: modal screens first, and refusals that keep the frame.
const KEYS = [
  ['F opens PRE-FLIGHT', 'keys=F', 'tui-gates-120x40.txt'],
  ['l opens the captured log', 'keys=F,l', 'tui-log-120x40.txt'],
  ['l again closes the log', 'keys=F,l,l', 'tui-gates-120x40.txt'],
  ['esc closes the log before anything else', 'keys=F,l,escape', 'tui-gates-120x40.txt'],
  ['g toggles the ledger on', 'keys=g', 'tui-ledger-120x40.txt'],
  ['g toggles the ledger off', 'keys=g,g', 'tui-prefetch-120x40.txt'],
  ['i opens the modal gate', 'keys=i', 'tui-install-gate-120x40.txt'],
  ['enter is refused until space attests', 'keys=i,enter', 'tui-install-gate-120x40.txt'],
  ['space attests, enter lands the receipt', 'keys=i,space,enter', 'tui-post-install-120x40.txt'],
  ['the gate ignores l, g, F', 'keys=i,l,g,F', 'tui-install-gate-120x40.txt'],
  ['the receipt ignores l, g, F', 'keys=i,space,enter,l,g,F', 'tui-post-install-120x40.txt'],
  ['i is refused while a fetch runs', 'keys=F,i', 'tui-gates-120x40.txt'],
  ['a second F is refused while a fetch runs', 'keys=F,F', 'tui-gates-120x40.txt'],
  ['l before any fetch does nothing', 'keys=l', 'tui-prefetch-120x40.txt'],
  ['the ledger ignores esc, as mod.rs does', 'scene=ledger&keys=escape', 'tui-ledger-120x40.txt'],
  ['the failing fetch ends on the repair card', 'keys=x&norum=0', 'tui-repair-120x40.txt', { budget: 4000 }],
  ['the install gate never auto-advances', 'keys=i&norum=0', 'tui-install-gate-120x40.txt', { budget: 3000 }],
  ['a narrow window selects the 80x24 capture', '', 'tui-prefetch-80x24.txt', { window: '900,700' }],
  ['a wide window selects the 120x40 capture', '', 'tui-prefetch-120x40.txt'],
];
for (const [label, query, wantFile, opts] of KEYS) {
  const q = query.includes('norum=') ? query : `${query}${query ? '&' : ''}norum=1`;
  check(label, q, wantFile, opts);
}

// 3. Palette constants from render.rs, per span class.
checkDom('planned markers are blue', 'scene=ledger&norum=1',
  (h) => /class="planned">\[ \]<\/span>/.test(h));
checkDom('done markers are green', 'scene=ledger&norum=1',
  (h) => /class="done">\[√\]<\/span>/.test(h));
checkDom('a failed row is red', 'scene=repair&norum=1',
  (h) => /class="failed">\[×\]<\/span>/.test(h));
checkDom('bars are yellow, empty cells dim', 'scene=showcase&norum=1',
  (h) => /class="active">[■█◧◨]{2,}/.test(h) && /class="dim">[□░]{2,}/.test(h));
checkDom('no legacy class names survive', 'scene=gates&norum=1',
  (h) => !/class="(ok|err|block|run|muted|accent)"/.test(h));
checkDom('ascii tier is monochrome, as use_color() is', 'scene=showcase&ascii=1&norum=1',
  (h) => !/class="(planned|active|done|failed|dim|cursor|warn|bold)"/.test(h));
checkDom('gate passes are green', 'scene=gates&norum=1',
  (h) => /class="done">✓<\/span>/.test(h));
checkDom('a gate warning is blue', 'scene=install-gate&norum=1',
  (h) => /class="warn">▲<\/span>/.test(h));
checkDom('a stale badge is yellow, not blue', 'scene=prefetch&norum=1',
  (h) => /class="active">▲<\/span>/.test(h));
checkDom('a receipt dash is dim', 'scene=post-install&norum=1',
  (h) => /class="dim">–<\/span>/.test(h));

// 4. The attested gate repaint (render.rs:391-408) and the tier label.
checkDom('space repaints the gate as attested', 'scene=install-gate&keys=space&norum=1', (h) => {
  const rows = rowsOf(h);
  return rows.length === 40
    && rows.some((r) => /✓  news     attested for this session/.test(r))
    && !rows.some((r) => /press space to attest/.test(r))
    && rows.some((r) => /enter install · esc cancel/.test(r));
});
checkDom('the size label names the tier on screen', 'scene=prefetch&size=120x40&norum=1',
  (h) => /id="size">120x40 · unicode/.test(h));
checkDom('a unicode fallback is labelled as such', 'scene=gates&ascii=1&norum=1',
  (h) => /unicode text, monochrome/.test(h));
checkDom('the picker offers every capture', 'norum=1', (h) => {
  const opts = [...h.matchAll(/<option value="([^"]+)"/g)].map((m) => m[1]);
  const scenes = new Set(fixtures.map((f) => parseName(f).scene));
  return opts.length === scenes.size && [...scenes].every((s) => opts.includes(s));
});

// 4. Declared substitutions and the two controls that are demo-only.
checkDom('the news key says it cannot open a browser', 'scene=install-gate&keys=n&norum=1',
  (h) => /news page/.test(noteOf(h)));
checkDom('a missing ascii capture is declared', 'scene=gates&ascii=1&norum=1',
  (h) => /no ascii capture/.test(noteOf(h)));
checkDom('ctrl-v self-check reads the DOM and passes', 'scene=prefetch&keys=ctrl-v&norum=1',
  (h) => /self-check: DOM matches prefetch/.test(noteOf(h)));
checkDom('ctrl-v self-check can fail', 'scene=prefetch&tamper=1&keys=ctrl-v&norum=1',
  (h) => /self-check: MISMATCH/.test(noteOf(h)));
checkDom('esc ends the session while a fetch runs', 'keys=F,escape&norum=1',
  (h) => /id="exit" style="display: block/.test(h));
checkDom('q ends the session with exit 0', 'keys=q&norum=1',
  (h) => /id="exit" style="display: block/.test(h) && /id="crt" style="display: none/.test(h)
    && /exits 0/.test(h));
checkDom('ctrl-c is its own exit path', 'keys=ctrl-c&norum=1',
  (h) => /exits 130/.test(h) && /Interrupted/.test(h));
checkDom('an unknown scene is declared, not silent', 'scene=nope&norum=1',
  (h) => /no capture for scene nope/.test(noteOf(h)));

rmSync(profile, { recursive: true, force: true });
// Coverage must be accounted for: a skipped check is itself a failure.
if (pass + failures.length !== scheduled) {
  failures.push(`coverage: ${pass} pass + ${failures.length} fail != ${scheduled} scheduled`);
}
const total = scheduled;
if (failures.length) {
  console.error(`FAIL ${pass}/${total}`);
  for (const f of failures) console.error(' - ' + f);
  process.exit(1);
}
console.log(`PASS ${pass}/${total}: every captured frame, key path and palette rule matches`);
