// Red-first test for the browser-infrastructure retry.
//
// Measured flake: run 44901392026 on a docs-only PR failed
//   FAIL 75/76 — tui-120x40.txt: spawnSync google-chrome ETIMEDOUT
// That is chrome hanging, not a golden mismatch. A hanging browser must not be
// reported as a finding, and it must not be reported as a skip either.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isInfraFault, withRetry, InfraFault } from './retry.mjs';

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

test('InfraFault carries the last real error for the log', () => {
  try {
    withRetry(() => { const e = new Error('spawnSync ETIMEDOUT'); e.code = 'ETIMEDOUT'; throw e; });
    assert.fail('should have thrown');
  } catch (e) {
    assert.equal(e.name, 'InfraFault');
    assert.match(e.message, /ETIMEDOUT/);
  }
});
