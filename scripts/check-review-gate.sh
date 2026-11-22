#!/usr/bin/env bash
# Deterministic test for the review surface: `scripts/review-state.sh --gate`
# and `--reviewed`. A fake `gh` supplies the meta, checks, review comments and
# API calls, so the test never touches the network. The fake
# applies the real `--jq` program to the fixture, so the comment selection is
# exercised too: a test that hands over one pre-filtered comment cannot catch a
# selection bug.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$ROOT/scripts/review-state.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
set -u
sub="${1:-} ${2:-}"
if [[ "$sub" == "pr checks" ]]; then
  if [[ "${FAKE_CHECKS_FAIL:-0}" == 1 ]]; then
    echo "HTTP 403: Resource not accessible by integration" >&2
    exit 1
  fi
  printf '%s\n' "${FAKE_CHECKS:-[]}"
  exit 0
fi
if [[ "$sub" == "pr view" ]]; then
  case " $* " in
    *" --json comments "*)
      expr=""
      prev=""
      for arg in "$@"; do
        [[ "$prev" == "--jq" ]] && expr="$arg"
        prev="$arg"
      done
      [[ -n "$expr" ]] || { echo "fake gh: no --jq program" >&2; exit 1; }
      jq -c "$expr" <<<"{\"comments\":${FAKE_COMMENTS:-[]}}"
      ;;
    *" --json isDraft,isCrossRepository "*)
      if [[ -n "${FAKE_PR_FLAGS:-}" ]]; then
        printf '%s\n' "$FAKE_PR_FLAGS"
      else
        printf '{"isDraft":false,"isCrossRepository":false}\n'
      fi
      ;;
    *)
      if [[ "${FAKE_META_FAIL:-0}" == 1 ]]; then
        echo "HTTP 404: Not Found" >&2
        exit 1
      fi
      printf '%s\n' "${FAKE_META:?FAKE_META is required}"
      ;;
  esac
  exit 0
fi
if [[ "${1:-}" == "api" ]]; then
  shift
  method=GET
  path=""
  jqexpr=""
  while (($#)); do
    case "$1" in
      -X) method="$2"; shift 2 ;;
      --jq) jqexpr="$2"; shift 2 ;;
      -f|-F) shift 2 ;;
      -*) shift ;;
      *) path="$1"; shift ;;
    esac
  done
  printf '%s %s\n' "$method" "$path" >>"${FAKE_CALLS:-/dev/null}"
  [[ "$method" == GET ]] || exit 0
  if [[ -n "$jqexpr" ]]; then
    # `gh api --jq` prints a string result raw, not JSON-quoted.
    jq -r "$jqexpr" <<<"${FAKE_API_COMMENTS:-[]}"
  else
    printf '%s\n' "${FAKE_API_COMMENTS:-[]}"
  fi
  exit 0
fi
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
GH
chmod +x "$TMP/bin/gh"

HEAD="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OLD="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
BOT="github-actions[bot]"

# A clean review carries no typed block: five sampled PRs had one exactly when
# findings existed (#99: 32, #133: 4, #136: 1; #112 and #134: 0). The comment
# still names the commit it reviewed, so a clean review stays judgeable.
clean_body() {
  local head="${1:-$HEAD}" verdict="${2:-No concerns found}"
  printf '## PR Reviewer Guide 🔍\n\n<!-- pr-agent:review:full -->\n\n<table>\n<tr><td>⚠️&nbsp;<strong>Risk level</strong>: Low</td></tr>\n<tr><td>✅&nbsp;<strong>Merge recommendation</strong>: %s</td></tr>\n</table>\n\n#### (Review updated until commit https://github.com/o/r/commit/%s)\n' "$verdict" "$head"
}

comment() {
  local body="$1" author="${2:-$BOT}"
  jq -cn --arg body "$body" --arg author "$author" \
    '{body: $body, url: "u", author: {login: $author}}'
}

typed_body() {
  local head="$1" verdict="${2:-No concerns found}"
  printf '<!-- pr-agent-review-state:v1\n{"findings":[],"last_run":{"complete":true,"excluded_files":[],"head_sha":"%s"}}\n-->\n<strong>Risk level</strong>: Low\n<strong>Merge recommendation</strong>: %s\n' "$head" "$verdict"
}

export FAKE_META="{\"number\":21,\"state\":\"OPEN\",\"title\":\"t\",\"headRefOid\":\"$HEAD\",\"url\":\"u\"}"
export FAKE_CHECKS='[]'

