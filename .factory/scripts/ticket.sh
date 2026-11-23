#!/usr/bin/env bash
# ticket.sh — the ticket file IS the state. No ticket, no work.
#
#   ticket.sh new <slug> --request <verbatim> --scope <p1,p2> --authority explicit|inferred [--issue N]
#                   [--base <ref>]             the base a gate run is diffed against
#   ticket.sh get <T-n> <key>
#   ticket.sh set <T-n> <key> <value>           e.g. `set T-1 pr 168`: the PR a ticket's branch opened
#                                              (event.sh matches a delivery's pull_request.number on it)
#   ticket.sh stage <T-n> <stage>
#   ticket.sh dispatch <T-n> <role> <taskId> [--stale <recorded taskId>]
#                                              refuses while a task is recorded;
#                                              --stale replaces one the caller
#                                              declares dead or already reported
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
  # `key:` is a field name, not data. A two-word key was measured writing
  # `original_request  Th: …` and exiting 0, which is a colon-less line every
  # later reader sees as an empty field, so the key is checked before any write.
  case "$k" in
    ''|*[!A-Za-z0-9_]*) echo "$k is not a front-matter field name ([A-Za-z0-9_]); nothing was written" >&2; exit 2 ;;
  esac
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
  # Same directory as the target, so the final mv is rename(2) and not a
  # cross-device copy: `/tmp` is another device than the ticket dir (measured
  # 57 vs 54), and a copy killed mid-way leaves a truncated ticket. A bare
  # mktemp also honours TMPDIR, so an unreadable TMPDIR failed every write.
  tmp="$(mktemp "$TICKETS/.tmp.XXXXXX")"
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
  local tmp
  # rename(2) in one directory, for the reason fm_set's temp gives above.
  tmp="$(mktemp "$FACTORY/.state.tmp.XXXXXX")"
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
  } >"$tmp"
  mv "$tmp" "$STATE"
}

