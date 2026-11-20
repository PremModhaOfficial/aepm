#!/usr/bin/env bash
# Deterministic test for scenario selection: `gate-scenarios.sh --list`.
#
# The thing this pins is the head argument. The runner checks out the synthetic
# merge commit for a pull request, and that commit's first parent is whatever
# `main` was when the merge ref was last rebuilt — not the `base.sha` the event
# froze. Diffing the frozen base against the merge commit therefore also picks up
# every commit `main` gained in between, and runs scenarios the change cannot
# reach. Measured on PR #143: three markdown files selected 27 of 56 scenarios.
#
# A throwaway git repository, no network, no real map.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

repo="$TMP/repo"
mkdir -p "$repo/scripts" "$repo/sim/scenarios" "$repo/.github/workflows" "$repo/src" "$repo/docs"
cp "$ROOT/scripts/gate-scenarios.sh" "$repo/scripts/"
# The gate refuses to run when the workflow no longer calls it; that grep is
# part of what this fixture satisfies.
printf 'run: scripts/gate-scenarios.sh --list "$BASE"\n' > "$repo/.github/workflows/sim.yml"
: > "$repo/sim/scenarios/01-a.sh"
: > "$repo/sim/scenarios/02-b.sh"
cat > "$repo/sim/scenario-map.tsv" <<'MAP'
# path	scenarios	why
src/a.rs	01	the first module
src/b.rs	02	the second module
sim/	all	the image and the stubs every scenario runs inside
sim/README.md	none	documentation only
MAP

git -C "$repo" init -q -b main
# A developer's global config may sign commits with an agent the runner has no
# socket for; the fixture is a scratch repository and signs nothing.
git -C "$repo" config user.email t@t
git -C "$repo" config user.name t
git -C "$repo" config commit.gpgsign false
git -C "$repo" -c commit.gpgsign=false add -A
git -C "$repo" -c commit.gpgsign=false commit -qm "base: src/a.rs"
base="$(git -C "$repo" rev-parse HEAD)"

# The pull request: a docs-only commit, branched from `base`.
git -C "$repo" checkout -q -b pr
printf 'note\n' > "$repo/docs/note.md"
git -C "$repo" -c commit.gpgsign=false add -A
git -C "$repo" -c commit.gpgsign=false commit -qm "pr: docs only"
head="$(git -C "$repo" rev-parse HEAD)"

# `main` moves on while the pull request is open: a src/ change and its map row.
git -C "$repo" checkout -q main
printf 'fn b() {}\n' > "$repo/src/b.rs"
git -C "$repo" -c commit.gpgsign=false add -A
git -C "$repo" -c commit.gpgsign=false commit -qm "main: src/b.rs"
drift="$(git -C "$repo" rev-parse HEAD)"

# What the runner checks out: the merge of the pull request into the new main.
git -C "$repo" checkout -q pr
git -C "$repo" -c commit.gpgsign=false merge -q --no-ff -m merge "$drift"
merge="$(git -C "$repo" rev-parse HEAD)"

status=0
# The closing line reports this counter, not a number typed by hand, so the claim
# and the run cannot drift apart: every passing block calls `ok` exactly once.
count=0
ok() {
    count=$((count + 1))
    printf '  ok   %s\n' "$*"
}
bad() {
    printf '  FAIL %s\n' "$*" >&2
    status=1
}
listed() {
    (cd "$repo" && bash scripts/gate-scenarios.sh --list "$1" "${2:-HEAD}" 2>&1)
}

# 1. The bug: base...merge picks up main's drift.
got="$(listed "$base" "$merge" | tr '\n' ' ')"
case $got in
    *02-b.sh*) ok "the merge commit inherits the base branch's drift (this is the bug the head argument fixes)" ;;
    *) bad "expected 02-b.sh when diffing ${base:0:7}...${merge:0:7}, got: ${got:-nothing}" ;;
esac

# 2. The fix: pinned to the pull request's own head, a docs commit selects nothing.
out="$(listed "$base" "$head")"
if [[ -z $out ]]; then
    ok "a docs-only head selects no scenario, whatever main gained"
else
    bad "a docs-only head selected: $(tr '\n' ' ' <<<"$out")"
fi

