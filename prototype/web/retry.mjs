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
// A missing binary is deliberately not here: no second attempt will install one.
export function isInfraFault(err) {
  if (!err) return false;
  if (err.signal) return true;                       // SIGTERM from execFileSync's timeout
  if (err.code === 'ETIMEDOUT') return true;
  return /ETIMEDOUT|timed out/.test(String(err.message));
}

// Whether the browser never produced a DOM, which is a different question from
// whether the attempt is worth repeating. A missing binary is not retried and is
// still infra: no golden was compared, so exit 2 says that and exit 1 would say
// every golden is wrong. The syscall decides, because a `readFileSync` ENOENT is
// a missing fixture, which is a repo defect and must stay a finding.
export function isNoBrowser(err) {
  return err instanceof InfraFault              // the retry already wrapped it
    || isInfraFault(err)
    || (err?.code === 'ENOENT' && /^spawn/.test(String(err.syscall || '')));
}

// One line a runner's log can be read from: the fault, and which attempt it hit.
const why = (err) => (err && (err.code || err.signal))
  || String((err && err.message) || err).split('\n')[0];

// stderr, because a recovered retry must leave a trace: without it a runner that
// lost 30s to a hang reads exactly like a healthy one.
const note = (line) => process.stderr.write(`retry: ${line}\n`);

// Two attempts total: the fault is transient or it is not. More attempts buy
// nothing and double the cost of a genuinely broken runner.
export function withRetry(fn, { attempts = 2 } = {}) {
  let last;
  for (let i = 0; i < attempts; i += 1) {
    try {
      const out = fn();
      if (last) note(`attempt ${i + 1}/${attempts} succeeded, after attempt ${i} failed with ${why(last)}`);
      return out;
    } catch (err) {
      if (!isInfraFault(err)) throw err;             // a finding is never retried
      last = err;
      if (i + 1 < attempts) note(`attempt ${i + 1}/${attempts} failed with an infrastructure fault (${why(err)}); retrying`);
    }
  }
  throw new InfraFault(last);
}

// The verdict for one finished verify run. 2 means the browser never produced a
// DOM and nothing was judged; anything else that failed is a finding. The error
// type decides, never the message: a finding may quote the fault text.
export function report(failures, { pass, total }) {
  if (!failures.length) {
    return { code: 0, stream: 'log', text: `PASS ${pass}/${total}: every captured frame, key path and palette rule matches` };
  }
  const infra = failures.every((f) => isNoBrowser(f.err));
  const header = infra
    ? `INFRASTRUCTURE ${pass}/${total}: the browser never produced a DOM`
    : `FAIL ${pass}/${total}`;
  return {
    code: infra ? 2 : 1,
    stream: 'error',
    text: [header, ...failures.map((f) => ' - ' + f.msg)].join('\n'),
  };
}
