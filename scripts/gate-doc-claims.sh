#!/usr/bin/env bash
# The two CI machinery documents are claims about this repository, and nothing
# checked them against it or against themselves. Each assertion below failed once,
# in one review of #147, so each one is a regression guard rather than a style
# rule:
#
#   plan count       "the twelve items below" over a fourteen-row table, and a
#                    "two that remain" that no arithmetic produced
#   plan remainder   "What that leaves" naming a row the same section had just
#                    killed, and dropping one it had left alive
#   gate count       "fourteen deterministic checks" over a table that had to
#                    grow when a gate was added
#   runs-in          "all fourteen run inside `bash ci.sh`", false for five of
#                    them, while the table said nothing about where they run
#   legs verdict     one document said MERGE the four legs, the other said no
#                    action on the same fact
#   outlier pointer  the 1162s tail sized against "§4 item 1", the
#                    scenario-selection row, instead of the buildx cache row
#
# Every check parses the document and the repository, so reverting a fix fails it
# rather than leaving a copy of the fixed text behind. Prose that merely mentions
# a rule (as this header does) is not what these read: they read tables, headings
# and the two paragraphs that carry a number.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="$ROOT/docs/CI-ARCHITECTURE.md"
LEDGER="$ROOT/docs/research/ledger.md"
WF="$ROOT/.github/workflows"

total=0
passed=0
failed_here=0
bad() {
  printf 'FAIL %s: %s\n' "$1" "$2" >&2
  failed_here=1
}
check() { total=$((total + 1)); failed_here=0; }
done_() { [ "$failed_here" = 1 ] || passed=$((passed + 1)); }

# Spelled counts are what the prose uses; digits are what the tables use.
num() {
  case "$1" in
    one) echo 1 ;; two) echo 2 ;; three) echo 3 ;; four) echo 4 ;;
    five) echo 5 ;; six) echo 6 ;; seven) echo 7 ;; eight) echo 8 ;;
    nine) echo 9 ;; ten) echo 10 ;; eleven) echo 11 ;; twelve) echo 12 ;;
    thirteen) echo 13 ;; fourteen) echo 14 ;; fifteen) echo 15 ;;
    sixteen) echo 16 ;; *) echo "$1" ;;
  esac
}

# "## 4. The reconciled plan" table, bounded by the heading that ends it.
plan_table() {
  awk '/^## 4\. The reconciled plan/{f=1; next} /^### What that leaves/{f=0} f && /^\| [0-9]+ \|/' "$ARCH"
}

# Verdict class of one plan row: the verdict is field 4 of the pipe-split line.
verdict_class() {
  awk -F'|' '{gsub(/[`*]/, "", $4); print tolower($4)}' | sed -e 's/^ *//' -e 's/ —.*//' -e 's/,.*//'
}

plan_rows=$(plan_table)
rows=$(printf '%s\n' "$plan_rows" | grep -c '^| [0-9]' || true)
killed=$(printf '%s\n' "$plan_rows" | verdict_class | grep -Ec '^(kill|park|reject|defer)' || true)
remain=$((rows - killed))

# --- plan count ------------------------------------------------------------
# The three numbers a reader uses to decide the audit is complete: how many rows
# there are, how many died, how many remain. They must agree with each other.
check
preamble=$(awk '/^Two clean-context reviewers audited/{f=1} f && /^$/{exit} f' "$ARCH")
w_audited=$(num "$(printf '%s' "$preamble" | sed -n 's/.*audited the \([a-z]*\) items.*/\1/p')")
w_total=$(num "$(printf '%s' "$preamble" | sed -n 's/.*of \([a-z]*\) rows were.*/\1/p')")
w_remain=$(num "$(printf '%s' "$preamble" | sed -n 's/.*the \([a-z]*\) that remain.*/\1/p')")
if [ "$w_audited" = "$rows" ] && [ "$w_total" = "$rows" ] && [ "$w_remain" = "$remain" ]; then
  :
else
  bad plan-count "the plan preamble says $w_audited items, $w_total rows and $w_remain remaining, but the table has $rows rows, $killed killed/parked/rejected/deferred and $remain remaining"
fi
done_

# --- plan remainder --------------------------------------------------------
# "What that leaves" is the summary a reader acts on. Naming a row the same
# section just killed, or dropping one it kept, is the same defect as a wrong
# count.
check
leaves=$(awk '/^### What that leaves/{f=1; next} f && /^## /{exit} f' "$ARCH" | tr '\n' ' ')
named=$(printf '%s' "$leaves" | grep -oE 'items? [0-9]+( and [0-9]+)?' | grep -oE '[0-9]+' | sort -un || true)
if [ -z "$named" ]; then
  bad plan-remainder "\"What that leaves\" names no plan row, so it cannot be the remainder of the plan table"
fi
for n in $named; do
  cls=$(printf '%s\n' "$plan_rows" | awk -F'|' -v n="$n" '$2+0 == n' | verdict_class)
  if [ -z "$cls" ]; then
    bad plan-remainder "\"What that leaves\" names item $n, which is not a row of the plan table"
  elif printf '%s' "$cls" | grep -Eq '^(kill|park|reject|defer)'; then
    bad plan-remainder "\"What that leaves\" names item $n as remaining, but its verdict is \"$cls\""
  fi