# 3. A commit that does reach src/ still selects its row. Branched from the
# pre-merge head, so this commit is the only thing between `base` and it.
git -C "$repo" checkout -q -b touched "$head"
mkdir -p "$repo/src"
printf 'fn a() {}\n' > "$repo/src/a.rs"
git -C "$repo" -c commit.gpgsign=false add -A
git -C "$repo" -c commit.gpgsign=false commit -qm "touched: src/a.rs"
touched="$(git -C "$repo" rev-parse HEAD)"
out="$(listed "$base" "$touched")"
if [[ $out == "sim/scenarios/01-a.sh" ]]; then
    ok "src/a.rs selects exactly its one scenario"
else
    bad "src/a.rs selected: ${out:-nothing}"
fi

# 4. A change to the harness itself runs the suite. The `sim/` row used to be
# inert because --list dropped every path outside src/, so a sim/Dockerfile edit
# selected nothing and merged unproven.
git -C "$repo" checkout -q -b harness "$head"
mkdir -p "$repo/sim"
printf 'FROM archlinux:base-devel\n' > "$repo/sim/Dockerfile"
git -C "$repo" -c commit.gpgsign=false add -A
git -C "$repo" -c commit.gpgsign=false commit -qm "harness: touch the image"
harness="$(git -C "$repo" rev-parse HEAD)"
out="$(listed "$base" "$harness" | tr '\n' ' ')"
case $out in
    *01-a.sh*02-b.sh* | *02-b.sh*01-a.sh*) ok "a sim/ change selects the whole suite" ;;
    *) bad "a sim/ change selected: ${out:-nothing}" ;;
esac

# 5. The map rows that own documentation carry `none`, so they still select
# nothing. A blanket "any sim/ change runs everything" would fail here.
git -C "$repo" checkout -q -b harness-docs "$head"
printf 'more\n' >> "$repo/sim/README.md"
git -C "$repo" -c commit.gpgsign=false add -A
git -C "$repo" -c commit.gpgsign=false commit -qm "harness: docs only"
docs="$(git -C "$repo" rev-parse HEAD)"
out="$(listed "$base" "$docs")"
if [[ -z $out ]]; then
    ok "a sim/ file with a none row still selects nothing"
else
    bad "a sim/README.md change selected: $(tr '\n' ' ' <<<"$out")"
fi

# 6. The default head is still HEAD, so a developer's branch keeps working.
git -C "$repo" checkout -q touched
out="$(cd "$repo" && bash scripts/gate-scenarios.sh --list "$base" 2>&1 | tr '\n' ' ')"
if [[ $out == *01-a.sh* ]]; then
    ok "--list with one argument still diffs against HEAD"
else
    bad "--list <base> did not default to HEAD: ${out:-nothing}"
fi

# 7. The real workflow must pass the head, and fetch enough history to resolve
# it. The fixture above is one argument wide on purpose, so this reads
# `.github/workflows/sim.yml` itself: dropping HEAD_SHA from the call, or
# `fetch-depth: 0` from the checkout, is a red self-test rather than the silent
# drift the head argument was added to fix (#143).
workflow="$ROOT/.github/workflows/sim.yml"
call="$(grep -h 'gate-scenarios\.sh --list' "$workflow" || true)"
if [[ $call == *'--list "$BASE" "$HEAD_SHA"'* ]]; then
    if grep -q 'fetch-depth: 0' "$workflow"; then
        ok "the real workflow passes both --list arguments and fetches the head"
    else
        bad "$workflow passes HEAD_SHA but no longer fetches it (fetch-depth: 0): the head sha cannot be resolved"
    fi
else
    bad "$workflow does not pass the head: expected --list \"\$BASE\" \"\$HEAD_SHA\", got: ${call:-no call}"
fi

# 8. A diff that cannot be computed must fail rather than select nothing. An
# unrelated root shares no history with the branch, so `base...head` exits 128;
# the failure used to vanish inside a process substitution, leaving an empty list
# that selected zero scenarios and reported the build green having run none.
orphan="$(git -C "$repo" commit-tree \
    "$(git -C "$repo" hash-object -t tree -w /dev/null)" -m "unrelated root")"
if out="$(listed "$orphan" "$head")"; then
    bad "a diff with no merge base exited 0: ${out:-no output}"
else
    case $out in
        *"cannot diff"*) ok "a diff with no merge base fails instead of selecting nothing" ;;
        *) bad "no-merge-base diff failed for the wrong reason: ${out:-no output}" ;;
    esac
fi

((status == 0)) || { printf 'gate-scenarios self-test FAILED\n' >&2; exit 1; }
printf 'gate-scenarios self-test: %s assertions hold\n' "$count"
