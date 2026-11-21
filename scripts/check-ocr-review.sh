#!/usr/bin/env bash
#Self-test for .github/workflows/ocr-review.yml, the advisory second reviewer.
#
# This workflow has no other check: nothing in ci.sh read it before this file.
# Each assertion below pins a defect that shipped and was caught by a review of
# the workflow itself. They are static because the workflow needs a runner, a
# model key and a live PR; the point is that the *shape* cannot regress silently
# while the behaviour is checked by the review it posts.
#
# The one thing a static check cannot see is whether the review happened. That is
# covered at runtime by the `status == complete` guard, which is asserted here by
# text so a rewrite cannot drop it without this file noticing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF="$ROOT/.github/workflows/ocr-review.yml"
status=0
ok() { printf '  ok   %s\n' "$*"; }
bad() {
    printf '  FAIL %s\n' "$*" >&2
    status=1
}

[[ -f $WF ]] || { printf 'FAIL: missing %s\n' "$WF" >&2; exit 1; }

# 1. A count read from tool output must be a single line. More than one match
#    makes `n` multi-line, $GITHUB_OUTPUT rejects it with an opaque
#    "Invalid format", and the step's own error message never appears.
#    The reduction must sit on the `n=` assignment itself: the pattern in a
#    comment or in the error message would satisfy a file-wide grep while the
#    multi-line value is still written.
count_assign="$(grep -E '^[[:space:]]*n=\$\(' "$WF" || true)"
if [[ $count_assign == *"Will review"* && $count_assign == *"| sed -n '1p')"* ]]; then
    ok "the reviewable-file count is reduced to its first line"
else
    bad "the --preview count is not pinned to one line on the n= assignment: a multi-line n breaks \$GITHUB_OUTPUT with an opaque error"
fi

# 2. A draft must not spend a model call, and neither must a closed or merged PR
#    when a synchronize event races the close.
guards="$(sed -n '/^    if: >-/,/^$/p' "$WF")"
for clause in 'draft == false' "state == 'open'"; do
    if [[ $guards == *"$clause"* ]]; then
        ok "the job skips unauthorised work: ${clause}"
    else
        bad "job if: lost ${clause}: a draft or closed PR will spend a review"
    fi
done

# 3. A failed comment lookup must not be read as "no matching comment", or the
#    run posts a duplicate that the next run cannot find.
# The lookup spans two lines, so a line-based grep cannot see the pipe. Join first.
lookup="$(tr '\n' ' ' <"$WF" | grep -oE 'if ! ids=\$\(gh api[^;]*; then' || true)"
if grep -q 'could not list PR comments' "$WF" \
    && [[ -n $lookup && $lookup != *'|| true'* ]]; then
    ok "a failed comment lookup fails instead of posting a duplicate"
else
    bad "the comment lookup still swallows its exit status: a transient error creates an unfindable duplicate"
fi

# 4. The runtime guard: exit 0 is not a review. An empty comments array is still
#    an array, so status must be checked too or a failed review posts "No findings".
grep -qE '"\$status" *= *"complete"' "$WF" \
    && ok "the artefact guard requires status=complete, not just an empty array" \
    || bad "the artefact guard no longer requires status=complete: a failed review can post 'No findings'"

# 5. The policy must come from the base branch, never the PR head.
grep -q 'git show "${BASE}:.github/ocr/rules.json"' "$WF" \
    && ok "the review policy is read from the base branch" \
    || bad "the policy is no longer read from the base branch: a PR could weaken the rules that judge it"

# 6. The summary must not overstate what ran. Count the numbered assertions in
#    this file and compare with the number the closing line prints, so a new
#    assertion that forgets to bump the message, or a bumped message with no
#    assertion behind it, fails here instead of reading as extra coverage.
self="${BASH_SOURCE[0]}"
n_assertions="$(grep -cE '^# [0-9]+\. ' "$self")"
printed="$(tail -n 1 "$self" | sed -n 's/.*: \([0-9][0-9]*\) assertions hold.*/\1/p')"
if [[ -n $printed && $printed -eq $n_assertions ]]; then
    ok "the summary line counts every numbered assertion (${n_assertions})"
else
    bad "the summary line says '${printed:-?}' but ${n_assertions} numbered assertions ran"
fi

# 7. The rollback must name every file that reads this workflow. `ci.sh` runs
#    this self-test, and this self-test fails when the workflow is absent, so
#    "delete the workflow" alone breaks ./ci.sh.
rollback="$(sed -n '/^## Turn it off/,/^## /p' "$ROOT/docs/OCR-REVIEW.md")"
if [[ $rollback == *scripts/check-ocr-review.sh* && $rollback == *ci.sh* ]]; then
    ok "the rollback names the self-test and the ci.sh line that read the workflow"
else
    bad "the rollback says the workflow has no other readers: deleting it alone breaks ./ci.sh"
fi

((status == 0)) || { printf 'ocr-review self-test FAILED\n' >&2; exit 1; }
printf 'ocr-review self-test: 7 assertions hold\n'
