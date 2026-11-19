#!/usr/bin/env bash
# Deterministic test for `scripts/review-state-stamp.sh`, the producer half of
# the review gate's typed state block.
#
# A fake `gh` supplies the comments and records the PATCH payload, so the test
# never touches the network and asserts on the block that would have been
# written, not on a message about it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$FAKE_GH_CALLS"
case "$*" in
    *"--paginate --slurp"*"/issues/"*"/comments"*) printf '[%s]\n' "${FAKE_COMMENTS:-[]}" ;;
    "api -X PATCH "*)
        cat >"$FAKE_PATCH_OUT"
        echo '{}'
        ;;
    "pr view "*"--json headRefOid"*)
        if [[ ${FAKE_PR_FAIL:-0} == 1 ]]; then
            echo "HTTP 502: bad gateway" >&2
            exit 1
        fi
        printf '%s\n' "${FAKE_PR_HEAD:-}"
        ;;
    *) echo "fake gh: unexpected call: $*" >&2; exit 1 ;;
esac
GH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export FAKE_GH_CALLS="$TMP/calls"
export FAKE_PATCH_OUT="$TMP/payload.json"
export GH_REPO="o/r"

status=0
ok() { printf '  ok   %s\n' "$*"; }
bad() {
    printf '  FAIL %s\n' "$*" >&2
    status=1
}

HEAD=1111111111111111111111111111111111111111
OTHER=2222222222222222222222222222222222222222
BOT="github-actions[bot]"

# A guide comment as the bot writes it: the two prose cells, the commit it
# reviewed, and no findings section.
guide() {
    local head="${1:-$HEAD}" verdict="${2:-No concerns found}" extra="${3:-}" summary="${4:-No major issues detected}"
    printf '## PR Reviewer Guide 🔍\n\n<!-- pr-agent:review:full -->\n\n#### (Review updated until commit https://github.com/o/r/commit/%s)\n\n<table>\n<tr><td>⚠️&nbsp;<strong>Risk level</strong>: Low</td></tr>\n<tr><td>✅&nbsp;<strong>Merge recommendation</strong>: %s</td></tr>\n<tr><td>⚡&nbsp;<strong>%s</strong></td></tr>\n</table>\n%s' \
        "$head" "$verdict" "$summary" "$extra"
}

# comment <body> [<author>] — one comment, as the REST API returns it.
comment() {
    jq -cn --arg body "$1" --arg user "${2:-$BOT}" '{id: 42, body: $body, user: {login: $user}}'
}

run() {
    rm -f "$FAKE_PATCH_OUT" "$FAKE_GH_CALLS"
    export FAKE_COMMENTS="$1" FAKE_HEAD="${2:-$HEAD}"
    "$ROOT/scripts/review-state-stamp.sh" 7 "$HEAD" 2>&1
}

payload() { jq -r "$1" "$FAKE_PATCH_OUT" 2>/dev/null || echo ""; }
block_of() { jq -r '.body' "$FAKE_PATCH_OUT" | awk '!f && /pr-agent-review-state:v1/{f=1;next} f&&/^-->/{exit} f'; }

# 1. The measured failure: a clean review, no block. It gets the two facts prose
# cannot carry, and an empty findings list the comment already states.
out="$(run "[$(comment "$(guide)")]")" && rc=0 || rc=$?
[[ $rc == 0 ]] || bad "a clean review exited $rc: $out"
block="$(block_of)"
[[ "$(jq -r '.last_run.head_sha' <<<"$block")" == "$HEAD" ]] ||
    bad "the block does not carry the reviewed head: ${block:-no block}"
[[ "$(jq -r '.last_run.complete' <<<"$block")" == "true" ]] ||
    bad "the block does not mark the run complete: ${block:-no block}"
[[ "$(jq -r '.findings | length' <<<"$block")" == "0" ]] ||
    bad "the block does not carry an empty findings list: ${block:-no block}"
[[ $status == 0 ]] && ok "a clean review gets a block naming its head, complete, no findings"

# 2. A review with findings but no block is refused. A block claiming an empty
# findings list over a real finding would pass a merge that must not.
findings="$(printf '\n<details><summary>⚠️ Issues found</summary>\n\n### src/main.rs:12\nA finding.\n</details>\n')"
out="$(run "[$(comment "$(guide "$HEAD" "Changes required" "$findings")")]")"
[[ ! -e "$FAKE_PATCH_OUT" ]] || bad "a review with findings was stamped: $(block_of)"
grep -q 'refusing to assert an empty list' <<<"$out" ||
    bad "refusing a review with findings said something else: $out"
[[ ! -e "$FAKE_PATCH_OUT" ]] && ok "a review listing findings is refused, not stamped empty"

# 2b. The bot's summary is the other shape a findings section takes, and it does
# not contain the word "findings": refusing on `### path:line` alone would stamp
# an empty list over real findings when the headers are missing.
loc="$(printf '\n<details><summary>⚠️ Issues found</summary>\n\nA finding with no header.\n</details>\n')"
out="$(run "[$(comment "$(guide "$HEAD" "Changes required" "$loc")")]")"
[[ ! -e "$FAKE_PATCH_OUT" ]] || bad "a findings summary without headers was stamped: $(block_of)"
grep -q 'refusing to assert an empty list' <<<"$out" ||
    bad "a findings summary without headers said something else: $out"
[[ ! -e "$FAKE_PATCH_OUT" ]] && ok "a findings summary without path:line headers is refused too"