GATE_ARGS=(--gate)

# What this file declares, counted from its own source: `run` and `check` each add
# a case, and the table row must equal this total whether or not the check that
# compares it runs last (finding 2e69f9e3c720). `CASES` keeps the printed total.
DECLARED=$(( $(grep -c '^run ' "$0") + $(grep -c '^check ' "$0") ))
CASES="$(grep -c '^run ' "$0")"
PASSED=0

run() {
  local name="$1" want_exit="$2" want="$3" assign="${4:-}" out rc
  set +e
  out="$(env $assign PATH="$TMP/bin:$PATH" "$STATE" 21 "${GATE_ARGS[@]}" 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -ne "$want_exit" ]]; then
    printf 'FAIL %s: exit %s, want %s\n%s\n' "$name" "$rc" "$want_exit" "$out"
    exit 1
  fi
  if [[ "$out" != *"$want"* ]]; then
    printf 'FAIL %s: missing %q\n%s\n' "$name" "$want" "$out"
    exit 1
  fi
  PASSED=$((PASSED + 1))
  printf 'ok %s\n' "$name"
}

# A case that asserts on the repository rather than on a gate run: the fixture
# counts itself in both tallies, so the printed total stays honest.
check() {
  local name="$1"
  shift
  if ! "$@"; then
    printf 'FAIL %s\n' "$name"
    exit 1
  fi
  PASSED=$((PASSED + 1))
  CASES=$((CASES + 1))
  printf 'ok %s\n' "$name"
}

export FAKE_COMMENTS="[$(comment "$(typed_body "$HEAD")")]"
run current 0 'gate: pass'

export FAKE_COMMENTS="[$(comment "$(typed_body "$OLD")")]"
run stale 1 'gate: fail'

export FAKE_COMMENTS='[]'
run missing 1 'from the bot'

# A typed block that records no head commit reports that, not staleness.
nohead="$(printf '<!-- pr-agent-review-state:v1\n{"findings":[],"last_run":{"complete":true}}\n-->\n')"
export FAKE_COMMENTS="[$(comment "$nohead")]"
run untracked 1 'does not record a head commit'

# Finding e86b80a0dd79, the first-run bound D33 states: the ledger row is written
# after the gate decides, so the first judged head has no row. What still holds is
# the block itself — one that does not name the judged head fails closed.
emptyhead="$(printf '<!-- pr-agent-review-state:v1\n{"findings":[],"last_run":{"complete":true,"excluded_files":[],"head_sha":""}}\n-->\n<strong>Merge recommendation</strong>: No concerns found\n')"
export FAKE_COMMENTS="[$(comment "$emptyhead")]"
run block-names-no-head 1 'does not record a head commit'

prose_quoted="$(printf 'The stamp skips when the comment already contains `pr-agent-review-state:v1`, so the block is not rewritten.\n\n<!-- pr-agent-review-state:v1\n{\"findings\":[],\"last_run\":{\"complete\":true,\"excluded_files\":[],\"head_sha\":\"%s\"}}\n-->\n<strong>Merge recommendation</strong>: No concerns found\n' "$HEAD")"
export FAKE_COMMENTS="[$(comment "$prose_quoted")]"
run marker-quoted-in-prose 0 'gate: pass'

# Prose alone is not a block: a PR that never carried one must not read as one
# that lost it. It fails as unrecorded, not as vanished.
export FAKE_COMMENTS="[$(comment "$(printf 'The gate reads `pr-agent-review-state:v1`, and here is why it matters.\n\n<!-- pr-agent:review:full -->\n<strong>Merge recommendation</strong>: No concerns found\n#### (Review updated until commit https://github.com/o/r/commit/%s)\n' "$HEAD")")]"
run prose-is-not-a-block 1 'no typed state block'

# Finding b312598ba745: a review with no typed block is `unrecorded`, and a
# truncated or timed-out run that still printed a clean recommendation looks the
# same. Nothing records that the run finished, so nothing passes: this case used
# to merge on its guide header alone.
export FAKE_COMMENTS="[$(comment "$(clean_body)")]"
run unrecorded-clean-does-not-pass 1 'no completed run is recorded'

export FAKE_COMMENTS="[$(comment "$(clean_body "$OLD")")]"
run clean-no-block-stale 1 'does not cover the head being judged'

export FAKE_COMMENTS="[$(comment "$(clean_body "$HEAD" 'Changes required')")]"
run clean-no-block-nonclean 1 'did not clear the merge'

