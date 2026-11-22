#!/usr/bin/env bash
# sweep.sh — the polling fallback. A webhook that never arrives is invisible to
# the factory, so every wake starts here: reconcile GitHub against the tickets.
#
#   sweep.sh            # human-readable reconcile
#   sweep.sh --json     # {open_issues, open_prs, untracked_issues, ...}
set -uo pipefail
FACTORY="${SWEEP_FACTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OWNER="$(sed -n 's/^ *authorized_sender: *//p' "$FACTORY/config.yml" | head -1 | sed 's/[[:space:]]*#.*//; s/[[:space:]]*$//')"
REPO="$(sed -n 's/^repo: *//p' "$FACTORY/config.yml" | head -1 | sed 's/[[:space:]]*#.*//; s/[[:space:]]*$//')"
JSON=0; [ "${1:-}" = "--json" ] && JSON=1

tracked() { # the front matter only: a `gh_issue:` line a comment appends is not a link
  local t
  for t in "$FACTORY"/tickets/T-*.md; do
    [ -f "$t" ] || continue
    awk 'NR==1{next} /^---$/{exit} /^gh_issue: /{sub(/^gh_issue: /,""); print}' "$t"
  done | grep -v '^$' | sort -u || true
}

# Does not run against the live repo: it builds a throwaway factory and a stub gh.
if [ "${1:-}" = "--self-test" ]; then
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/factory"/{tickets,gates,scripts} "$tmp/bin"
  cp "$FACTORY/config.yml" "$tmp/factory/config.yml"
  cp "$FACTORY/scripts/ticket.sh" "$tmp/factory/scripts/ticket.sh"
  chmod +x "$tmp/factory/scripts/ticket.sh"
  ASSERTIONS="$tmp/assertions"; : >"$ASSERTIONS"
  okd() { echo . >>"$ASSERTIONS"; echo "ok  - $1"; }
  sw() { PATH="$tmp/bin:$PATH" SWEEP_FACTORY="$tmp/factory" bash "${BASH_SOURCE[0]}" --json 2>&1; }

  # T-15 finding 10: the failure marker was a line of OUTPUT, so a gh that printed
  # a partial page and then failed counted its fields as two open issues. The read
  # now reports its own status; nothing it printed can be mistaken for data.
  printf '#!/bin/sh\ncase "$1 $2" in\n  "issue list") printf "61\\ta real title\\n"; exit 1 ;;\n  "pr list") printf "168\\tbranch\\ta PR\\n"; exit 0 ;;\nesac\nexit 1\n' >"$tmp/bin/gh"
  chmod +x "$tmp/bin/gh"
  out="$(sw)"; st=$?
  [ "$st" -ne 0 ] || { echo "self-test FAILED: a gh read that failed mid-stream was reported as success: $out" >&2; exit 1; }
  okd "a gh read that halves through fails the sweep"
  printf '%s' "$out" | grep -q '__FETCH_FAILED__' \
    && { echo "self-test FAILED: the failure marker reached the JSON as data: $out" >&2; exit 1; }
  okd "no failure marker reaches the JSON as an issue"

  # And the other direction: a read that completes is still counted, or the fix
  # above would pass by always failing.
  printf '#!/bin/sh\ncase "$1 $2" in\n  "issue list") printf "61\\ta real title\\n"; exit 0 ;;\n  "pr list") printf "168\\tbranch\\ta PR\\n"; exit 0 ;;\nesac\nexit 1\n' >"$tmp/bin/gh"
  out="$(sw)"; st=$?
  [ "$st" = 0 ] || { echo "self-test FAILED: a completed gh read failed the sweep (exit $st: $out)" >&2; exit 1; }
  printf '%s' "$out" | grep -q '"open_issues":1' \
    || { echo "self-test FAILED: a completed read was not counted: $out" >&2; exit 1; }
  okd "a completed read is still counted"

  # T-15 round 8, finding 3: the parse read the whole file, so a `gh_issue:` line
  # a comment appended counted as a tracked issue. Front matter only.
  printf -- '---\nid: T-1\ngh_issue: 61\nscope: src/\n---\n# T-1\n\ngh_issue: 62\n' >"$tmp/factory/tickets/T-1.md"
  printf '#!/bin/sh\ncase "$1 $2" in\n  "issue list") printf "62\\tanother title\\n"; exit 0 ;;\n  "pr list") printf "168\\tbranch\\ta PR\\n"; exit 0 ;;\nesac\nexit 1\n' >"$tmp/bin/gh"
  chmod +x "$tmp/bin/gh"
  out="$(sw)"; st=$?
  [ "$st" = 0 ] || { echo "self-test FAILED: a completed gh read failed the sweep (exit $st: $out)" >&2; exit 1; }
  printf '%s' "$out" | grep -q '#62 another title' \
    || { echo "self-test FAILED: a gh_issue: line outside the front matter counted as tracked: $out" >&2; exit 1; }
  okd "a gh_issue: line outside the front matter is not a tracked issue"

  # T-15 round 8, finding 4: an empty listing is not evidence of a closed issue.
  printf '#!/bin/sh\ncase "$1 $2" in\n  "issue list") exit 0 ;;\n  "pr list") printf "168\\tbranch\\ta PR\\n"; exit 0 ;;\nesac\nexit 1\n' >"$tmp/bin/gh"
  chmod +x "$tmp/bin/gh"
  out="$(sw)"; st=$?
  [ "$st" = 0 ] || { echo "self-test FAILED: a successful empty read failed the sweep (exit $st: $out)" >&2; exit 1; }
  printf '%s' "$out" | grep -q '"ticket_issue_state":"unknown"' \
    || { echo "self-test FAILED: an empty listing was reported as a known stale list: $out" >&2; exit 1; }
  printf '%s' "$out" | grep -q '"tickets_without_open_issue":" 61"' \
    && { echo "self-test FAILED: an empty listing marked a tracked issue stale: $out" >&2; exit 1; }
  okd "an empty gh listing is unknown, never stale"

  # Other direction: a listing that did return rows still decides staleness.
  printf '#!/bin/sh\ncase "$1 $2" in\n  "issue list") printf "63\\tstill open\\n"; exit 0 ;;\n  "pr list") exit 0 ;;\nesac\nexit 1\n' >"$tmp/bin/gh"
  chmod +x "$tmp/bin/gh"
  out="$(sw)"; st=$?
  [ "$st" = 0 ] || { echo "self-test FAILED: a completed read failed the sweep (exit $st: $out)" >&2; exit 1; }
  printf '%s' "$out" | grep -q '"ticket_issue_state":"known"' \
    || { echo "self-test FAILED: a listing that returned rows was reported as unknown: $out" >&2; exit 1; }
  printf '%s' "$out" | grep -q '"tickets_without_open_issue":" 61"' \
    || { echo "self-test FAILED: an issue absent from a completed listing was not reported stale: $out" >&2; exit 1; }
  okd "a completed listing still reports a closed issue as stale"
  echo "sweep self-test: $(wc -l <"$ASSERTIONS" | tr -d ' ') assertions hold"
  exit 0
