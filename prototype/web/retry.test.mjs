// Red-first test for the browser-infrastructure retry.
//
// Measured flake: run 44901392026 on a docs-only PR failed
//   FAIL 75/76 — tui-120x40.txt: spawnSync google-chrome ETIMEDOUT
// That is chrome hanging, not a golden mismatch. A hanging browser must not be
// reported as a finding, and it must not be reported as a skip either.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isInfraFault, withRetry, InfraFault } from './retry.mjs';
// Namespace import so a missing export fails one test, not the whole file.
import * as web from './retry.mjs';

test('a chrome timeout is an infrastructure fault, not a finding', () => {
  const e = new Error('spawnSync google-chrome ETIMEDOUT');
  e.code = 'ETIMEDOUT';
  assert.equal(isInfraFault(e), true);
});

test('a signal-killed browser is an infrastructure fault', () => {
  const e = new Error('Command failed');
  e.signal = 'SIGTERM';
  assert.equal(isInfraFault(e), true);
});

test('a golden mismatch is not an infrastructure fault', () => {
  assert.equal(isInfraFault(new Error('screen differs from golden')), false);
});

test('one infrastructure fault is retried once and can succeed', () => {
  let calls = 0;
  const out = withRetry(() => {
    calls += 1;
    if (calls === 1) { const e = new Error('ETIMEDOUT'); e.code = 'ETIMEDOUT'; throw e; }
    return 'dom';
  });
  assert.equal(out, 'dom');
  assert.equal(calls, 2);
});

test('a finding is never retried', () => {
  let calls = 0;
  assert.throws(() => withRetry(() => { calls += 1; throw new Error('screen differs from golden'); }));
  assert.equal(calls, 1);
});

test('two infrastructure faults raise InfraFault, not a bare error', () => {
  let calls = 0;
  assert.throws(() => withRetry(() => {
    calls += 1;
    const e = new Error('ETIMEDOUT'); e.code = 'ETIMEDOUT'; throw e;
  }), InfraFault);
  assert.equal(calls, 2, 'retries exactly once: two attempts, not three');
});

test('a missing browser binary is deterministic: ENOENT is not retried', () => {
  const err = new Error('spawnSync chromium ENOENT');
  err.code = 'ENOENT';
  assert.equal(isInfraFault(err), false, 'no binary will not appear on a second attempt');
  let calls = 0;
  assert.throws(() => withRetry(() => { calls += 1; throw err; }), (e) => {
    assert.equal(e, err, 'the caller is handed the honest error, not an InfraFault');
    return true;
  });
  assert.equal(calls, 1, 'one attempt, so the honest message is not delayed by a retry');
});

test('a recovered retry says which attempt failed and that the next one worked', () => {
  const seen = [];
  const real = process.stderr.write;
  process.stderr.write = (chunk) => { seen.push(String(chunk)); return true; };
  try {
    let calls = 0;
    const out = withRetry(() => {
      calls += 1;
      if (calls === 1) { const e = new Error('ETIMEDOUT'); e.code = 'ETIMEDOUT'; throw e; }
      return 'dom';
    });
    assert.equal(out, 'dom');
  } finally {
    process.stderr.write = real;
  }
  const said = seen.join('');
  assert.match(said, /attempt 1\/2 failed/, 'stderr names the attempt that failed');
  assert.match(said, /ETIMEDOUT/, 'stderr carries the fault a runner can act on');
  assert.match(said, /attempt 2\/2 succeeded/, 'stderr says the retry recovered');
});

test('the verdict comes from the error type, not from the message text', () => {
  const infra = {
    msg: 'tui-120x40.txt: browser infrastructure fault after 2 attempts: ETIMEDOUT',
    err: new InfraFault(new Error('ETIMEDOUT')),
  };
  // A finding may quote the fault text; only the error's type decides.
  const finding = {
    msg: 'tui-log-120x40.txt: row 2\n  want "ok"\n  got  "browser infrastructure fault after 2 attempts"',
    err: new Error('screen differs from golden'),
  };
  assert.equal(web.report([finding], { pass: 89, total: 90 }).code, 1,
    'a finding that talks about infrastructure is still a finding');
  const mixed = web.report([infra, finding], { pass: 88, total: 90 });
  assert.equal(mixed.code, 1, 'one finding outranks any number of infrastructure faults');
  assert.match(mixed.text, /tui-120x40\.txt/, 'the report names the infrastructure fault');
  assert.match(mixed.text, /tui-log-120x40\.txt/, 'the report names the finding too');
  assert.equal(web.report([infra, infra], { pass: 88, total: 90 }).code, 2,
    'only an all-infrastructure run says the browser never produced a DOM');
  assert.equal(web.report([], { pass: 90, total: 90 }).code, 0);
});

