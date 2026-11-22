#!/usr/bin/env bash
# sweep.sh — the polling fallback. A webhook that never arrives is invisible to
# the factory, so every wake starts here: reconcile GitHub against the tickets.
#
#   sweep.sh            # human-readable reconcile
#   sweep.sh --json     # {open_issues, open_prs, untracked_issues, ...}
set -uo pipefail
FACTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNER="$(sed -n 's/^ *authorized_sender: *//p' "$FACTORY/config.yml" | head -1 | sed 's/[[:space:]]*#.*//; s/[[:space:]]*$//')"
REPO="$(sed -n 's/^repo: *//p' "$FACTORY/config.yml" | head -1 | sed 's/[[:space:]]*#.*//; s/[[:space:]]*$//')"
JSON=0; [ "${1:-}" = "--json" ] && JSON=1

tracked() { grep -h "^gh_issue: " "$FACTORY"/tickets/T-*.md 2>/dev/null | sed 's/^gh_issue: //' | grep -v '^$' | sort -u; }

issues="$(timeout 60 gh issue list --repo "$REPO" --state open --limit 100 --json number,title,labels \
  --jq '.[] | select((.labels|map(.name)|index("factory"))|not) | "\(.number)\t\(.title)"' 2>/dev/null || echo '__FETCH_FAILED__')"
prs="$(timeout 60 gh pr list --repo "$REPO" --state open --limit 100 --json number,title,headRefName,isDraft \
  --jq '.[] | "\(.number)\t\(.headRefName)\t\(.title)"' 2>/dev/null || echo '__FETCH_FAILED__')"

if [ "$issues" = "__FETCH_FAILED__" ] || [ "$prs" = "__FETCH_FAILED__" ]; then
  echo "sweep: gh read failed (offline or rate limited). Do not act on stale state." >&2
  exit 1   # fail loudly: a silent empty sweep looks like "nothing to do"
fi

known="$(tracked)"
new_issues=""
while IFS=$(printf '\t') read -r n t; do
  [ -n "$n" ] || continue
  printf '%s\n' "$known" | grep -qx "$n" || new_issues="${new_issues}#${n} ${t}"$'\n'
done <<<"$issues"

# Tickets whose issue was closed outside the factory are stale, not active.
stale=""
while IFS= read -r n; do
  [ -n "$n" ] && ! printf '%s\n' "$issues" | cut -f1 | grep -qx "$n" && stale="$stale $n"
done <<<"$known"

open_tickets="$(bash "$FACTORY/scripts/ticket.sh" resume 2>/dev/null | grep -c 'stage=' || true)"

if [ "$JSON" = 1 ]; then
  jq -cn --argjson oi "$(printf '%s\n' "$issues" | grep -c . )" \
    --argjson pr "$(printf '%s\n' "$prs" | grep -c .)" \
    --arg new "$(printf '%s' "$new_issues" | tr '\n' ' ')" --arg stale "$stale" --argjson tickets "${open_tickets:-0}" \
    '{open_issues:$oi,open_prs:$pr,untracked_issues:$new,tickets_without_open_issue:$stale,active_tickets:$tickets}'
  exit 0
fi

echo "sweep: $(date -u +%Y-%m-%dT%H:%M:%SZ)  repo=$REPO owner=$OWNER"
echo "  open issues (no factory label): $(printf '%s\n' "$issues" | grep -c .)"
echo "  open PRs: $(printf '%s\n' "$prs" | grep -c .)"
echo "  active tickets: ${open_tickets:-0}"
if [ -n "$new_issues" ]; then
  echo "  UNTRACKED ISSUES (no ticket yet — file one):"
  printf '%s' "$new_issues" | sed 's/^/    /'
fi
[ -n "$stale" ] && echo "  tickets whose issue is closed:$stale"
echo "  open PRs (re-arm a watch for each):"
printf '%s\n' "$prs" | sed 's/^/    PR #/'
