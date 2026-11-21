#!/usr/bin/env bash
# Agent-facing review state. AXI: typed contract, compact output, minimal
# schema, pre-computed aggregates, definitive empty state, structured errors.
set -uo pipefail

VERSION="0.4.0"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$SELF_DIR/$(basename "${BASH_SOURCE[0]}")"
case "$BIN" in "$HOME"/*) BIN="~${BIN#"$HOME"}" ;; esac

usage() {
  cat <<EOF
bin: $BIN
description: Compact PR review state for agents

usage:
  scripts/review-state.sh [<pr>] [--findings] [--full] [--gate] [--reviewed] [--sha <hex>]
  scripts/review-state.sh --help
  scripts/review-state.sh --version

flags:
  --findings  list findings as a TOON table
  --full      include the complete review comment (collapsed to one line)
  --gate      exit 1 when the review is missing, older than the head, does not
              record a completed run, or does not clear the merge
  --reviewed  exit 0 when a complete review covers the head, whatever its
              verdict: the "is another review worth a model call" question
  --sha <hex> judge this 40-hex commit instead of the PR's current head
  --help      this reference
  --version   print the version only

env:
  REVIEW_BOT_LOGIN  comma-separated logins whose comments count as the review
                    (default: github-actions[bot],github-actions, because
                    \`gh pr view\` drops the [bot] suffix the API keeps)
  REVIEW_GATE_VERDICT  the merge verdict \`--gate\` accepts, snake_case
                    (default: no_concerns_found)

examples:
  scripts/review-state.sh
  scripts/review-state.sh 20
  scripts/review-state.sh 20 --findings
  scripts/review-state.sh 20 --full
  scripts/review-state.sh 20 --gate
EOF
}

err() {
  printf 'error: %s\nhelp: %s\n' "$1" "$2"
  exit "${3:-1}"
}

pr=""
full=0
show_findings=0
gate=0
reviewed_mode=0
sha=""
want_sha=0

for arg in "$@"; do
  if [[ "$want_sha" -eq 1 ]]; then
    sha="$arg"
    want_sha=0
    continue
  fi
  case "$arg" in
    --help|-h) usage; exit 0 ;;
    --version|-v|-V) printf '%s\n' "$VERSION"; exit 0 ;;
    --full) full=1 ;;
    --findings) show_findings=1 ;;
    --gate) gate=1 ;;
    --reviewed) reviewed_mode=1 ;;
    --sha) want_sha=1 ;;
    -*) err "unknown flag $arg" "valid flags: --findings, --full, --gate, --reviewed, --sha, --help, --version" 2 ;;
    *)
      [[ -z "$pr" ]] || err "unexpected argument $arg" "pass one PR number" 2
      pr="$arg"
      ;;
  esac
done
[[ "$want_sha" -eq 0 ]] || err "--sha needs a commit" "pass a full 40-hex SHA" 2
# A short or non-hex SHA would compare unequal to every recorded head and read
# as a stale review, which is a verdict about a typo rather than about the PR.
[[ -z "$sha" || "$sha" =~ ^[0-9a-f]{40}$ ]] \
  || err "--sha is not a 40-hex commit: $sha" "pass the full SHA from \`git rev-parse HEAD\`" 2

command -v gh >/dev/null 2>&1 || err "gh is not installed" "install the GitHub CLI"
command -v jq >/dev/null 2>&1 || err "jq is not installed" "install jq"

GERR="$(mktemp)"
trap 'rm -f "$GERR"' EXIT

if [[ -z "$pr" ]]; then
  pr="$(gh pr view --json number --jq .number 2>"$GERR")"
  if [[ -z "$pr" ]]; then
    if grep -qi "no pull requests found" "$GERR"; then
      branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
      if [[ "$gate" -eq 1 ]]; then
        printf 'gate: fail\npr: 0\nreason: no open pull request for branch %s\nhelp: open a PR and run `/review`\n' "$branch"
        exit 1
      fi
      printf 'pr: 0 open pull requests for branch %s\n' "$branch"
      printf 'help[1]: push the branch and open a PR to get a review\n'
      exit 0
    fi
    err "gh pr view failed: $(head -1 "$GERR")" "run \`gh auth status\`"
  fi
else
  [[ "$pr" =~ ^[0-9]+$ ]] || err "PR must be a number, got $pr" "run \`gh pr list\` to see numbers" 2
fi

if ! meta="$(gh pr view "$pr" --json number,state,title,headRefOid,url 2>"$GERR")"; then
  err "PR #$pr not found: $(head -1 "$GERR")" "check the number or run \`gh pr list\`"
fi

number="$(jq -r '.number' <<<"$meta")"
state="$(jq -r '.state' <<<"$meta")"
title="$(jq -r '.title' <<<"$meta")"
head="$(jq -r '.headRefOid[0:7]' <<<"$meta")"
head_full="$(jq -r '.headRefOid' <<<"$meta")"
url="$(jq -r '.url' <<<"$meta")"

# `--sha` pins the commit the verdict is about, so a push during the run cannot
# move the target between the check the caller reports and the review it reads.
if [[ -n "$sha" ]]; then
  head="${sha:0:7}"
  head_full="$sha"
fi

# Checks are read for the full report only. `--gate` decides on the review alone,
# so it needs no Checks API permission: a workflow can grant it
# `pull-requests: read` and nothing else.
if [[ "$gate" == 0 ]]; then
  checks="$(gh pr checks "$pr" --json name,state 2>"$GERR")"
  if [[ -z "$checks" ]]; then
    if grep -qi "no checks reported" "$GERR"; then
      checks='[]'
    else
      err "gh pr checks failed: $(head -1 "$GERR")" "run \`gh auth status\`"
    fi
  fi
  jq -e . >/dev/null 2>&1 <<<"$checks" || err "gh pr checks returned invalid JSON" "rerun the command"

  total="$(jq 'length' <<<"$checks")"
  passed="$(jq '[.[] | select(.state == "SUCCESS")] | length' <<<"$checks")"
  failed="$(jq '[.[] | select(.state == "FAILURE" or .state == "CANCELLED" or .state == "TIMED_OUT" or .state == "ERROR" or .state == "ACTION_REQUIRED" or .state == "STARTUP_FAILURE" or .state == "STALE")] | length' <<<"$checks")"
  pending="$(jq '[.[] | select(.state == "PENDING" or .state == "IN_PROGRESS" or .state == "QUEUED" or .state == "WAITING" or .state == "REQUESTED" or .state == "EXPECTED")] | length' <<<"$checks")"
  skipped="$(jq '[.[] | select(.state == "SKIPPED" or .state == "NEUTRAL")] | length' <<<"$checks")"
fi

# The marker text is forgeable: any commenter can paste a typed block carrying
# the current head SHA, and `last` would then pick the forgery over the bot's
# review. Author first, marker second. Two review-only markers select the
# comment: the typed block, and the guide header's `<!-- pr-agent:review:full`.
# The guide marker carries the review kind, and an incremental review writes
# `:incremental` instead (finding 6488fe1fce59): matching only `:full` read a
# clean incremental review as no review at all, so both kinds are a review.
# The block is not always emitted (a clean review carries none: #112 and #134
# had zero findings and no block, while #99, #133 and #136 had findings and one),
# and the guide does not always name its commit (#134), so the head also comes
# from the persistent review line, read in the selected review and nowhere else
# (finding bed8f31fda88): an older review's line named a head this one never
# judged, so the gate called that stale where the failure was that no run of this
# review recorded anything at all.
REVIEW_BOT_LOGIN="${REVIEW_BOT_LOGIN:-github-actions[bot],github-actions}"
[[ "$REVIEW_BOT_LOGIN" =~ ^[A-Za-z0-9-]+(\[bot\])?(,[A-Za-z0-9-]+(\[bot\])?)*$ ]] \
  || err "REVIEW_BOT_LOGIN is not a login list: $REVIEW_BOT_LOGIN" "pass comma-separated GitHub logins, e.g. github-actions[bot]" 2
# Every marker below is read on the body with code blocks removed: a review that
# quotes the block, or the guide marker, in an example is writing about one, not
# carrying one (finding f7d291ec6f97). `defenced` drops a ``` or ~~~ fence and an
# indented code block, the two forms GitHub renders as text rather than markup
# (finding e6024f4c203c: an indented quote carrying `complete: true` cleared the
# gate). The state-block awk below starts a block only at column 0, the position a
# run writes one in, so the same quotes cannot reach the JSON either; one fixture
# pins both, so the two cannot drift. `is_review` is the review identity, and it is
# what a comment must be before it can name a head (finding 33acdf68e0d2).
JQ_SELECT='
def defenced: reduce (split("\n")[]) as $l ({f: false, keep: []};
    if ($l | test("^[[:space:]]*(```|~~~)")) then .f |= not
    elif (.f or ($l | test("^( {4}|\t)"))) then .
    else .keep += [$l] end) | .keep | join("\n");
def is_review: test("(^|\n)[[:space:]]*<!-- pr-agent-review-state:v1|(^|\n)[[:space:]]*<!-- pr-agent:review:(full|incremental)");
[.comments[]
  | select((.author.login // "") as $a | ("$LOGINS" | split(",") | any(. == $a)))] as $c
| ([$c[] | select(.body | defenced | is_review)] | last // {}) as $r
| {review: $r,
   head_from: ((($r.body // "") | defenced
                | (capture("Review updated until commit [^\n]*?commit/(?<s>[0-9a-f]{7,40})")? | .s)) // ""),
   blocks: ([$c[] | select(.body | defenced | test("(^|\n)[[:space:]]*<!-- pr-agent-review-state:v1"))] | length)}'
if ! found="$(gh pr view "$pr" --json comments \
  --jq "${JQ_SELECT//\$LOGINS/$REVIEW_BOT_LOGIN}" 2>"$GERR")"; then
  err "gh pr view comments failed: $(head -1 "$GERR")" "run \`gh auth status\`"
fi
[[ -n "$found" ]] || found='{"review":{},"head_from":""}'
review="$(jq -c '.review' <<<"$found")"
fallback_head="$(jq -r '.head_from // ""' <<<"$found")"
# Whether this PR has ever carried a findings block: a block keeps its resolved
# findings, so a PR with any finding history always has one. Absence is only
# explainable as "no findings yet" when nothing ever recorded one: this counts
# the block-bearing review comments that exist now, and nothing else.
prior_blocks="$(jq -r '.blocks // 0' <<<"$found")"
[[ -n "$review" ]] || review='{}'

review_body="$(jq -r '.body // ""' <<<"$review" 2>/dev/null || echo "")"
review_url="$(jq -r '.url // ""' <<<"$review" 2>/dev/null || echo "")"

# Typed state block pr-agent embeds in the review comment (multi-line HTML comment).
# The start rule must fire once and only on the block itself: the marker is
# quoted inside finding bodies and in prose when the reviewer writes about the
# gate, and a start rule that fires there swallows the JSON line, so a review at
# the right head reads as recording no head. A code block is a quote of one, like
# the prose: a review that shows the block in an example carries none. So the
# marker must be at column 0, which is where a run writes it (findings
# f7d291ec6f97, e6024f4c203c: an indented quote carrying `complete: true` and the
# judged head cleared the gate, with `[[:space:]]*` before the marker).
state_json="$(printf '%s\n' "$review_body" | awk '
  /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
  fence { next }
  !f && /^<!-- pr-agent-review-state:v1/ { f = 1; next }
  f && /^-->/ { exit }
  f')"
if [[ -n "$state_json" ]] && jq -e . >/dev/null 2>&1 <<<"$state_json"; then
  complete="$(jq -r '.last_run.complete // false' <<<"$state_json")"
  excluded="$(jq -r '(.last_run.excluded_files // []) | length' <<<"$state_json")"
  findings_total="$(jq -r '(.findings // []) | length' <<<"$state_json")"
  findings_active="$(jq -r '[.findings[]? | select(.state == "ACTIVE")] | length' <<<"$state_json")"
  review_head="$(jq -r '.last_run.head_sha // ""' <<<"$state_json")"
  if [[ "$complete" == "true" && "$excluded" -eq 0 ]]; then
    coverage="full"
  else
    coverage="partial"
  fi
else
  state_json=""
  complete="false"
  findings_total="0"
  findings_active="0"
  review_head=""
  if [[ -z "$review_body" ]]; then
    coverage="unknown"
  elif grep -q "Review coverage" <<<"$review_body"; then
    coverage="partial"
  else
    coverage="full"
  fi
fi

# The block travels with findings, resolved ones included, so a review of a PR
# that ever had a finding always carries one (#99: 32, #133: 4 with 0 active,
# #136: 1, #143: 2 with 0 active). Only a PR the bot has never found anything in
# has no block at all (#112, #134, #144). So absence means "nothing to record"
# only while no block survives on this PR: once one has, its absence is a fault
# to fail on, not a clean review.
#
# `prior_blocks` counts the comments that exist now, which is the bound: the
# review is one comment a run rewrites in place, so a run that wrote it without
# the block erased the only evidence that a block had existed. That absence no
# longer reads as a clean review, since a review with no block fails as
# `unrecorded`, so what the count still buys is the difference between a run that
# dropped a block and a review that never carried one: the same failure, and a
# different repair on each. The reviewer never reads this file (`.pr_agent.toml`
# `repo_context_files` is AGENTS.md, NEXT.md, context.md and PR-AGENT.md), so a
# bound stated only here is re-filed as a finding unless AGENTS.md states it too.
if [[ -z "$state_json" && -n "$review_body" ]]; then
  # The guide header is the evidence: it names the head the run checked out. With
  # no block this head is reported and never clears the gate; it decides which
  # failure a reader is told about, a stale review or an unrecorded one.
  # The span between the phrase and the link is the URL and nothing else: no
  # whitespace and no `)`, so the only `commit/` it can reach is the header's own.
  # An earlier version allowed anything but `)`, so a header with no closing paren
  # let that span run to the end of the line and take the last link on it, which is
  # an older fix the header quotes, not the head. The closing paren stays optional,
  # so a truncated header still matches; a short sha is not accepted, because the
  # template writes all 40 hex.
  review_head="$(sed -n 's/.*Review updated until commit[[:space:]]\{1,\}https:\/\/[^ )]*commit\/\([0-9a-f]\{40\}\).*/\1/p' <<<"$review_body" | head -1)"
  # Then the persistent review line, which is the head a run recorded. A bare
  # `commit/<sha>` in the body is only the last resort: a review that discusses an
  # earlier fix quotes one, so it must never outrank a recorded head (finding
  # 3de53d74d7e9).
  [[ -n "$review_head" ]] || review_head="$fallback_head"
  [[ -n "$review_head" ]] || review_head="$(grep -oE 'commit/[0-9a-f]{7,40}' <<<"$review_body" | tail -1 | cut -d/ -f2)"
  if [[ "$prior_blocks" -eq 0 ]]; then
    [[ -n "$review_head" ]] && complete="unrecorded"
  else
    complete="missing"
  fi
