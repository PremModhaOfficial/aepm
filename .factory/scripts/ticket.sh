#!/usr/bin/env bash
# ticket.sh — the ticket file IS the state. No ticket, no work.
#
#   ticket.sh new <slug> --request <verbatim> --scope <p1,p2> --authority explicit|inferred [--issue N]
#   ticket.sh get <T-n> <key>
#   ticket.sh set <T-n> <key> <value>           e.g. `set T-1 pr 168`: the PR a ticket's branch opened
#                                              (event.sh matches a delivery's pull_request.number on it)
#   ticket.sh stage <T-n> <stage>
#   ticket.sh dispatch <T-n> <role> <taskId>    refuses while another task is live
#   ticket.sh done <T-n> <taskId>
#   ticket.sh bump <T-n>                        attempts += 1
#   ticket.sh list | resume | next
#   ticket.sh --self-test                       # prove the stage writer refuses what it cannot route
set -euo pipefail
FACTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TICKETS="$FACTORY/tickets"
STATE="$FACTORY/state.md"
LEDGER="$FACTORY/ledger.jsonl"
mkdir -p "$TICKETS"
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# The stages .factory/README.md:46-47 documents. config.yml carries no stage
# list, so this is the one copy: every writer of `stage:` is checked against it.
# `done` is here although next_action has no arm for it — it is the terminal
# state write_state and resume skip, so rejecting it would strand a ticket.
STAGES="queued researching planning building verifying merging post-merge-watch done blocked failed paused"

ledger() { # <ticket> <role> <event> <detail>
  jq -cn --arg ts "$(now)" --arg ticket "$1" --arg role "$2" --arg event "$3" \
    --arg detail "$4" \
    '{ts:$ts,ticket:$ticket,role:$role,event:$event,detail:$detail}' >>"$LEDGER"
}

# retry.max_attempts from the retry: section of config.yml, with its inline comment
# stripped. The limit lives here, in code, so a drill cannot supply it by hand.
retry_max() {
  awk '/^retry:/{f=1;next} f&&/^[^[:space:]]/{f=0} f' "$FACTORY/config.yml" \
    | sed -n 's/^ *max_attempts: *//p' | head -1 | sed 's/[[:space:]]*#.*//; s/[[:space:]]*$//'
}

frontmatter() { awk 'NR==1{next} /^---$/{exit} {print}' "$1"; }
fm_get() { frontmatter "$1" | sed -n "s/^$2: *//p" | head -1; }

# A value must never be able to shape the front matter it lands in: `---` closes
# it, `key:` sets a field, a newline starts one. Untrusted text (an issue body)
# is therefore written as an indented block scalar, and a single-line value is
# flattened and stripped to the field's own charset.
flatten() { printf '%s' "$1" | tr '\n\r' '  '; }
path_charset() { flatten "$1" | tr -cd 'A-Za-z0-9._/,-'; }
token_charset() { flatten "$1" | tr -cd 'A-Za-z0-9._-'; }
block_scalar() { # write stdin as an indented block scalar body
  sed 's/^/  /'
}

