#!/usr/bin/env bash
# Deterministic test for the step in .github/workflows/pr-conflicts.yml that
# lists open PRs whose head conflicts with its base (F4).
#
# Why: this is the one check whose whole purpose is to catch a stuck PR, and it
# had two ways to print success without having looked. Findings 4a5a9f1d9e0b
# (`gh api` without `--paginate` read page 1 and stopped, so the 101st open PR
# was never inspected) and 6ea304eea0b7 (`mergeable: null` was dropped, so a PR
# GitHub had not finished computing was reported clean). Both are silent greens,
# so every case here asserts the exit code a state must produce.
#
# The step is extracted from the workflow: delete it and this fails rather than
# passing against a copy nobody runs. `gh` is faked and walks pages only when
# `--paginate` is given, exactly as the real one does, so the later-page case
# fails the moment the flag is removed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/pr-conflicts.yml"
DOC="$ROOT/.github/PR-AGENT.md"

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
step="$root/step.sh"

BEGIN='# --- pr-conflicts-step:begin ---'
END='# --- pr-conflicts-step:end ---'
if ! grep -qF "$BEGIN" "$WORKFLOW" || ! grep -qF "$END" "$WORKFLOW"; then
  echo "FAIL no-step: $WORKFLOW has no list step, so a conflicted PR is reported by nothing"
  exit 1
fi
# Strip the workflow's YAML indentation (10 spaces) to make a runnable block.
sed -n "/$BEGIN/,/$END/p" "$WORKFLOW" | sed '1d;$d' | cut -c11- >"$step"

mkdir -p "$root/bin" "$root/seq" "$root/work"
ln -s "$ROOT/scripts" "$root/work/scripts"
cat >"$root/bin/gh" <<'GH'
#!/usr/bin/env bash
# Serves two shapes: the paginated open-PR list from FAKE_PULLS, and one PR from
# FAKE_PULL_SEQ/<number> (one mergeable value per line, the last one repeats).
set -u
if [ "${1:-}" != api ]; then echo "fake gh: unexpected call: $*" >&2; exit 1; fi
shift
if [ "${FAKE_GH_FAIL:-}" = 1 ]; then
  echo "fake gh: HTTP 401: Bad credentials" >&2
  exit 1
fi
paginate=0
path=""
while (($#)); do
  case "$1" in
    --paginate) paginate=1; shift ;;
    -X|-f|-F|--jq|--input) shift 2 ;;
    -*) shift ;;
    *) path="$1"; shift ;;
  esac
