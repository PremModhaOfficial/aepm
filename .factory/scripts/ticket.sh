#!/usr/bin/env bash
# ticket.sh — the ticket file IS the state. No ticket, no work.
#
#   ticket.sh new <slug> --request <verbatim> --scope <p1,p2> --authority explicit|inferred [--issue N]
#   ticket.sh get <T-n> <key>
#   ticket.sh set <T-n> <key> <value>
#   ticket.sh stage <T-n> <stage>
#   ticket.sh dispatch <T-n> <role> <taskId>    refuses while another task is live
#   ticket.sh done <T-n> <taskId>
#   ticket.sh bump <T-n>                        attempts += 1
#   ticket.sh list | resume | next
set -euo pipefail
FACTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TICKETS="$FACTORY/tickets"
STATE="$FACTORY/state.md"
LEDGER="$FACTORY/ledger.jsonl"
mkdir -p "$TICKETS"
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

ledger() { # <ticket> <role> <event> <detail>
  jq -cn --arg ts "$(now)" --arg ticket "$1" --arg role "$2" --arg event "$3" \
    --arg detail "$4" \
    '{ts:$ts,ticket:$ticket,role:$role,event:$event,detail:$detail}' >>"$LEDGER"
}

frontmatter() { awk 'NR==1{next} /^---$/{exit} {print}' "$1"; }
fm_get() { frontmatter "$1" | sed -n "s/^$2: *//p" | head -1; }

# fm_set edits only the front matter, inserting the key before its closing ---
fm_set() {
  local f="$1" k="$2" v="$3" tmp
  tmp="$(mktemp)"
  awk -v k="$k" -v v="$v" '
    NR==1 { print; next }
    !inbody && /^---$/ { if (!found) print k": "v; inbody=1; print; next }
    !inbody && $0 ~ "^"k":" { print k": "v; found=1; next }
    !inbody { print; next }
    { print }
  ' "$f" >"$tmp"
  mv "$tmp" "$f"
}

next_action() {
  case "$1" in
    queued) echo "dispatch researcher: bash .factory/scripts/brief.sh <T> researcher" ;;
    researching) echo "await researcher, then write plan via planner (stage planning)" ;;
    planning) echo "await planner, then dispatch builder (isolation: worktree)" ;;
    building) echo "await builder, then re-run gates/gate.sh all --ticket <T> yourself" ;;
    verifying) echo "await verifier, then merged = gate+verifier+CI all green" ;;
    merging) echo "watch_pull_request on the head, merge --squash --match-head-commit" ;;
    post-merge-watch) echo "watch default-branch CI; red -> open a revert ticket" ;;
    blocked) echo "retries exhausted or scope refused: comment on the issue" ;;
    failed) echo "read the worker report; decide retry vs blocked" ;;
    paused) echo "mode paused: nothing runs until resume" ;;
    *) echo "inspect the ticket" ;;
  esac
}

write_state() {
  {
    echo "# .factory/state.md — rewritten by ticket.sh on every stage change."
    echo "# Read this first after a restart, crash or compaction. Files are truth."
    echo
    echo "mode: $(sed -n 's/^mode: *//p' "$FACTORY/config.yml" | head -1 | sed 's/ *#.*//')"
    echo "updated: $(now)"
    echo
    echo "| ticket | stage | issue | attempts | live task | next action |"
    echo "|---|---|---|---|---|---|"
    if compgen -G "$TICKETS/T-*.md" >/dev/null; then
      for t in $(ls "$TICKETS"/T-*.md | sort -V); do
        local st
        st=$(fm_get "$t" stage)
        [ "$st" = "done" ] && continue
        echo "| $(basename "$t" .md) | $st | $(fm_get "$t" gh_issue) | $(fm_get "$t" attempts) | $(fm_get "$t" live_task) | $(next_action "$st") |"
      done
    else
      echo "| (none) | - | - | - | - | file a ticket: ticket.sh new ... |"
    fi
  } >"$STATE"
}