fi

if [[ -n "$review_head" ]]; then
  # A review may quote an abbreviated sha, so a prefix of seven or more hex
  # characters matches in either direction rather than equality (D34). The floor
  # is what stops a truncated or mistyped value from matching a head that merely
  # starts the same way.
  if [[ ${#review_head} -ge 7 && ( "$review_head" == "$head_full"* || "$head_full" == "$review_head"* ) ]]; then
    stale="false"
  else
    stale="true"
  fi
else
  stale="unknown"
fi

risk="$(sed -n 's/.*<strong>Risk level<\/strong>:[[:space:]]*\([^<]*\).*/\1/p' <<<"$review_body" | head -1 | tr '[:upper:]' '[:lower:]' | xargs)"
verdict="$(sed -n 's/.*<strong>Merge recommendation<\/strong>:[[:space:]]*\([^<]*\).*/\1/p' <<<"$review_body" | head -1 | tr '[:upper:]' '[:lower:]' | tr ' ' '_' | xargs)"

[[ -n "$risk" ]] || risk="unknown"
[[ -n "$verdict" ]] || verdict="unknown"
[[ -n "$review_body" ]] && present="true" || present="false"

# `--reviewed` is a different question from `--gate`: whether another review run
# would be reviewing a commit that was not already reviewed, so a verdict that
# asked for changes still counts as reviewed.
if [[ "$reviewed_mode" -eq 1 ]]; then
  covered="false"
  if [[ "$present" == "true" && "$stale" == "false" ]]; then
    # A review with no typed block does not record that its run finished, so it
    # is not a passed review either: another run is exactly what it needs, and
    # skipping that run would leave the gate failed with nothing to repair it.
    [[ "$complete" == "true" ]] && covered="true"
  fi
  printf 'reviewed: %s\npr: %s\nhead: %s\n' "$covered" "$number" "$head"
  [[ "$covered" == "true" ]] && exit 0
  exit 1
fi

if [[ "$gate" -eq 1 ]]; then
  if [[ "$present" != "true" ]]; then
    printf 'gate: fail\npr: %s\nhead: %s\nreason: no review comment from the bot for this PR\nhelp: comment `/review` on the PR to create one\n' "$number" "$head"
    exit 1
  fi
  # A block that vanished after this PR carried one is a fault of the run, not a
  # clean review, so it is named before the stale check: the fault is the run,
  # and a stale head is only its symptom.
  if [[ "$complete" == "missing" ]]; then
    printf 'gate: fail\npr: %s\nhead: %s\nreason: this review has no typed state block although an earlier one on this PR did\nhelp: comment `/review` on the PR to run it again\n' "$number" "$head"
    exit 1
  fi
  if [[ "$stale" != "false" ]]; then
    if [[ "$stale" == "true" ]]; then
      printf 'gate: fail\npr: %s\nhead: %s\nreview_head: %s\nreason: the review does not cover the head being judged\nhelp: comment `/review` on the PR to refresh it\n' "$number" "$head" "${review_head:0:7}"
    elif [[ -n "$state_json" ]]; then
      printf 'gate: fail\npr: %s\nhead: %s\nreason: the review does not record a head commit\nhelp: comment `/review` on the PR to refresh it\n' "$number" "$head"
    else
      printf 'gate: fail\npr: %s\nhead: %s\nreason: the review has no typed state block and does not name the commit it reviewed\nhelp: comment `/review` on the PR to refresh it\n' "$number" "$head"
    fi
    exit 1
  fi
  # The verdict is the merge decision, not a footnote. A review that says
  # `changes required` or `needs review` did not clear the merge, and merging
  # it anyway is the failure this gate exists to catch. It is reported before the
  # block, because it is the reason a reader can act on.
  GATE_VERDICT="${REVIEW_GATE_VERDICT:-no_concerns_found}"
  if [[ "$verdict" != "$GATE_VERDICT" ]]; then
    printf 'gate: fail\npr: %s\nhead: %s\nverdict: %s\nreason: the review did not clear the merge\nhelp: fix the findings, then comment `/review`\n' "$number" "$head" "$verdict"
    exit 1
  fi
  # A clean recommendation is not evidence that the run read the diff: a
  # truncated or timed-out run prints one too. Only the typed block records that
  # a run finished, so only a block that says `complete:true` clears the gate for
  # this head (finding b312598ba745). A review with no block at all cannot be
  # told apart from such a run, so `unrecorded` fails: it is a review nobody
  # recorded, not a clean review nobody had to.
  if [[ "$complete" != "true" ]]; then
    if [[ "$complete" == "unrecorded" ]]; then
      printf 'gate: fail\npr: %s\nhead: %s\nreason: no typed state block, so no completed run is recorded\nhelp: comment `/review` on the PR to run it again\n' "$number" "$head"
    else
      printf 'gate: fail\npr: %s\nhead: %s\nreason: the review did not complete\nhelp: comment `/review` on the PR to run it again\n' "$number" "$head"
    fi
    exit 1
  fi
  printf 'gate: pass\npr: %s\nhead: %s\nreview: current\nverdict: %s\n' "$number" "$head" "$verdict"
  exit 0
fi

printf 'bin: %s\n' "$BIN"
printf 'description: Compact PR review state for agents\n'
printf 'pr:\n'
printf '  number: %s\n' "$number"
printf '  state: %s\n' "$state"
printf '  title: %s\n' "$title"
printf '  head: %s\n' "$head"
printf '  url: %s\n' "$url"
printf 'checks:\n'
printf '  total: %s\n' "$total"
printf '  passed: %s\n' "$passed"
printf '  failed: %s\n' "$failed"
printf '  pending: %s\n' "$pending"
printf '  skipped: %s\n' "$skipped"
printf 'review:\n'
printf '  present: %s\n' "$present"
printf '  stale: %s\n' "$stale"
printf '  risk: %s\n' "$risk"
printf '  verdict: %s\n' "$verdict"
printf '  coverage: %s\n' "$coverage"
printf '  complete: %s\n' "$complete"
printf '  findings: %s\n' "$findings_total"
printf '  active: %s\n' "$findings_active"
if [[ -n "$review_url" ]]; then
  printf '  url: %s\n' "$review_url"
else
  printf '  url: null\n'
fi

if [[ "$show_findings" -eq 1 ]]; then
  if [[ -z "$state_json" ]]; then
    printf 'findings: unknown; the review has no typed state block\n'
  elif [[ "$findings_total" -eq 0 ]]; then
    printf 'findings: 0 findings in this review\n'
  else
    printf 'findings[%s]{id,path,line,state}:\n' "$findings_total"
    jq -r '.findings[]? | [.finding_id, .path, (.line_start|tostring), .state] | join(",")' <<<"$state_json"
  fi
fi

if [[ "$full" -eq 1 && -n "$review_body" ]]; then
  chars="${#review_body}"
  limit=20000
  if [[ "$chars" -gt "$limit" ]]; then
    body="$(tr '\n' ' ' <<<"${review_body:0:$limit}") ... (truncated, $chars chars total)"
  else
    body="$(tr '\n' ' ' <<<"$review_body")"
  fi
  printf 'comment:\n'
  printf '  chars: %s\n' "$chars"
  printf '  body: %s\n' "$body"
fi

if [[ "$present" != "true" ]]; then
  printf 'help[2]:\n'
  printf '  No review comment yet; it is posted when the PR opens\n'
  printf '  Run `gh pr view %s --web` to open the PR\n' "$number"
elif [[ "$stale" == "true" ]]; then
  printf 'help[2]:\n'
  printf '  Review is stale for head %s; run `gh pr comment %s --body "/review"` to refresh\n' "$head" "$number"
  printf '  Run `scripts/review-state.sh %s --findings` to list findings\n' "$number"
elif [[ "$coverage" == "partial" ]]; then
  printf 'help[2]:\n'
  printf '  Coverage is partial; open the PR and read the coverage footer\n'
  printf '  Run `scripts/review-state.sh %s --findings` to list findings\n' "$number"
else
  printf 'help[2]:\n'
  printf '  Run `scripts/review-state.sh %s --findings` to list findings\n' "$number"
  printf '  Run `gh pr view %s --web` to open the PR\n' "$number"
fi