nobody="$(printf '<!-- pr-agent:review:full -->\n<strong>Merge recommendation</strong>: No concerns found\n')"
export FAKE_COMMENTS="[$(comment "$nobody")]"
run no-block-no-head 1 'no typed state block'

# A PR that already had a findings block keeps one, resolved findings and all
# (#133: 4 findings, 0 active, block present). Absence after that is a fault.
export FAKE_COMMENTS="[$(comment "$(typed_body "$OLD")"), $(comment "$(clean_body)")]"
run block-vanished 1 'although an earlier one on this PR did'

# Same two comments, but the older block is a review of the current head: the
# newest comment still wins, so this stays a fault rather than a pass.
export FAKE_COMMENTS="[$(comment "$(typed_body "$HEAD")"), $(comment "$(clean_body)")]"
run block-vanished-current 1 'although an earlier one on this PR did'

# Finding f7d291ec6f97: a fenced code block is a quote, not a marker. An older
# comment showing the block in an example must not make this PR look like one
# that carried a block and lost it, or a clean review fails for the wrong reason.
fenced_quote="$(printf 'A hook would print:\n\n```html\n<!-- pr-agent-review-state:v1\n{"findings":[],"last_run":{"complete":true,"excluded_files":[],"head_sha":"%s"}}\n-->\n```\n' "$OLD")"
export FAKE_COMMENTS="[$(comment "$fenced_quote"), $(comment "$(clean_body)")]"
run fenced-block-is-not-a-prior-block 1 'no completed run is recorded'

# The same rule where the block is read: a review that shows the block in an
# example carries none, so a quoted `complete: true` cannot clear the gate.
fenced_in_review="$(printf '<!-- pr-agent:review:full -->\n<strong>Merge recommendation</strong>: No concerns found\n#### (Review updated until commit https://github.com/o/r/commit/%s)\n\n```html\n<!-- pr-agent-review-state:v1\n{"findings":[],"last_run":{"complete":true,"excluded_files":[],"head_sha":"%s"}}\n-->\n```\n' "$HEAD" "$HEAD")"
export FAKE_COMMENTS="[$(comment "$fenced_in_review")]"
run fenced-block-in-review-is-not-a-block 1 'no completed run is recorded'

# Finding e6d2f0bb258c named the info-string form: a fence line is the marker plus
# whatever follows it, ` ```json ` as much as ` ``` `. The ```html case above
# skips it on the leading-text rule as well, so this case carries an attribute
# (`~~~text title="example"`), the form only the tick-initial rule can catch: an
# info string with a space in it does not end the line with the marker and a bare
# language.
info_fence="$(printf '<!-- pr-agent:review:full -->\n<strong>Merge recommendation</strong>: No concerns found\n#### (Review updated until commit https://github.com/o/r/commit/%s)\n\n~~~text title="example"\n<!-- pr-agent-review-state:v1\n{"findings":[],"last_run":{"complete":true,"excluded_files":[],"head_sha":"%s"}}\n-->\n~~~\n' "$HEAD" "$HEAD")"
export FAKE_COMMENTS="[$(comment "$info_fence")]"
run info-string-fence-is-not-a-block 1 'no completed run is recorded'

# The other form a review quotes a block in, and the one nothing knew about: an
# HTML example. The fence rules do not apply inside `<pre>`, so a quoted
# `complete: true` with the judged head cleared the gate (finding e6d2f0bb258c).
pre_example="$(printf '<!-- pr-agent:review:full -->\n<strong>Merge recommendation</strong>: No concerns found\n#### (Review updated until commit https://github.com/o/r/commit/%s)\n\n<pre>\n<!-- pr-agent-review-state:v1\n{"findings":[],"last_run":{"complete":true,"excluded_files":[],"head_sha":"%s"}}\n-->\n</pre>\n' "$HEAD" "$HEAD")"
export FAKE_COMMENTS="[$(comment "$pre_example")]"
run pre-example-is-not-a-block 1 'no completed run is recorded'

# The same example form with the other tag name: `<code>` is quoted the same way,
# and both names are one rule (finding e6d2f0bb258c).
code_example="$(printf '<!-- pr-agent:review:full -->\n<strong>Merge recommendation</strong>: No concerns found\n#### (Review updated until commit https://github.com/o/r/commit/%s)\n\n<code>\n<!-- pr-agent-review-state:v1\n{"findings":[],"last_run":{"complete":true,"excluded_files":[],"head_sha":"%s"}}\n-->\n</code>\n' "$HEAD" "$HEAD")"
export FAKE_COMMENTS="[$(comment "$code_example")]"
run code-example-is-not-a-block 1 'no completed run is recorded'