cmd="${1:-}"
shift || true
case "$cmd" in
  new)
    slug="${1:?slug}"
    shift
    request="" scope="" authority="inferred" issue=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --request) request="$2"; shift 2 ;;
        --scope) scope="$2"; shift 2 ;;
        --authority) authority="$2"; shift 2 ;;
        --issue) issue="$2"; shift 2 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$request" ] || { echo "--request is required" >&2; exit 2; }
    last=0
    if compgen -G "$TICKETS/T-*.md" >/dev/null; then
      last=$(ls "$TICKETS"/T-*.md | sed 's/.*\/T-//; s/\.md$//' | sort -n | tail -1)
    fi
    id="T-$((last + 1))"
    file="$TICKETS/$id.md"
    {
      echo "---"
      echo "id: $id"
      echo "slug: $slug"
      echo "gh_issue: $issue"
      echo "original_request: $request"
      echo "scope: $scope"
      echo "authority: $authority"
      echo "stage: queued"
      echo "task_ids:"
      echo "live_task:"
      echo "worktree:"
      echo "attempts: 0"
      echo "research_refs:"
      echo "verdict:"
      echo "created: $(now)"
      echo "---"
      echo
      echo "# $id — $slug"
      echo
      echo "## Original request (verbatim, never rewritten)"
      echo
      echo "> $request"
      echo
      echo "## Scope (the mandate)"
      echo
      echo "Allowed: ${scope:-none declared}. Anything outside it is refused by the gate."
      echo
      echo "## Acceptance checks"
      echo
      echo "- [ ] gate exits 0: \`bash .factory/gates/gate.sh all --ticket $id\`"
      echo "- [ ] verifier: fresh-context verdict recorded below"
      echo "- [ ] required checks green on the PR head"
      echo
      echo "## Research"
      echo
      echo "## Plan"
      echo
      echo "## Reports"
      echo
      echo "## Injection log"
      echo
    } >"$file"
    ledger "$id" router ticket-created "authority=$authority scope=$scope issue=$issue"
    write_state
    echo "$file"
    ;;
  get) fm_get "$TICKETS/${1:?}.md" "${2:?}" ;;
  set)
    fm_set "$TICKETS/${1:?}.md" "${2:?}" "${3:-}"
    write_state
    ;;
  bump)
    t="$TICKETS/${1:?}.md"
    n=$(fm_get "$t" attempts)
    fm_set "$t" attempts "$(( ${n:-0} + 1 ))"
    ledger "$(basename "$t" .md)" router attempt-bumped "$(fm_get "$t" attempts)"
    write_state
    ;;
  stage)
    t="$TICKETS/${1:?}.md"
    fm_set "$t" stage "${2:?}"
    ledger "$(basename "$t" .md)" router stage-changed "${2:?}"
    write_state
    ;;
  dispatch)
    t="$TICKETS/${1:?}.md"
    role="${2:?}"
    tid="${3:?}"
    live="$(fm_get "$t" live_task)"
    if [ -n "$live" ]; then
      echo "REFUSED: $1 already has a live task ($live). task_status it first." >&2
      exit 1
    fi
    fm_set "$t" live_task "$role $tid"
    fm_set "$t" task_ids "$(fm_get "$t" task_ids)$role=$tid;"
    ledger "$(basename "$t" .md)" "$role" dispatched "$tid"
    write_state
    echo "dispatched $role taskId=$tid"
    ;;
  done)
    t="$TICKETS/${1:?}.md"
    tid="${2:?}"
    live="$(fm_get "$t" live_task)"
    case "$live" in
      *"$tid")
        fm_set "$t" live_task ""
        ledger "$(basename "$t" .md)" router task-finished "$tid"
        write_state
        ;;
      *)
        echo "no live task $tid on $1 (live: ${live:-none})" >&2
        exit 1
        ;;
    esac
    ;;
  list) ls "$TICKETS"/T-*.md 2>/dev/null | xargs -r -n1 basename | sed 's/\.md$//' ;;
  resume)
    echo "mode: $(sed -n 's/^mode: *//p' "$FACTORY/config.yml" | head -1 | sed 's/ *#.*//')"
    if compgen -G "$TICKETS/T-*.md" >/dev/null; then
      for t in $(ls "$TICKETS"/T-*.md | sort -V); do
        st=$(fm_get "$t" stage)
        [ "$st" = "done" ] && continue
        echo "$(basename "$t" .md) stage=$st issue=$(fm_get "$t" gh_issue) attempts=$(fm_get "$t" attempts)"
        echo "   next: $(next_action "$st")"
        live="$(fm_get "$t" live_task)"
        [ -n "$live" ] && echo "   live: $live (task_status before any re-dispatch)"
      done
    else
      echo "(no tickets)"
    fi
    ;;
  next)
    write_state
    cat "$STATE"
    ;;
  *)
    echo "usage: ticket.sh new|get|set|stage|dispatch|done|bump|list|resume|next" >&2
    exit 2
    ;;
esac
