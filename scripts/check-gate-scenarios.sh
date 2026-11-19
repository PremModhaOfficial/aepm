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
ok() { printf '  ok   %s\n' "$*"; }
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

# 4. The default head is still HEAD, so a developer's branch keeps working.
out="$(cd "$repo" && bash scripts/gate-scenarios.sh --list "$base" 2>&1 | tr '\n' ' ')"
if [[ $out == *01-a.sh* ]]; then
    ok "--list with one argument still diffs against HEAD"
else
    bad "--list <base> did not default to HEAD: ${out:-nothing}"
fi

((status == 0)) || { printf 'gate-scenarios self-test FAILED\n' >&2; exit 1; }
printf 'gate-scenarios self-test: 4 assertions hold\n'