done
if [[ "$path" =~ /pulls/([0-9]+)$ ]]; then
  n="${BASH_REMATCH[1]}"
  f="${FAKE_PULL_SEQ:?}/$n"
  if [ ! -f "$f" ]; then echo "fake gh: no canned answer for PR $n" >&2; exit 1; fi
  count=0
  [ -f "$f.count" ] && count="$(cat "$f.count")"
  count=$((count + 1))
  printf '%s' "$count" >"$f.count"
  mapfile -t seq <"$f"
  idx=$((count - 1))
  ((idx < ${#seq[@]})) || idx=$((${#seq[@]} - 1))
  printf '{"number": %s, "mergeable": %s}\n' "$n" "${seq[$idx]}"
  exit 0
fi
all="$(cat "${FAKE_PULLS:?}")"
per=30
if [[ "$path" == *per_page=* ]]; then
  per="${path##*per_page=}"
  per="${per%%[!0-9]*}"
fi
total="$(jq 'length' <<<"$all")"
pages=$(((total + per - 1) / per))
((pages > 0)) || pages=1
# A real `gh api` walks the pages only when told to. An unpaginated fetch sees
# page 1 and nothing else, which is the defect this fixture has to be able to see.
((paginate)) || pages=1
for ((i = 0; i < pages; i++)); do
  jq -c --argjson off "$((i * per))" --argjson per "$per" '.[$off:($off + $per)]' <<<"$all"
done
GH
chmod +x "$root/bin/gh"

failures=0
checks=0
fail() {
  printf 'FAIL %s: %s\n%s\n' "$1" "$2" "${3:-}"
  failures=$((failures + 1))
}

run_case() { # label, pulls json, want exit, must-mention text, "n:v1,v2;m:w" re-query answers
  local label=$1 pulls=$2 want=$3 want_text=${4:-} seqs=${5:-}
  local rc=0 out
  checks=$((checks + 1))
  rm -rf "$root/seq"
  mkdir -p "$root/seq"
  local spec num vals
  local IFS=';'
  for spec in $seqs; do
    [[ -n "$spec" ]] || continue
    num="${spec%%:*}"
    vals="${spec#*:}"
    tr ',' '\n' <<<"$vals" >"$root/seq/$num"
  done
  unset IFS
  printf '%s' "$pulls" >"$root/pulls.json"
  set +e
  ( cd "$root/work" && env PATH="$root/bin:$PATH" GH_TOKEN=x GITHUB_REPOSITORY=o/r \
      PR_CONFLICTS_RETRY_SLEEP=0 FAKE_PULLS="$root/pulls.json" FAKE_PULL_SEQ="$root/seq" \
      bash "$step" ) >"$root/out" 2>&1
  rc=$?
  set -e
  out="$(cat "$root/out")"

  if [[ "$rc" -ne "$want" ]]; then
    fail "$label" "exit $rc, want $want" "$out"
    return 0
  fi
  # A job that failed must not also print the line that says it read everything.
  if [[ "$rc" -ne 0 && "$out" == *"no conflicted open PRs"* ]]; then
    fail "$label" "the step printed its success line and still exited $rc" "$out"
    return 0
  fi
  if [[ -n "$want_text" && "$out" != *"$want_text"* ]]; then
    fail "$label" "output has no '$want_text'" "$out"
  fi
}

clean="$(jq -nc '[{number:1,mergeable:true,head:{ref:"a"}},{number:2,mergeable:true,head:{ref:"b"}}]')"
conflicted="$(jq -nc '[{number:7,mergeable:false,head:{ref:"docs/stuck"}}]')"
unknown="$(jq -nc '[{number:5,mergeable:null,head:{ref:"docs/fresh"}}]')"
# 100 clean PRs fill page 1 exactly; #101 is the conflict that only a paginated
# read can see. This is the case that fails when `--paginate` is removed.
later_page="$(jq -nc '[range(1;101) | {number: ., mergeable: true, head: {ref: "a"}}]
  + [{number:101, mergeable:false, head:{ref:"docs/later"}}]')"

run_case clean "$clean" 0 'no conflicted open PRs'
run_case conflicted-on-page-1 "$conflicted" 1 'cannot be merged into its base'
run_case conflicted-on-later-page "$later_page" 1 '#101'
run_case unknown-then-clean "$unknown" 0 'no conflicted open PRs' '5:null,true'
run_case unknown-then-conflicted "$unknown" 1 'cannot be merged into its base' '5:null,false'
run_case unknown-stays-unknown "$unknown" 1 'could not determine the mergeability' '5:null,null,null'

# A `gh` call that fails is a failed check, never an empty clean list: the guard
# has to catch it, because `> conflicts.json` would otherwise leave a file the
# next line reads as "nothing to report".
checks=$((checks + 1))
set +e
( cd "$root/work" && env PATH="$root/bin:$PATH" GH_TOKEN=x GITHUB_REPOSITORY=o/r \
    PR_CONFLICTS_RETRY_SLEEP=0 FAKE_PULLS="$root/pulls.json" FAKE_PULL_SEQ="$root/seq" \
    FAKE_GH_FAIL=1 bash "$step" ) >"$root/out" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  fail gh-fails-closed "exit 0 when gh api failed" "$(cat "$root/out")"
fi

# The suite's own count, taken from its output rather than typed into the doc:
# row 149 said 11/11 while the script printed 15, and nothing compared them.
checks=$((checks + 1))
conflict_holds="$(bash "$ROOT/scripts/check-pr-conflicts.sh" --self-test 2>&1 \
  | sed -n 's/.*self-test: \([0-9]*\) hold.*/\1/p')"
if [[ -z "$conflict_holds" ]]; then
  fail doc-count-conflicts "check-pr-conflicts.sh --self-test printed no hold count"
else
  conflict_all="$(grep -oE 'scripts/check-pr-conflicts\.sh --self-test`?[^0-9]{0,6}[0-9]+/[0-9]+' "$DOC" \
    | grep -oE '[0-9]+/[0-9]+')"
  conflict_row="$(printf '%s\n' "$conflict_all" | sort -u)"
  # Counted before dedupe: two mentions of the same count collapsed to one line,
  # which read as a missing mention.
  n_conflict_mentions=$(printf '%s\n' "$conflict_all" | grep -c . || true)
  n_conflict_rows=$(printf '%s\n' "$conflict_row" | grep -c . || true)
  # Two places quote this suite: D41's verified sentence and the coverage row,
  # whose count sits past a backtick and a pipe. Matching only the first shape
  # left the table row uncompared while the guard said it was compared.
  if [ "$n_conflict_mentions" -lt 2 ]; then
    fail doc-count-conflicts "PR-AGENT.md quotes this suite $n_conflict_mentions time(s); expected the D41 sentence and the coverage row: '${conflict_row:-nothing}'"
  elif [ "$n_conflict_rows" -gt 1 ]; then
    fail doc-count-conflicts "PR-AGENT.md quotes $n_conflict_rows different counts for the conflicts suite: $(printf "%s" "$conflict_row" | tr "\\n" " ")"
  elif [[ "$conflict_row" != "$conflict_holds/$conflict_holds" ]]; then
    fail doc-count-conflicts "PR-AGENT.md says '${conflict_row:-nothing}' for the conflicts suite, which prints '$conflict_holds/$conflict_holds'"
  fi
fi

# The decision log states this suite's count, and a count the run refutes is a
# claim, not evidence: the expected number is counted from this file (one per
# `run_case` call, plus the gh case and this check), so a case appended here
# raises both sides together and neither depends on where the check sits.
checks=$((checks + 1))
declared=$(( $(grep -c '^run_case ' "$0") + 3 ))
# Every mention must agree: `head -1` let a stale row coexist with a correct one
# and pass on whichever came first. Anchored to the D41 row shape, because a
# count quoted in the row's own [VERIFIED] prose is not the row's count.
# Read every mention, not just the row shape: D41's [VERIFIED] prose quotes the
# same count and the row-only pattern left it uncompared, which is the defect
# the conflicts-suite guard above already had fixed.
doc_all="$(grep -oE 'scripts/check-pr-conflicts-workflow\.sh`?[^0-9]{0,6}[0-9]+/[0-9]+' "$DOC" \
  | grep -oE '[0-9]+/[0-9]+')"
doc_rows="$(printf '%s\n' "$doc_all" | sort -u)"
n_doc_mentions=$(printf '%s\n' "$doc_all" | grep -c . || true)
doc_row="$doc_rows"
if [[ "$n_doc_mentions" -lt 2 ]]; then
  fail doc-count "PR-AGENT.md quotes this suite $n_doc_mentions time(s); expected the D41 sentence and the coverage row: '${doc_rows:-nothing}'"
fi
[[ "$(printf '%s\n' "$doc_rows" | grep -c .)" -le 1 ]] || doc_row="$doc_rows (disagree)"
if [[ "$declared" -ne "$checks" ]]; then
  fail doc-count "the suite counted $checks case(s) but its source declares $declared"
elif [[ "$doc_row" != "$declared/$declared" ]]; then
  fail doc-count "PR-AGENT.md says '${doc_row:-nothing}' for this suite, which prints '$declared/$declared'"
fi

[[ "$failures" -eq 0 ]] || { echo "$failures case(s) failed"; exit 1; }
echo "pr-conflicts step: $checks/$checks"