cmd="${1:-}"
shift || true
case "$cmd" in
  new)
    slug="${1:?slug}"
    shift
    request="" scope="" authority="inferred" issue="" base=""
    while [ $# -gt 0 ]; do
      # Every flag here takes a value, so a flag with nothing after it is the
      # caller's mistake and must say so: `$2` unset aborted under `set -u` with
      # bash's own `unbound variable` and exit 1 (measured on all five arms at
      # 75c13cb, `--base` last), which a caller cannot tell from a real failure.
      [ $# -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; }
      case "$1" in
        --request) request="$2"; shift 2 ;;
        --scope) scope="$2"; shift 2 ;;
        --authority) authority="$2"; shift 2 ;;
        --issue) issue="$2"; shift 2 ;;
        # An empty value is not "no flag": it would fall through to the no-base
        # branch and file a ticket whose caller thinks it named a base.
        --base) [ -n "$2" ] || { echo "--base needs a ref" >&2; exit 2; }; base="$2"; shift 2 ;;
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
    # The base lands in the front matter and in a command a builder pastes, so it
    # is a revision and nothing else — and it is REFUSED, never stripped. The
    # `tr -cd 'A-Za-z0-9._/-'` this replaces deleted `~`, `^` and `@`, so `HEAD~1`
    # was recorded as `HEAD1`: a ref the caller never named, in `base:` and in the
    # emitted line (measured at 75c13cb). The allowed set is what git reads as a
    # revision minus what router-guard refuses on shape (SHELL_META: backtick, $,
    # ( ) { } ! \ ; & | < >), so `main@{1}` is refused by name rather than
    # silently becoming `main1`; gate.sh still refuses a base that does not
    # resolve, which is the backstop this cannot be.
    case "$base" in
      *[!A-Za-z0-9._/~^@+-]*) echo "--base '$base' carries whitespace or a character router-guard refuses in a pasted command (allowed: A-Za-z0-9._/-~^@+); nothing was filed" >&2; exit 2 ;;
    esac
    case "$authority" in explicit|inferred) ;; *) echo "--authority explicit|inferred" >&2; exit 2 ;; esac
    # The id is derived from a listing, so two concurrent calls can pick the same
    # one — measured in 2 of 12 runs, and the second `>` truncated the first, which
    # is the splice shape T-28 was found in. The body is written to a temp in the
    # same directory and then LINKED into place, because link(2) is the exclusive
    # create: a body write that stops half way (file-size limit, full disk, killed)
    # cannot leave a reserved id holding truncated front matter. Writing `> "$file"`
    # under noclobber did exactly that — measured at 75c13cb as 20 truncated
    # tickets, one per retry, each treated as a reserved id. The write runs in a
    # subshell so a killed writer is a status this loop can clean up after instead
    # of the script's own death. A collision still leaves the shell's own line on
    # stderr: silencing it would silence a real write error too, and the branch
    # below tells the two apart by whether the target exists.
    tries=0
    while :; do
      last=0
      if compgen -G "$TICKETS/T-*.md" >/dev/null; then
        last=$(ls "$TICKETS"/T-*.md | sed 's/.*\/T-//; s/\.md$//' | sort -n | tail -1)
      fi
      id="T-$((last + 1))"
      file="$TICKETS/$id.md"
      tmpf="$(mktemp "$TICKETS/.new.XXXXXX")"
      if ( {
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
      # relative gate path, a literal base, and none of the characters its
      # SHELL_META refuses on shape — the parenthesised `git rev-parse HEAD` hint
      # and its backticks were refused shapes, claimed guard-legal by an assertion
      # that could not fail. The self-test now tests the emitted bytes for that
      # class instead of for a `$FACTORY` that `echo` had already expanded.
      if [ -n "$base" ]; then
        echo "- [ ] gate exits 0, substituting HEAD_SHA from git rev-parse HEAD: bash .factory/gates/gate.sh all --base $base --sha HEAD_SHA --ticket-file $FACTORY/tickets/$id.md"
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
      } >"$tmpf" ); then
        # 0644, the mode `> "$file"` gave under the usual umask; mktemp's own is
        # 0600 and a silent mode change is drift nobody asked for.
        chmod 0644 "$tmpf"
        if ln "$tmpf" "$file"; then rm -f "$tmpf"; break; fi
        rm -f "$tmpf"
        if [ ! -e "$file" ]; then
          echo "new: could not link a body into $file; nothing was filed" >&2
          exit 1
        fi
      else
        rm -f "$tmpf"
        echo "new: could not write the body of $id; nothing was filed" >&2
        exit 1
      fi
      tries=$((tries + 1))
      [ "$tries" -lt 20 ] || { echo "new: no id could be reserved after 20 tries" >&2; exit 1; }
    done
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
    okd "new --base records the ref and emits a relative, guard-legal --base line"
    # The line a builder pastes is judged by its bytes, never by what the emitter
    # meant. These are router-guard's SHELL_META characters; the assertion this
    # replaces tested for `$(` and for a literal `$FACTORY` that `echo` had already
    # expanded, so it could not fail while the line it passed carried a
    # parenthesised hint and two backticks — shapes the guard refuses.
    for ch in ';' '&' '|' '<' '>' '`' '$' '(' ')' '{' '}' '!' '\'; do
      if printf '%s' "$line" | grep -qF -- "$ch"; then
        echo "self-test FAILED: the emitted gate line carries '$ch', which router-guard refuses in a pasted command: $line" >&2; exit 1
      fi
    done
    okd "the emitted gate line carries no character router-guard refuses on shape"
    st=0; f="$(tk new unbased --request 'no base' --scope 'src/' --authority explicit 2>&1)" || st=$?
    [ "$st" = 0 ] || { echo "self-test FAILED: new without --base exited $st; event.sh files every ticket that way" >&2; exit 1; }
    bid="$(basename "$f" .md)"
    [ -z "$(tk get "$bid" base)" ] || { echo "self-test FAILED: a ticket with no --base recorded one" >&2; exit 1; }
    line="$(sed -n '/NOT EMITTED/p' "$f")" || line=""
    case "$line" in *--base*) ;; *) echo "self-test FAILED: no NOT EMITTED line, and no refusal by name: $line" >&2; exit 1 ;; esac
    case "$line" in *"ticket.sh set"*) ;; *) echo "self-test FAILED: the refused line names no way to record a base: $line" >&2; exit 1 ;; esac
    okd "new without --base still exits 0 and refuses to emit a line that judged nothing"
    # A base is a revision, not a prefix of one: stripping `~`, `^` and `@` recorded
    # `HEAD1` for `HEAD~1` — a ref the caller never named, in `base:` and in the line
    # a builder runs. `HEAD~1` is guard-legal as written, so it is kept; `main@{1}`
    # needs braces the guard refuses, so it is refused by name, never rewritten.
    st=0; f="$(tk new refbase --request 'a ref' --scope 'src/' --authority explicit --base 'HEAD~1' 2>&1)" || st=$?
    [ "$st" = 0 ] || { echo "self-test FAILED: new --base HEAD~1 exited $st: $f" >&2; exit 1; }
    [ "$(tk get "$(basename "$f" .md)" base)" = 'HEAD~1' ] \
      || { echo "self-test FAILED: --base HEAD~1 recorded '$(tk get "$(basename "$f" .md)" base)'" >&2; exit 1; }
    rline="$(sed -n '/^- \[ \] gate exits 0/p' "$f")" || rline=""
    case "$rline" in
      *'--base HEAD~1'*) ;;
      *) echo "self-test FAILED: the emitted line names a base the caller did not: $rline" >&2; exit 1 ;;
    esac
    n0=$(ls "$tmp/.factory/tickets"/T-*.md | wc -l)
    for bad in 'main@{1}' 'a b;$(id)/x&y'; do
      st=0; out="$(tk new junkbase --request 'junk base' --scope 'src/' --authority explicit --base "$bad" 2>&1)" || st=$?
      [ "$st" = 2 ] \
        || { echo "self-test FAILED: --base '$bad' exited $st instead of refusing a ref it cannot carry: $out" >&2; exit 1; }
      case "$out" in *--base*) ;; *) echo "self-test FAILED: the refusal does not name the flag: $out" >&2; exit 1 ;; esac
    done
    [ "$(ls "$tmp/.factory/tickets"/T-*.md | wc -l)" = "$n0" ] \
      || { echo "self-test FAILED: a refused --base still filed a ticket" >&2; exit 1; }
    okd "a base keeps its revision syntax, and a ref it cannot carry is refused rather than rewritten"
    # A flag with nothing after it aborted with bash's own `unbound variable` and
    # exit 1 on all five arms (measured at 75c13cb), which reads like a crash. An
    # empty `--base` is the same mistake and must not fall through to no-base.
    for flag in --request --scope --authority --issue --base; do
      st=0; out="$(tk new novalue "$flag" 2>&1)" || st=$?
      [ "$st" = 2 ] || { echo "self-test FAILED: 'new novalue $flag' exited $st, not 2: $out" >&2; exit 1; }
      case "$out" in
        *"$flag needs a value"*) ;;
        *) echo "self-test FAILED: '$flag' with no value is not named in a refusal: $out" >&2; exit 1 ;;
      esac
    done
    st=0; out="$(tk new emptybase --request 'r' --scope 'src/' --authority explicit --base '' 2>&1)" || st=$?
    [ "$st" = 2 ] || { echo "self-test FAILED: --base with an empty value exited $st, not 2: $out" >&2; exit 1; }
    [ "$(ls "$tmp/.factory/tickets"/T-*.md | wc -l)" = "$n0" ] \
      || { echo "self-test FAILED: a refused new filed a ticket" >&2; exit 1; }
    okd "a flag with no value is refused by name with exit 2, and files nothing"
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
    # --- the writers ---
    # `new` must not truncate a ticket that already holds an id it derived. This is
    # the sequential half: the derived id is the highest + 1, so the file it must
    # leave alone is the one it would have written next.
    last=$(ls "$tmp/.factory/tickets"/T-*.md | sed 's/.*\/T-//; s/\.md$//' | sort -n | tail -1)
    coll="T-$((last + 1))"
    printf 'keep\n' >"$tmp/.factory/tickets/$coll.md"
    c0="$(cksum <"$tmp/.factory/tickets/$coll.md")"
    st=0; f="$(tk new race --request 'prove the exclusive create' --scope 'src/' --authority explicit 2>&1)" || st=$?
    [ "$st" = 0 ] || { echo "self-test FAILED: new beside an occupied id exited $st: $f" >&2; exit 1; }
    [ "$(cksum <"$tmp/.factory/tickets/$coll.md")" = "$c0" ] \
      || { echo "self-test FAILED: new truncated an existing ticket file ($coll)" >&2; exit 1; }
    [ "$(basename "$f" .md)" = "T-$((last + 2))" ] \
      || { echo "self-test FAILED: new did not land on the next free id: $f" >&2; exit 1; }
    [ "$(grep -c '^## Scope (the mandate)' "$f")" = 1 ] \
      || { echo "self-test FAILED: a ticket landed with a spliced body" >&2; exit 1; }
    [ "$(jq -r 'select(.event=="ticket-created") | .ticket' "$tmp/.factory/ledger.jsonl" | grep -cFx "$(basename "$f" .md)")" = 1 ] \
      || { echo "self-test FAILED: a ticket landed without exactly one ticket-created row" >&2; exit 1; }
    okd "new leaves an existing ticket byte-identical and lands on the next free id"
    # The same property where it is decided: with the tickets dir unreadable, the id
    # listing returns nothing, so the target is an id that already exists. `>` would
    # truncate it and exit 0 (measured: 5 bytes became 746); noclobber refuses, the
    # loop exhausts, and the existing ticket is byte-identical. Exit 1 is right here:
    # a listing it cannot read is a refusal, not an empty ticket set.
    keep="$tmp/.factory/tickets/$coll.md"
    c0="$(cksum <"$keep")"
    c1="$(cksum <"$tmp/.factory/tickets/T-1.md")" # the id a blind listing derives
    chmod 0300 "$tmp/.factory/tickets"
    st=0; out="$(tk new blind --request 'prove the exclusive create' --scope 'src/' --authority explicit 2>&1)" || st=$?
    chmod 0700 "$tmp/.factory/tickets"
    [ "$(cksum <"$tmp/.factory/tickets/T-1.md")" = "$c1" ] \
      || { echo "self-test FAILED: new truncated T-1.md when it could not read the ids" >&2; exit 1; }
    [ "$(cksum <"$keep")" = "$c0" ] \
      || { echo "self-test FAILED: new truncated $coll.md when it could not read the ids" >&2; exit 1; }
    [ "$st" = 1 ] \
      || { echo "self-test FAILED: new exited $st on an id it could not see; a truncating write exits 0, so only a refusal is safe: $out" >&2; exit 1; }
    okd "an unresolvable id collision refuses and writes nothing instead of truncating"
    # The body is written to a temp and linked into place, so a write that cannot
    # finish leaves no ticket at all. Writing `> "$file"` under noclobber left a
    # truncated ticket on EVERY retry — measured at 75c13cb as 20 files of 1024
    # bytes with no closing `---`, each one an id no later call could reuse. The
    # limit kills the writer mid-body, which is the cheapest deterministic way to
    # make a body write fail; the tick is a killed process, not a broken script.
    n0=$(ls "$tmp/.factory/tickets"/T-*.md | wc -l)
    st=0; out="$( ( ulimit -f 1; bash "$tmp/.factory/scripts/ticket.sh" new bigbody \
      --request "$(printf 'x%.0s' $(seq 1 1200))" --scope 'src/' --authority explicit ) 2>&1 )" || st=$?
    [ "$st" != 0 ] \
      || { echo "self-test FAILED: a body write that could not finish exited 0" >&2; exit 1; }
    n1=$(ls "$tmp/.factory/tickets"/T-*.md | wc -l)
    [ "$n1" = "$n0" ] \
      || { echo "self-test FAILED: a failed body write left $((n1 - n0)) truncated ticket files: $out" >&2; exit 1; }
    okd "a body write that cannot finish leaves no ticket, not a reserved id with truncated front matter"
    # 8 concurrent `new` calls: no loss, no spliced body, one ledger row per id. This
    # asserts the outcome and is NOT the mechanism proof — the two drills above are,
    # because this shape was measured intermittent (2 of 12 runs) before the fix.
    n0=$(ls "$tmp/.factory/tickets"/T-*.md | wc -l)
    pids=""
    for i in 1 2 3 4 5 6 7 8; do
      tk new "race$i" --request 'r' --scope 'src/' --authority explicit >/dev/null 2>&1 &
      pids="$pids $!"
    done
    for p in $pids; do wait "$p" || { echo "self-test FAILED: a concurrent new failed" >&2; exit 1; }; done
    n1=$(ls "$tmp/.factory/tickets"/T-*.md | wc -l)
    [ "$((n1 - n0))" = 8 ] || { echo "self-test FAILED: 8 concurrent new calls produced $((n1 - n0)) files" >&2; exit 1; }
    for i in 1 2 3 4 5 6 7 8; do
      m="$(grep -l "^slug: race$i$" "$tmp/.factory/tickets"/T-*.md)" || m=""
      [ -n "$m" ] || { echo "self-test FAILED: race$i landed nowhere" >&2; exit 1; }
      [ "$(grep -c '^## Scope (the mandate)' "$m")" = 1 ] \
        || { echo "self-test FAILED: race$i's body was spliced or duplicated" >&2; exit 1; }
      [ "$(jq -r 'select(.event=="ticket-created") | .ticket' "$tmp/.factory/ledger.jsonl" | grep -cFx "$(basename "$m" .md)")" = 1 ] \
        || { echo "self-test FAILED: race$i did not get exactly one ticket-created row" >&2; exit 1; }
    done
    okd "8 concurrent new calls lose nothing: one file, one heading and one ledger row each"
    # A temp in /tmp is honoured by a bare mktemp, so an unreadable TMPDIR failed
    # every write; in the target's own directory it is not consulted at all. Also
    # the rename(2) half: /tmp is another device than the ticket dir (57 vs 54).
    c0="$(cksum <"$tmp/.factory/tickets/T-1.md")"
    st=0; TMPDIR=/nonexistent tk set T-1 attempts 3 >/dev/null 2>&1 || st=$?
    [ "$st" = 0 ] || { echo "self-test FAILED: a write with an unreadable TMPDIR exited $st" >&2; exit 1; }
    [ "$(cksum <"$tmp/.factory/tickets/T-1.md")" != "$c0" ] \
      || { echo "self-test FAILED: the TMPDIR drill changed nothing, so it proves nothing" >&2; exit 1; }
    okd "a write ignores TMPDIR and lands in the target's own directory"
    # A two-word key was measured writing `original_request  Th: …` and exiting 0.
    c0="$(cksum <"$tmp/.factory/tickets/T-1.md")"
    st=0; out="$(tk set T-1 'original_request  Th' x 2>&1)" || st=$?
    [ "$st" = 2 ] || { echo "self-test FAILED: a field name with a space exited $st: $out" >&2; exit 1; }
    [ "$(cksum <"$tmp/.factory/tickets/T-1.md")" = "$c0" ] \
      || { echo "self-test FAILED: a refused field name changed the ticket" >&2; exit 1; }
    st=0; tk set T-1 original_request x >/dev/null 2>&1 || st=$?
    [ "$st" = 0 ] || { echo "self-test FAILED: a real field name was refused (exit $st)" >&2; exit 1; }
    okd "a field name outside [A-Za-z0-9_] is refused before any write; a real key still sets"
    # The sweep: no verb may truncate or splice a ticket in the shapes real tickets
    # carry. It proves that and nothing more — T-15's 0 bytes is NOT explained here.
    keys() { sed -n '2,/^---$/p' "$1" | sed -n 's/^\([A-Za-z0-9_]*\):.*/\1/p' | sort | tr '\n' ' '; }
    heads() { grep -n '^## ' "$1"; }
    cat >"$tmp/.factory/tickets/T-90.md" <<'T15'