# 3. The coverage footer is the bot's own disclosure that files went unreviewed.
# The block says so, and the gate then fails on it rather than on a missing block.
footer="$(printf '\n---\nReview coverage: 3 of 9 files.\n')"
out="$(run "[$(comment "$(guide "$HEAD" "No concerns found" "$footer")")]")"
[[ "$(jq -r '.last_run.complete' <<<"$(block_of)")" == "false" ]] ||
    bad "a chunked review was stamped complete: $(block_of)"
[[ $status == 0 ]] && ok "a review with a coverage footer is stamped incomplete"

# 3b. A footer that says everything was read is a complete review. The counts
# decide, not the footer's presence; treating the footer alone as incomplete
# would fail every clean review this PR exists to unblock.
fullfoot="$(printf '\n---\nReview coverage: 9 of 9 files.\n')"
out="$(run "[$(comment "$(guide "$HEAD" "No concerns found" "$fullfoot")")]")"
[[ "$(jq -r '.last_run.complete' <<<"$(block_of)")" == "true" ]] ||
    bad "a 9-of-9 coverage footer was stamped incomplete: $(block_of)"
[[ $status == 0 ]] && ok "a coverage footer that read every file is stamped complete"

# 3c. The head lookup is an API call like any other. Its failure must be a
# warning and exit 0, not a red check on main (#111), and its success must stamp.
run_noprhead() {
    rm -f "$FAKE_PATCH_OUT" "$FAKE_GH_CALLS"
    export FAKE_COMMENTS="$1" FAKE_PR_HEAD="$HEAD"
    "$ROOT/scripts/review-state-stamp.sh" 7 2>&1
}
out="$(run_noprhead "[$(comment "$(guide)")]")" && rc=0 || rc=$?
[[ $rc == 0 ]] || bad "an unreadable head exited $rc: $out"
[[ -e "$FAKE_PATCH_OUT" ]] || bad "a readable head from the API did not stamp"
[[ $status == 0 ]] && ok "with no head argument the API supplies it"

rm -f "$FAKE_PATCH_OUT"
export FAKE_PR_FAIL=1
out="$(run_noprhead "[$(comment "$(guide)")]")" && rc=0 || rc=$?
unset FAKE_PR_FAIL
[[ $rc == 0 ]] || bad "an API fault on the head lookup exited $rc: $out"
grep -q '::warning::stamp: cannot read the head' <<<"$out" ||
    bad "an API fault was not a warning: $out"
[[ ! -e "$FAKE_PATCH_OUT" ]] || bad "an API fault still stamped a block"
[[ $status == 0 ]] && ok "an API fault on the head lookup warns and exits 0"

# 4. Idempotent: a block the bot wrote itself is never rewritten.
body="$(guide)"
with_block="$body

<!-- pr-agent-review-state:v1
{\"schema_version\":1,\"findings\":[],\"last_run\":{\"complete\":true,\"head_sha\":\"$HEAD\",\"excluded_files\":[]}}
-->"
out="$(run "[$(comment "$with_block")]")"
[[ ! -e "$FAKE_PATCH_OUT" ]] || bad "an existing block was rewritten"
grep -q 'already carries a typed block' <<<"$out" ||
    bad "an existing block was not reported: $out"
[[ ! -e "$FAKE_PATCH_OUT" ]] && ok "a block the bot wrote is left alone"

# 5. Another commit: the review does not cover the head being judged, so there is
# nothing honest to stamp on it.
out="$(run "[$(comment "$(guide "$OTHER")")]")"
[[ ! -e "$FAKE_PATCH_OUT" ]] || bad "a review of another commit was stamped"
grep -q 'not the head' <<<"$out" || bad "a review of another commit said something else: $out"
[[ ! -e "$FAKE_PATCH_OUT" ]] && ok "a review quoting another commit is not stamped onto the head"

# 6. The author is the trust boundary: a pull request can paste the guide marker
# into its own comment, and the stamp must not reward that with a typed block.
out="$(run "[$(comment "$(guide)" "someone-else")]")"
[[ ! -e "$FAKE_PATCH_OUT" ]] || bad "a non-bot comment was stamped"
grep -q 'no review guide comment from the bot' <<<"$out" ||
    bad "a non-bot comment said something else: $out"
[[ ! -e "$FAKE_PATCH_OUT" ]] && ok "a comment the bot did not author is never stamped"

# 7. A block naming another head is replaced, not skipped: a bot that appends
# instead of replacing would otherwise leave the gate reading an old commit.
old_block="$(printf '\n\n<!-- pr-agent-review-state:v1\n{\"schema_version\":1,\"findings\":[],\"last_run\":{\"complete\":true,\"head_sha\":\"%s\",\"excluded_files\":[]}}\n-->' "$OTHER")"
out="$(run "[$(comment "$(guide)$old_block")]")"
[[ -e "$FAKE_PATCH_OUT" ]] || bad "a block naming another head was not refreshed"
grep -q 'refreshed the typed block' <<<"$out" || bad "a refresh said something else: $out"
[[ "$(jq -r '.body' "$FAKE_PATCH_OUT" | grep -c 'pr-agent-review-state:v1')" == "1" ]] ||
    bad "a refresh left more than one block in the comment"
[[ "$(jq -r '.last_run.head_sha' <<<"$(block_of)")" == "$HEAD" ]] ||
    bad "a refresh did not rewrite the head: $(block_of)"
[[ $status == 0 ]] && ok "a block naming another head is replaced with one for the head"

((status == 0)) || { printf 'review-state-stamp self-test FAILED\n' >&2; exit 1; }
printf 'review-state-stamp self-test: 11 assertions hold\n'
