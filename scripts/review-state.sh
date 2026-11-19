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
  --gate      exit 1 when the review is missing, older than the head, or does
              not clear the merge
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
# review. Author first, marker second. The marker is the typed block alone:
# `Risk level`, `Merge recommendation` and the guide header are all emitted by
# other bot commands too, and the newest of those shadowed the review.
REVIEW_BOT_LOGIN="${REVIEW_BOT_LOGIN:-github-actions[bot],github-actions}"
[[ "$REVIEW_BOT_LOGIN" =~ ^[A-Za-z0-9-]+(\[bot\])?(,[A-Za-z0-9-]+(\[bot\])?)*$ ]] \
  || err "REVIEW_BOT_LOGIN is not a login list: $REVIEW_BOT_LOGIN" "pass comma-separated GitHub logins, e.g. github-actions[bot]" 2
if ! review="$(gh pr view "$pr" --json comments \
  --jq "[.comments[]
    | select((.author.login // \"\") as \$a | (\"$REVIEW_BOT_LOGIN\" | split(\",\") | any(. == \$a)))
    | select(.body | contains(\"pr-agent-review-state:v1\"))]
    | last // {}" \
  2>"$GERR")"; then
  err "gh pr view comments failed: $(head -1 "$GERR")" "run \`gh auth status\`"
fi
[[ -n "$review" ]] || review='{}'

review_body="$(jq -r '.body // ""' <<<"$review" 2>/dev/null || echo "")"
review_url="$(jq -r '.url // ""' <<<"$review" 2>/dev/null || echo "")"

# Typed state block pr-agent embeds in the review comment (multi-line HTML comment).
# The start rule must fire once: the marker is also quoted inside finding bodies,
# and a start rule that re-triggers on those lines swallows the JSON line.
# The start rule is anchored on the marker being a whole HTML comment, because a
# review that discusses this marker in prose (a finding about the gate itself
# does) otherwise starts the block early and swallows the JSON line: measured on
# PR #146, whose block parsed as nothing and read as "no head recorded" at a real
# head. `<!--` at the start of the line is what a real block has and prose does
# not.
state_json="$(printf '%s\n' "$review_body" | awk '!f && /^[[:space:]]*<!-- pr-agent-review-state:v1/{f=1;next} f&&/^-->/{exit} f')"
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

if [[ -n "$review_head" ]]; then
  [[ "$review_head" == "$head_full" ]] && stale="false" || stale="true"
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
  if [[ "$present" == "true" && "$stale" == "false" && "$complete" == "true" ]]; then
    covered="true"
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
  if [[ "$stale" != "false" ]]; then
    if [[ "$stale" == "true" ]]; then
      printf 'gate: fail\npr: %s\nhead: %s\nreview_head: %s\nreason: the review does not cover the head being judged\nhelp: comment `/review` on the PR to refresh it\n' "$number" "$head" "${review_head:0:7}"
    else
      printf 'gate: fail\npr: %s\nhead: %s\nreason: the review does not record a head commit\nhelp: comment `/review` on the PR to refresh it\n' "$number" "$head"
    fi
    exit 1
  fi
  # A truncated or timed-out run can still print a clean recommendation, so a
  # partial review never counts.
  if [[ "$complete" != "true" ]]; then
    printf 'gate: fail\npr: %s\nhead: %s\nreason: the review did not complete\nhelp: comment `/review` on the PR to run it again\n' "$number" "$head"
    exit 1
  fi
  # The verdict is the merge decision, not a footnote. A review that says
  # `changes required` or `needs review` did not clear the merge, and merging
  # it anyway is the failure this gate exists to catch.
  GATE_VERDICT="${REVIEW_GATE_VERDICT:-no_concerns_found}"
  if [[ "$verdict" != "$GATE_VERDICT" ]]; then
    printf 'gate: fail\npr: %s\nhead: %s\nverdict: %s\nreason: the review did not clear the merge\nhelp: fix the findings, then comment `/review`\n' "$number" "$head" "$verdict"
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
