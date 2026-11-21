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
    paginate=0
    while (($#)); do
      case "$1" in
        -X) method="$2"; shift 2 ;;
        --jq) jqexpr="$2"; shift 2 ;;
        --input) input="$2"; shift 2 ;;
        --paginate) paginate=1; shift ;;
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
        # A real `gh api` applies `--jq` once per page and prints each page's
        # result, and it walks the pages only when `--paginate` is given. Honouring
        # both is the point: an unpaginated fetch sees page 1 and nothing else, so
        # a comment on a later page is invisible here exactly as it is on GitHub.
        per=30
        if [[ "$path" == *per_page=* ]]; then
          per="${path##*per_page=}"
          per="${per%%[!0-9]*}"
        fi
        total="$(jq 'length' <<<"${FAKE_COMMENTS:-[]}")"
        pages=$(((total + per - 1) / per))
        ((pages > 0)) || pages=1
        ((paginate)) || pages=1
        for ((i = 0; i < pages; i++)); do
          page="$(jq -c --argjson off "$((i * per))" --argjson per "$per" \
            '.[$off:($off + $per)]' <<<"${FAKE_COMMENTS:-[]}")"
          if [[ -n "$jqexpr" ]]; then
            jq -c "$jqexpr" <<<"$page"
          else
            printf '%s\n' "$page"
          fi
        done
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
checks=0
fail() {
  printf 'FAIL %s: %s\n%s\n' "$1" "$2" "${3:-}"
  failures=$((failures + 1))
}

run_case() { # label, body, author, PR_HEAD, want(patch|none), text, older body, all comments
  local label=$1 original=$2 author=$3 prhead=$4 want=$5 want_text=${6:-} older=${7:-} all=${8:-}
  local patch="$root/patch" comments out rc body state
  checks=$((checks + 1))
  if [[ -n "$all" ]]; then
    comments="$all"
  elif [[ -n "$older" ]]; then
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
checks=$((checks + 1))
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

# #153: an `issue_comment` run carries no pull_request payload, and a body with no
# commit footer leaves the head unknown. The step used to read the PR's current
# head from the API, which is the head at append time rather than the one the
# review read: a push in between was recorded as reviewed and `--gate` then
# passed on a review of an older commit. An unverified head writes nothing, so
# this case asserts that a served head (`FAKE_PULL_HEAD`) is not taken.
WANT_HEAD="$HEAD"
run_case head-from-api "$(guide_body '-' 'No concerns found')" "$BOT" "" none 'names no commit'

# #153: the newest bot review already carries a block, an older one does not.
# Selection is the newest bot review and stops there, so the older review is not
# rewritten with a block naming its own, different head.
WANT_HEAD="$HEAD"
run_case newest-blocked-writes-nothing "$blocked" "$BOT" "" none 'already carries a state block' "$(guide_body "$OLD" 'No concerns found')"

# The oldest matching review wins nothing: a newer clean review is the one the
# gate must read.
WANT_HEAD="$HEAD"
run_case newest-wins "$(guide_body "$HEAD" 'No concerns found')" "$BOT" "" patch 'now records a complete review' "$(guide_body "$OLD" 'Changes required')"

# #153: more than one page of comments, and only the last one is the bot review.
# It sits on page 2 of a 100-per-page list, so an unpaginated fetch cannot see it
# and the step writes nothing. The case asserts the PATCH only a paginated read
# produces, which is what makes it fail when `--paginate` is removed.
WANT_HEAD="$HEAD"
pagination_comments="$(jq -nc --argjson last "$(comment_json "$(guide_body "$HEAD" 'No concerns found')")" \
  '[range(0;100) | {id: (900000000 + .), body: "chatter \(.)", user: {login: "someone"}, author: {login: "someone"}}] + [$last]')"
run_case pagination "$(guide_body "$HEAD" 'No concerns found')" "$BOT" "" patch 'now records a complete review' '' "$pagination_comments"

# #153: the job guard skips a draft and a fork, and the step must say so itself.
# On a draft the `reviewed` step is skipped, its output is empty, and the step's
# own condition was true, so the writer ran for a review the model never made.
# The draft-guard case reads the step's `if:` out of the YAML and compares it with
# the spaces removed, so the check is about the clauses rather than formatting.
checks=$((checks + 1))
# Read as text, not with a parser (#153): a folded scalar's continuation lines are
# deeper than its `if:` key, which is all the structure this needs.
step_if="$(awk '
  /^ *- name: Append the typed review state block *$/ { found = 1; next }
  found && /^ *- name:/ { exit }
  found && !have && /^ *if:/ {
    match($0, /^ */); base = RLENGTH
    rest = substr($0, base + 4)
    sub(/^ */, "", rest)
    have = 1
    if (rest !~ /^[>|]/) print rest
    next
  }
  have {
    if ($0 == "" || (match($0, /^ */) && RLENGTH <= base)) exit
    print
  }' "$WORKFLOW")"
step_if="$(tr -d '[:space:]' <<<"$step_if")"
if [[ -z "$step_if" ]]; then
  fail draft-guard "cannot read the append step's if: from $WORKFLOW"
fi
if [[ -n "$step_if" ]]; then
  for clause in 'github.event.pull_request.draft==false' \
                'github.event.pull_request.head.repo.full_name==github.repository' \
                "github.event_name=='issue_comment'"; do
    [[ "$step_if" == *"$clause"* ]] \
      || fail draft-guard "the append step's if: does not carry '$clause'" "$step_if"
  done
fi

# #153: the `if:` above was read with `python3` and `import yaml`, a dependency
# neither `ci.sh` nor this script declares, so the draft-guard case went red on an
# environment reason rather than a code defect. The step's `if:` is now read as
# text with awk. This case proves the suite needs no python3 at all: it runs itself
# again with a python3 that fails first on PATH, and that shim's message is what
# this asserts on, so an unrelated failure in the nested run is not misreported
# here.
if [[ -z "${PR_AGENT_STATE_BLOCK_NO_PYTHON:-}" ]]; then
  checks=$((checks + 1))
  mkdir -p "$root/nopy"
  printf '#!/bin/sh\necho "python3: command not found" >&2\nexit 127\n' >"$root/nopy/python3"
  chmod +x "$root/nopy/python3"
  set +e
  env PATH="$root/nopy:$PATH" PR_AGENT_STATE_BLOCK_NO_PYTHON=1 \
    bash "${BASH_SOURCE[0]}" >"$root/nopy.log" 2>&1
  set -e
  if [[ ! -s "$root/nopy.log" ]]; then
    fail no-python3 "the suite printed nothing without python3"
  elif grep -q 'python3: command not found' "$root/nopy.log"; then
    fail no-python3 "the suite runs python3" "$(grep -m1 -B3 'python3: command not found' "$root/nopy.log")"
  fi
fi

[[ "$failures" -eq 0 ]] || { echo "$failures case(s) failed"; exit 1; }
echo "pr-agent state block: $checks/$checks"
