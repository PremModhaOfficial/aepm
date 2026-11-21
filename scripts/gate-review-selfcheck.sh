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

# The fake `gh`: one head commit, one run title, a capture of the check-run body,
# and a switch for a refused write.
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
# expected text in the log, and whether the write is refused.
cases=0
failures=0
run_case() {
  local label=$1 event=$2 run_sha=$3 run_pr=$4 fake_head=$5 verdict=$6
  cases=$((cases + 1))
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
cases=$((cases + 1))
grep -q "workflow_run.conclusion == 'skipped'" "$workflow" \
  || { echo "FAIL workflow: the skipped-/review guard is gone from the job condition"; failures=$((failures + 1)); }

# The docs state the protection this gate depends on, so each stated setting
# names a proof that shows it. Narrowing a proof back to the contexts array
# leaves `strict`, admins-enforced and no-force-push as memory, and a doc that
# offers an admin merge as the way past the gate contradicts `enforce_admins`.
#
# Both assertions are functions so the fixtures at the end can hand them the doc
# they must reject: a check that cannot reject its own regression proves nothing
# about the real doc, and the fixture stops a silent revert of either one.

# Prints one line per problem found in a doc's proof of the protection. No
# output means the doc names a proof covering every setting it states beside it.
protection_problems() {
  local doc=$1 cmd line_missing missing="" found=0
  if [[ ! -r "$doc" ]]; then
    printf '%s cannot be read, so its proof cannot be checked\n' "$doc"
    return 0
  fi
  while IFS= read -r cmd; do
    if [[ "$cmd" == *--jq* ]]; then
      # A narrowed proof must name every setting stated beside it. The contexts
      # array carries the "all three required" claim, so it is one of them.
      line_missing=""
      for key in '.required_status_checks.contexts' \
                 '.required_status_checks.strict' \
                 '.enforce_admins.enabled' \
                 '.allow_force_pushes.enabled' \
                 '.allow_deletions.enabled'; do
        case "$cmd" in *"$key"*) ;; *) line_missing="$key" ;; esac
      done
      if [[ -z "$line_missing" ]]; then found=1; else missing="$line_missing"; fi
    else
      # Only a bare `gh api` call prints the whole protection object and so
      # proves all five. Prose that merely names the endpoint proves nothing.
      case "$cmd" in *"gh api"*) found=1 ;; esac
    fi
  done < <(grep -F 'branches/main/protection' "$doc" 2>/dev/null || true)
  # A proof that was deleted, or a doc that cannot be read, is a failure: a
  # claim with no evidence must not pass this check.
  if [[ -n "$missing" ]]; then
    printf '%s proves the required checks without %s, so the setting stated beside it is unsourced\n' "$doc" "$missing"
  elif [[ "$found" -eq 0 ]]; then
    printf '%s states the protection with no proof line, so the claim is unsourced\n' "$doc"
  fi
  return 0
}

# The override must be the mechanism that exists. With admins enforced no merge
# action bypasses the gate, so advising an admin merge sends a reader after a
# button that refuses them, and `no merge bypass` alone names no way forward.
override_problems() {
  local doc=$1 flat phrase
  if [[ ! -r "$doc" ]]; then
    printf '%s cannot be read, so its override cannot be checked\n' "$doc"
    return 0
  fi
  # Squash the newlines: a reflowed paragraph must not decide this assertion.
  flat="$(tr -s '[:space:]' ' ' <"$doc")"
  for phrase in 'Overriding it is an admin merge' 'human override is an admin merge'; do
    case "$flat" in
      *"$phrase"*)
        printf '%s offers an admin merge as the override, which admins-enforced refuses\n' "$doc"
        return 0 ;;
    esac
  done
  case "$flat" in
    *'editing the `main` ruleset or protection'*) ;;
    *) printf '%s names no ruleset or protection edit as the override, so a blocked merge reads as unfixable\n' "$doc" ;;
  esac
  return 0
}

doc_cases=0
docs_ok=0
# Prints what an assertion found wrong with a doc, and counts the case.
doc_case() {  # <label> <problem output>
  local label=$1 problems=$2 problem
  cases=$((cases + 1))
  doc_cases=$((doc_cases + 1))
  if [[ -z "$problems" ]]; then
    docs_ok=$((docs_ok + 1))
    return 0
  fi
  while IFS= read -r problem; do
    echo "FAIL docs: $problem"
  done <<<"$problems"
  echo "  ($label)"
  failures=$((failures + 1))
}

for doc in AGENTS.md .github/PR-AGENT.md; do
  doc_case "$doc protection proof" "$(protection_problems "$repo_root/$doc")"
