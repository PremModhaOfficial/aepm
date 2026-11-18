#!/usr/bin/env bash
# Self-check for the superseded-run branch in .github/workflows/review-gate.yml.
#
# Why: that branch decides whether the review gate reports a pass without
# looking at any review. Three shapes matter and each was wrong once:
#   stale run      -> say so, gate nothing (exit 0, stale=true)
#   current run    -> carry on to the review check
#   unreadable PR  -> fail loudly, never "superseded" (an API fault must not
#                     turn into a green check)
#
# The block is extracted from the workflow itself so this cannot drift from it.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
workflow="$repo_root/.github/workflows/review-gate.yml"
block=$(mktemp)
trap 'rm -f "$block" "${case_file:-}" "${out_file:-}"' EXIT

python3 - "$workflow" >"$block" <<'PY'
import sys

text = open(sys.argv[1]).read()
start = text.index('          head="$(gh pr view')
end = text.index('          echo "head=$head"')
# Strip the workflow's YAML indentation (10 spaces) to make a runnable block.
print("\n".join(line[10:] for line in text[start:end].splitlines()))
PY

# Each case: RUN_SHA, the head `gh` reports, expected exit, expected stale flag.
cases=(
  "aaaa bbbb 0 1 stale-run"
  "cccc cccc 0 0 current-run"
  "aaaa '' 1 0 unreadable-head"
)

failures=0
for case in "${cases[@]}"; do
  read -r run_sha head_value want_exit want_stale label <<<"$case"
  case_file=$(mktemp)
  out_file=$(mktemp)
  {
    echo "GITHUB_OUTPUT=$out_file; : >$out_file"
    echo 'RUN_EVENT=pull_request; pr=9'
    printf 'RUN_SHA=%s; HEAD_VALUE=%s\n' "$run_sha" "$head_value"
    echo 'gh() { printf "%s\n" "$HEAD_VALUE"; }'
    cat "$block"
    echo 'echo "gate-continues head=$head"'
  } >"$case_file"

  set +e
  bash "$case_file" >/dev/null 2>&1
  got_exit=$?
  set -e
  got_stale=0
  grep -q 'stale=true' "$out_file" 2>/dev/null && got_stale=1

  if [[ "$got_exit" != "$want_exit" || "$got_stale" != "$want_stale" ]]; then
    echo "FAIL $label: exit $got_exit (want $want_exit), stale $got_stale (want $want_stale)"
    failures=$((failures + 1))
  else
    echo "ok   $label"
  fi
  rm -f "$case_file" "$out_file"
done

[[ "$failures" -eq 0 ]] || { echo "$failures case(s) failed"; exit 1; }
echo "review-gate self-check: 3/3"
