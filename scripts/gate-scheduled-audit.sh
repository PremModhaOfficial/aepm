#!/usr/bin/env bash
# The weekly drift gate: the checks that go stale without a pull request.
#
#   scripts/gate-scheduled-audit.sh
#
# Runs the same three commands .github/workflows/scheduled-audit.yml runs, in
# the same order, so the schedule and a local run cannot disagree:
#
#   1. cargo deny --all-features check   policy in deny.toml
#   2. cargo audit                       the RUSTSEC advisory database
#   3. cargo build --locked              pinned toolchain (rust-toolchain.toml)
#   4. cargo build --locked              latest stable
#
# Exit 0 only when all four pass.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

WORKFLOW=.github/workflows/scheduled-audit.yml

die() {
    printf 'gate-scheduled-audit: %s\n' "$*" >&2
    exit 1
}

# A gate nobody schedules is a comment. This is the assertion that fails on the
# tree that never had a schedule, and the one that goes red if the workflow is
# deleted or its cron line is dropped.
[[ -f $WORKFLOW ]] || die "missing $WORKFLOW: nothing reruns these checks"
grep -q 'scripts/gate-scheduled-audit.sh' "$WORKFLOW" \
    || die "$WORKFLOW no longer runs scripts/gate-scheduled-audit.sh"
grep -qE '^ +- cron: ' "$WORKFLOW" \
    || die "$WORKFLOW has no schedule.cron line"
grep -q 'cargo audit' "$WORKFLOW" \
    || die "$WORKFLOW no longer runs cargo audit"

pinned=$(sed -n 's/^channel *= *"\(.*\)"/\1/p' rust-toolchain.toml)
[[ -n $pinned ]] || die "rust-toolchain.toml has no channel line"

# Advisories cargo-deny already accepts in deny.toml [advisories] ignore. The
# list lives there because that is the policy a reviewer reads; cargo-audit has
# no config file, so it is repeated here and nowhere else.
ignores=(
    --ignore RUSTSEC-2024-0436 # paste, ratatui 0.29 build-only macro
    --ignore RUSTSEC-2026-0253 # lru pop() panic, never called
    --ignore RUSTSEC-2026-0002 # lru IterMut, never called
)

echo "=== cargo-deny (policy: deny.toml) ==="
command -v cargo-deny >/dev/null || die "cargo-deny not installed"
cargo deny --all-features check

echo "=== cargo audit (RUSTSEC database) ==="
command -v cargo-audit >/dev/null || die "cargo-audit not installed"
cargo audit "${ignores[@]}"

echo "=== cargo build --locked on the pinned toolchain ($pinned) ==="
cargo build --locked

echo "=== cargo build --locked on latest stable ==="
cargo "+stable" build --locked

echo "gate-scheduled-audit: all four checks passed"