done
doc_case 'AGENTS.md override' "$(override_problems "$repo_root/AGENTS.md")"

# Fixtures: the docs the assertions above must reject, and the one they must
# still accept. Each is the regression its check exists to catch, so reverting
# the check turns this suite red instead of quietly passing the real docs.
fixture_rejects() {  # <label> <assertion> <want text> <file>
  local label=$1 assertion=$2 want=$3 file=$4 out
  cases=$((cases + 1))
  out="$("$assertion" "$file")"
  if [[ "$out" == *"$want"* ]]; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s: the check accepts a doc where %s (output: %s)\n' "$label" "$want" "${out:-none}"
    failures=$((failures + 1))
  fi
}

fixture_accepts() {  # <label> <assertion> <file>
  local label=$1 assertion=$2 file=$3 out
  cases=$((cases + 1))
  out="$("$assertion" "$file")"
  if [[ -z "$out" ]]; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s: the check rejects a doc that names the whole proof (%s)\n' "$label" "$out"
    failures=$((failures + 1))
  fi
}

fixture="$root/fixture-prose.md"
cat >"$fixture" <<'MD'
The `branches/main/protection` endpoint returns the object the gate reads.
MD
fixture_rejects prose-is-not-proof protection_problems 'with no proof line' "$fixture"

fixture="$root/fixture-narrowed.md"
cat >"$fixture" <<'MD'
`gh api repos/o/r/branches/main/protection --jq '{strict: .required_status_checks.strict, admins: .enforce_admins.enabled, force: .allow_force_pushes.enabled, deletions: .allow_deletions.enabled}'`
MD
fixture_rejects contexts-not-required protection_problems '.required_status_checks.contexts' "$fixture"

fixture="$root/fixture-full.md"
cat >"$fixture" <<'MD'
`gh api repos/o/r/branches/main/protection --jq '{contexts: .required_status_checks.contexts, strict: .required_status_checks.strict, admins: .enforce_admins.enabled, force: .allow_force_pushes.enabled, deletions: .allow_deletions.enabled}'`
MD
fixture_accepts full-proof-is-proof protection_problems "$fixture"

fixture="$root/fixture-no-way-forward.md"
cat >"$fixture" <<'MD'
While `enforce_admins` is on there is no merge bypass.
MD
fixture_rejects bypass-without-mechanism override_problems 'names no ruleset or protection edit' "$fixture"

fixture="$root/fixture-admin-merge.md"
cat >"$fixture" <<'MD'
A human override is an admin merge, and it is a decision, not a formality.
MD
fixture_rejects admin-merge-override override_problems 'offers an admin merge as the override' "$fixture"

# The summary counts the cases that ran. A count typed in as a constant is the
# regression this guards: it keeps printing the old total while the suite grows,
# so a dropped case reads as a pass.
cases=$((cases + 1))
if grep -qE '^echo "review-gate self-check: [0-9]' "${BASH_SOURCE[0]}"; then
  echo "FAIL summary: the case count is typed in, not counted, so it cannot follow the suite"
  failures=$((failures + 1))
fi

# The evidence table states this suite's count, and a count the run refutes is a
# claim, not evidence: the row said 12/12 for a suite that printed 9/9. Read the
# row for this script and compare it with the total counted above, so adding a
# case fails here until the table says what the suite prints (finding
# 91f0289550e3).
#
# Every citation, not just the table row: the decision rows cite the same count,
# and one that is updated while another is left behind shows one suite two
# totals (finding 474daa440a5e), which the table row alone never catches.
cases=$((cases + 1))
doc_row="$(grep -oE '^\| `scripts/gate-review-selfcheck\.sh` \| [0-9]+/[0-9]+' "$repo_root/.github/PR-AGENT.md" \
  | grep -oE '[0-9]+/[0-9]+' | head -1)"
if [[ "$doc_row" != "$cases/$cases" ]]; then
  echo "FAIL doc-count: table says '${doc_row:-nothing}', suite has $cases case(s)"
  failures=$((failures + 1))
fi
while IFS= read -r cite; do
  [[ -n "$cite" && "$cite" != "$cases/$cases" ]] || continue
  echo "FAIL doc-count: a citation says '$cite', suite has $cases case(s)"
  failures=$((failures + 1))
done < <(grep -oE 'scripts/gate-review-selfcheck\.sh [0-9]+/[0-9]+' "$repo_root/.github/PR-AGENT.md" \
  | grep -oE '[0-9]+/[0-9]+')

[[ "$failures" -eq 0 ]] || { echo "$failures of $cases case(s) failed"; exit 1; }
echo "review-gate self-check: $cases/$cases"
echo "review-gate docs name their proof: $docs_ok/$doc_cases"
