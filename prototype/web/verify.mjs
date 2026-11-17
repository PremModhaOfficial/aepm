#!/usr/bin/env node
// Turing check for prototype/web/aur-prefetch.html.
// 1. Every captured screen renders in headless chromium with the DOM text of
//    #screen equal, byte for byte, to the golden fixture it came from.
// 2. Key sequences reach the screen the landed TUI reaches (F, l, g, i, esc).
// Fails loudly: missing chromium, crashed page, or one differing byte is a fail.
import { readdirSync, readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import { execFileSync } from 'node:child_process';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..');
const golden = join(root, 'tests', 'golden');
const page = join(here, 'aur-prefetch.html');
const chrome = process.env.CHROMIUM || 'chromium';
const profile = mkdtempSync(join(tmpdir(), 'aur-prefetch-verify-'));

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

function dom(query) {
  return execFileSync(chrome, [
    '--headless=new', '--disable-gpu', '--no-sandbox', '--hide-scrollbars',
    '--virtual-time-budget=800', `--user-data-dir=${profile}`,
    '--window-size=1400,1200', '--dump-dom', `file://${page}?${query}`
  ], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 30000 });
}

const decode = (s) => s
  .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
  .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&nbsp;/g, ' ');

function rowsOf(html) {
  const pre = /<pre id="screen">([\s\S]*?)<\/pre>/.exec(html);
  if (!pre) throw new Error('no #screen in DOM');
  return decode(pre[1].replace(/<\/div>/g, '\n').replace(/<[^>]+>/g, ''))
    .replace(/\n$/, '').split('\n');
}

const failures = [];
let pass = 0;

function check(label, query, wantFile) {
  const want = readFileSync(join(golden, wantFile), 'utf8').replace(/\n$/, '').split('\n');
  let got;
  try {
    got = rowsOf(dom(query));
  } catch (e) {
    failures.push(`${label}: ${e.message.split('\n')[0]}`);
    return;
  }
  if (got.length !== want.length) {
    failures.push(`${label}: ${got.length} rows rendered, expected ${want.length}`);
    return;
  }
  const bad = want.findIndex((line, i) => got[i] !== line);
  if (bad === -1) { pass++; return; }
  failures.push(`${label}: row ${bad + 1}\n  want ${JSON.stringify(want[bad])}\n  got  ${JSON.stringify(got[bad])}`);
}

// 1. Every fixture, at its own size, in colour and in ascii where captured.
for (const file of readdirSync(golden).sort()) {
  if (!file.endsWith('.txt')) continue;
  const { scene, size, ascii } = parseName(file);
  check(file, `scene=${scene}&size=${size}${ascii ? '&ascii=1' : ''}`, file);
}

// 2. The landed TUI's key paths.
const INTERACTION = [
  ['F opens PRE-FLIGHT', 'keys=F', 'tui-gates-120x40.txt'],
  ['l opens the captured log', 'keys=F,l', 'tui-log-120x40.txt'],
  ['esc closes the log first, back to the frame underneath', 'keys=F,l,escape', 'tui-gates-120x40.txt'],
  ['g opens the ledger', 'keys=g', 'tui-ledger-120x40.txt'],
  ['i opens the install gate', 'keys=i', 'tui-install-gate-120x40.txt'],
  ['space attests, enter lands the receipt', 'keys=i,space,enter', 'tui-post-install-120x40.txt'],
  ['esc detaches a running fetch and keeps the frame', 'keys=F,escape&size=80x24', 'tui-gates-80x24.txt'],
  ['esc from a top-level screen returns to the tree', 'keys=escape&size=80x24', 'tui-prefetch-80x24.txt'],
];
for (const [label, query, wantFile] of INTERACTION) check(label, `${query}&norum=1`, wantFile);

rmSync(profile, { recursive: true, force: true });
const total = pass + failures.length;
if (failures.length) {
  console.error(`FAIL ${pass}/${total}`);
  for (const f of failures) console.error(' - ' + f);
  process.exit(1);
}
console.log(`PASS ${pass}/${total}: every captured frame and key path matches the app`);
