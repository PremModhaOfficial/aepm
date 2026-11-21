#!/usr/bin/env bash
# Deterministic test for the step in .github/workflows/pr-agent.yml that appends
# the typed state block to the review comment the pr-agent container posted.
#
# Why: the container is a pinned image that emits no block on a clean review
# (#140), so `review-state.sh` read `present: false` and the Review Gate said "no
# review comment from the bot" about a review that did run. The block is appended
# by the workflow, and a fake `gh` supplies the comments and captures the PATCH,
# so this never touches the network.
#
# The block is extracted from the workflow itself: delete the step and this fails
# rather than passing against a copy nobody runs. The last case feeds the body the
# step wrote back into the real `scripts/review-state.sh --gate`, so the proof is
# that the gate reads it, not that a file looks right.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/pr-agent.yml"
STATE="$ROOT/scripts/review-state.sh"

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
block="$root/block.sh"

BEGIN='# --- pr-agent-state:begin ---'
END='# --- pr-agent-state:end ---'
if ! grep -qF "$BEGIN" "$WORKFLOW" || ! grep -qF "$END" "$WORKFLOW"; then
  echo "FAIL no-step: $WORKFLOW has no state-block step, so a clean review stays unreadable to the gate"
  exit 1
fi
# Strip the workflow's YAML indentation (10 spaces) to make a runnable block.
sed -n "/$BEGIN/,/$END/p" "$WORKFLOW" | sed '1d;$d' | cut -c11- >"$block"

