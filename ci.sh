#!/usr/bin/env bash
set -euo pipefail

# This box caps agent sessions at 9.6 of 16 cores; an uncapped ci.sh is what took
# the machine down. CI runners are separate boxes, so there the defaults are right.
# JOBS bounds rustc; TEST_THREADS bounds the suite, which JOBS does not reach.
[ -n "${CI:-}" ] || export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-6}"
[ -n "${CI:-}" ] || export RUST_TEST_THREADS="${RUST_TEST_THREADS:-4}"

# F11 — Debug-only per-PR gate. `cargo test --release` (dropped) doubles
# compile time and burns free-tier minutes for almost no extra signal;
# release-only bugs are rare. Run `cargo test --release --all-targets
# --all-features --locked` manually or on a schedule before a release.
echo "=== sim scenario numbers (unique) ==="
bash scripts/check-sim-numbers.sh --self-test
bash scripts/check-sim-numbers.sh

echo "=== pkgbuild version (Cargo.toml is the one typed version) ==="
# An AUR checkout has no Cargo.toml at parse time, so PKGBUILD's pkgver and
# _tag stay literal; this gate keeps them equal to the crate version.
bash scripts/gate-pkgbuild-version.sh

echo "=== sim scenario map (every src path names its scenarios) ==="
# F19 — A src file no scenario exercises used to merge green. The map in
# sim/scenario-map.tsv names the scenarios for every path under src/, and
# .github/workflows/sim.yml runs exactly the mapped set for a pull request.
bash scripts/gate-scenarios.sh --check-map

echo "=== state machines (docs match code) ==="
# An implicit machine drifts in silence: a variant is added, a precedence branch
# moves, and the table keeps describing the tree it was written against. F11 —
# docs/STATE-MACHINES.md is checked against the variants it names and the lines
# it cites, and the checker proves it can fail.
bash scripts/gate-state-machines.sh --self-test
bash scripts/gate-state-machines.sh

echo "=== review gate (current, stale, missing, untracked, pinned) ==="
# The review gate fails closed when no review exists or the head moved, including
# when the caller pins the commit it reports on (`--sha`). This self-test pins the
# outcomes with a fake gh, so the gate cannot silently pass everything.
bash scripts/check-review-gate.sh

echo "=== review gate workflow: verdicts land on the PR head, a superseded run gates nothing ==="
# The workflow's own reporting block, extracted from review-gate.yml and run
# against a fake gh: where the verdict lands, and that an unreadable head fails.
bash scripts/gate-review-selfcheck.sh

echo "=== clippy (deny warnings) ==="
cargo clippy --all-targets --all-features --locked -- -D warnings

echo "=== test (debug) ==="
cargo test --all-targets --all-features --locked

echo "=== sim image tag (per worktree) ==="
./sim/check-image-tag.sh

echo "=== sim build retry (BuildKit sandbox fault) ==="
bash sim/check-build-retry.sh

echo "=== fmt --check ==="
cargo fmt --all --check

echo "=== audit (cargo-deny, strict) ==="
# F06/F07/F08 — The old script silently skipped when no audit tool was
# installed, so CI (which installed neither tool) never audited: fake
# coverage. Now: CI installs cargo-deny (ci.yml), and this check fails
# loudly if it is missing. Local devs can opt out with ALLOW_AUDIT_SKIP=1.
# Policy lives in deny.toml; Cargo.lock is committed (binary crate).
# cargo-deny 0.20 moved --config to top level and --lockfile never existed;
# defaults (<cwd>/deny.toml, lockfile auto-discovered) are correct and
# portable across 0.19–0.20.
test -f deny.toml || { echo "::error::deny.toml missing — audit config not committed; refusing to run cargo-deny with defaults (empty license allow-list)"; exit 1; }
if command -v cargo-deny >/dev/null 2>&1; then
  cargo deny --all-features check
elif [[ -n "${CI:-}" ]]; then
  echo "::error::cargo-deny not found in CI — refusing to skip the audit gate"
  exit 1
elif [[ -n "${ALLOW_AUDIT_SKIP:-}" ]]; then
  echo "cargo-deny not installed, skipping audit (ALLOW_AUDIT_SKIP=1, local only)"
else
  echo "cargo-deny not installed — install it (taiki-e/install-action) or opt out locally with ALLOW_AUDIT_SKIP=1 ./ci.sh"
  exit 1
fi

echo "OK"
