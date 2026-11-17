#!/usr/bin/env bash
# Fresh proof of state. Every line is measured at run time; nothing is cached
# and nothing is remembered. Run this before claiming anything about the repo.
#
#   scripts/proof.sh          # repo, PRs, CI, issues, plan
#   scripts/proof.sh --quiet  # counts only
#
# Exits 1 when a proof cannot be taken (gh offline, no origin) instead of
# printing a stale or empty success. That is the whole point.
set -uo pipefail

cd "$(dirname "$0")/.."
QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1
fail=0
say() { printf '%s\n' "$*"; }      # always: quiet mode only drops per-PR rows
detail() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

say "proof taken $(now)"

# --- git -------------------------------------------------------------------
branch=$(git rev-parse --abbrev-ref HEAD) || { echo "FAIL no git"; exit 1; }
head_sha=$(git rev-parse --short HEAD)
dirty=$(git status --porcelain | wc -l)
say "git: $branch @ $head_sha, $dirty dirty file(s)"

if git rev-parse --verify -q origin/main >/dev/null; then
  git fetch -q origin main 2>/dev/null || true
  ahead=$(git rev-list --count origin/main..HEAD)
  behind=$(git rev-list --count HEAD..origin/main)
  detail "vs origin/main: $ahead ahead, $behind behind ($(git rev-parse --short origin/main))"
else
  detail "vs origin/main: no remote ref"
  fail=1
fi

# --- pull requests and their checks (live) ---------------------------------
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  prs=$(gh pr list --json number --jq 'length' 2>/dev/null) || { say "prs: gh query failed"; fail=1; prs=0; }
  say "prs open: ${prs:-0}"
  for n in $(gh pr list --json number --jq '.[].number' 2>/dev/null); do
    row=$(gh pr view "$n" --json number,title,mergeable,statusCheckRollup \
      --jq '"#" + (.number|tostring) + " " + (.mergeable // "?") + " " +
            ((.statusCheckRollup // []) | group_by(.conclusion // .state // "PENDING")
             | map((.[0].conclusion // .[0].state // "PENDING") + ":" + (length|tostring))
             | join(","))' 2>/dev/null)
    detail "  ${row:-#$n checks unreadable}"
  done
  say "issues open: $(gh issue list --state open --json number --jq 'length' 2>/dev/null || echo 0)"
else
  say "prs: gh unavailable or unauthenticated"
  fail=1
fi

# --- plan ------------------------------------------------------------------
# Measured on origin/main, not the working tree: a checkout 28 commits behind
# reported 95/117 while main was at 114/128, which is a stale proof.
plan_src=$(git rev-parse --verify -q origin/main >/dev/null && echo origin/main || echo HEAD)
if git show "$plan_src:NEXT.md" >/tmp/proof-next.md 2>/dev/null; then
  done_n=$(grep -c '^- \[x\]' /tmp/proof-next.md)
  open_n=$(grep -c '^- \[ \]' /tmp/proof-next.md)
  total=$((done_n + open_n))
  pct=$(( total ? done_n * 100 / total : 0 ))
  say "plan: $done_n/$total done (${pct}%), $open_n left [$plan_src]"
else
  say "plan: NEXT.md missing"
  fail=1
fi

# --- build proof age -------------------------------------------------------
# A green claim needs an artifact produced after the current HEAD. Name the
# newest evidence file and how old it is, so a stale log cannot pass as proof.
newest=$(ls -t /tmp/*ci*.log /tmp/*sim*.log /tmp/*test*.log /tmp/*clippy*.log 2>/dev/null | head -1)
if [ -n "$newest" ]; then
  age=$(( $(date +%s) - $(stat -c %Y "$newest") ))
  detail "newest evidence: $(basename "$newest"), ${age}s old"
else
  detail "newest evidence: none"
  fail=1
fi

[ "$fail" = 0 ] || { say "PROOF INCOMPLETE"; exit 1; }
say "PROOF COMPLETE"
