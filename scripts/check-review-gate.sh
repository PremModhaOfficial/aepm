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

prose_quoted="$(printf 'The stamp skips when the comment already contains `pr-agent-review-state:v1`, so the block is not rewritten.\n\n<!-- pr-agent-review-state:v1\n{\"findings\":[],\"last_run\":{\"complete\":true,\"excluded_files\":[],\"head_sha\":\"%s\"}}\n-->\n<strong>Merge recommendation</strong>: No concerns found\n' "$HEAD")"
export FAKE_COMMENTS="[$(comment "$prose_quoted")]"
run marker-quoted-in-prose 0 'gate: pass'

# Prose alone is not a ledger: a PR that never carried a block must not read as
# one that lost it, or the fix for a clean review would fail on the reviewer
# writing about the marker.
export FAKE_COMMENTS="[$(comment "$(printf 'The gate reads `pr-agent-review-state:v1`, and here is why it matters.\n\n<!-- pr-agent:review:full -->\n<strong>Merge recommendation</strong>: No concerns found\n#### (Review updated until commit https://github.com/o/r/commit/%s)\n' "$HEAD")")]"
run prose-is-not-a-block 0 'gate: pass'

export FAKE_COMMENTS="[$(comment "$(clean_body)")]"
run clean-no-block 0 'gate: pass'

export FAKE_COMMENTS="[$(comment "$(clean_body "$OLD")")]"
run clean-no-block-stale 1 'does not cover the head being judged'

export FAKE_COMMENTS="[$(comment "$(clean_body "$HEAD" 'Changes required')")]"
run clean-no-block-nonclean 1 'did not clear the merge'

nobody="$(printf '<!-- pr-agent:review:full -->\n<strong>Merge recommendation</strong>: No concerns found\n')"
export FAKE_COMMENTS="[$(comment "$nobody")]"
run no-block-no-head 1 'no typed state block'

# A PR that already had a findings ledger keeps one, resolved findings and all
# (#133: 4 findings, 0 active, block present). Absence after that is a fault.
export FAKE_COMMENTS="[$(comment "$(typed_body "$OLD")"), $(comment "$(clean_body)")]"
run block-vanished 1 'although an earlier one on this PR did'

# Same two comments, but the older block is a review of the current head: the
# newest comment still wins, so this stays a fault rather than a pass.
export FAKE_COMMENTS="[$(comment "$(typed_body "$HEAD")"), $(comment "$(clean_body)")]"
run block-vanished-current 1 'although an earlier one on this PR did'

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

# `--reviewed` on a clean block-less review: already reviewed, so no second run.
export FAKE_COMMENTS="[$(comment "$(clean_body)")]"
GATE_ARGS=(--reviewed --sha "$HEAD")
run reviewed-unrecorded 0 'reviewed: true'

export FAKE_COMMENTS="[$(comment "$(clean_body "$OLD")")]"
GATE_ARGS=(--reviewed --sha "$HEAD")
run reviewed-unrecorded-stale 1 'reviewed: false'

# The fallback head comes from the persistent review line only: a `/describe`
# comment quoting the head must not make an older review look current.
export FAKE_COMMENTS="[$(comment "$(printf '<!-- pr-agent:review:full -->\n<strong>Merge recommendation</strong>: No concerns found\n')"), $(comment "$(printf '## PR Description\n\nHead is https://github.com/o/r/commit/%s\n' "$HEAD")")]"
GATE_ARGS=(--gate)
run describe-quotes-head 1 'does not name the commit'

# One comment quoting the phrase without a commit must not kill the whole read.
export FAKE_COMMENTS="[$(comment "$(typed_body "$HEAD")"), $(comment 'Review updated until commit (the line was truncated)')]"
GATE_ARGS=(--gate)
run persisted-line-odd 0 'gate: pass'

# A four-character head is not a prefix match: the floor is what stops a
# truncated value from clearing the gate.
export FAKE_COMMENTS="[$(comment "$(typed_body "${HEAD:0:4}")")]"
run short-head-is-not-current 1 'does not cover the head'
GATE_ARGS=(--reviewed --sha "$HEAD")

export FAKE_COMMENTS="[$(comment "$incomplete")]"
run reviewed-incomplete 1 'reviewed: false'

export FAKE_COMMENTS='[]'
run reviewed-missing 1 'reviewed: false'

GATE_ARGS=(--gate)

# The guide header is the evidence, not the first bare commit link: a clean
# review that discusses an earlier fix quotes one, and reading that as the
# reviewed head judged a current review as stale.
export FAKE_COMMENTS="[$(comment "$(printf 'See commit/%s for the earlier attempt.\n\n%s' "$OLD" "$(clean_body "$HEAD")")")]"
run header-beats-earlier-link 0 'gate: pass'

# The marker in prose is not a review: only a line-start block or the guide
# header selects the comment, so a newer comment merely writing about the
# marker cannot be judged in place of the real review.
export FAKE_COMMENTS="[$(comment "$(typed_body "$HEAD")"), $(comment "$(printf '> the gate reads `<!-- pr-agent-review-state:v1` and commit/%s\n' "$HEAD")")]"
run prose-mention-is-not-a-review 0 'gate: pass'

# A block that vanished after this PR carried one is the run's fault, and it is
# named before staleness: the missing block is the cause, the stale head only
# its symptom.
export FAKE_COMMENTS="[$(comment "$(typed_body "$OLD")"), $(comment "$(clean_body "$OLD")")]"
run missing-block-named-before-stale 1 'no typed state block although an earlier one'

printf 'review gate: %s/%s\n' "$PASSED" "$CASES"
