#!/usr/bin/env bash
# Self-check for the reporting logic in .github/workflows/review-gate.yml.
#
# Why: that block decides what a merge reads, and each part of it was wrong once.
#   where the verdict goes  a `workflow_run` check lands on the default branch
#                           HEAD, never on the PR head (measured 2026-11-19), so
#                           the verdict must be written onto the head
#   what the verdict is     fail closed: no review, a review of another commit,
#                           or an incomplete run is a failure
#   who it judges           the PR head, pinned with `--sha`, so the commit the
#                           verdict is about and the commit it lands on agree
#   what a stale run does   a push run whose head moved on reports nothing, since
#                           that head has its own run
#   what fails the job      only a fault it cannot decide around: an unreadable
#                           PR head, a base without `--gate`, a refused write. A
#                           review verdict never reddens the default branch.
#
# The block is extracted from the workflow itself so this cannot drift from it:
# delete the reporting from the workflow and this fails rather than passing on a
# script copy nobody runs.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
workflow="$repo_root/.github/workflows/review-gate.yml"

HEAD="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OTHER="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
block="$root/block.sh"

BEGIN='# --- review-gate:begin ---'
END='# --- review-gate:end ---'

if ! grep -qF "$BEGIN" "$workflow" || ! grep -qF "$END" "$workflow"; then
  # No block means no reporting at all. Name what is missing, so reverting this
  # workflow to the version that anchored nothing on the PR head reads as a
  # failed assertion rather than as a broken self-check.
  echo "FAIL report-on-head: $workflow never writes a check-run, so a review verdict has nowhere to land on the PR head"
  grep -q 'check-runs' "$workflow" || echo "  (no check-runs call found)"
  echo "FAIL pinned-head: $workflow does not pin the judged commit, so the verdict and the commit it lands on can drift apart"
  grep -q -- '--sha "\$head"' "$workflow" || echo "  (no --sha \"\$head\" found)"
  echo "FAIL checks-write: $workflow does not grant checks: write, so a verdict written onto the head would be refused"
  grep -q 'checks: write' "$workflow" || echo "  (no checks: write permission found)"
  echo "3 named case(s) failed: the gate reports no verdict on the PR head"
  exit 1
fi

python3 - "$workflow" "$BEGIN" "$END" >"$block" <<'PY'
import sys

text = open(sys.argv[1]).read()
lines = text.splitlines()
start = next(i for i, l in enumerate(lines) if sys.argv[2] in l) + 1
end = next(i for i, l in enumerate(lines) if sys.argv[3] in l)
# Strip the workflow's YAML indentation (10 spaces) to make a runnable block.
print("\n".join(l[10:] for l in lines[start:end]))
PY

# The fake `gh`: one head commit, one run title, a capture of the check-run body
# and a switch for a refused check-run write.
mkdir -p "$root/bin" "$root/scripts"
cat >"$root/bin/gh" <<'GH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  pr) printf '%s\n' "${FAKE_HEAD-}" ;;
  api)
    case " $* " in
      *"actions/runs/"*) printf 'Review PR #%s\n' "${FAKE_TITLE_PR:-9}" ;;
      *"check-runs"*)
        [[ "${FAKE_CHECKRUN_FAIL:-0}" == 1 ]] && { echo "HTTP 403: Resource not accessible by integration" >&2; exit 1; }
        input=""
        prev=""
        for arg in "$@"; do
          [[ "$prev" == "--input" ]] && input="$arg"
          prev="$arg"
        done
        [[ -n "$input" ]] || { echo "fake gh: check-runs without --input" >&2; exit 1; }
        cp "$input" "${FAKE_CHECKRUN:?FAKE_CHECKRUN is required}"
        printf '{}\n'
        ;;
      *) printf '{}\n' ;;
    esac
    ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 1 ;;
esac
GH
chmod +x "$root/bin/gh"

cat >"$root/scripts/review-state.sh" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "--help" ]]; then
  [[ "${FAKE_GATE_FLAG:-1}" == 1 ]] && echo "--gate"
  exit 0
fi
# A verdict is only valid for the commit it was asked about. A block that forgot
# `--sha`, or passed the review run's SHA instead of the PR head, fails here
# rather than passing every case with a verdict about the wrong commit.
pin=""
prev=""
for a in "$@"; do
  [[ "$prev" == "--sha" ]] && pin="$a"
  prev="$a"
done
if [[ "$pin" != "${FAKE_GATE_HEAD:?}" ]]; then
  echo "fake gate: --sha is '$pin', want '$FAKE_GATE_HEAD'" >&2
  exit 9
fi
printf 'gate: %s\npr: 9\nhead: %s\nreason: the review does not cover the head being judged\n' \
  "${FAKE_VERDICT:-pass}" "${FAKE_GATE_HEAD:0:7}"
[[ "${FAKE_VERDICT:-pass}" == "pass" ]] && exit 0
exit 1
SH
chmod +x "$root/scripts/review-state.sh"

