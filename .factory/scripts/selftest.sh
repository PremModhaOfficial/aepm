#!/usr/bin/env bash
# selftest.sh — the drills from the definition of done, as one command.
#
#   bash .factory/scripts/selftest.sh
#
# Each drill proves a failure mode is handled, not that a paragraph exists.
set -uo pipefail
FACTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$FACTORY/.." && pwd)"
FAILED=0
ok()   { echo "ok   - $1"; }
bad()  { echo "FAIL - $1"; FAILED=$((FAILED + 1)); }
head1() { echo; echo "== $1 =="; }
skipped_drills() { case "$1" in *"skipped the unreadable-file drills as root"*) return 0 ;; esac; return 1; }

head1 "1. deterministic gate can fail (self-test)"
out="$(bash "$FACTORY/gates/gate.sh" --self-test 2>&1)"; st=$?
printf '%s\n' "$out"
if [ "$st" != 0 ]; then bad "gate self-test (exit $st)"
elif skipped_drills "$out"; then
  bad "gate self-test skipped the unreadable-file drills (re-run unprivileged, or fix gate.sh: T-15)"
else ok "the gate self-test ran every drill"
fi
# The detector is the fix, so drill it on both answers: a root run must not read as
# a pass, a clean run must not read as a skip. Matches gate.sh:700's wording.
# shortcut: the match is gate.sh's root-skip sentence; when T-15 fixes that skip this
# goes quiet (the drill still passes) and §1 returns to a plain exit check.
skipped_drills "gate self-test: skipped the unreadable-file drills as root (root reads chmod 000)" \
  && ok "a skipped gate self-test is refused, not reported as ok" \
  || bad "the root-skip line was not recognised"
skipped_drills "ok  - the gate can fail" \
  && bad "a clean gate self-test was read as a skip" \
  || ok "a clean gate self-test is a pass"

head1 "2. intake: sender check, duplicate, injection"
bash "$FACTORY/scripts/event.sh" --self-test || bad "event self-test"

head1 "3. router-guard blocks the Router and permits a worktree"
bash "$FACTORY/scripts/guard-self-test.sh" || bad "guard self-test"

head1 "3b. safety blocks every .env-prefixed name through a shell write"
D="$(mktemp -d)"
printf 'export type ExtensionAPI = any;\nexport const isToolCallEventType = (n: string, e: any) => e.toolName === n;\n' >"$D/stub.ts"
sed 's|"@earendil-works/pi-coding-agent"|"./stub.ts"|g' "$ROOT/.pi/extensions/safety.ts" >"$D/safety.ts"
cat >"$D/t.mjs" <<'EOF'
import safety from "./safety.ts";
const load = (ext) => { const h = {}; ext({ on: (n, f) => (h[n] = f), registerCommand: () => {} }); return h; };
const s = load(safety);
// [label, tool, input, blocked?] — the review on 0b2018e found the first six ALLOW:
// the name was matched with a trailing word boundary, and `.envrc` has none between
// `v` and `r`, so a direnv file that exports every secret was writable. The last two
// are the other direction: a prefix match must not swallow an unrelated redirect.
const CASES = [
  ["shell redirect into .envrc", "bash", { command: "echo SECRET=leaked > .envrc" }, true],
  ["shell append into .envrc", "bash", { command: "echo A=1 >> .envrc" }, true],
  ["cp over .envrc", "bash", { command: "cp a .envrc" }, true],
  ["shell redirect into .env.prefixed", "bash", { command: "echo x > .env.prefixed" }, true],
  ["shell redirect into .env", "bash", { command: "echo SECRET=leaked > .env" }, true],
  ["edit of .envrc (the PROTECTED list is a substring test, so it holds)", "edit", { path: "/repo/.envrc" }, true],
  ["shell redirect into notes.txt", "bash", { command: "echo hi > notes.txt" }, false],
  ["shell redirect into src/env.rs", "bash", { command: "echo hi > src/env.rs" }, false],
];
let bad = 0;
for (const [label, tool, input, shouldBlock] of CASES) {
  const r = await s.tool_call({ toolName: tool, input }, { cwd: "/repo", hasUI: false });
  const ok = (r?.block === true) === shouldBlock;
  if (!ok) bad++;
  console.log(`${ok ? "ok  " : "FAIL"} - ${shouldBlock ? "blocked" : "allowed"}: ${label}`);
}
process.exit(bad ? 1 : 0);
EOF
node "$D/t.mjs" || bad "safety .env drill"
rm -rf "$D"

