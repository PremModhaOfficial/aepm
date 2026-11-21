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
# The map decides what a PR runs; the base it diffs against decides whether that
# is the PR's own change. CI checks out the merge commit, so a three-dot diff
# from the frozen base.sha also picks up every commit main gained meanwhile
# (measured on #143: 27 of 56 scenarios for three markdown files). The head is
# pinned in sim.yml and this proves the pin is what keeps the selection honest.
bash scripts/check-gate-scenarios.sh

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

echo "=== pr-agent state block (appended to the review the container posts) ==="
# #140: the pinned image posts a clean review with no typed block, so the gate
# read present=false on a review that ran. The block is extracted from
# pr-agent.yml and run against a fake gh, and its output is fed back through the
# real gate: the step is proven by the gate reading it, not by a shape.
bash scripts/check-pr-agent-state-block.sh

echo "=== pr conflicts watchdog (a conflicted head runs no workflow at all) ==="
# A PR whose head cannot merge into its base gets no checks at all, so nothing
# turns red and it sits forever. The check that reports it must not print
# success having read part of the list, or having failed to read a PR: the step
# extracted from pr-conflicts.yml is run against a fake `gh` that walks pages
# only on `--paginate`, and its cases fail on either silent green (findings
# 4a5a9f1d9e0b, 6ea304eea0b7).
bash scripts/check-pr-conflicts.sh --self-test
bash scripts/check-pr-conflicts-workflow.sh

echo "=== ci architecture doc matches the repository ==="
# The document drifted from the repo once and a reviewer had to find it: a typed
# "five workflows" with a sixth open, two of three required check names, a step
# decomposition that summed to 6% less than its own total, a stale gate count, a
# scenario filename that existed as nothing. Each assertion below holds one of
# those drifts shut, offline, on any PR.
bash scripts/check-ci-architecture.sh

echo "=== pr-triage doc: the prose counts match the table beside them ==="
# PR-TRIAGE.md states its counts twice, as a table read from the API and as the
# sentence a reader acts on. Both drifted and a reviewer found them: "three of
# the four open PRs look missing checks" against a table with one conflicting
# head, and a merge order that "costs nothing" under `strict: true`, where the
# first merge is what puts the next PR behind. Every count is derived here.
bash scripts/gate-doc-claims.sh

echo "=== clippy (deny warnings) ==="
cargo clippy --all-targets --all-features --locked -- -D warnings

echo "=== test (debug) ==="
cargo test --all-targets --all-features --locked

# The RenderCtx compile-fail doctest is the structural proof that a renderer
# outside the module cannot build a context and skip the palette gate.
echo "=== doc tests ==="
cargo test --doc --all-features --locked

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
