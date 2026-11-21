#!/usr/bin/env bash
# Keeps PR-TRIAGE.md's prose equal to the table beside it.
#
# Why: that document states its counts twice, once as a table read from the API
# and once as a sentence a reader acts on. Both sentences drifted and a reviewer
# had to find them — "three of the four open PRs look missing checks" against a
# table with exactly one conflicting head, and a merge order that "costs nothing"
# under `strict: true`, where the first merge is what puts the next PR behind.
# A count that can be read off the table is derived here, never keyed by hand.
#
# Offline on purpose: no `gh`, no token, so it runs on any PR and in ci.sh. The
# table is the source of truth; the assertions below only compare the prose to it.
set -euo pipefail
cd "$(dirname "$0")/.."

DOC=PR-TRIAGE.md
ok=0
fail=0

pass() { ok=$((ok + 1)); printf 'ok   %s\n' "$1"; }
die() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1" >&2; }
# One, two, ... ten -> 1..10. A count word this table cannot read is a failure,
# not a pass: silence is how a renamed heading turns a gate off.
word() {
  case "$1" in
    1|one) echo 1 ;; 2|two) echo 2 ;; 3|three) echo 3 ;; 4|four) echo 4 ;;
    5|five) echo 5 ;; 6|six) echo 6 ;; 7|seven) echo 7 ;; 8|eight) echo 8 ;;
    9|nine) echo 9 ;; 10|ten) echo 10 ;; *) echo "?" ;;
  esac
}

if [ ! -f "$DOC" ]; then
  die "missing: $DOC"
  printf '\ndoc-claims self-test: %d assertions hold, %d failed\n' "$ok" "$fail"
  exit 1
fi

# The PR table: | # | state | branch | mergeable | behind | files |
# Columns 2 and 5 are the number and the mergeable flag; the mergeable cell is
# `**false**` for a head GitHub cannot build a merge ref for.
rows=$(awk -F'|' '/^\| *[0-9]+ *\|/ { gsub(/[ `*]/, "", $3); gsub(/[ `*]/, "", $5); print $2"\t"$3"\t"$5 }' "$DOC")
open_n=$(printf '%s\n' "$rows" | awk -F'\t' 'NF && $2=="open"' | { grep -c . || true; })
conflict=$(printf '%s\n' "$rows" | awk -F'\t' 'NF && $3=="false" { gsub(/ /, "", $1); print $1 }')
conflict_n=$(printf '%s' "$conflict" | { grep -c . || true; })

# 1. The headline count is the table's count. It was typed as a word, which is
#    why nothing noticed when the pile changed.
typed=$(grep -oE '\*\*[A-Za-z0-9]+ PRs are open' "$DOC" | grep -oE '[A-Za-z0-9]+' | head -1 | tr '[:upper:]' '[:lower:]' || true)
if [ -z "$typed" ]; then
  die "open-count: no '**N PRs are open**' sentence to compare against the table"
elif [ "$(word "$typed")" = "$open_n" ]; then
  pass "open-count: the sentence says $typed, the table has $open_n open row(s)"
else
  die "open-count: the sentence says '$typed', the table has $open_n open row(s)"
fi

# 2. Every failure section that says a head cannot be checked names exactly the
#    rows whose mergeable cell is false — no more, no fewer. This is the one that
#    read "three of the four" while the table held one.
# Flattened: the paragraph wraps, and a line-oriented grep cannot see "three of
# the / four open PRs" — which is how the first version of this gate passed the
# very sentence it was written for.
flat=$(tr '\n' ' ' < "$DOC" | tr -s ' ')
want=$(printf '%s\n' "$conflict" | sort -un | paste -sd, -)
f4=$(awk '/^\*\*F4/{f=1} f && /^## /{exit} f' "$DOC" | tr '\n' ' ' | tr -s ' ')
[ -n "$f4" ] || die "f4-conflict-set: no F4 section to compare against the table"
if [ -n "$f4" ]; then
  named=$(printf '%s\n' "$f4" | grep -oE '#[0-9]+' | sed 's/#//' | sort -un | paste -sd, - || true)
  if [ "$named" = "$want" ]; then
    pass "f4-conflict-set: F4 names #$named, the table's conflicting head(s) are #$want"
  else
    die "f4-conflict-set: F4 names #${named:-nothing}, the table's conflicting head(s) are #${want:-none}"
  fi