# fm_set edits only the front matter, inserting the key before its closing ---
fm_set() {
  local f="$1" k="$2" v="$3" tmp s valid
  v="$(flatten "$v")" # one line: a newline would start a front-matter field
  # A stage is one of the documented states; validate the flattened value, since
  # that is what lands. One stage at a time: a substring test over the whole list
  # accepted any contiguous run of ADJACENT names (`merging post-merge-watch`, or
  # the entire $STAGES), which lands a value next_action has no arm for — the
  # stuck ticket this check exists to prevent. Nothing is written or ledgered
  # before this point, so a refusal leaves the ticket byte-identical.
  if [ "$k" = stage ]; then
    valid=""
    for s in $STAGES; do # unquoted on purpose: one word per stage
      [ "$v" = "$s" ] || continue
      valid=1
    done
    [ -n "$valid" ] || { echo "unknown stage: $v — one of: $STAGES" >&2; exit 2; }
  fi
  tmp="$(mktemp)"
  # Through the environment, not `awk -v`: -v interprets backslash escapes, so a
  # value carrying a backslash (`docs\path`) came back as `docspath`.
  FM_K="$k" FM_V="$v" awk '
    BEGIN { k = ENVIRON["FM_K"]; v = ENVIRON["FM_V"] }
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
    building) echo "await builder, then re-run $FACTORY/gates/gate.sh all --sha <head> --ticket-file $FACTORY/tickets/<T>.md yourself" ;;
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
    request="" scope="" authority="inferred" issue="" base=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --request) request="$2"; shift 2 ;;
        --scope) scope="$2"; shift 2 ;;
        --authority) authority="$2"; shift 2 ;;
        --issue) issue="$2"; shift 2 ;;
        --base) base="$2"; shift 2 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$request" ] || { echo "--request is required" >&2; exit 2; }
    # The mandate is path prefixes and nothing else. `scope:` is what the gate
    # reads, so it accepts no `:`, no newline, no `---` — untrusted text cannot
    # reach it even by accident.
    scope="$(path_charset "$scope")"
    slug="$(token_charset "$slug")"
    issue="$(printf '%s' "$issue" | tr -cd '0-9')"
    # The base lands in the front matter and in an emitted command, so it is a
    # ref and nothing else: `A-Za-z0-9._/-` carries no shell metacharacter and no
    # whitespace, which is what router-guard refuses on shape.
    base="$(flatten "$base" | tr -cd 'A-Za-z0-9._/-')"
    case "$authority" in explicit|inferred) ;; *) echo "--authority explicit|inferred" >&2; exit 2 ;; esac
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
      # Untrusted text goes in as a block scalar: every line is indented, so no
      # line of it can start at column 0 and no `---` of it can close this block.
      echo "original_request: |"
      printf '%s\n' "$request" | block_scalar
      echo "scope: $scope"
      echo "authority: $authority"
      echo "base: ${base:-}"
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
      printf '%s\n' "$request" | sed 's/^/> /'
      echo
      echo "## Scope (the mandate)"
      echo
      echo "Allowed: ${scope:-none declared}. Anything outside it is refused by the gate."
      echo
      echo "## Acceptance checks"
      echo
      # A ticket is filed before its head exists, so the head stays a word the
      # runner substitutes. The pasted shape is the one router-guard allows: a
      # relative gate path, a literal base, no `$(` and no `$(git`.
      if [ -n "$base" ]; then
        echo "- [ ] gate exits 0 (substitute HEAD_SHA from \`git rev-parse HEAD\`): \`bash .factory/gates/gate.sh all --base $base --sha HEAD_SHA --ticket-file $FACTORY/tickets/$id.md\`"
      else
        # Loud, not a green line that judged nothing: with no base the gate falls
        # back to `merge-base HEAD origin/main`, which lists every other ticket's
        # files as outside this one's mandate, so the line would be unrunnable.
        echo "- [ ] gate: NOT EMITTED — no base recorded, so a pasted line would judge \`merge-base HEAD origin/main\`. Record it with \`bash .factory/scripts/ticket.sh set $id base <ref>\`, or pass \`--base <ref>\` to \`new\`."
      fi
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
    n=$(( ${n:-0} + 1 ))
    fm_set "$t" attempts "$n"
    ledger "$(basename "$t" .md)" router attempt-bumped "$n"
    # The retry limit is enforced here, not by whoever remembers to check it.
    # A count above retry.max_attempts parks the ticket; equal does not.
    max="$(retry_max)"; max="${max:-2}"
    if [ "$n" -gt "$max" ]; then fm_set "$t" stage blocked; fi
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
    # A worker's role file refuses anything outside the ticket's scope, so a ticket
    # with no scope is a mandate nobody can act inside — measured at c2aaf8d, where
    # dispatch printed `dispatched` for a `scope:` of nothing. Filing with an empty
    # scope stays legal (the planner fills it in); dispatching on one does not.
    scope="$(fm_get "$t" scope)"
    if [ -z "$scope" ]; then
      echo "REFUSED: $1 has no scope, so no worker could act inside it. Set the mandate: bash .factory/scripts/ticket.sh set $1 scope '<p1,p2>'" >&2
      exit 2
    fi
    live="$(fm_get "$t" live_task)"
    # `--stale <taskId>` is the caller's declaration about the recorded task. This
    # script reads no task state at all, so it cannot tell a live task from a dead
    # one and must not pretend to. The flag requires the recorded id exactly (the
    # last word, the same match `done` uses and for the same reason: a substring
    # test cleared task-10 for task-1) and records who replaced what before it
    # dispatches, so the ledger always says what was declared.
    stale=""
    if [ $# -gt 3 ]; then
      [ "$4" = --stale ] || { echo "unknown flag: $4" >&2; exit 2; }
      stale="${5:-}"
      [ -n "$stale" ] || { echo "--stale needs a taskId" >&2; exit 2; }
      [ $# -le 5 ] || { echo "unknown flag: $6" >&2; exit 2; }
    fi
    if [ -n "$live" ]; then
      if [ -z "$stale" ]; then
        echo "REFUSED: $1 already records a live task ($live), and ticket.sh cannot read task state, so it cannot tell live from dead. If that task is dead: dispatch $1 $role $tid --stale ${live##* }. If it reported: bash .factory/scripts/ticket.sh done $1 ${live##* }" >&2
        exit 2
      fi
      if [ "${live##* }" != "$stale" ]; then
        echo "REFUSED: --stale $stale is not the recorded task (${live##* }); nothing was written" >&2
        exit 2
      fi
      fm_set "$t" live_task ""
      ledger "$(basename "$t" .md)" router task-replaced "$live -> $role $tid"
    elif [ -n "$stale" ]; then
      echo "REFUSED: --stale $stale on $1, which records no live task; nothing was written" >&2
      exit 2
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
    # The task id is the LAST word: a substring match let `done task-1` clear
    # `task-10`, so the drill in selftest.sh section 4 pins the exact shape.
    if [ "${live##* }" = "$tid" ]; then
      fm_set "$t" live_task ""
      ledger "$(basename "$t" .md)" router task-finished "$tid"
      write_state
    else
      echo "no live task $tid on $1 (live: ${live:-none})" >&2
      exit 1
    fi
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
        # An `if` whose test fails and which has no `else` still returns 0. The AND
        # list this replaced returned 1, the loop returned its last body's status,
        # and bash exited with it: `resume` reported failure whenever the last
        # listed ticket had no live task (measured at d555886 and at ca6d35a).
        if [ -n "$live" ]; then echo "   live: $live (task_status before any re-dispatch)"; fi
      done
    else
      echo "(no tickets)"
    fi
    ;;
  next)
    write_state
    cat "$STATE"
    ;;
  --self-test)
    # Proves the stage writer refuses what next_action has no arm for. Runs the
    # COPY in a throwaway .factory, so no drill can touch a real ticket.
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    mkdir -p "$tmp/.factory/scripts" "$tmp/.factory/tickets"
    cp "$FACTORY/config.yml" "$tmp/.factory/config.yml"
    cp "$FACTORY/scripts/ticket.sh" "$tmp/.factory/scripts/ticket.sh"
    # Counted, not typed: a removed drill must not leave a green line that still
    # claims its number. Same mechanism as gate.sh --self-test.
    ASSERTIONS="$tmp/assertions"; : >"$ASSERTIONS"
    okd() { echo . >>"$ASSERTIONS"; echo "ok  - $1"; }
    tk() { bash "$tmp/.factory/scripts/ticket.sh" "$@"; }
    tk new drill --request 'prove the stage writer' --scope 'src/' --authority explicit >/dev/null
    t="$tmp/.factory/tickets/T-1.md"
    before="$(cksum <"$t")"
    # `merging post-merge-watch` and `verifying merging` are the values the old
    # substring test accepted because those names are ADJACENT in $STAGES;
    # `mergin` was refused then too, so it alone cannot carry this drill.
    for bad in mergin "merging post-merge-watch" "verifying merging" "$STAGES"; do
      st=0; out="$(tk stage T-1 "$bad" 2>&1)" || st=$?
      [ "$st" = 2 ] || { echo "self-test FAILED: stage accepted '$bad' (exit $st: $out)" >&2; exit 1; }
      [ "$(tk get T-1 stage)" = queued ] || { echo "self-test FAILED: '$bad' reached the front matter" >&2; exit 1; }
      [ "$(cksum <"$t")" = "$before" ] || { echo "self-test FAILED: refusing '$bad' changed the ticket" >&2; exit 1; }
      okd "stage refuses '$bad' with exit 2 and leaves the ticket byte-identical"
    done
    # The second writer of the same field, reached by `set <T> stage <v>`.
    st=0; out="$(tk set T-1 stage "verifying merging" 2>&1)" || st=$?
    [ "$st" = 2 ] || { echo "self-test FAILED: set wrote a value the stage writer refuses (exit $st: $out)" >&2; exit 1; }
    [ "$(cksum <"$t")" = "$before" ] || { echo "self-test FAILED: a refused set changed the ticket" >&2; exit 1; }
    okd "set is refused the same value the stage verb refuses"
    st=0; tk stage T-1 building >/dev/null 2>&1 || st=$?
    [ "$st" = 0 ] && [ "$(tk get T-1 stage)" = building ] \
      || { echo "self-test FAILED: a documented stage was refused (exit $st)" >&2; exit 1; }
    okd "a documented stage is still accepted"
    st=0; tk stage T-1 done >/dev/null 2>&1 || st=$?
    [ "$st" = 0 ] && [ "$(tk get T-1 stage)" = done ] \
      || { echo "self-test FAILED: done is unreachable, stranding every finished ticket (exit $st)" >&2; exit 1; }
    okd "done stays reachable"
    # Every accepted value but `done` must route to a named next action, or
    # `resume` prints "inspect the ticket" with no way back. Assert the ROW that
    # names the stage, not the absence of a string: `grep -q` also exits 2 on a
    # state.md that was never written, and an `if grep` on that is false for
    # every stage, so the drill would pass without proving anything.
    state="$tmp/.factory/state.md"
    for s in $STAGES; do # unquoted on purpose: one word per stage
      [ "$s" = done ] && continue # the terminal skip is proven below, not here
      tk stage T-1 "$s" >/dev/null
      [ -f "$state" ] || { echo "self-test FAILED: stage '$s' wrote no $state" >&2; exit 1; }
      tk next >/dev/null
      row="$(grep -F '| T-1 |' "$state")" || row=""
      case "$row" in
        "") echo "self-test FAILED: stage '$s' left no state row to route" >&2; exit 1 ;;
        *'inspect the ticket'*) echo "self-test FAILED: stage '$s' has no next_action arm" >&2; exit 1 ;;
      esac
    done
    okd "every accepted stage but done routes to a named next action"
    # `done` is accepted although next_action has no arm: write_state and resume
    # skip it as the terminal state. Prove that skip, since there is no row to grep.
    tk stage T-1 done >/dev/null
    [ -f "$state" ] || { echo "self-test FAILED: stage 'done' wrote no $state" >&2; exit 1; }
    tk next >/dev/null
    if grep -qF '| T-1 |' "$state"; then
      echo "self-test FAILED: done is not skipped by write_state" >&2; exit 1
    fi
    st=0; out="$(tk resume 2>&1)" || st=$?
    [ "$st" = 0 ] || { echo "self-test FAILED: resume on a done ticket exited $st: $out" >&2; exit 1; }
    case "$out" in
      *'T-1'*) echo "self-test FAILED: done is not skipped by resume: $out" >&2; exit 1 ;;
    esac
    okd "done is skipped by write_state and resume, not routed"
    # The tail of resume's loop body is a status: if its last statement can fail,
    # the loop, the `if` and bash all return 1. T-1 is re-opened with a live task
    # so the list carries both branches, and T-2 is filed last with none — the
    # shape that exited 1 before the guard, and the shape PR 175's all-`done`
    # assertion cannot reach because `continue` never runs the body.
    tk stage T-1 queued >/dev/null
    tk dispatch T-1 builder task-a >/dev/null
    tk new resume-drill --request 'prove resume status' --scope 'src/' --authority explicit >/dev/null
    want="mode: $(sed -n 's/^mode: *//p' "$tmp/.factory/config.yml" | head -1 | sed 's/ *#.*//')"
    want="$want