mkdir -p "$root/bin"
cat >"$root/bin/gh" <<'GH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  pr)
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
      *) printf '%s\n' "${FAKE_META:?FAKE_META is required}" ;;
    esac
    ;;
  api)
    shift
    method=GET
    path=""
    input=""
    jqexpr=""
    while (($#)); do
      case "$1" in
        -X) method="$2"; shift 2 ;;
        --jq) jqexpr="$2"; shift 2 ;;
        --input) input="$2"; shift 2 ;;
        -f|-F) shift 2 ;;
        -*) shift ;;
        *) path="$1"; shift ;;
      esac
    done
    case "$path" in
      */issues/*comments*)
        if [[ "$method" == PATCH ]]; then
          cp "$input" "${FAKE_PATCH:?FAKE_PATCH is required}"
          printf '{}\n'
          exit 0
        fi
        if [[ -n "$jqexpr" ]]; then
          jq -r "$jqexpr" <<<"${FAKE_COMMENTS:-[]}"
        else
          printf '%s\n' "${FAKE_COMMENTS:-[]}"
        fi
        ;;
      */pulls/*) printf '%s\n' "${FAKE_PULL_HEAD:-}" ;;
      *) printf '{}\n' ;;
    esac
    ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 1 ;;
esac
GH
chmod +x "$root/bin/gh"

BOT="github-actions[bot]"
HEAD="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OLD="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
META="{\"number\":148,\"state\":\"OPEN\",\"title\":\"t\",\"headRefOid\":\"$HEAD\",\"url\":\"u\"}"

# The shape the container actually posts: the guide header, the `pr-agent:review`
# marker, a commit footer, and a merge recommendation row.
guide_body() { # $1 = reviewed head or "-" for no footer, $2 = recommendation or "-"
  printf '## PR Reviewer Guide 🔍\n\n<!-- pr-agent:review:full -->\n'
  [[ "$1" == "-" ]] || printf '#### (Review updated until commit https://github.com/o/r/commit/%s)\n' "$1"
  printf '\n<table>\n<tr><td>⚠️&nbsp;<strong>Risk level</strong>: Low</td></tr>\n'
  [[ "$2" == "-" ]] || printf '<tr><td>✅&nbsp;<strong>Merge recommendation</strong>: %s</td></tr>\n' "$2"
  printf '</table>\n\n<details><summary>Run details</summary>model, tokens, duration</details>\n'
}

# Both key shapes in one fixture: `user` for the REST comment list, `author` for
# `gh pr view --json comments` that review-state.sh reads.
comment_json() { # $1 = body, $2 = login
  jq -cn --arg b "$1" --arg a "${2:-$BOT}" \
    '{id: 7004549373, body: $b, url: "https://github.com/o/r/pull/148#issuecomment-7004549373", user: {login: $a}, author: {login: $a}}'
}

state_of() { # the gate's own extraction, copied from review-state.sh
  printf '%s\n' "$1" | awk '!f && /pr-agent-review-state:v1/{f=1;next} f&&/^-->/{exit} f'
}

failures=0
fail() {
  printf 'FAIL %s: %s\n%s\n' "$1" "$2" "${3:-}"
  failures=$((failures + 1))
}

run_case() { # label, body, author, PR_HEAD, want(patch|none), text, older body
  local label=$1 original=$2 author=$3 prhead=$4 want=$5 want_text=${6:-} older=${7:-}
  local patch="$root/patch" comments out rc body state
  if [[ -n "$older" ]]; then
    comments="[$(comment_json "$older"), $(comment_json "$original" "$author")]"
  else
    comments="[$(comment_json "$original" "$author")]"
  fi
  rm -f "$patch"
  set +e
  env PATH="$root/bin:$PATH" GH_REPO=o/r GH_TOKEN=x PR=148 PR_HEAD="$prhead" \
    BOT_LOGIN="$BOT" FAKE_COMMENTS="$comments" FAKE_PATCH="$patch" \
    FAKE_META="$META" FAKE_PULL_HEAD="$HEAD" \
    bash "$block" >"$root/log" 2>&1
  rc=$?
  set -e
  out="$(cat "$root/log")"

  if [[ "$rc" -ne 0 ]]; then
    fail "$label" "exit $rc, want 0" "$out"
    return 0
  fi
  if [[ -n "$want_text" && "$out" != *"$want_text"* ]]; then
    fail "$label" "output has no '$want_text'" "$out"
    return 0
  fi
  if [[ "$want" == "none" ]]; then
    [[ ! -f "$patch" ]] || fail "$label" "the comment was PATCHed and this case must not write"
    return 0
  fi
  if [[ ! -f "$patch" ]]; then
    fail "$label" "no PATCH was sent" "$out"
    return 0
  fi
  jq -e . "$patch" >/dev/null 2>&1 || { fail "$label" "PATCH payload is not JSON" "$(cat "$patch")"; return 0; }
  body="$(jq -r '.body' "$patch")"
  # The review must survive verbatim above the block.
  if [[ "$body" != "$original"* ]]; then
    fail "$label" "the original body is not an unchanged prefix" "$body"
    return 0
  fi
  # The marker and the closing line must each sit on their own line, and the
  # JSON between them must parse: that is the whole contract the gate relies on.
  grep -qxF '<!-- pr-agent-review-state:v1' <<<"$body" \
    || fail "$label" "no marker line of its own"
  grep -qxF -- '-->' <<<"$body" \
    || fail "$label" "no closing --> line of its own"
  state="$(state_of "$body")"
  jq -e --arg sha "$WANT_HEAD" \
    '.schema_version == 1 and .last_run.complete == true
     and .last_run.head_sha == $sha and (.last_run.excluded_files | length) == 0
     and (.findings | length) == 0' <<<"$state" >/dev/null 2>&1 \
    || fail "$label" "the block does not parse as a complete review of $WANT_HEAD" "$state"
}

# A clean review: the case #140 is about. The block is derived from the body's
# own commit footer, and its verdict comes from the merge recommendation row.
WANT_HEAD="$HEAD"
run_case clean "$(guide_body "$HEAD" 'No concerns found')" "$BOT" "" patch 'now records a complete review'

# The proof that matters: the gate reads what the step wrote.
[[ -f "$root/patch" ]] || { echo "FAIL gate-reads-block: no PATCH to read"; exit 1; }
patched="$(jq -r '.body' "$root/patch")"
set +e
env PATH="$root/bin:$PATH" FAKE_COMMENTS="[$(comment_json "$patched")]" FAKE_META="$META" \
  FAKE_PULL_HEAD="$HEAD" "$STATE" 148 --gate >"$root/gate.log" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] || ! grep -q 'gate: pass' "$root/gate.log"; then
  fail gate-reads-block "the gate did not pass on the body the step wrote" "$(cat "$root/gate.log")"
fi

# Never rewrite a body that already carries a block: a second append would nest
# one block in another, and every later read would see the older head.
blocked="$(guide_body "$HEAD" 'No concerns found')
<!-- pr-agent-review-state:v1
{\"findings\":[],\"last_run\":{\"complete\":true,\"excluded_files\":[],\"head_sha\":\"$HEAD\"}}
-->"
run_case already-blocked "$blocked" "$BOT" "" none 'nothing to append'

# No merge recommendation, no block: this step must never invent a verdict.
run_case no-recommendation "$(guide_body "$HEAD" '-')" "$BOT" "" none 'no merge recommendation'

# The marker is forgeable, and the step writes with `issues: write`: a comment
# that is not the bot's is not a review to annotate.
run_case other-author "$(guide_body "$HEAD" 'No concerns found')" mallory "" none 'nothing to append'

# A body that names no commit was still reviewed at the head this run started
# for, which is the workflow's payload.
WANT_HEAD="$HEAD"
run_case head-from-payload "$(guide_body '-' 'No concerns found')" "$BOT" "$HEAD" patch 'now records a complete review'

# An `issue_comment` run carries no pull_request payload, so a body with no commit
# footer leaves the head to the API. FAKE_PULL_HEAD serves it.
WANT_HEAD="$HEAD"
run_case head-from-api "$(guide_body '-' 'No concerns found')" "$BOT" "" patch 'now records a complete review'

# The oldest matching review wins nothing: a newer clean review is the one the
# gate must read.
WANT_HEAD="$HEAD"
run_case newest-wins "$(guide_body "$HEAD" 'No concerns found')" "$BOT" "" patch 'now records a complete review' "$(guide_body "$OLD" 'Changes required')"

[[ "$failures" -eq 0 ]] || { echo "$failures case(s) failed"; exit 1; }
echo "pr-agent state block: 7/7"
