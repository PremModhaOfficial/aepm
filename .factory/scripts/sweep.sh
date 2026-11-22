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
  printf '#!/bin/sh\ncase "$1 $2" in\n  "issue list") printf "61\\topen\\ta real title\\n"; exit 1 ;;\n  "pr list") printf "168\\tbranch\\ta PR\\n"; exit 0 ;;\nesac\nexit 1\n' >"$tmp/bin/gh"
  chmod +x "$tmp/bin/gh"
  out="$(sw)"; st=$?
  [ "$st" -ne 0 ] || { echo "self-test FAILED: a gh read that failed mid-stream was reported as success: $out" >&2; exit 1; }
  okd "a gh read that halves through fails the sweep"
  printf '%s' "$out" | grep -q '__FETCH_FAILED__' \
    && { echo "self-test FAILED: the failure marker reached the JSON as data: $out" >&2; exit 1; }
  okd "no failure marker reaches the JSON as an issue"

  # And the other direction: a read that completes is still counted, or the fix
  # above would pass by always failing.
  printf '#!/bin/sh\ncase "$1 $2" in\n  "issue list") printf "61\\topen\\ta real title\\n"; exit 0 ;;\n  "pr list") printf "168\\tbranch\\ta PR\\n"; exit 0 ;;\nesac\nexit 1\n' >"$tmp/bin/gh"
  out="$(sw)"; st=$?
  [ "$st" = 0 ] || { echo "self-test FAILED: a completed gh read failed the sweep (exit $st: $out)" >&2; exit 1; }
  printf '%s' "$out" | grep -q '"open_issues":1' \
    || { echo "self-test FAILED: a completed read was not counted: $out" >&2; exit 1; }
  printf '%s' "$out" | grep -q '"active_tickets":0' || { echo "self-test FAILED: a completed ticket read with no tickets was not a known zero: $out" >&2; exit 1; }
  okd "a completed read is still counted"

  # T-15 round 8, finding 3: the parse read the whole file, so a `gh_issue:` line
  # a comment appended counted as a tracked issue. Front matter only.
  printf -- '---\nid: T-1\ngh_issue: 61\nscope: src/\n---\n# T-1\n\ngh_issue: 62\n' >"$tmp/factory/tickets/T-1.md"
  printf '#!/bin/sh\ncase "$1 $2" in\n  "issue list") printf "62\\topen\\tanother title\\n"; exit 0 ;;\n  "pr list") printf "168\\tbranch\\ta PR\\n"; exit 0 ;;\nesac\nexit 1\n' >"$tmp/bin/gh"
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
  printf '#!/bin/sh\ncase "$1 $2" in\n  "issue list") printf "63\\topen\\tstill open\\n"; exit 0 ;;\n  "pr list") exit 0 ;;\nesac\nexit 1\n' >"$tmp/bin/gh"
  chmod +x "$tmp/bin/gh"
  out="$(sw)"; st=$?
  [ "$st" = 0 ] || { echo "self-test FAILED: a completed read failed the sweep (exit $st: $out)" >&2; exit 1; }
  printf '%s' "$out" | grep -q '"ticket_issue_state":"known"' \
    || { echo "self-test FAILED: a listing that returned rows was reported as unknown: $out" >&2; exit 1; }
  printf '%s' "$out" | grep -q '"tickets_without_open_issue":" 61"' \
    || { echo "self-test FAILED: an issue absent from a completed listing was not reported stale: $out" >&2; exit 1; }
  okd "a completed listing still reports a closed issue as stale"

  # T-15 R9, 593ff9ea6ce5: staleness was computed from the list with
  # `factory`-labelled issues filtered out, so a ticket whose issue is open and
  # carries the factory's own marker was reported stale. It is open, so it is not.
  # The second row keeps the filtered list non-empty, so the drill fails if the
  # comparison goes back to that list rather than to an empty read.
  printf '#!/bin/sh\ncase "$1 $2" in\n  "issue list") printf "61\\tfactory\\ta factory marker\\n62\\topen\\tstill open\\n"; exit 0 ;;\n  "pr list") exit 0 ;;\nesac\nexit 1\n' >"$tmp/bin/gh"
  chmod +x "$tmp/bin/gh"
  out="$(sw)"; st=$?
  [ "$st" = 0 ] || { echo "self-test FAILED: a completed read failed the sweep (exit $st: $out)" >&2; exit 1; }
  printf '%s' "$out" | grep -q '"tickets_without_open_issue":""' \
    || { echo "self-test FAILED: an open factory-labelled issue was reported stale: $out" >&2; exit 1; }
  printf '%s' "$out" | grep -q '"open_issues":1' \
    || { echo "self-test FAILED: a factory-labelled issue was counted as work: $out" >&2; exit 1; }
  okd "an open factory-labelled issue is tracked, not stale, and not new work"

  # T-15 R10: an issue carrying a tracked ticket's number is not untracked, and
  # with no ticket file at all there is no baseline — so the list is UNKNOWN, not
  # every open issue. A clone or worktree has no tickets/ (it is gitignored), and
  # calling #29 new there is the false alarm the wake acted on.
  printf '#!/bin/sh\ncase "$1 $2" in\n  "issue list") printf "61\\topen\\tthe tracked one\\n62\\topen\\tthe unknown one\\n"; exit 0 ;;\n  "pr list") exit 0 ;;\nesac\nexit 1\n' >"$tmp/bin/gh"
  chmod +x "$tmp/bin/gh"
  out="$(sw)"; st=$?
  [ "$st" = 0 ] || { echo "self-test FAILED: a completed read failed the sweep (exit $st: $out)" >&2; exit 1; }
  printf '%s' "$out" | grep -q '"untracked_issues":"#61 ' \
    && { echo "self-test FAILED: an issue carrying a tracked ticket's number was reported untracked: $out" >&2; exit 1; }
  printf '%s' "$out" | grep -q '"untracked_issue_state":"known"' \
    || { echo "self-test FAILED: a tracked issue set was not reported as a known baseline: $out" >&2; exit 1; }
  printf -- '---\nid: T-9\ngh_issue: \nscope: src/\n---\n# T-9\n' >"$tmp/factory/tickets/T-1.md"
  out="$(sw)"; st=$?
  printf '%s' "$out" | grep -q '"untracked_issue_state":"unknown"' \
    || { echo "self-test FAILED: with no ticket to compare against, every open issue was called untracked: $out" >&2; exit 1; }
  printf '%s' "$out" | grep -q '"untracked_issues":"#61 ' \
    && { echo "self-test FAILED: a ticketless checkout invented untracked issues: $out" >&2; exit 1; }
  okd "a tracked issue is not untracked, and no ticket at all is unknown, never a list"
  # T-15 R18, r4658452352: `| grep -c … || true` printed 0 when the ticket read failed, so a broken store read as "no ticket is working"; the counted zero above is the other direction.
  printf '#!/bin/sh\nprintf "T-1 stage=building\\n"; exit 1\n' >"$tmp/factory/scripts/ticket.sh"; chmod +x "$tmp/factory/scripts/ticket.sh"
  out="$(sw)"; cp "$FACTORY/scripts/ticket.sh" "$tmp/factory/scripts/ticket.sh"; chmod +x "$tmp/factory/scripts/ticket.sh"
  printf '%s' "$out" | grep -q '"active_tickets":null,"active_ticket_state":"unknown"' || { echo "self-test FAILED: a failed ticket read was reported as a count: $out" >&2; exit 1; }
  okd "a failed ticket read is unknown, never zero active tickets"
  echo "sweep self-test: $(wc -l <"$ASSERTIONS" | tr -d ' ') assertions hold"
  exit 0
