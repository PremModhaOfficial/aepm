#!/usr/bin/env bash
# F4: an open PR whose head conflicts with its base runs no workflow at all.
#
# GitHub builds a test merge into refs/pull/<n>/merge before it starts
# `pull_request` workflows. If that merge cannot be built the ref does not
# exist, no run is created, and every required status context stays absent —
# so the PR shows no red check, no green check, and cannot be merged. Measured
# on #147 (head 1f6d484): actions/runs for that branch returned total_count 0
# while the same head rebased onto main started CI, Sim and Review.
#
# That state is invisible in the UI: a "waiting for status" PR and a broken one
# look identical. This turns it into a named failure.
#
# A PR this check could not read is not a PR it may call clean (finding
# 6ea304eea0b7): the list endpoint answers `mergeable: null` while GitHub is
# still computing the test merge, so a recently pushed or not-yet-recomputed
# conflicted PR would have been dropped and the job would have printed success.
# An unknown row is re-queried by number with a bounded retry, and whatever
# stays unknown fails with exit 2.
#
# Usage:
#   check-pr-conflicts.sh [--self-test]
#   gh api --paginate 'repos/O/R/pulls?state=open&per_page=100' | check-pr-conflicts.sh
#
# Exit 0: every open PR is known to be mergeable. Exit 1: at least one is
# conflicted, listed. Exit 2: the input was not a PR array, or a PR stayed
# unknown past the retries (never pass a PR this check could not evaluate).
set -euo pipefail

# Bounded, because the re-query happens inside a job with a 5-minute timeout.
# Tuning floor: GitHub computes mergeability in seconds after a push, so three
# attempts two seconds apart covers the normal case; the exit stays loud.
RETRIES=${PR_CONFLICTS_RETRIES:-3}
RETRY_SLEEP=${PR_CONFLICTS_RETRY_SLEEP:-2}
# An unvalidated bound is not a bound: `[ "$attempt" -ge x ]` errors on a
# non-numeric value, and 0 retries would drop a null row as if it were clean.
for pair in "PR_CONFLICTS_RETRIES:1:$RETRIES" "PR_CONFLICTS_RETRY_SLEEP:0:$RETRY_SLEEP"; do
  name=${pair%%:*}; rest=${pair#*:}; min=${rest%%:*}; val=${rest#*:}
  case "$val" in
    ''|*[!0-9]*) echo "$name must be a non-negative integer, got '$val'" >&2; exit 2 ;;
  esac
  [ "$val" -ge "$min" ] || { echo "$name must be >= $min, got '$val'" >&2; exit 2; }
done

# `gh api --paginate` prints one array per page, so the pages are slurped and
# concatenated here rather than in the caller: a caller that forgot to flatten
# would silently read page 1 only (finding 4a5a9f1d9e0b).
flatten() { jq -sc 'if length == 0 then [] else add end'; }

# One PR's mergeability, straight from the pull endpoint. Prints false|true|null.
resolve_mergeable() {
  local n=$1 attempt=1 body value=null
  while :; do
    body="$(gh api "repos/${GITHUB_REPOSITORY}/pulls/$n" 2>/dev/null)" || body=""
    value="$(printf '%s' "$body" \
      | jq -r 'if type == "object" then (.mergeable | tostring) else "null" end' 2>/dev/null)" \
      || value=null
    case "$value" in
      true|false) printf '%s\n' "$value"; return 0 ;;
    esac
    [ "$attempt" -ge "$RETRIES" ] && break
    attempt=$((attempt + 1))
    [ "$RETRY_SLEEP" = 0 ] || sleep "$RETRY_SLEEP"
  done
  printf 'null\n'
}