# Each case: label, RUN_EVENT, RUN_SHA, RUN_PR, fake PR head, fake verdict,
# expected exit, expected check-run (created|none), expected conclusion,
# expected text in the log, and whether the check-run write is refused.
failures=0
passed=0
CASES="$(grep -c '^run_case ' "$0")"
run_case() {
  local label=$1 event=$2 run_sha=$3 run_pr=$4 fake_head=$5 verdict=$6
  local want_exit=$7 want_body=$8 want_conclusion=$9 want_text=${10:-} write_fail=${11:-0}
  local out_file checkrun case_file out rc body problem=""
  out_file="$root/out"; : >"$out_file"
  checkrun="$root/checkrun"; rm -f "$checkrun"
  case_file="$root/case.sh"
  {
    echo "GITHUB_OUTPUT=$out_file; : >$out_file"
    printf 'RUN_EVENT=%s; RUN_SHA=%s; RUN_PR=%s\n' "$event" "$run_sha" "$run_pr"
    echo 'RUN_BRANCH=main; RUN_ID=42; DEFAULT_BRANCH=main; GH_REPO=o/r'
    echo "GH_TOKEN=x; export FAKE_HEAD='$fake_head' FAKE_CHECKRUN=$checkrun"
    printf 'export FAKE_VERDICT=%s FAKE_TITLE_PR=9 FAKE_CHECKRUN_FAIL=%s\n' "$verdict" "$write_fail"
    printf 'export FAKE_GATE_HEAD=%s\n' "$HEAD"
    printf 'PATH=%s/bin:$PATH\n' "$root"
    cat "$block"
  } >"$case_file"

  set +e
  ( cd "$root" && bash "$case_file" ) >"$root/log" 2>&1
  rc=$?
  set -e
  out="$(cat "$root/log")"

  if [[ "$rc" != "$want_exit" ]]; then
    problem="exit $rc, want $want_exit"
  elif [[ "$want_body" == "created" ]]; then
    if [[ ! -f "$checkrun" ]]; then
      problem="no check-run was created"
    else
      body="$(cat "$checkrun")"
      if [[ "$(jq -r '.head_sha' <<<"$body")" != "$fake_head" ]]; then
        problem="check-run head_sha $(jq -r '.head_sha' <<<"$body"), want $fake_head"
      elif [[ "$(jq -r '.conclusion' <<<"$body")" != "$want_conclusion" ]]; then
        problem="check-run conclusion $(jq -r '.conclusion' <<<"$body"), want $want_conclusion"
      elif [[ "$(jq -r '.name' <<<"$body")" != "Review Gate" ]]; then
        problem="check-run named $(jq -r '.name' <<<"$body"), want Review Gate"
      fi
    fi
  elif [[ "$want_body" == "none" && -f "$checkrun" ]]; then
    problem="a check-run was created, and this case must not create one"
  fi
  if [[ -z "$problem" && -n "$want_text" && "$out" != *"$want_text"* ]]; then
    problem="output has no '$want_text'"
  fi

  if [[ -n "$problem" ]]; then
    printf 'FAIL %s: %s\n%s\n' "$label" "$problem" "$out"
    failures=$((failures + 1))
  else
    passed=$((passed + 1))
    printf 'ok   %s\n' "$label"
  fi
}

# A push run reports on the head it reviewed. A review that did not clear the
# merge is a red check on the head, and the job stays green: its own check is
# anchored on the default branch, where a red mark outlives the PR (#111).
run_case push-passed    pull_request  "$HEAD"  9 "$HEAD" pass 0 created success 'reported on the PR head'
run_case push-findings  pull_request  "$HEAD"  9 "$HEAD" fail 0 created failure 'reported on the PR head'
# A `/review` run checked out the default branch but reviewed the PR, so it
# reports on the head too.
run_case review-passed  issue_comment "$OTHER" 9 "$HEAD" pass 0 created success 'reported on the PR head'
run_case review-failed  issue_comment "$OTHER" 9 "$HEAD" fail 0 created failure 'reported on the PR head'
# The same, with the PR resolved from the run name: a `/review` run carries no
# `pull_requests` entry.
run_case review-resolved issue_comment "$OTHER" "" "$HEAD" fail 0 created failure 'reported on the PR head'
# A push run whose head moved on reviewed a commit that has its own run.
run_case superseded     pull_request  "$OTHER" 9 "$HEAD" fail 0 none  ""          'reports nothing'
# Faults the block cannot decide around: each must fail the job, because a
# silent pass would read as a passing gate.
run_case unreadable-head pull_request "$HEAD"  9 ""      fail 1 none  ""          'cannot read the head'
run_case write-refused   pull_request "$HEAD"  9 "$HEAD" pass 1 none  ""          'Resource not accessible' 1
# A default branch without `--gate` cannot pass either: a neutral result counts
# as a pass.
cat >"$root/scripts/review-state.sh" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == "--help" ]] && exit 0
printf 'gate: pass\n'
SH
chmod +x "$root/scripts/review-state.sh"
run_case no-gate-on-base pull_request "$HEAD"  9 "$HEAD" pass 1 none  ""          'has no review-state.sh --gate'

# A `/review` run that was not authorized changes nothing, so the job never
# starts; that is a workflow-level `if` and is asserted here as text.
grep -q "workflow_run.conclusion == 'skipped'" "$workflow" \
  || { echo "FAIL workflow: the skipped-/review guard is gone from the job condition"; failures=$((failures + 1)); }

[[ "$failures" -eq 0 ]] || { echo "$failures case(s) failed"; exit 1; }
echo "review-gate self-check: $passed/$CASES"
