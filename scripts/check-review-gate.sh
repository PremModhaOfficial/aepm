#!/usr/bin/env bash
# Deterministic test for `scripts/review-state.sh --gate`. A fake `gh` supplies
# the meta, checks, and review comments, so the test never touches the network.
# The fake applies the real `--jq` program to the fixture, so the comment
# selection is exercised too: a test that hands over one pre-filtered comment
# cannot catch a selection bug.
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
    *) printf '%s\n' "${FAKE_META:?FAKE_META is required}" ;;
  esac
  exit 0
fi
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
GH
chmod +x "$TMP/bin/gh"

HEAD="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OLD="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
BOT="github-actions[bot]"

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

run() {
  local name="$1" want_exit="$2" want="$3" assign="${4:-}" out rc
  set +e
  out="$(env $assign PATH="$TMP/bin:$PATH" "$STATE" 21 --gate 2>&1)"
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
  printf 'ok %s\n' "$name"
}

export FAKE_COMMENTS="[$(comment "$(typed_body "$HEAD")")]"
run current 0 'gate: pass'

export FAKE_COMMENTS="[$(comment "$(typed_body "$OLD")")]"
run stale 1 'gate: fail'

export FAKE_COMMENTS='[]'
run missing 1 'from the bot'

export FAKE_COMMENTS="[$(comment 'Risk level: Medium')]"
run untracked 1 'does not record a head'

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
run forged-newer 1 'older than the PR head'

printf 'review gate: 10/10\n'