head1 "4. duplicate dispatch is refused (idempotency)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp -r "$FACTORY/scripts" "$FACTORY/config.yml" "$TMP/"
mkdir -p "$TMP/tickets" "$TMP/inbox" "$TMP/gates" "$TMP/roles"
chmod +x "$TMP/scripts/"*.sh
T="$(bash "$TMP/scripts/ticket.sh" new drill --request 'prove idempotency' --scope 'src/' --authority explicit)"
bash "$TMP/scripts/ticket.sh" dispatch T-1 builder task-aaa >/dev/null || bad "first dispatch refused"
out="$(bash "$TMP/scripts/ticket.sh" dispatch T-1 builder task-bbb 2>&1)"; st=$?
[ "$st" -ne 0 ] && ok "a second dispatch of the same ticket is refused" || bad "a second dispatch was accepted: $out"
bash "$TMP/scripts/ticket.sh" done T-1 task-aaa >/dev/null || bad "task completion not recorded"
bash "$TMP/scripts/ticket.sh" dispatch T-1 builder task-bbb >/dev/null \
  && ok "a dispatch after completion is allowed" || bad "a dispatch after completion was refused"
# `done` compared with a substring, so `task-1` cleared a live `task-10`.
bash "$TMP/scripts/ticket.sh" done T-1 task-bbb >/dev/null
bash "$TMP/scripts/ticket.sh" dispatch T-1 builder task-10 >/dev/null
out="$(bash "$TMP/scripts/ticket.sh" done T-1 task-1 2>&1)"; st=$?
[ "$st" -ne 0 ] && ok "done task-1 is refused while task-10 is live" || bad "done task-1 exited 0: $out"
[ "$(bash "$TMP/scripts/ticket.sh" get T-1 live_task)" = "builder task-10" ] \
  && ok "task-10 is still live after the refused done" || bad "a substring match cleared task-10"

head1 "4b. a ticket value survives a backslash"
# fm_set wrote the value through `awk -v`, which interprets escapes: `docs\path`
# came back as `docspath` and `T-\1` as a control byte. Through ENVIRON, verbatim.
bash "$TMP/scripts/ticket.sh" new backslash --request 'prove a value round-trips' --scope 'src/' --authority explicit >/dev/null
want='docs\path,T-\1'
bash "$TMP/scripts/ticket.sh" set T-2 scope "$want" >/dev/null
got="$(bash "$TMP/scripts/ticket.sh" get T-2 scope)"
[ "$got" = "$want" ] && ok "a scope value with a backslash round-trips verbatim" \
  || bad "fm_set mangled the value: want '$want' got '$got'"

head1 "5. restart resumes from files, not memory"
bash "$TMP/scripts/ticket.sh" stage T-1 building >/dev/null
grep -q "building" "$TMP/state.md" && ok "state.md carries the stage" || bad "state.md did not carry the stage"
resumed="$(bash "$TMP/scripts/ticket.sh" resume)"
printf '%s' "$resumed" | grep -q "T-1 stage=building" && ok "resume reads the stage back from disk" || bad "resume lost the stage: $resumed"
printf '%s' "$resumed" | grep -q "next: " && ok "resume names the next action" || bad "resume named no next action"

head1 "6. retries loop, then park blocked at retry.max_attempts"
bash "$TMP/scripts/ticket.sh" stage T-1 building >/dev/null
for i in 1 2; do bash "$TMP/scripts/ticket.sh" bump T-1 >/dev/null; done
[ "$(bash "$TMP/scripts/ticket.sh" get T-1 stage)" = "building" ] \
  && ok "attempts 2 = max 2 keeps the ticket going" || bad "the ticket parked at or below the limit"
bash "$TMP/scripts/ticket.sh" bump T-1 >/dev/null
[ "$(bash "$TMP/scripts/ticket.sh" get T-1 attempts)" = "3" ] \
  && ok "attempts counted: 3" || bad "attempts not counted"
[ "$(bash "$TMP/scripts/ticket.sh" get T-1 stage)" = "blocked" ] \
  && ok "bump 3 > retry.max_attempts 2 parks the ticket blocked" || bad "the ticket did not park blocked"
grep -q "blocked" "$TMP/state.md" && ok "state.md shows the blocked stage" || bad "state.md missed the park"