# A fence opener with text before it (`text ```html`). Markdown does not read that
# as a fence — a fence may only be indented three spaces — so the block behind it is
# prose, and it used to clear the gate (finding e6d2f0bb258c, shape 1).
leading_text_fence="$(printf '<!-- pr-agent:review:full -->\n<strong>Merge recommendation</strong>: No concerns found\n#### (Review updated until commit https://github.com/o/r/commit/%s)\n\ntext ```html\n<!-- pr-agent-review-state:v1\n{"findings":[],"last_run":{"complete":true,"excluded_files":[],"head_sha":"%s"}}\n-->\n```\n' "$HEAD" "$HEAD")"
export FAKE_COMMENTS="[$(comment "$leading_text_fence")]"
run leading-text-fence-is-not-a-block 1 'no completed run is recorded'

# Finding e6024f4c203c: a block quoted in an example is not this review's block.
# The example here is indented, its closing `-->` is not, which is the shape that
# used to pass: the block awk started on the indented marker, the JSON behind it
# parsed, and `complete: true` with the judged head cleared the gate. It also
# counted as a block the PR had carried. The awk now starts a block only at
# column 0 and `defenced` drops indented lines, and this one case fails when
# either is reverted.
indented_quote="$(printf '%s\n\nAn older run wrote this:\n\n    <!-- pr-agent-review-state:v1\n    {"findings":[],"last_run":{"complete":true,"excluded_files":[],"head_sha":"%s"}}\n-->\n' "$(clean_body)" "$HEAD")"
export FAKE_COMMENTS="[$(comment "$indented_quote")]"
run indented-block-in-review-is-not-a-block 1 'no completed run is recorded'

# A timed-out or truncated run can still print a clean recommendation.
incomplete="$(printf '<!-- pr-agent-review-state:v1\n{"findings":[],"last_run":{"complete":false,"head_sha":"%s"}}\n-->\n<strong>Risk level</strong>: Low\n<strong>Merge recommendation</strong>: No concerns found\n' "$HEAD")"
export FAKE_COMMENTS="[$(comment "$incomplete")]"
run incomplete 1 'did not complete'

export FAKE_COMMENTS="[$(comment "$(typed_body "$HEAD" 'Changes required')")]"
run changes-required 1 'did not clear the merge'

export FAKE_COMMENTS="[$(comment "$(typed_body "$HEAD" 'Needs review')")]"
run needs-review 1 'did not clear the merge'
# A typed block with no verdict line is not a merge decision.
noverdict="$(printf '<!-- pr-agent-review-state:v1\n{"findings":[],"last_run":{"complete":true,"excluded_files":[],"head_sha":"%s"}}\n-->\n' "$HEAD")"
export FAKE_COMMENTS="[$(comment "$noverdict")]"
run no-verdict 1 'did not clear the merge'

# The escape hatch: a repo that accepts `needs review` says so explicitly.
export FAKE_COMMENTS="[$(comment "$(typed_body "$HEAD" 'Needs review')")]"
run verdict-override 0 'gate: pass' 'REVIEW_GATE_VERDICT=needs_review'

# A commenter cannot pass the gate by pasting the typed block themselves.
export FAKE_COMMENTS="[$(comment "$(typed_body "$HEAD")" "mallory")]"
run forged 1 'from the bot'

# Nor by pasting a newer one after a stale review: the bot's comment still wins
# the selection and still reads as stale.
export FAKE_COMMENTS="[$(comment "$(typed_body "$OLD")"), $(comment "$(typed_body "$HEAD")" "mallory")]"
run forged-newer 1 'does not cover the head being judged'

# `--gate` decides on the review alone, so it must not need the Checks API: a
# workflow can grant `pull-requests: read` and nothing else.
export FAKE_CHECKS_FAIL=1
export FAKE_COMMENTS="[$(comment "$(typed_body "$HEAD")")]"
run no-checks-api 0 'gate: pass'
unset FAKE_CHECKS_FAIL

# A later bot comment from another command must not shadow the review: only
# the typed block identifies one, and `/describe` also prints the guide header,
# `Risk level` and `Merge recommendation`.
describe_body='## PR Reviewer Guide 🔍

