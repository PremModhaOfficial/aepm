// Browser-infrastructure retry for verify.mjs.
//
// The demo verifier drives headless chrome once per golden. A hang there is the
// runner's problem, not the page's: measured on run 44901392026 (a docs-only PR)
//   FAIL 75/76 — tui-120x40.txt: spawnSync google-chrome ETIMEDOUT
// One retry covers it. The distinction that matters is that a *finding* is never
// retried and never reported as infrastructure — only the reverse mistake, a
// hanging browser read as a golden mismatch, is worth fixing here.

export class InfraFault extends Error {
  constructor(cause) {
    super(`browser infrastructure fault after 2 attempts: ${cause && cause.message ? cause.message : cause}`);
    this.name = 'InfraFault';
    this.cause = cause;
  }
}

// Anything the runner produces: the process was killed, or it outran the budget.
// A golden mismatch is a normal Error thrown by the comparison and matches none.
export function isInfraFault(err) {
  if (!err) return false;
  if (err.signal) return true;                       // SIGTERM from execFileSync's timeout
  if (err.code === 'ETIMEDOUT') return true;
  if (err.code === 'ENOENT') return true;            // browser binary vanished
  return /ETIMEDOUT|timed out|spawnSync .* ENOENT/.test(String(err.message));
}

// Two attempts total: the fault is transient or it is not. More attempts buy
// nothing and double the cost of a genuinely broken runner.
export function withRetry(fn, { attempts = 2 } = {}) {
  let last;
  for (let i = 0; i < attempts; i += 1) {
    try {
      return fn();
    } catch (err) {
      if (!isInfraFault(err)) throw err;             // a finding is never retried
      last = err;
    }
  }
  throw new InfraFault(last);
}
