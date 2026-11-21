#!/usr/bin/env bash
# F4: an open PR whose head conflicts with its base runs no workflow at all.
#
# GitHub builds a test merge into refs/pull/<n>/merge before it starts
# `pull_request` workflows. If that merge cannot be built the ref does not
# exist, no run is created, and every required status context stays absent —
# so the PR shows no red check, no green check, and cannot be merged. Measured
# on #147 (head 1f6d484): actions/runs for that branch returned total_count 0
# while the same head rebased onto main started CI, Sim and Review.
#
# That state is invisible in the UI: a "waiting for status" PR and a broken one
# look identical. This turns it into a named failure.
#
# Usage:
#   check-pr-conflicts.sh [--self-test]
#   gh api 'repos/O/R/pulls?state=open&per_page=100' | check-pr-conflicts.sh
#
# Exit 0: no open PR is conflicted. Exit 1: at least one is, listed.
# Exit 2: the input was not a PR array (never pass silently on unreadable input).
set -euo pipefail

list_conflicts() {
  # `mergeable` is null while GitHub computes it; only an explicit false means
  # "the merge is already known to be impossible".
  jq -r '.[] | select(.mergeable == false) | "#\(.number)  \(.head.ref)"'
}

self_test() {
  local ok=0 fail=0
  t() { # name, json, expected exit
    local name="$1" json="$2" want="$3" got=0
    printf '%s' "$json" | "$0" >/dev/null 2>&1 || got=$?
    if [ "$got" = "$want" ]; then ok=$((ok + 1)); printf 'ok   %s\n' "$name"
    else fail=$((fail + 1)); printf 'FAIL %s: exit %s, want %s\n' "$name" "$got" "$want" >&2; fi
  }
  t "a conflicted open PR is a failure" \
    '[{"number":147,"mergeable":false,"head":{"ref":"docs/ci-failure-inventory"}}]' 1
  t "a clean PR passes" \
    '[{"number":155,"mergeable":true,"head":{"ref":"docs/pr-triage"}}]' 0
  t "mergeable:null (not computed yet) is not a conflict" \
    '[{"number":156,"mergeable":null,"head":{"ref":"docs/prose-claim-rule"}}]' 0
  t "one conflict among many still fails" \
    '[{"number":1,"mergeable":true,"head":{"ref":"a"}},{"number":2,"mergeable":false,"head":{"ref":"b"}}]' 1
  t "no open PRs passes" '[]' 0
  t "unreadable input is exit 2, not a pass" 'not json' 2
  printf '\ncheck-pr-conflicts self-test: %d hold, %d failed\n' "$ok" "$fail"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--self-test" ]; then self_test; exit $?; fi

input=$(cat)
if ! printf '%s' "$input" | jq -e 'type == "array"' >/dev/null 2>&1; then
  echo "check-pr-conflicts: input is not a JSON array; refusing to report 'no conflicts'" >&2
  exit 2
fi

conflicts=$(printf '%s' "$input" | list_conflicts)
if [ -n "$conflicts" ]; then
  printf 'conflicted open PRs (no workflow can start, so required checks never appear):\n%s\n' "$conflicts" >&2
  exit 1
fi
echo "no conflicted open PRs"
