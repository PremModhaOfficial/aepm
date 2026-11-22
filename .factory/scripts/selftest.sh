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

head1 "1. deterministic gate can fail (self-test)"
bash "$FACTORY/gates/gate.sh" --self-test || bad "gate self-test"

head1 "2. intake: sender check, duplicate, injection"
bash "$FACTORY/scripts/event.sh" --self-test || bad "event self-test"

head1 "3. router-guard blocks the Router and permits a worktree"
bash "$FACTORY/scripts/guard-self-test.sh" || bad "guard self-test"

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
# T-1 already carries task-bbb; a dispatch that is refused changes nothing, so
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

echo
if [ "$FAILED" = 0 ]; then echo "factory self-test: all drills hold"; else echo "factory self-test: $FAILED drill(s) FAILED"; fi
exit "$FAILED"