---
id: T-90
slug: t15shape
gh_issue:
original_request: |
  Triage the unexplained 0-byte ticket write.
scope: .factory/scripts/,src/
authority: inferred
base: d915c6dc262d1ec118201117728fd46319cdbd7a
stage: queued
task_ids: researcher=task-0123456789abcdef;planner=task-fedcba9876543210;builder=task-0011223344556677;verifier=task-8899aabbccddeeff;
live_task:
worktree:
attempts: 0
research_refs: .factory/research/x.md
verdict:
created: 2026-11-01T00:00:00Z
park_reason: "queued behind PR 175, which owns .factory/scripts/ticket.sh until it merges; dispatching now would put two builders on one file."
---

# T-90 — t15shape

## Scope (the mandate)

## Plan

## Injection log
T15
    cat >"$tmp/.factory/tickets/T-91.md" <<'T28'
---
id: T-91
slug: t28shape
gh_issue:
original_request  Th  Triage the threads.
scope: .factory/research/
authority: inferred
stage: queued
task_ids:
live_task:
worktree:
attempts: 0
created: 2026-11-01T00:00:00Z
---

# T-91 — t28shape

## Injection log

## Scope

- [ ] a foreign block, preserved verbatim
T28
    for shp in T-90 T-91; do
      f="$tmp/.factory/tickets/$shp.md"
      k0="$(keys "$f")"; h0="$(heads "$f")"
      for v in "set $shp attempts 1" "stage $shp planning" "dispatch $shp builder task-sweep" \
               "done $shp task-sweep" "bump $shp" "resume" "next" "get $shp stage" \
               "set $shp stage queued"; do
        st=0; tk $v >/dev/null 2>&1 || st=$?
        [ "$st" = 0 ] || { echo "self-test FAILED: '$v' exited $st on the $shp shape" >&2; exit 1; }
        [ "$(wc -c <"$f")" -gt 0 ] || { echo "self-test FAILED: '$v' left $shp at 0 bytes" >&2; exit 1; }
        [ "$(keys "$f")" = "$k0" ] || { echo "self-test FAILED: '$v' changed $shp's front-matter key set" >&2; exit 1; }
        [ "$(heads "$f")" = "$h0" ] || { echo "self-test FAILED: '$v' changed $shp's section headings" >&2; exit 1; }
      done
      okd "nine verbs leave the $shp shape non-empty, with its key set and headings unchanged"
    done
    if compgen -G "$tmp/.factory/tickets/.tmp.*" >/dev/null || compgen -G "$tmp/.factory/tickets/.new.*" >/dev/null || compgen -G "$tmp/.factory/.state.tmp.*" >/dev/null; then
      echo "self-test FAILED: a temporary file was left behind" >&2; exit 1
    fi
    okd "no temporary file is left in the tickets dir or the factory root"
    echo "ticket self-test: $(wc -l <"$ASSERTIONS" | tr -d ' ') assertions hold"
    exit 0
    ;;
  *)
    echo "usage: ticket.sh new [--base <ref>] | get | set | stage | dispatch [--stale <taskId>] | done | bump | list | resume | next | --self-test" >&2
    exit 2
    ;;
esac
