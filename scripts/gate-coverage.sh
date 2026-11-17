#!/usr/bin/env bash
# The coverage gate: measure line coverage, enforce the committed floor, and
# leave the lcov file behind for the artifact upload.
#
#   scripts/gate-coverage.sh                     # enforce coverage-floor.txt
#   COVERAGE_FLOOR=99 scripts/gate-coverage.sh   # prove the gate fires
#
# The floor is a measurement, not a target: coverage-floor.txt records what the
# tree measured on the commit that set it. Raise it when coverage rises; the
# gate fails the moment it falls below.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

FLOOR_FILE=coverage-floor.txt
CI=.github/workflows/ci.yml
LCOV=target/lcov.info

die() {
    printf 'gate-coverage: %s\n' "$*" >&2
    exit 1
}

# A coverage job that was deleted is not a coverage gate. These three greps are
# the drift the gate exists for: no signal, no floor, no artifact.
grep -q 'scripts/gate-coverage.sh' "$CI" \
    || die "$CI no longer runs scripts/gate-coverage.sh, so nothing enforces coverage"
grep -q 'coverage-lcov' "$CI" \
    || die "$CI no longer uploads the lcov artifact (coverage-lcov)"
grep -q 'ci-log-' "$CI" \
    || die "$CI no longer uploads the per-job logs (ci-log-*)"

floor=$(sed -n 's/^floor=//p' "$FLOOR_FILE")
[[ $floor =~ ^[0-9]+\.[0-9]{2}$ ]] \
    || die "$FLOOR_FILE has no 'floor=<xx.yy>' line (the measured line coverage)"
floor=${COVERAGE_FLOOR:-$floor}

echo "=== cargo llvm-cov (line coverage) ==="
cargo llvm-cov --locked --all-targets --all-features \
    --lcov --output-path "$LCOV"

read -r found covered pct <<<"$(
    awk -F: '/^LF:/ { found += $2 } /^LH:/ { hit += $2 }
             END { printf "%d %d %.2f", found, hit, (found ? 100 * hit / found : 0) }' "$LCOV"
)"

((found > 0)) || die "$LCOV has no line records; the measurement did not run"
echo "gate-coverage: $covered/$found lines = $pct% (floor $floor%)"

if awk -v p="$pct" -v f="$floor" 'BEGIN { exit !(p + 0 < f + 0) }'; then
    die "line coverage $pct% is below the floor $floor% ($covered/$found lines, $LCOV)"
fi

echo "gate-coverage: ok"