fi

# A failed read is its own thing, not a line of the answer: the old shape echoed
# `__FETCH_FAILED__` into the output and compared that, so a gh that printed a
# partial page and then failed counted the marker AND its partial page as issues.
# Row shape: number<TAB>open|factory<TAB>title. `factory`-labelled issues are the
# factory's own markers, not work, so they are excluded from "untracked" — but
# they are still OPEN, so a ticket whose issue carries that label is not stale
# (T-15 R9, 593ff9ea6ce5: staleness was computed from the filtered list).
rows="$(timeout 60 gh issue list --repo "$REPO" --state open --limit 100 --json number,title,labels \
  --jq '.[] | "\(.number)\t\(if (.labels|map(.name)|index("factory")) then "factory" else "open" end)\t\(.title)"' 2>/dev/null)"; issues_rc=$?
prs="$(timeout 60 gh pr list --repo "$REPO" --state open --limit 100 --json number,title,headRefName,isDraft \
  --jq '.[] | "\(.number)\t\(.headRefName)\t\(.title)"' 2>/dev/null)"; prs_rc=$?

if [ "${issues_rc:-1}" != 0 ] || [ "${prs_rc:-1}" != 0 ]; then
  echo "sweep: gh read failed (offline or rate limited). Do not act on stale state." >&2
  exit 1   # fail loudly: a silent empty sweep looks like "nothing to do"
