#!/bin/sh
# One setting covers every worktree: core.hooksPath is repo config, not per-tree.
# A checkout that predates scripts/ has no hook and commits without one; CI runs
# the same fmt check, so that costs convenience, not correctness.
set -eu
git config core.hooksPath scripts/githooks
echo "core.hooksPath=$(git config core.hooksPath)"
