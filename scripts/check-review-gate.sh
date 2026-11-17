#!/usr/bin/env bash
# Deterministic test for `scripts/review-state.sh --gate`. A fake `gh` supplies
# the meta, checks, and review comment, so the test never touches the network.
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
      if [[ -n "${FAKE_REVIEW:-}" ]]; then
        printf '%s\n' "$FAKE_REVIEW"
      else
        printf '{}\n'
      fi
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

review_json() {
  jq -cn --arg body "$1" '{body: $body, url: "u"}'
}

typed_body() {
  printf '<!-- pr-agent-review-state:v1\n{"findings":[],"last_run":{"complete":true,"excluded_files":[],"head_sha":"%s"}}\n-->\nRisk level: Low\n' "$1"
}

export FAKE_META="{\"number\":21,\"state\":\"OPEN\",\"title\":\"t\",\"headRefOid\":\"$HEAD\",\"url\":\"u\"}"
export FAKE_CHECKS='[]'

run() {
  local name="$1" want_exit="$2" want="$3" out rc
  set +e
  out="$(PATH="$TMP/bin:$PATH" "$STATE" 21 --gate 2>&1)"
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

export FAKE_REVIEW="$(review_json "$(typed_body "$HEAD")")"
run current 0 'gate: pass'

export FAKE_REVIEW="$(review_json "$(typed_body "$OLD")")"
run stale 1 'gate: fail'

export FAKE_REVIEW='{}'
run missing 1 'no review comment'

export FAKE_REVIEW="$(review_json 'Risk level: Medium')"
run untracked 1 'does not record a head'

printf 'review gate: 4/4\n'
