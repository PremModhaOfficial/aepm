#!/usr/bin/env bash
# Give a review its typed state block when the bot omitted it.
#
# `Review Gate` reads `<!-- pr-agent-review-state:v1 -->` and nothing else. The
# bot emits that block with the findings section, so a review that found nothing
# arrives without one: measured on 2026-11-19, #136 (1 finding) and #133 (4) and
# #143 (2) carried it, #134 and #144 (0 findings each) did not, and a required
# check then blocked a clean pull request.
#
# This is the producer half, and it runs where the trust boundary is: only from
# `review-gate.yml`, which is triggered by `workflow_run` and therefore executes
# the default branch's copy of this file. A block written here is authored by the
# bot through its own token, so `review-state.sh`'s author-first selection keeps
# the anti-forgery property that a `pull_request`-triggered step would lose.
#
# It only ever adds the two facts prose cannot carry — the commit the review was
# about, and whether the run completed — plus an empty findings list that the
# comment already states. It refuses whenever the comment disagrees with that,
# because a manufactured pass over real findings is worse than a red gate.
#
#   scripts/review-state-stamp.sh [<pr>] [<head>]
#
# With no arguments it resolves both the way the gate does, from the triggering
# `workflow_run`. Environment: GH_REPO, GH_TOKEN, and optionally RUN_ID,
# RUN_EVENT, RUN_BRANCH, DEFAULT_BRANCH, REVIEW_BOT_LOGIN.
set -euo pipefail

# Everything below runs before the gate, and this step must never redden `main`:
# a `workflow_run` job's own check is anchored on the default branch, so a failure
# here would leave a red mark that outlives the pull request it described (#111).
# An API fault is therefore a warning, and the gate then reports what it actually
# sees. Only a missing GH_REPO — a broken workflow, not a flaky API — exits 1.
warn() {
    printf '::warning::stamp: %s\n' "$*"
    exit 0
}

GH_REPO="${GH_REPO:-}"
[[ -n "$GH_REPO" ]] || { echo "stamp: GH_REPO is unset" >&2; exit 1; }
BOT_LOGIN="${REVIEW_BOT_LOGIN:-github-actions[bot],github-actions}"

# `skipped` is the normal answer most of the time; it goes to the step summary so
# a reader can see why no block was written without reading the job log.
skip() {
    printf 'stamp: skipped (%s)\n' "$*"
    exit 0
}

pr="${1:-${RUN_PR:-}}"
if [[ -z "$pr" ]]; then
    # A `/review` run carries no `pull_requests` entry and reports the default
    # branch as its head, so its PR comes from its run name, exactly as the gate
    # resolves it.
    if [[ "${RUN_EVENT:-}" == "issue_comment" && "${RUN_BRANCH:-}" == "${DEFAULT_BRANCH:-}" ]]; then
        pr="$(gh api "repos/$GH_REPO/actions/runs/${RUN_ID:-}" --jq .display_title 2>/dev/null \
            | grep -o 'PR #[0-9]\+' | tr -dc '0-9' || true)"
    fi
fi
[[ -n "$pr" ]] || warn "cannot tell which pull request this run reviewed"

head="${2:-}"
if [[ -z "$head" ]]; then
    head="$(gh pr view "$pr" --json headRefOid --jq .headRefOid 2>/dev/null)" || true
fi
[[ -n "$head" ]] || warn "cannot read the head of PR $pr"

comments="$(gh api --paginate --slurp "repos/$GH_REPO/issues/$pr/comments?per_page=100" 2>/dev/null)" \
    || warn "cannot read the comments of PR $pr"