test('a missing browser is not retried, but it is still no verdict on a golden', () => {
  const err = new Error('spawnSync chromium ENOENT');
  err.code = 'ENOENT';
  err.syscall = 'spawnSync chromium';
  // The no-retry rule and the exit-code rule are different questions: this run
  // judged nothing, so it must not read as "every golden is wrong".
  const verdict = web.report([{ msg: 'tui-120x40.txt: spawnSync chromium ENOENT', err }], { pass: 0, total: 76 });
  assert.equal(verdict.code, 2, 'the browser never ran, so nothing was judged');
  assert.match(verdict.text, /INFRASTRUCTURE 0\/76/);
});

test('a missing fixture file is a finding, not a missing browser', () => {
  const err = new Error("ENOENT: no such file or directory, open 'tests/golden/tui-x.txt'");
  err.code = 'ENOENT';
  err.syscall = "open 'tests/golden/tui-x.txt'";
  const verdict = web.report([{ msg: 'tui-x.txt: ENOENT', err }], { pass: 75, total: 76 });
  assert.equal(verdict.code, 1, 'a missing golden is a repo defect, not a browser fault');
  assert.match(verdict.text, /FAIL 75\/76/);
});

test('a missing browser beside a real finding still reports the finding', () => {
  const gone = new Error('spawnSync chromium ENOENT');
  gone.code = 'ENOENT';
  gone.syscall = 'spawnSync chromium';
  const verdict = web.report([
    { msg: 'tui-120x40.txt: spawnSync chromium ENOENT', err: gone },
    { msg: 'tui-log-120x40.txt: row 2 differs', err: new Error('screen differs from golden') },
  ], { pass: 74, total: 76 });
  assert.equal(verdict.code, 1, 'one finding outranks any number of browser faults');
});

test('a finding that merely says "timed out" is still a finding', () => {
  // A golden frame can carry a TUI status line: the comparison error then quotes
  // "timed out" without being a browser fault. Only type and fields decide.
  const quoting = new Error('tui-prefetch-120x40.txt: want "⏱ 6s timed out" got "⏱ 6s"');
  const verdict = web.report([{ msg: quoting.message, err: quoting }], { pass: 75, total: 76 });
  assert.equal(verdict.code, 1, 'a golden mismatch that quotes the words is not infrastructure');
  assert.match(verdict.text, /FAIL 75\/76/);
});

test('a signal-killed browser is classified infra after the retry wraps it', () => {
  // The wrap drops code and signal, so the type has to carry the verdict: a
  // SIGKILL on a memory-limited runner never compared a golden.
  let wrapped;
  try {
    withRetry(() => { const e = new Error('Command failed: chromium'); e.signal = 'SIGKILL'; throw e; });
    assert.fail('should have thrown');
  } catch (e) { wrapped = e; }
  assert.equal(wrapped.name, 'InfraFault');
  const verdict = web.report([{ msg: `tui-120x40.txt: ${wrapped.message}`, err: wrapped }], { pass: 0, total: 76 });
  assert.equal(verdict.code, 2, 'a killed browser is not a verdict on a golden');
  assert.match(verdict.text, /INFRASTRUCTURE 0\/76/);
});

test('InfraFault carries the last real error for the log', () => {
  try {
    withRetry(() => { const e = new Error('spawnSync ETIMEDOUT'); e.code = 'ETIMEDOUT'; throw e; });
    assert.fail('should have thrown');
  } catch (e) {
    assert.equal(e.name, 'InfraFault');
    assert.match(e.message, /ETIMEDOUT/);
  }
});