done
done_

# --- gate count ------------------------------------------------------------
# §2's heading, its first sentence and §7's cost paragraph all count the same
# table, so adding a row cannot leave three numbers stale.
check
gate_rows=$(awk '/^## 2\. Gate scripts/{f=1; next} /^## 3\./{f=0} f && /^\| `/' "$LEDGER")
gates=$(printf '%s\n' "$gate_rows" | grep -c '^| `' || true)
w_head=$(num "$(sed -n 's/^## 2\. Gate scripts — \([a-z]*\) deterministic checks$/\1/p' "$LEDGER")")
w_all=$(num "$(sed -n 's/^All \([a-z]*\) are deterministic.*/\1/p' "$LEDGER")")
w_cost=$(sed -n 's/.*at \([0-9]*\) gates, \([0-9]*\) workflows.*/\1 \2/p' "$LEDGER")
if [ "$w_head" = "$gates" ] && [ "$w_all" = "$gates" ] && [ "${w_cost%% *}" = "$gates" ]; then
  :
else
  bad gate-count "§2's heading says $w_head, its first sentence says $w_all, and §7 says ${w_cost%% *} gates, but the table has $gates rows"
fi
if [ "${w_cost##* }" != "5" ]; then
  bad workflow-count "§7 says ${w_cost##* } workflows against the five in §1 of docs/CI-ARCHITECTURE.md"
fi
done_

# --- runs-in column --------------------------------------------------------
# The claim the finding killed was that every check surfaces as one `Run CI
# script` step. The column replaces it, so each cell must name a place the script
# is really called, and "nowhere" must be true as well.
check
declare -A where=(
  ['ci.sh']="$ROOT/ci.sh"
  ['ci.yml']="$WF/ci.yml"
  ['sim.yml']="$WF/sim.yml"
  ['scheduled-audit.yml']="$WF/scheduled-audit.yml"
  ['pr-agent.yml']="$WF/pr-agent.yml"
  ['review-gate.yml']="$WF/review-gate.yml"
  ['sim/run.sh']="$ROOT/sim/run.sh"
)
while IFS= read -r row; do
  [ -n "$row" ] || continue
  script=$(printf '%s' "$row" | sed -n 's/^| `\([^`]*\)`.*/\1/p')
  cell=$(printf '%s' "$row" | awk -F'|' '{print $(NF-1)}')
  found=0
  for token in "${!where[@]}"; do
    case "$cell" in
      *"$token"*)
        found=1
        if ! grep -qF "$script" "${where[$token]}"; then
          bad runs-in "\`$script\` says it runs in \`$token\`, but ${where[$token]#"$ROOT"/} never mentions it"
        fi
        ;;
    esac
  done
  if [ "$found" = 0 ]; then
    case "$cell" in
      *nothing*)
        if grep -qF "$script" "$ROOT/ci.sh" || grep -rqF "$script" "$WF"; then
          bad runs-in "\`$script\` says it runs nowhere, but ci.sh or a workflow calls it"
        fi
        ;;
      *) bad runs-in "\`$script\` names no location a reader can check: $cell" ;;
    esac
  fi
done <<< "$gate_rows"
done_

# --- legs verdict ----------------------------------------------------------
# One fact, one verdict. docs/CI-ARCHITECTURE.md §4 item 11 decided "no action"
# on the four CI legs; the ledger must not recommend merging them instead.
check
if grep -q 'MERGE the four legs' "$ARCH" "$LEDGER"; then
  bad legs-verdict "a document still says \"MERGE the four legs\" while docs/CI-ARCHITECTURE.md §4 item 11 says no action on the same fact"
fi
if ! grep -q '§4 item 11' "$LEDGER"; then
  bad legs-verdict "the ledger's CI row does not point at the decision that settled it (§4 item 11)"
fi
done_

# --- outlier pointer -------------------------------------------------------
# The 1162s tail is a build tail, sized against the buildx layer cache. The
# pointer must resolve to a row that is about the cache, not to row 1.
check
outlier=$(grep -n 'Outlier, run 44464311286' "$ARCH" | cut -d: -f1 || true)
if [ -n "$outlier" ]; then
  tail_para=$(awk '/^The 1162s outlier is/{f=1} f && /^$/{exit} f' "$ARCH")
  ptr=$(printf '%s' "$tail_para" | grep -oE '§4 item [0-9]+' | head -1 || true)
  if [ -z "$ptr" ]; then
    bad outlier-pointer "the 1162s outlier paragraph names no §4 item, so a reader cannot find the decision it was sized against"
  else
    n=${ptr##* }
    item=$(printf '%s\n' "$plan_rows" | awk -F'|' -v n="$n" '$2+0 == n {print $3}')
    case "$item" in
      *gha*|*cache*) : ;;
      *) bad outlier-pointer "the 1162s outlier says it is sized against §4 item $n, which is \"$(printf '%s' "$item" | sed -e 's/^ *//' -e 's/ *$//' | cut -c1-60)\" — not the layer-cache row" ;;
    esac
  fi
fi
done_

printf 'doc claims: %d/%d\n' "$passed" "$total"
[ "$passed" = "$total" ]