fi

# 2b. The same claim is restated in "The systemic finding, stated once", which
#     is outside the F4 block, so the count word is compared over the whole
#     document: guarding only the block left the restatement unchecked, and both
#     had drifted. Two ways to be wrong: the count word against the conflicting
#     heads, and the total it names against the table's open rows. No match at
#     all is a failure, not a skip — silence is how a rewritten sentence turns
#     this assertion off.
claims=$(printf '%s\n' "$flat" | grep -oiE '[A-Za-z0-9]+ of the [A-Za-z0-9]+ open PRs' || true)
if [ -z "$claims" ]; then
  die "f4-conflict-count: no 'N of the M open PRs' claim in $DOC to compare against the table"
else
  while IFS= read -r claim; do
    [ -n "$claim" ] || continue
    n=$(word "$(printf '%s' "$claim" | grep -oE '^[A-Za-z0-9]+' | tr '[:upper:]' '[:lower:]')")
    total=$(word "$(printf '%s' "$claim" | grep -oE 'of the [A-Za-z0-9]+' | grep -oE '[A-Za-z0-9]+$' | tr '[:upper:]' '[:lower:]')")
    if [ "$total" != "$open_n" ]; then
      die "f4-conflict-count: '$claim' counts $total open PR(s), the table has $open_n"
    elif [ "$n" = "$conflict_n" ]; then
      pass "f4-conflict-count: '$claim' matches $conflict_n conflicting head(s) and $open_n open row(s)"
    else
      die "f4-conflict-count: '$claim', but the table has $conflict_n conflicting head(s)"
    fi
  done <<< "$claims"
fi

# 2c. The systemic paragraph names the same heads the F4 block does, in its own
#     "blocked by F4" clause. A name set edited in one place and not the other
#     is the same defect in the other direction.
sys=$(printf '%s\n' "$flat" | grep -oiE 'blocked by F4[^.]*' || true)
if [ -z "$sys" ]; then
  die "f4-systemic-set: no 'blocked by F4' clause in $DOC to compare against the table"
else
  sys_named=$(printf '%s\n' "$sys" | grep -oE '#[0-9]+' | sed 's/#//' | sort -un | paste -sd, - || true)
  if [ "$sys_named" = "$want" ]; then
    pass "f4-systemic-set: the systemic clause names #$sys_named, the table's conflicting head(s) are #$want"
  else
    die "f4-systemic-set: the systemic clause names #${sys_named:-nothing}, the table's conflicting head(s) are #${want:-none}"
  fi
fi

# 3. No merge is free while the table lists more than one open PR: `strict: true`
#    puts every other PR behind `main` on the first merge. The sentence claimed a
#    cost of zero, and the paragraph above it already said each merge invalidates
#    the next. The order decides who pays, not whether.
free_claim=$(grep -niE 'costs nothing|cost nothing|only order that does not force' "$DOC" || true)
if [ "$open_n" -le 1 ]; then
  pass "merge-order-cost: $open_n open row(s), so a free merge is not a claim to refute"
elif [ -z "$free_claim" ]; then
  pass "merge-order-cost: no free-merge claim while $open_n PRs are open"
else
  die "merge-order-cost: claims a merge is free while $open_n PRs are open — $free_claim"
fi

printf '\ndoc-claims self-test: %d assertions hold, %d failed\n' "$ok" "$fail"
[ "$fail" -eq 0 ]