head1 "7. stop switch pauses and lists in-flight work"
cp "$FACTORY/config.yml" "$TMP/config.yml"
# T-1 already carries a live task; a dispatch that is refused changes nothing, so
# the live task is whatever the ticket recorded, not what the test wished for.
live="$(bash "$TMP/scripts/ticket.sh" get T-1 live_task | awk '{print $2}')"
[ -n "$live" ] && ok "ticket carries a live task ($live)" || bad "no live task recorded before the stop drill"
out="$(bash "$TMP/scripts/stop.sh" pause)"
printf '%s' "$out" | grep -q "mode: paused" && ok "stop sets mode: paused" || bad "stop did not pause: $out"
printf '%s' "$out" | grep -q "$live" && ok "stop lists the live task to cancel" || bad "stop listed no in-flight task: $out"
[ "$(bash "$TMP/scripts/stop.sh" status)" = "paused" ] && ok "status reports paused" || bad "status wrong"
bash "$TMP/scripts/stop.sh" resume >/dev/null
[ "$(bash "$TMP/scripts/stop.sh" status)" = "auto" ] && ok "resume restores auto" || bad "resume failed"

head1 "8. sweep fails loudly instead of reporting an empty success"
# A gh that always fails: the sweep must fail, not print an empty reconcile.
BIN="$TMP/bin"; mkdir -p "$BIN"
printf '#!/bin/sh\nexit 1\n' >"$BIN/gh"; chmod +x "$BIN/gh"
out="$(cd "$ROOT" && PATH="$BIN:$PATH" bash .factory/scripts/sweep.sh 2>&1)"; st=$?
[ "$st" -ne 0 ] && ok "an unreadable GitHub fails the sweep (exit $st)" || bad "the sweep reported success while offline: $out"
printf '%s' "$out" | grep -q "gh read failed" && ok "the sweep says why it failed" || bad "the sweep failed silently: $out"

head1 "9. sweep self-test: unknown-vs-zero and the failed ticket read"
# sweep.sh --self-test carries the drills for a gh read that halves through, an
# empty listing being unknown rather than stale, and front-matter-only tracking.
# Nothing ran them: section 8 above only proves the offline exit.
out="$(bash "$FACTORY/scripts/sweep.sh" --self-test 2>&1)"; st=$?
[ "$st" = 0 ] && ok "the sweep self-test passed" || bad "sweep self-test (exit $st): $out"
count="$(printf '%s\n' "$out" | sed -n 's/^sweep self-test: \([0-9][0-9]*\) assertions hold$/\1/p')"
[ -n "$count" ] && ok "the sweep self-test reported its assertion count ($count)" \
  || bad "the sweep self-test printed no assertion count: $out"
printf '%s\n' "$out" | grep -q "^ok  - an empty gh listing is unknown, never stale$" \
  && ok "the unknown-vs-zero drill ran" || bad "the unknown-vs-zero drill did not run: $out"
printf '%s\n' "$out" | grep -q "^ok  - a gh read that halves through fails the sweep$" \
  && ok "the failed-read drill ran" || bad "the failed-read drill did not run: $out"

head1 "10. the README documents the bound the gate enforces"
bound="$(sed -n 's/^SCAN_MAX_BYTES=\([0-9][0-9]*\)$/\1/p' "$FACTORY/gates/gate.sh")"
if [ -z "$bound" ]; then bad "gate.sh declares no SCAN_MAX_BYTES"
elif grep -qE "(^|[^0-9])$bound([^0-9]|$)" "$FACTORY/README.md"; then
  ok "the README names gate.sh's scan bound ($bound bytes)"
else bad "the README does not name gate.sh's scan bound ($bound bytes)"
fi
# GATE SKIP was removed at 61f249c. Documenting it, or omitting it while gate.sh
# prints it, is a false claim in one direction or the other. The match is the
# line's own shape (`GATE SKIP [<phase>]`), so prose saying there is none is not
# read as announcing one.
if grep -q 'GATE SKIP \[' "$FACTORY/gates/gate.sh"; then
  grep -q 'GATE SKIP \[' "$FACTORY/README.md" && ok "the README documents the gate's GATE SKIP line" \
    || bad "gate.sh prints GATE SKIP and the README does not document it"
else
  grep -q 'GATE SKIP \[' "$FACTORY/README.md" \
    && bad "the README documents a GATE SKIP line the gate no longer prints" \
    || ok "the README advertises no GATE SKIP line the gate does not print"
fi

echo
if [ "$FAILED" = 0 ]; then echo "factory self-test: all drills hold"; else echo "factory self-test: $FAILED drill(s) FAILED"; fi
exit "$FAILED"