self_test() {
  local ok=0 fail=0
  # Not `local`: the EXIT trap fires after the function's scope is gone.
  self_root="$(mktemp -d)"
  root="$self_root"
  trap 'rm -rf "$self_root"' EXIT
  mkdir -p "$root/bin"
  # Answers the per-PR re-query from FAKE_MERGE_SEQ (comma separated, the last
  # value repeats), so a bounded retry is testable without waiting for it.
  cat >"$root/bin/gh" <<'GH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = api ] || { echo "fake gh: unexpected call: $*" >&2; exit 1; }
count=0
[ -f "${FAKE_GH_COUNTER:?}" ] && count="$(cat "$FAKE_GH_COUNTER")"
count=$((count + 1))
printf '%s' "$count" >"$FAKE_GH_COUNTER"
IFS=',' read -r -a seq <<<"${FAKE_MERGE_SEQ:-null}"
idx=$((count - 1))
((idx < ${#seq[@]})) || idx=$((${#seq[@]} - 1))
printf '{"mergeable": %s}\n' "${seq[$idx]}"
GH
  chmod +x "$root/bin/gh"

  t() { # name, json, want exit, mergeable sequence served to re-queries
    local name="$1" json="$2" want="$3" seq="${4:-null}" got=0
    rm -f "$root/count"
    printf '%s' "$json" | env PATH="$root/bin:$PATH" GITHUB_REPOSITORY=o/r \
      PR_CONFLICTS_RETRY_SLEEP=0 FAKE_GH_COUNTER="$root/count" FAKE_MERGE_SEQ="$seq" \
      bash "${BASH_SOURCE[0]}" >"$root/out" 2>&1 || got=$?
    if [ "$got" = "$want" ]; then ok=$((ok + 1)); printf 'ok   %s\n' "$name"
    else
      fail=$((fail + 1))
      printf 'FAIL %s: exit %s, want %s\n%s\n' "$name" "$got" "$want" "$(cat "$root/out")" >&2
    fi
  }

  t "a conflicted open PR is a failure" \
    '[{"number":147,"mergeable":false,"head":{"ref":"docs/ci-failure-inventory"}}]' 1
  t "a clean PR passes" \
    '[{"number":155,"mergeable":true,"head":{"ref":"docs/pr-triage"}}]' 0
  t "mergeable:null that resolves to true passes" \
    '[{"number":156,"mergeable":null,"head":{"ref":"docs/prose-claim-rule"}}]' 0 true
  t "mergeable:null that resolves to false is a failure" \
    '[{"number":156,"mergeable":null,"head":{"ref":"docs/prose-claim-rule"}}]' 1 false
  t "mergeable:null that stays null is exit 2, not a pass" \
    '[{"number":157,"mergeable":null,"head":{"ref":"docs/x"}}]' 2 null
  t "a null that clears on the second attempt is retried" \
    '[{"number":158,"mergeable":null,"head":{"ref":"docs/y"}}]' 1 'null,false'
  t "one conflict among many still fails" \
    '[{"number":1,"mergeable":true,"head":{"ref":"a"}},{"number":2,"mergeable":false,"head":{"ref":"b"}}]' 1
  t "a conflict on a later page still fails" \
    '[{"number":1,"mergeable":true,"head":{"ref":"a"}}][{"number":2,"mergeable":false,"head":{"ref":"b"}}]' 1
  t "no open PRs passes" '[]' 0
  t "an empty read is not a pass" '' 2
  t "unreadable input is exit 2, not a pass" 'not json' 2
  # `[[1,2]]` is an array of arrays, so the shape check above let it through and
  # the row loop then read nothing and reported clean.
  t "a row that is not a PR object is exit 2, not a pass" '[[1,2]]' 2
  t "a PR object with no number is exit 2, not a pass" \
    '[{"mergeable":true,"head":{"ref":"a"}}]' 2
  t "an empty head ref is '?', so a conflict on it is not read as clean" \
    '[{"number":160,"mergeable":false,"head":{"ref":""}}]' 1
  # A bound taken from the environment is validated, not trusted: `-ge` on a
  # non-numeric value errors out, and 0 retries would drop a null row as clean.
  for bad in "PR_CONFLICTS_RETRIES=abc" "PR_CONFLICTS_RETRIES=0" \
             "PR_CONFLICTS_RETRY_SLEEP=x"; do
    got=0
    # A clean PR list, so exit 2 can only come from the bound, not from an
    # unreadable input that also exits 2.
    printf '%s' '[{"number":1,"mergeable":true,"head":{"ref":"a"}}]' \
      | env "$bad" PATH="$root/bin:$PATH" GITHUB_REPOSITORY=o/r \
        bash "${BASH_SOURCE[0]}" >"$root/out" 2>&1 || got=$?
    if [ "$got" = 2 ]; then ok=$((ok + 1)); printf 'ok   %s rejected\n' "$bad"
    else
      fail=$((fail + 1))
      printf 'FAIL %s: exit %s, want 2\n%s\n' "$bad" "$got" "$(cat "$root/out")" >&2
    fi
  done
  printf '\ncheck-pr-conflicts self-test: %d hold, %d failed\n' "$ok" "$fail"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--self-test" ]; then self_test; exit $?; fi

input=$(cat)
if ! printf '%s' "$input" | jq -e -s 'length > 0 and all(.[]; type == "array")' >/dev/null 2>&1; then
  echo "check-pr-conflicts: input is not a JSON array of open PRs; refusing to report 'no conflicts'" >&2
  exit 2
fi
# An array of arrays is not an array of PRs: `[[1,2]]` passed the check above,
# then jq failed on `.number` of a number, the row loop read no rows, and this
# printed "no conflicted open PRs" with exit 0 — the false green it exists to
# stop. Every element of every page must be an object carrying a number.
if ! printf '%s' "$input" | jq -e -s 'all(add[]; type == "object" and has("number"))' >/dev/null 2>&1; then
  echo "check-pr-conflicts: an open-PR row is not an object with a number; refusing to report 'no conflicts'" >&2
  exit 2
fi
if ! prs=$(printf '%s' "$input" | flatten); then
  echo "check-pr-conflicts: could not read the open-PR rows; refusing to report 'no conflicts'" >&2
  exit 2
fi

conflicts=()
unknown=()
# The projection's failure is not swallowed: `done <<<"$(...)"` cannot report
# its exit status, so a jq error there read no rows and printed "no conflicted
# open PRs". Projected first, checked, then read.
if ! rows=$(printf '%s' "$prs" \
  | jq -r '.[] | [(.number | tostring), (.head.ref | if . == null or . == "" then "?" else . end), (.mergeable | tostring)] | @tsv'); then
  echo "check-pr-conflicts: could not project the open-PR rows; refusing to report 'no conflicts'" >&2
  exit 2
fi

while IFS=$'\t' read -r num ref mergeable; do
  [ -n "${num:-}" ] || continue
  case "$mergeable" in
    false) conflicts+=("#$num  $ref") ;;
    null)
      if ! command -v gh >/dev/null 2>&1; then
        echo "check-pr-conflicts: gh is missing, so #$num's mergeability cannot be re-queried" >&2
        unknown+=("#$num  $ref")
        continue
      fi
      case "$(resolve_mergeable "$num")" in
        false) conflicts+=("#$num  $ref") ;;
        true) ;;
        *) unknown+=("#$num  $ref") ;;
      esac
      ;;
  esac
done <<<"$rows"

if [ "${#conflicts[@]}" -gt 0 ]; then
  printf 'conflicted open PRs (no workflow can start, so required checks never appear):\n' >&2
  printf '%s\n' "${conflicts[@]}" >&2
fi
if [ "${#unknown[@]}" -gt 0 ]; then
  printf 'open PRs whose mergeability stayed unknown after %s attempt(s), so this check cannot clear them:\n' \
    "$RETRIES" >&2
  printf '%s\n' "${unknown[@]}" >&2
fi
if [ "${#conflicts[@]}" -gt 0 ]; then exit 1; fi
if [ "${#unknown[@]}" -gt 0 ]; then exit 2; fi
echo "no conflicted open PRs"