fi

# A failed read is its own thing, not a line of the answer: the old shape echoed
# `__FETCH_FAILED__` into the output and compared that, so a gh that printed a
# partial page and then failed counted the marker AND its partial page as issues.
issues="$(timeout 60 gh issue list --repo "$REPO" --state open --limit 100 --json number,title,labels \
  --jq '.[] | select((.labels|map(.name)|index("factory"))|not) | "\(.number)\t\(.title)"' 2>/dev/null)"; issues_rc=$?
prs="$(timeout 60 gh pr list --repo "$REPO" --state open --limit 100 --json number,title,headRefName,isDraft \
  --jq '.[] | "\(.number)\t\(.headRefName)\t\(.title)"' 2>/dev/null)"; prs_rc=$?

if [ "${issues_rc:-1}" != 0 ] || [ "${prs_rc:-1}" != 0 ]; then
  echo "sweep: gh read failed (offline or rate limited). Do not act on stale state." >&2
  exit 1   # fail loudly: a silent empty sweep looks like "nothing to do"
fi

known="$(tracked)"
new_issues=""
while IFS=$(printf '\t') read -r n t; do
  [ -n "$n" ] || continue
  printf '%s\n' "$known" | grep -qx "$n" || new_issues="${new_issues}#${n} ${t}"$'\n'
done <<<"$issues"

# Tickets whose issue was closed outside the factory are stale. An empty listing
# is not evidence of that: no rows is reported as unknown, never as stale (R8, #4).
stale=""; stale_state="known"
if [ -z "$(printf '%s' "$issues" | tr -d '[:space:]')" ]; then
  stale_state="unknown"
else
  while IFS= read -r n; do
    [ -n "$n" ] && ! printf '%s\n' "$issues" | cut -f1 | grep -qx "$n" && stale="$stale $n"
  done <<<"$known"
fi

open_tickets="$(bash "$FACTORY/scripts/ticket.sh" resume 2>/dev/null | grep -c 'stage=' || true)"

if [ "$JSON" = 1 ]; then
  jq -cn --argjson oi "$(printf '%s\n' "$issues" | grep -c . )" \
    --argjson pr "$(printf '%s\n' "$prs" | grep -c .)" \
    --arg new "$(printf '%s' "$new_issues" | tr '\n' ' ')" --arg stale "$stale" --arg state "$stale_state" --argjson tickets "${open_tickets:-0}" \
    '{open_issues:$oi,open_prs:$pr,untracked_issues:$new,tickets_without_open_issue:$stale,ticket_issue_state:$state,active_tickets:$tickets}'
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
[ "$stale_state" = unknown ] && echo "  tickets whose issue is closed: unknown (gh issue list returned no rows)"
echo "  open PRs (re-arm a watch for each):"
printf '%s\n' "$prs" | sed 's/^/    PR #/'
