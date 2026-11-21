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

# 1. Every workflow file is named in the workflow TABLE, using its own `name:`
#    field, and the table has one row per file. Two things this must not accept:
#    a name mentioned anywhere else in the document (the flake table names
#    `OCR Review (advisory)`, so a glob-free grep would pass for a workflow with
#    no row), and a file this glob does not see (GitHub accepts .yaml as well
#    as .yml, and an unseen file is a silent pass).
wtable=$(awk '/^\| Workflow \| Triggers \|/{f=1} f&&/^$/{exit} f' "$DOC")
[ -n "$wtable" ] || die "could not find the workflow table in $DOC"
while IFS= read -r f; do
  name=$(sed -n 's/^name: *//p' "$f" | head -1)
  [ -n "$name" ] || { die "$f has no top-level name:"; continue; }
  if printf '%s' "$wtable" | grep -qF "\`$name\`"; then
    pass "workflow $f ($name) has a row in the table"
  else
    die "$f is named '$name' but has no row in the workflow table"
  fi
done < <(ls .github/workflows/*.yml .github/workflows/*.yaml 2>/dev/null)

# 1b. The table has exactly one row per workflow file. This is what the document
#     means by "the count is asserted, not typed".
# Same pipefail trap: an unmatched *.yaml glob makes ls exit 2, and with pipefail
# the assignment fails and the script dies before printing anything.
files=$( { ls .github/workflows/*.yml .github/workflows/*.yaml 2>/dev/null || true; } | wc -l )
rows=$(printf '%s\n' "$wtable" | grep -cE '^\| `[^`]+` \|' || true)
if [ "$files" = "$rows" ]; then
  pass "workflow table has $rows rows for $files workflow files"
else
  die "workflow table has $rows rows but the repository has $files workflow files"
fi

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
# `|| true` because pipefail turns a format change into an immediate exit, which
# would kill the script before the diagnostic below could say what broke.
parts=$( { sed -n '/^| Step | avg |$/,/^| \*\*total\*\* |/p' "$DOC" \
  | grep -oE '\| [0-9]+\.[0-9]s \|$' | grep -oE '[0-9]+\.[0-9]' \
  | awk '{s+=$1} END{if (NR) printf "%.1f", s}'; } || true)
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


# 10. Every `file:NN` citation that resolves to a real file points inside it.
#     This document has twice cited a line that does not exist (sim.yml:189-193
#     in a 77-line file) and twice cited the wrong existing line, which this
#     cannot catch — but an off-the-end number is the failure that reads as a
#     citation while being unmatchable, and it is cheap to hold shut.
badcite=""
n_cites=0
while IFS= read -r c; do
  f="${c%:*}"; n="${c##*:}"; n="${n%%-*}"
  path=""
  for cand in "$f" ".github/workflows/$(basename "$f")" "sim/$(basename "$f")" \
              "scripts/$(basename "$f")" "docs/$(basename "$f")" "src/$(basename "$f")"; do
    if [ -f "$cand" ]; then path="$cand"; break; fi
  done
  [ -n "$path" ] || continue
  n_cites=$((n_cites + 1))
  len=$(wc -l < "$path")
  [ "$n" -le "$len" ] || badcite="$badcite $c($path has $len lines)"
done < <(grep -oE '[A-Za-z0-9_./-]+\.(sh|yml|yaml|rs|md):[0-9]+(-[0-9]+)?' "$DOC" | sort -u)
if [ -z "$badcite" ]; then
  pass "all $n_cites resolvable file:line citations point inside their file"
else
  die "citations point past the end of their file:$badcite"
fi


# 12. Every row of every table has the same cell count as its header. GFM splits
#     cells on a raw `|` before it parses inline code, so a pipe inside a code
#     span silently truncates the row — that is how row 2 shipped broken while
#     every other assertion stayed green. Counting pipes catches it whether the
#     pipe is in a code span, a URL or plain text.
badtable=$(awk '
  /^\|/ { n=gsub(/\|/,"|"); if (!intbl) { intbl=1; want=n } else if (n!=want) { print NR": "n" cells, header has "want; bad=1 } next }
  { intbl=0 }
  END { exit(bad?1:0) }
' "$DOC" 2>&1) &&   pass "every table row matches its header's cell count" ||   die "table rows with the wrong cell count: ${badtable:-see above}"

printf '\nci-architecture self-test: %d assertions hold, %d failed\n' "$ok" "$fail"
[ "$fail" -eq 0 ]