# Bot-authored, last one wins: the guide is the persistent comment, updated in
# place, so the newest bot comment is the current review.
review="$(jq -c --arg bots "$BOT_LOGIN" '
  add
  | [.[]
   | select((.user.login // "") as $a | ($bots | split(",") | any(. == $a)))
   | select(.body | contains("pr-agent:review:full"))]
  | last // empty' <<<"$comments")"

[[ -n "$review" ]] || skip "no review guide comment from the bot"

cid="$(jq -r '.id' <<<"$review")"
body="$(jq -r '.body' <<<"$review")"

# The commit the comment says it reviewed. Without it there is no head evidence,
# and a stamp would assert a completeness nobody can check.
quoted="$(sed -n 's|.*/commit/\([0-9a-f]\{7,40\}\).*|\1|p' <<<"$body" | head -1)"
[[ -n "$quoted" ]] || skip "the review does not name the commit it reviewed"
if [[ "$head" != "$quoted"* ]]; then
    skip "the review quotes ${quoted:0:7}, not the head ${head:0:7}"
fi

# A block the bot wrote for *this* head is left alone. One that names another
# head is replaced: the bot rewrites its persistent comment on every review
# (measured on #146, whose single guide carried the newest head and no trace of
# the previous block), but a bot that appends instead of replacing would
# otherwise leave the gate reading an old commit forever.
if grep -q 'pr-agent-review-state:v1' <<<"$body"; then
    stamped="$(sed -n '/pr-agent-review-state:v1/,/^-->/p' <<<"$body" | sed -n 's/.*"head_sha":"\([0-9a-f]\{7,40\}\)".*/\1/p' | head -1)"
    [[ "$stamped" == "$head"* ]] && skip "the review already carries a typed block for ${head:0:7}"
    body="$(awk '!f && /pr-agent-review-state:v1/{f=1;next} f&&/^-->/{f=0;next} !f' <<<"$body")"
    refreshed=1
fi

# The comment lists findings as `### path:line` sections under a summary. This
# producer cannot enumerate them into the typed schema, and a block claiming
# `findings: []` over a real finding would pass a merge that should not. The
# summary is matched on what the bot writes — "Issues found", "Resolved
# findings" — not on the word "findings" alone.
# Matched on the shapes the bot writes, not on the words: "No issues found" is a
# clean review's own summary, and refusing it would fail the reviews this exists
# to unblock.
if grep -qE '^### .*:[0-9]' <<<"$body" \
    || grep -qE '<summary>[^<]*(⚠[^<]*Issues found|Resolved findings)' <<<"$body"; then
    skip "the review lists findings but carries no usable typed block; refusing to assert an empty list"
fi

# The coverage footer is the bot's own disclosure of what it did not read. The
# counts decide, not the footer's presence: `Review coverage: 9 of 9 files` is a
# complete review. A footer without parseable counts is treated as incomplete,
# because the conservative direction costs a model call and the other costs a
# merge nobody reviewed.
complete=true
if grep -q 'Review coverage' <<<"$body"; then
    complete=false
    if read -r seen total < <(sed -n 's/.*Review coverage:[^0-9]*\([0-9]\+\)[^0-9]\+of[^0-9]*\([0-9]\+\).*/\1 \2/p' <<<"$body" | head -1); then
        [[ -n "${seen:-}" && -n "${total:-}" && "$seen" -ge "$total" ]] && complete=true
    fi
fi

block="$(jq -cn --arg head "$head" --argjson complete "$complete" '{
  schema_version: 1,
  findings: [],
  last_run: {complete: $complete, head_sha: $head, excluded_files: []}
}')"

new_body="$(printf '%s\n\n<!-- pr-agent-review-state:v1\n%s\n-->' "$body" "$block")"
jq -cn --arg body "$new_body" '{body: $body}' \
    | gh api -X PATCH "repos/$GH_REPO/issues/comments/$cid" --input - >/dev/null \
    || warn "cannot update comment $cid"

verb=wrote
[[ -n "${refreshed:-}" ]] && verb=refreshed
printf 'stamp: %s the typed block on PR %s for %s (complete=%s, findings=0)\n' \
    "$verb" "$pr" "${head:0:7}" "$complete"