<table><tr><td>⚠️ <strong>Risk level</strong>: Low</td></tr>
<tr><td>✅ <strong>Merge recommendation</strong>: No concerns found</td></tr></table>'
export FAKE_COMMENTS="[$(comment "$(typed_body "$OLD")"), $(comment "$describe_body")]"
run describe-newer 1 'does not cover the head being judged'

# The reverse: a describe behind a current review does not break the pass.
export FAKE_COMMENTS="[$(comment "$(typed_body "$HEAD")"), $(comment "$describe_body")]"
run describe-after-review 0 'gate: pass'

# The review body quotes the marker name inside its own findings, so the block
# start must fire once. A start rule that re-triggers on the quoted line eats
# the JSON line and the gate reads "does not record a head" at a real head.
quoted="$(printf '<!-- pr-agent-review-state:v1\n{"findings":[{"body":"the marker is `pr-agent-review-state:v1`","state":"ACTIVE"}],"last_run":{"complete":true,"excluded_files":[],"head_sha":"%s"}}\n-->\n<strong>Merge recommendation</strong>: No concerns found\n' "$HEAD")"
export FAKE_COMMENTS="[$(comment "$quoted")]"
run marker-quoted 0 'gate: pass'

# `--sha` pins the commit the verdict is about. The workflow resolves the PR head
# once and then reports on that exact commit, so a push mid-run cannot make the
# verdict describe one commit and land on another.
export FAKE_COMMENTS="[$(comment "$(typed_body "$HEAD")")]"
GATE_ARGS=(--gate --sha "$HEAD")
run pinned-head 0 'gate: pass'

export FAKE_COMMENTS="[$(comment "$(typed_body "$OLD")")]"
run pinned-other 1 'does not cover the head being judged'

# The pin decides, not the PR's current head: a review of the old commit passes
# when the old commit is what is being judged.
GATE_ARGS=(--gate --sha "$OLD")
run pinned-old-reviewed 0 'gate: pass'

# A short or non-hex pin would compare unequal to every recorded head and read as
# a stale review, which is a verdict about a typo rather than about the PR.
GATE_ARGS=(--gate --sha abc)
run pinned-short 2 'is not a 40-hex commit'

GATE_ARGS=(--gate --sha)
run pinned-missing 2 '--sha needs a commit'

GATE_ARGS=(--gate)

# `--reviewed` is the question the push trigger asks before spending a model
# call: is there a complete review of this exact commit? The verdict is not part
# of it, so a review that asked for changes counts as reviewed, and the commit
# that fixes the findings is a different one.
export FAKE_COMMENTS="[$(comment "$(typed_body "$HEAD" 'Changes required')")]"
GATE_ARGS=(--reviewed --sha "$HEAD")
run reviewed-despite-findings 0 'reviewed: true'

export FAKE_COMMENTS="[$(comment "$(typed_body "$OLD")")]"
run reviewed-stale 1 'reviewed: false'

# `--reviewed` on a block-less review: nothing records that the run finished, so
# it is not reviewed either. Skipping the run would leave the gate failed with
# nothing to repair it, which is why this answers false.
export FAKE_COMMENTS="[$(comment "$(clean_body)")]"
GATE_ARGS=(--reviewed --sha "$HEAD")
run reviewed-unrecorded 1 'reviewed: false'

export FAKE_COMMENTS="[$(comment "$(clean_body "$OLD")")]"
GATE_ARGS=(--reviewed --sha "$HEAD")
run reviewed-unrecorded-stale 1 'reviewed: false'

# The fallback head comes from the persistent review line only: a `/describe`
# comment quoting the head must not make an older review look current.
export FAKE_COMMENTS="[$(comment "$(printf '<!-- pr-agent:review:full -->\n<strong>Merge recommendation</strong>: No concerns found\n')"), $(comment "$(printf '## PR Description\n\nHead is https://github.com/o/r/commit/%s\n' "$HEAD")")]"
GATE_ARGS=(--gate)
run describe-quotes-head 1 'does not name the commit'

# Finding 33acdf68e0d2: only a review comment may name the head. A `/describe`
# comment quoting the persistent review line with the judged head cannot supply
# one, or an older review would read as current off a comment that judged nothing.
# The review here names no commit, so it is reported as naming none rather than as
# a review whose head is current.
export FAKE_COMMENTS="[$(comment "$nobody"), $(comment "$(printf '## PR Description\n\nReview updated until commit https://github.com/o/r/commit/%s\n' "$HEAD")")]"
GATE_ARGS=(--gate)
run fallback-head-from-non-review 1 'does not name the commit'