fi

issues="$(printf '%s\n' "$rows" | awk -F'\t' '$2=="open"{printf "%s\t%s\n", $1, $3}')"
open_numbers="$(printf '%s\n' "$rows" | awk -F'\t' 'NF{print $1}')"

known="$(tracked)"
new_issues=""
# The tickets' `gh_issue:` front matter IS the tracked set, so a `factory` label
# is not what decides this: that label is event.sh's self-event guard, and no
# issue in this repo carries it. What can be wrong is the baseline — a checkout
# with no ticket file (tickets/ is gitignored) would call EVERY open issue new.
untracked_state="known"
if [ -z "$(printf '%s' "$known" | tr -d '[:space:]')" ]; then
  [ -z "$(printf '%s' "$issues" | tr -d '[:space:]')" ] || untracked_state="unknown"
else
  while IFS=$(printf '\t') read -r n t; do
    [ -n "$n" ] || continue
    printf '%s\n' "$known" | grep -qx "$n" || new_issues="${new_issues}#${n} ${t}"$'\n'
  done <<<"$issues"
fi

# Tickets whose issue was closed outside the factory are stale. An empty listing
# is not evidence of that: no rows is reported as unknown, never as stale (R8, #4).
# Staleness is decided against EVERY open issue number, factory-labelled included.
stale=""; stale_state="known"
if [ -z "$(printf '%s' "$open_numbers" | tr -d '[:space:]')" ]; then
  stale_state="unknown"
else
  while IFS= read -r n; do
    [ -n "$n" ] && ! printf '%s\n' "$open_numbers" | grep -qx "$n" && stale="$stale $n"
  done <<<"$known"
fi

# A failed read is "unknown", never a count of zero active tickets (T-15 R18, r4658452352).
resume="$(bash "$FACTORY/scripts/ticket.sh" resume 2>/dev/null)"; resume_rc=$?
open_tickets=""; [ "${resume_rc:-1}" = 0 ] && open_tickets="$(printf '%s\n' "$resume" | grep -c 'stage=' || true)"

if [ "$JSON" = 1 ]; then
  jq -cn --argjson oi "$(printf '%s\n' "$issues" | grep -c . )" \
    --argjson pr "$(printf '%s\n' "$prs" | grep -c .)" \
    --arg new "$(printf '%s' "$new_issues" | tr '\n' ' ')" --arg ustate "$untracked_state" \
    --arg stale "$stale" --arg state "$stale_state" --argjson tickets "${open_tickets:-null}" \
    '{open_issues:$oi,open_prs:$pr,untracked_issues:$new,untracked_issue_state:$ustate,tickets_without_open_issue:$stale,ticket_issue_state:$state,active_tickets:$tickets,active_ticket_state:(if $tickets == null then "unknown" else "known" end)}'
  exit 0
fi

echo "sweep: $(date -u +%Y-%m-%dT%H:%M:%SZ)  repo=$REPO owner=$OWNER"
echo "  open issues (no factory label): $(printf '%s\n' "$issues" | grep -c .)"
echo "  open PRs: $(printf '%s\n' "$prs" | grep -c .)"
echo "  active tickets: ${open_tickets:-unknown}"
if [ -n "$new_issues" ]; then
  echo "  UNTRACKED ISSUES (no ticket yet — file one):"
  printf '%s' "$new_issues" | sed 's/^/    /'
fi
[ "$untracked_state" = unknown ] && echo "  untracked issues: unknown (no ticket to compare against)"
[ -n "$stale" ] && echo "  tickets whose issue is closed:$stale"
[ "$stale_state" = unknown ] && echo "  tickets whose issue is closed: unknown (gh issue list returned no rows)"
echo "  open PRs (re-arm a watch for each):"
printf '%s\n' "$prs" | sed 's/^/    PR #/'
