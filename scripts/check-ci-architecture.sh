#!/usr/bin/env bash
# Keeps docs/CI-ARCHITECTURE.md matching the repository.
#
# Every assertion here exists because the document drifted from the facts once
# and a reviewer had to find it: a typed "five workflows" while a sixth was open,
# two of three required check names, a step decomposition that did not sum to its
# own total, a stale gate count, a scenario filename that matched no file.
# Offline on purpose: no `gh`, no tokens, so it can run on any PR.
set -euo pipefail
cd "$(dirname "$0")/.."

DOC=docs/CI-ARCHITECTURE.md
ok=0
fail=0

pass() { ok=$((ok + 1)); printf 'ok   %s\n' "$1"; }
die() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1" >&2; }

# 1. Every workflow file is named in the table, using its own `name:` field.
#    A workflow added by a PR turns this red until the table gains its row.
while IFS= read -r f; do
  name=$(sed -n 's/^name: *//p' "$f" | head -1)
  [ -n "$name" ] || { die "$f has no top-level name:"; continue; }
  if grep -qF "\`$name\`" "$DOC"; then
    pass "workflow $f ($name) is in the table"
  else
    die "$f is named '$name' but $DOC never mentions it"
  fi
done < <(ls .github/workflows/*.yml)

# 2. All three required checks are named in the sentence that enumerates them.
#    `Review Gate` is a Checks-API write on the head, not a job name, so losing it
#    is invisible to any grep of a workflow. Newlines are flattened first: the
#    list wraps, and a line-oriented grep cannot see a name split across lines —
#    which is how the first version of this assertion passed while the name was
#    only present later in the same bullet.
required_list=$(awk '/Never change branch protection/{f=1} f{printf "%s ", $0} f && /are the required names/{exit}' "$DOC" | tr -s ' ')
for c in 'CI (Linux)' 'Arch simulation' 'Review Gate'; do
  if printf '%s' "$required_list" | grep -qF "$c"; then
    pass "required check '$c' named in the enumeration"
  else
    die "required check '$c' missing from the sentence naming the required checks"
  fi
done

# 3. The CI (Linux) step table sums to its stated total. It did not: five rows
#    came to 54.0s against a stated 57.5s, losing 6% of the job to nothing.
stated=$(sed -n 's/^| \*\*total\*\* | \*\*\([0-9.]*\)s\*\* |$/\1/p' "$DOC" | head -1)
parts=$(sed -n '/^| Step | avg |$/,/^| \*\*total\*\* |/p' "$DOC" \
  | grep -oE '\| [0-9]+\.[0-9]s \|$' | grep -oE '[0-9]+\.[0-9]' | awk '{s+=$1} END{printf "%.1f", s}')
if [ -n "$stated" ] && [ -n "$parts" ]; then
  if awk -v a="$parts" -v b="$stated" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<=0.6)}'; then
    pass "CI step table sums to its stated total (${parts}s vs ${stated}s)"
  else
    die "CI step table sums to ${parts}s but claims ${stated}s"
  fi
else
  die "could not read the CI step table and its total from $DOC"
fi

# 4. The gate count quoted for ci.sh equals the count on disk.
actual=$(grep -cE '^(bash scripts/|\./sim/|bash sim/)' ci.sh || true)
quoted=$(grep -oE "bash sim/\)' ci\.sh\` → [0-9]+" "$DOC" | grep -oE '[0-9]+$' || true)
if [ -n "$quoted" ] && [ "$quoted" = "$actual" ]; then
  pass "ci.sh gate count quoted as $quoted and measured as $actual"
else
  die "ci.sh gate count quoted as '${quoted:-nothing}' but measured as $actual"
fi

# 5. No typed workflow count in the heading: it goes stale the day a workflow is
#    added, and assertion 1 is the check that should speak instead.
if grep -qE '^### The (one|two|three|four|five|six|seven|eight|nine|ten) workflows$' "$DOC"; then
  die "the workflows heading types a count; drop the number and let assertion 1 hold it"
else
  pass "the workflows heading types no count"
fi

# 6. Every sim scenario the document names resolves to a real file. It once
#    printed `43-delete-db-lck`, which greps to nothing.
while IFS= read -r n; do
  if [ -f "sim/scenarios/$n.sh" ]; then
    pass "scenario $n resolves"
  else
    die "scenario $n is named in $DOC and exists in sim/scenarios/ as nothing"
  fi
done < <(grep -oE '`[0-9]{2}-[a-z0-9-]+`' "$DOC" | tr -d '`' | sort -u)

# 7. Every invocation count quoted as current equals the count on disk. The step
#    table said 11 while the prose said 12, because an earlier fix updated one and
#    not the other. Only present-tense phrasings are checked: the document also
#    records "10 invocations at the commit that first published this table", and a
#    historical figure that must stay historical is not drift.
for n in $(grep -oE 'in [0-9]+ invocations' "$DOC" | grep -oE '[0-9]+' | sort -u; \
           grep -oE '[0-9]+ invocations over [0-9]+ scripts' "$DOC" | grep -oE '^[0-9]+' | sort -u); do
  if [ "$n" = "$actual" ]; then
    pass "quoted invocation count $n matches ci.sh"
  else
    die "a sentence quotes $n invocations; ci.sh has $actual"
  fi
done
scripts_actual=$(grep -oE '^(bash scripts/|\./sim/|bash sim/)[a-z-]+\.sh' ci.sh | sed 's|.*/||' | sort -u | wc -l)
for n in $(grep -oE '[0-9]+ gate scripts' "$DOC" | grep -oE '^[0-9]+' | sort -u); do
  if [ "$n" = "$scripts_actual" ]; then
    pass "quoted gate-script count $n matches ci.sh"
  else
    die "a sentence quotes $n gate scripts; ci.sh invokes $scripts_actual distinct"
  fi
done

# 8. The Sim max quoted in the workflow table equals the one the prose explains.
#    The table said 636s while the paragraph below said 646s, both "measured".
sim_max=$(grep -oE 'max [0-9]+s \(n=49\)' "$DOC" | grep -oE '[0-9]+' | head -1)
range_end=$(grep -oE 'one range ends at [0-9]+s' "$DOC" | grep -oE '[0-9]+' | head -1)
if [ -n "$sim_max" ] && [ "$sim_max" = "$range_end" ]; then
  pass "the explained Sim tail ($range_end s) matches the table ($sim_max s)"
else
  die "the Sim table says ${sim_max:-nothing}s and the prose explains ${range_end:-nothing}s"
fi

# 9. A row parked behind another row must name a row that comes *before* it.
#    Row 4 once said "parked behind #5" while row 5 sat below it: a plan whose
#    fourth step waits on its fifth is not a plan.
bad=$(awk -F'|' '/^\| [0-9]+ \|/ {n=$2; gsub(/[^0-9]/,"",n); line=$0;
  while (match(line, /parked behind #[0-9]+/)) {
    tok=substr(line, RSTART, RLENGTH); gsub(/[^0-9]/,"",tok);
    if (tok+0 >= n+0) print n " waits on " tok;
    line=substr(line, RSTART+RLENGTH);
  }}' "$DOC")
if [ -z "$bad" ]; then
  pass "no ranked row waits on a row below it"
else
  die "a ranked row waits on a row below it: $bad"
fi

printf '\nci-architecture self-test: %d assertions hold, %d failed\n' "$ok" "$fail"
[ "$fail" -eq 0 ]