# One comment quoting the phrase without a commit must not kill the whole read.
export FAKE_COMMENTS="[$(comment "$(typed_body "$HEAD")"), $(comment 'Review updated until commit (the line was truncated)')]"
GATE_ARGS=(--gate)
run persisted-line-odd 0 'gate: pass'

# A four-character head is not a prefix match: the floor is what stops a
# truncated value from clearing the gate.
export FAKE_COMMENTS="[$(comment "$(typed_body "${HEAD:0:4}")")]"
run short-head-is-not-current 1 'does not cover the head'

# D34 (finding 13d53e61b390): seven or more hex characters match as a prefix,
# because a review may quote an abbreviated sha. The decision row and this case
# are what keep the stated rule and the implemented rule the same rule.
export FAKE_COMMENTS="[$(comment "$(typed_body "${HEAD:0:12}")")]"
run prefix-head-is-current 0 'gate: pass'
GATE_ARGS=(--reviewed --sha "$HEAD")

export FAKE_COMMENTS="[$(comment "$incomplete")]"
run reviewed-incomplete 1 'reviewed: false'

export FAKE_COMMENTS='[]'
run reviewed-missing 1 'reviewed: false'

GATE_ARGS=(--gate)

# One green: a pass is a review that recorded a completed run and cleared the
# merge. There is no second green, because a review with nothing recorded is not
# a passing review.
export FAKE_COMMENTS="[$(comment "$(typed_body "$HEAD")")]"
run green 0 'gate: pass'

# The guide header is the evidence, not the first bare commit link: a clean
# review that discusses an earlier fix quotes one, and reading that as the
# reviewed head reported a current review as stale. Neither passes now, so the
# header is proven by which failure is named: a body link read as the head says
# "does not cover", and the header says the head is current and the run is not
# recorded.
export FAKE_COMMENTS="[$(comment "$(printf 'See commit/%s for the earlier attempt.\n\n%s' "$OLD" "$(clean_body "$HEAD")")")]"
run header-beats-earlier-link 1 'no completed run is recorded'

# And with the quote after the header, where only a pattern that reaches the sha
# through the URL can find the header at all.
export FAKE_COMMENTS="[$(comment "$(printf '%s\n\nSee commit/%s for the earlier attempt.\n' "$(clean_body "$HEAD")" "$OLD")")]"
run header-beats-later-link 1 'no completed run is recorded'

# Finding 3de53d74d7e9: a bare link in the body must never outrank the head the
# selected review recorded. Its guide header omits the commit and its body quotes
# an earlier fix, while its own persistent review line names the head being judged
# in a form the header pattern does not take (an abbreviated sha); reading the
# body link first judged this current review as stale.
export FAKE_COMMENTS="[$(comment "$(printf '<!-- pr-agent:review:full -->\n<strong>Merge recommendation</strong>: No concerns found\n\nReview updated until commit https://github.com/o/r/commit/%s\n\nSee commit/%s for the earlier attempt.\n' "${HEAD:0:7}" "$OLD")")]"
run body-link-does-not-beat-recorded-head 1 'no completed run is recorded'

# The marker in prose is not a review: only a line-start block or the guide
# header selects the comment, so a newer comment merely writing about the
# marker cannot be judged in place of the real review.
export FAKE_COMMENTS="[$(comment "$(typed_body "$HEAD")"), $(comment "$(printf '> the gate reads `<!-- pr-agent-review-state:v1` and commit/%s\n' "$HEAD")")]"
run prose-mention-is-not-a-review 0 'gate: pass'

# Finding 6488fe1fce59: pr-agent writes `<!-- pr-agent:review:incremental` for an
# incremental review, and only `:full` matched, so a clean incremental review was
# not a review at all and the gate failed a reviewed head with "no review comment
# from the bot". It still fails — nothing records that the run finished — and the
# named failure is what tells the two readings apart.
incremental="$(printf '## PR Reviewer Guide \U0001F50D\n\n<!-- pr-agent:review:incremental -->\n\n<strong>Merge recommendation</strong>: No concerns found\n#### (Review updated until commit https://github.com/o/r/commit/%s)\n' "$HEAD")"
export FAKE_COMMENTS="[$(comment "$incremental")]"
run incremental-review-is-a-review 1 'no completed run is recorded'