T-1 stage=queued issue= attempts=0
   next: dispatch researcher: bash .factory/scripts/brief.sh <T> researcher
   live: builder task-a (task_status before any re-dispatch)
T-2 stage=queued issue= attempts=0
   next: dispatch researcher: bash .factory/scripts/brief.sh <T> researcher"
    st=0; out="$(tk resume 2>&1)" || st=$?
    [ "$st" = 0 ] \
      || { echo "self-test FAILED: resume exited $st although its last ticket (T-2) has no live task" >&2; exit 1; }
    [ "$out" = "$want" ] \
      || { echo "self-test FAILED: resume's list changed. want: $want / got: $out" >&2; exit 1; }
    okd "resume exits 0 and prints the same list when the last ticket has no live task"
    st=0; out="$(tk nosuchverb 2>&1)" || st=$?
    [ "$st" = 2 ] || { echo "self-test FAILED: an unknown subcommand exited $st, not 2" >&2; exit 1; }
    case "$out" in
      *"usage: ticket.sh"*) ;;
      *) echo "self-test FAILED: an unknown subcommand printed no usage line: $out" >&2; exit 1 ;;
    esac
    okd "an unknown subcommand still exits 2 with the usage line"
    # The base a ticket records, and the line it emits. router-guard refuses any
    # command carrying `$` or `(` on shape alone, and a line naming no base lets
    # the gate fall back to merge-base origin/main, i.e. another ticket's diff.
    bsha=d915c6dc262d1ec118201117728fd46319cdbd7a
    st=0; f="$(tk new based --request 'a base' --scope 'src/' --authority explicit --base "$bsha" 2>&1)" || st=$?
    [ "$st" = 0 ] || { echo "self-test FAILED: new --base exited $st: $f" >&2; exit 1; }
    bid="$(basename "$f" .md)"
    [ "$(tk get "$bid" base)" = "$bsha" ] \
      || { echo "self-test FAILED: new --base recorded '$(tk get "$bid" base)'" >&2; exit 1; }
    line="$(sed -n '/^- \[ \] gate exits 0/p' "$f")" || line=""
    case "$line" in
      *"bash .factory/gates/gate.sh all --base $bsha"*) ;;
      *) echo "self-test FAILED: the emitted line names no relative gate path and base: $line" >&2; exit 1 ;;
    esac
    case "$line" in
      *'$('*|*'$FACTORY'*) echo "self-test FAILED: the emitted line carries a substitution the guard refuses: $line" >&2; exit 1 ;;
    esac
    okd "new --base records the ref and emits a relative, guard-legal --base line"
    st=0; f="$(tk new unbased --request 'no base' --scope 'src/' --authority explicit 2>&1)" || st=$?
    [ "$st" = 0 ] || { echo "self-test FAILED: new without --base exited $st; event.sh files every ticket that way" >&2; exit 1; }
    bid="$(basename "$f" .md)"
    [ -z "$(tk get "$bid" base)" ] || { echo "self-test FAILED: a ticket with no --base recorded one" >&2; exit 1; }
    line="$(sed -n '/NOT EMITTED/p' "$f")" || line=""
    case "$line" in *--base*) ;; *) echo "self-test FAILED: no NOT EMITTED line, and no refusal by name: $line" >&2; exit 1 ;; esac
    case "$line" in *"ticket.sh set"*) ;; *) echo "self-test FAILED: the refused line names no way to record a base: $line" >&2; exit 1 ;; esac
    okd "new without --base still exits 0 and refuses to emit a line that judged nothing"
    st=0; f="$(tk new junky --request 'junk base' --scope 'src/' --authority explicit --base 'a b;$(id)/x&y' 2>&1)" || st=$?
    [ "$st" = 0 ] || { echo "self-test FAILED: new --base rejected a hostile ref instead of stripping it (exit $st)" >&2; exit 1; }
    junk="$(tk get "$(basename "$f" .md)" base)"
    [ -n "$junk" ] || { echo "self-test FAILED: a hostile --base recorded nothing" >&2; exit 1; }
    case "$junk" in
      *[!A-Za-z0-9._/-]*) echo "self-test FAILED: an untrusted --base reached the front matter: $junk" >&2; exit 1 ;;
    esac
    okd "an untrusted --base cannot carry a metacharacter into the front matter"
    # A ticket filed with no scope is legal (event.sh files every webhook ticket
    # that way); dispatching a worker into it is not. Keys on emptiness: a
    # present-but-short `src/` was measured dispatching and must keep dispatching.
    st=0; nf="$(tk new noscope --request 'no mandate' --scope '' --authority inferred 2>&1)" || st=$?
    [ "$st" = 0 ] || { echo "self-test FAILED: filing a ticket with an empty scope exited $st" >&2; exit 1; }
    nid="$(basename "$nf" .md)"
    [ -z "$(tk get "$nid" scope)" ] || { echo "self-test FAILED: the empty-scope fixture is not empty" >&2; exit 1; }
    before="$(cksum <"$nf")"
    st=0; out="$(tk dispatch "$nid" builder task-x 2>&1)" || st=$?
    [ "$st" = 2 ] \
      || { echo "self-test FAILED: dispatch accepted a ticket with no scope (exit $st): $out" >&2; exit 1; }
    case "$out" in *scope*) ;; *) echo "self-test FAILED: the refusal does not name the field: $out" >&2; exit 1 ;; esac
    case "$out" in *"ticket.sh set"*) ;; *) echo "self-test FAILED: the refusal names no command to fix it: $out" >&2; exit 1 ;; esac
    [ -z "$(tk get "$nid" live_task)" ] || { echo "self-test FAILED: a refused dispatch wrote live_task" >&2; exit 1; }
    [ "$(cksum <"$nf")" = "$before" ] || { echo "self-test FAILED: a refused dispatch changed the ticket" >&2; exit 1; }
    okd "dispatch refuses an empty scope with exit 2, names the field and how to set it, and writes nothing"
    st=0; sf="$(tk new shortscope --request 'a short mandate' --scope 'src/' --authority explicit 2>&1)" || st=$?
    [ "$st" = 0 ] || { echo "self-test FAILED: filing a short-scope ticket exited $st" >&2; exit 1; }
    st=0; out="$(tk dispatch "$(basename "$sf" .md)" builder task-s 2>&1)" || st=$?
    ssid="$(basename "$sf" .md)"
    [ "$st" = 0 ] \
      || { echo "self-test FAILED: a present-but-short scope was refused (exit $st): $out" >&2; exit 1; }
    okd "a present-but-short scope still dispatches"
    # The refusal is dispatch's half only: the same ticket still takes every verb.
    st=0
    tk get "$nid" scope >/dev/null || st=$?
    tk set "$nid" live_task "builder task-x" >/dev/null || st=$?
    tk stage "$nid" building >/dev/null || st=$?
    tk bump "$nid" >/dev/null || st=$?
    tk resume >/dev/null || st=$?
    tk next >/dev/null || st=$?
    tk done "$nid" task-x >/dev/null || st=$?
    [ "$st" = 0 ] \
      || { echo "self-test FAILED: the empty-scope refusal leaked into another verb (exit $st)" >&2; exit 1; }
    okd "the empty-scope refusal is dispatch's alone: get set stage bump resume next done still exit 0"
    # The recorded task cannot be judged from here, so dispatch takes a declaration.
    st=0; df="$(tk new stateful --request 'prove the state refusal' --scope 'src/' --authority explicit 2>&1)" || st=$?
    [ "$st" = 0 ] || { echo "self-test FAILED: filing the state fixture exited $st" >&2; exit 1; }
    did="$(basename "$df" .md)"
    st=0; tk dispatch "$did" builder task-a >/dev/null 2>&1 || st=$?
    [ "$st" = 0 ] || { echo "self-test FAILED: a first dispatch was refused (exit $st)" >&2; exit 1; }
    [ "$(tk get "$did" live_task)" = "builder task-a" ] \
      || { echo "self-test FAILED: dispatch recorded '$(tk get "$did" live_task)'" >&2; exit 1; }
    okd "dispatch records the task when none is recorded"
    before="$(cksum <"$df")"
    st=0; out="$(tk dispatch "$did" verifier task-b 2>&1)" || st=$?
    [ "$st" = 2 ] \
      || { echo "self-test FAILED: a second dispatch was not refused with exit 2 (exit $st): $out" >&2; exit 1; }
    [ "$(tk get "$did" live_task)" = "builder task-a" ] \
      || { echo "self-test FAILED: a refused dispatch changed live_task" >&2; exit 1; }
    [ "$(cksum <"$df")" = "$before" ] || { echo "self-test FAILED: a refused dispatch changed the ticket" >&2; exit 1; }
    case "$out" in *"--stale"*) ;; *) echo "self-test FAILED: the refusal names no way to replace a dead task: $out" >&2; exit 1 ;; esac
    case "$out" in *"done $did task-a"*) ;; *) echo "self-test FAILED: the refusal does not name `done` for a task that reported: $out" >&2; exit 1 ;; esac
    if jq -r --arg t "$did" 'select(.ticket==$t) | .detail' "$tmp/.factory/ledger.jsonl" | grep -qF 'task-b'; then
      echo "self-test FAILED: a refused dispatch wrote a ledger row naming task-b" >&2; exit 1
    fi
    okd "a second dispatch is refused by name, writes nothing, and leaves no ledger row"
    st=0; out="$(tk dispatch "$did" verifier task-b --stale task-zzz 2>&1)" || st=$?
    [ "$st" = 2 ] \
      || { echo "self-test FAILED: a --stale that is not the recorded task exited $st, not 2" >&2; exit 1; }
    [ "$(cksum <"$df")" = "$before" ] || { echo "self-test FAILED: a mismatched --stale changed the ticket" >&2; exit 1; }
    okd "a --stale that is not the recorded task is refused and writes nothing"
    st=0; out="$(tk dispatch "$did" verifier task-b --stale task-a 2>&1)" || st=$?
    [ "$st" = 0 ] || { echo "self-test FAILED: --stale <recorded id> exited $st: $out" >&2; exit 1; }
    [ "$(tk get "$did" live_task)" = "verifier task-b" ] \
      || { echo "self-test FAILED: --stale left live_task at '$(tk get "$did" live_task)'" >&2; exit 1; }
    row="$(jq -r --arg t "$did" 'select(.ticket==$t and .event=="task-replaced") | .detail' "$tmp/.factory/ledger.jsonl")"
    case "$row" in *task-a*) ;; *) echo "self-test FAILED: the task-replaced row names no replaced id: $row" >&2; exit 1 ;; esac
    case "$row" in *task-b*) ;; *) echo "self-test FAILED: the task-replaced row names no replacement id: $row" >&2; exit 1 ;; esac
    okd "--stale <recorded id> clears it, dispatches, and the ledger names both ids"
    # The two shapes the Router hit: a task that reported `completed`, and one that
    # died with no report. ticket.sh records the disposition its caller declares; it
    # never observes one, so the drill pins the declaration, not a guess.
    st=0; tk done "$did" task-b >/dev/null 2>&1 || st=$?
    [ "$st" = 0 ] && [ -z "$(tk get "$did" live_task)" ] \
      || { echo "self-test FAILED: done did not clear a task that reported (exit $st)" >&2; exit 1; }
    st=0; tk dispatch "$did" verifier task-c >/dev/null 2>&1 || st=$?
    [ "$st" = 0 ] || { echo "self-test FAILED: re-dispatch after done exited $st" >&2; exit 1; }
    st=0; tk dispatch "$did" tester task-d --stale task-c >/dev/null 2>&1 || st=$?
    [ "$st" = 0 ] || { echo "self-test FAILED: --stale after re-dispatch exited $st" >&2; exit 1; }
    fin="$(jq -r --arg t "$did" 'select(.ticket==$t) | .event + " " + .detail' "$tmp/.factory/ledger.jsonl")"
    case "$fin" in
      *"task-finished task-b"*) ;;
      *) echo "self-test FAILED: no task-finished row for the task that reported: $fin" >&2; exit 1 ;;
    esac
    case "$fin" in
      *"task-replaced verifier task-c -> tester task-d"*) ;;
      *) echo "self-test FAILED: the replacement does not say what it replaced: $fin" >&2; exit 1 ;;
    esac
    okd "both dispositions are on the record: task-finished for a report, task-replaced for a dead task"
    st=0; tk done "$ssid" task-s >/dev/null 2>&1 || st=$?
    [ "$st" = 0 ] || { echo "self-test FAILED: done on the short-scope ticket exited $st" >&2; exit 1; }
    before="$(cksum <"$sf")"
    st=0; out="$(tk dispatch "$ssid" builder task-e --stale task-s 2>&1)" || st=$?
    [ "$st" = 2 ] \
      || { echo "self-test FAILED: --stale on a ticket with no live task exited $st, not 2" >&2; exit 1; }
    [ "$(cksum <"$sf")" = "$before" ] || { echo "self-test FAILED: a --stale with nothing to replace changed the ticket" >&2; exit 1; }
    okd "--stale with no live task to replace is refused and writes nothing"
    echo "ticket self-test: $(wc -l <"$ASSERTIONS" | tr -d ' ') assertions hold"
    exit 0
    ;;
  *)
    echo "usage: ticket.sh new|get|set|stage|dispatch|done|bump|list|resume|next|--self-test" >&2
    exit 2
    ;;
esac
