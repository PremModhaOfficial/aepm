#!/usr/bin/env bash
# router-guard self-test: proves the guard blocks the Router and permits a
# worktree. Runs the real extension against a stub of the Pi imports, so it
# needs no Pi session.
#
#   bash .factory/scripts/guard-self-test.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/stub.ts" <<'EOF'
export type ExtensionAPI = any;
export const isToolCallEventType = (name: string, e: any) => e.toolName === name;
EOF
sed 's|"@earendil-works/pi-coding-agent"|"./stub.ts"|g' "$ROOT/.pi/extensions/router-guard.ts" >"$TMP/guard.ts"
sed 's|"@earendil-works/pi-coding-agent"|"./stub.ts"|g' "$ROOT/.pi/extensions/safety.ts" >"$TMP/safety.ts"

cat >"$TMP/t.mjs" <<'EOF'
import guard from "./guard.ts";
import safety from "./safety.ts";

const load = (ext) => { const h = {}; ext({ on: (n, f) => (h[n] = f), registerCommand: () => {} }); return h; };
const g = load(guard), s = load(safety);

const MAIN = process.argv[2];
const WT = process.argv[3];

const both = async (toolName, input, cwd) => {
  for (const h of [g.tool_call, s.tool_call]) {
    const r = await h({ toolName, input }, { cwd, hasUI: false });
    if (r?.block) return r;
  }
  return undefined;
};

const CASES = [
  ["Router edits src/main.rs in the main checkout", "edit", { path: MAIN + "/src/main.rs" }, MAIN, true],
  ["Router writes docs/x.md in the main checkout", "write", { path: MAIN + "/docs/x.md" }, MAIN, true],
  ["Router runs git commit -am x in the checkout", "bash", { command: "git commit -am x" }, MAIN, true],
  ["Router moves a source file in the checkout", "bash", { command: "mv src/a.rs src/b.rs" }, MAIN, true],
  ["Router runs sudo in the checkout", "bash", { command: "sudo pacman -Syu" }, MAIN, true],
  ["Router force-pushes main", "bash", { command: "git push --force origin main" }, MAIN, true],
  ["Router merges with --admin", "bash", { command: "gh pr merge 12 --admin --squash" }, MAIN, true],
  ["Router edits .env", "edit", { path: MAIN + "/.env" }, MAIN, true],
  ["Router reads a file", "read", { path: MAIN + "/src/main.rs" }, MAIN, false],
  ["Router runs read-only git", "bash", { command: "git log --oneline -3" }, MAIN, false],
  ["Router runs the gate", "bash", { command: "bash .factory/gates/gate.sh fast --ticket T-1" }, MAIN, false],
  ["Router writes bookkeeping in .factory/", "write", { path: MAIN + "/.factory/state.md" }, MAIN, false],
  ["Builder edits in its own worktree", "edit", { path: WT + "/src/main.rs" }, WT, false],
  ["Builder runs the test suite in its worktree", "bash", { command: "cargo test --locked" }, WT, false],
  ["Builder commits in its worktree", "bash", { command: "git commit -m 'feat: x'" }, WT, false],
];

let bad = 0;
for (const [name, tool, input, cwd, shouldBlock] of CASES) {
  const r = await both(tool, input, cwd);
  const blocked = r?.block === true;
  const ok = blocked === shouldBlock;
  if (!ok) bad++;
  console.log(`${ok ? "ok  " : "FAIL"} - ${shouldBlock ? "blocked" : "allowed"}: ${name}${r?.reason ? `  [${r.reason.slice(0, 60)}]` : ""}`);
}
console.log(bad === 0 ? `guard self-test: ${CASES.length} assertions hold` : `guard self-test: ${bad} FAILED`);
process.exit(bad ? 1 : 0);
EOF

# A worktree is one where .git is a file. Make both shapes real, not assumed.
WT="$TMP/worktree"
mkdir -p "$WT"
printf 'gitdir: %s/.git/worktrees/x\n' "$ROOT" >"$WT/.git"

node "$TMP/t.mjs" "$ROOT" "$WT"