# A truncated header names the head and then quotes an older fix on the same line,
# and a newer bot comment only writes about the guide marker. The header's link is
# the first commit after the phrase, and the marker is only a review at a line
# start, so neither the quoted fix nor the prose comment can move the head.
export FAKE_COMMENTS="[$(comment "$(printf '## PR Reviewer Guide \U0001F50D\n\n<!-- pr-agent:review:full -->\n\n<strong>Merge recommendation</strong>: No concerns found\n#### (Review updated until commit https://github.com/o/r/commit/%s, and the earlier attempt is at commit/%s\n' "$HEAD" "$OLD")"), $(comment "$(printf '> selection matches `<!-- pr-agent:review:full` and names commit/%s\n' "$OLD")")]"
run truncated-header-and-prose-guide-marker 1 'no completed run is recorded'

# A block that vanished after this PR carried one is the run's fault, and it is
# named before staleness: the missing block is the cause, the stale head only
# its symptom.
export FAKE_COMMENTS="[$(comment "$(typed_body "$OLD")"), $(comment "$(clean_body "$OLD")")]"
run missing-block-named-before-stale 1 'no typed state block although an earlier one'

# Finding d5440e1022c1: NEXT.md ticked `Review Gate` as required on `main` while
# AGENTS.md called that same setting one this repo cannot assert. The measurement
# is `gh api .../branches/main/protection`, which no fixture can take without the
# network; what the repo can hold itself to is that both files state it, name the
# three contexts, and neither calls it unassertable. A revert of either file
# fails here instead of waiting for the next review to notice.
authority_matches_next() {
  local f
  # What is asserted here is a fact and not a sentence: which checks one paragraph
  # of a document names, where the required set is configured, and which claim is
  # forbidden outright. A rewording inside a paragraph passes; a paragraph that
  # stops naming a check fails (finding 2e69f9e3c720: a rewording used to fail a
  # behavioural suite).
  flat() { tr '\n' ' ' <"$1" | tr -s ' '; }
  # Paragraphs as single lines, so a claim can be located without pinning its
  # wording. Each pattern narrows what is left: all of them have to be in one
  # paragraph, not merely somewhere in the file.
  para_all() {
    local file="$1" left pat
    shift
    left="$(awk 'BEGIN{RS=""; ORS="\n"} {gsub(/[[:space:]]+/," "); print}' "$file")"
    for pat in "$@"; do
      left="$(grep -F -- "$pat" <<<"$left")" || return 1
      [[ -n "$left" ]] || return 1
    done
  }
  ! grep -qF 'not something this repo can assert' "$ROOT/AGENTS.md" || return 1
  ! grep -qF 'the verdict stays advisory' "$ROOT/AGENTS.md" || return 1
  # Every document that names the required set names all three of them. The README
  # named two and left `Review Gate` out (finding 15e004115e8c), which reads as
  # "advisory" to anyone who follows it. The wrong pair is what is forbidden; that
  # all three are named is the loop below, in each document.
  ! flat "$ROOT/README.md" | grep -qF 'requires `CI (Linux)` and `Arch simulation`' || return 1
  para_all "$ROOT/README.md" 'CI (Linux)' 'Arch simulation' 'Review Gate' || return 1
  for f in "$ROOT/AGENTS.md" "$ROOT/NEXT.md"; do
    flat "$f" | grep -qF 'CI (Linux)' || return 1
    flat "$f" | grep -qF 'Arch simulation' || return 1
    flat "$f" | grep -qF 'Review Gate' || return 1
  done
  for f in "$ROOT/AGENTS.md" "$ROOT/NEXT.md"; do
    grep -qF 'branches/main/protection' "$f" || return 1
  done
  # AGENTS.md must not claim the header is the only head source (finding
  # 6d74deeef539): the code has a persistent review line and a body link after it.
  # One paragraph has to name both mechanisms, so a rewording passes and a dropped
  # fallback fails.
  ! grep -qF "guide header's link only" "$ROOT/AGENTS.md" || return 1
  para_all "$ROOT/AGENTS.md" 'persistent review line' 'commit/<sha>' || return 1
}
check authority-matches-next authority_matches_next

# Two claims the script refutes, both raised on the previous head: `AGENTS.md`
# said the typed block is the only marker that identifies a review, while the
# next sentence says the guide marker selects one too (finding a1a8f8570dc0), and
# D33c called `.github/PR-AGENT.md` "not review input" in the same row that adds
# it to `repo_context_files` (finding b835ca937d10). The policy file is read, so
# the row is held to what it actually configures.
doc_claims_match_code() {
  local flat_d
  flat_d() { tr '\n' ' ' <"$1" | tr -s ' '; }
  # This one stays a sentence, and that is deliberate. A prose-level "does the file
  # mention both words" check is too weak here: AGENTS.md names `typed block` and
  # `clears the gate` in three paragraphs, so deleting the mechanism from this
  # sentence still passes a proximity check, and a softened wording ("the review
  # comment clears the gate") is a false claim about what the gate accepts. The
  # sentence is the contract; rewording it means trading down the review contract
  # and the check moves with it in the same commit (finding 2e69f9e3c720 records
  # this as the one claim whose wording is the fact).
  flat_d "$ROOT/AGENTS.md" | grep -qF 'its typed block clears the gate' || return 1
  ! flat_d "$ROOT/AGENTS.md" | grep -qF 'only its typed block identifies one' || return 1
  if grep -qF '.github/PR-AGENT.md' "$ROOT/.pr_agent.toml"; then
    # Here the wording is the fact: D33c says this file is review input *and* that
    # reading it is bounded by the four files listed; a differently worded title
    # would be a different decision, so the title is asserted as written.
    ! grep -qF 'This file is not review input' "$ROOT/.github/PR-AGENT.md" || return 1
    grep -qF 'This file is review input, bounded' "$ROOT/.github/PR-AGENT.md" || return 1
  fi
}
check doc-claims-match-code doc_claims_match_code

# Finding bed8f31fda88: the fallback head is read from the selected review and
# from no other, so an older review's persistent line cannot supply one. The
# newest review here names no commit at all, which is the state it is reported
# in, rather than the older head being judged in its place.
export FAKE_COMMENTS="[$(comment "$(printf '<!-- pr-agent:review:full -->\n<strong>Merge recommendation</strong>: Needs review\n\nReview updated until commit https://github.com/o/r/commit/%s\n' "$OLD")"), $(comment "$(printf '<!-- pr-agent:review:full -->\n<strong>Merge recommendation</strong>: No concerns found\n')")]"
run fallback-head-from-an-older-review 1 'does not name the commit'

# A bound that lives only in a code comment is re-filed as a finding on the next
# review, so what is asserted is that the finding behind each bound sits on a
# `| D.. |` row of PR-AGENT.md: the row is the record a reviewer reads. The
# wording of the row is not asserted, so a reworded row still passes and a
# deleted row still fails (findings 13d53e61b390, 2e69f9e3c720).
doc_bounds_are_recorded() {
  local id
  for id in 13d53e61b390 e6024f4c203c bed8f31fda88 aab48f179d5e 691bb9dc9491; do
    grep -qE "^\| D[0-9a-z]+ \|.*$id" "$ROOT/.github/PR-AGENT.md" || return 1
  done
}
check doc-bounds-are-recorded doc_bounds_are_recorded

# The evidence table states this suite's count, and a count the run refutes is a
# claim, not evidence: the row said 48/48 while a green run printed 50/50, so the
# table had drifted two cases behind the suite. The row is read for this script's
# own line, so adding a case fails here until the table says what the suite prints.
# This check counts itself, hence the +1 on both sides.
doc_count_matches() {
  local want row
  # The row is compared against what the source declares, not against the counters:
  # a case appended after this check used to raise the printed total without
  # raising the number compared here, so the suite could print 55/55 while the
  # table still said 54/54 (finding 91f0289550e3), and a check that has to run last
  # breaks every later addition (finding 2e69f9e3c720). That the run really counted
  # them is asserted after the last case.
  want="$DECLARED/$DECLARED"
  row="$(grep -oE '^\| `scripts/check-review-gate\.sh` \| [0-9]+/[0-9]+' "$ROOT/.github/PR-AGENT.md" \
    | grep -oE '[0-9]+/[0-9]+' | head -1)"
  [[ -n "$row" ]] || { echo "  (no table row for scripts/check-review-gate.sh)"; return 1; }
  [[ "$row" == "$want" ]] || { echo "  table says $row, the source declares $want"; return 1; }
}
check doc-count-matches-table doc_count_matches

# Every declared case has to have run. A `run` line that was comment out, or a
# `check` that returned before its case, otherwise lowers the printed total with
# nothing comparing it to the source.
[[ "$PASSED" -eq "$DECLARED" ]] \
  || { printf 'FAIL case-count: the run counted %s case(s), the source declares %s\n' "$PASSED" "$DECLARED"; exit 1; }
printf 'review gate: %s/%s\n' "$PASSED" "$CASES"
