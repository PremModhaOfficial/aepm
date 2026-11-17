#!/usr/bin/env bash
# Renames the package everywhere in this repo. One-time use, kept because the
# name is still undecided: edit `name` in Cargo.toml back and run it again with
# the old name, which is the whole cost of changing your mind.
#
# Usage: scripts/rename.sh <new-name> [--dry-run]
#   old name is read from Cargo.toml, so the script works once and never again
#   after a successful run without re-reading it.
set -euo pipefail

cd "$(dirname "$0")/.."

new="${1:?usage: scripts/rename.sh <new-name> [--dry-run]}"
dry="${2:-}"
old="$(sed -n 's/^name = "\(.*\)"/\1/p' Cargo.toml | head -1)"
[ -n "$old" ] || { echo "cannot read package name from Cargo.toml" >&2; exit 1; }
[ "$old" != "$new" ] || { echo "package is already $new" >&2; exit 1; }

old_snake="${old//-/_}"
new_snake="${new//-/_}"
old_upper="$(echo "$old" | tr 'a-z-' 'A-Z_')"
new_upper="$(echo "$new" | tr 'a-z-' 'A-Z_')"

mapfile -t files < <(grep -rl --binary-files=without-match \
  -e "$old" -e "$old_snake" -e "$old_upper" \
  --exclude-dir=target --exclude-dir=.git --exclude=.git \
  --exclude='*.png' . || true)
# --exclude=.git is not redundant: inside a git worktree `.git` is a file holding
# `gitdir: /path/to/<old-name>/.git/worktrees/<x>`, so rewriting it breaks the
# worktree (every later git command dies with "gitfile does not point to a valid
# repository").
echo "old=$old new=$new files=${#files[@]}"

for f in "${files[@]}"; do
  if [ "$dry" = "--dry-run" ]; then
    printf '  would edit %s\n' "$f"
    continue
  fi
  sed -i "s/${old_upper}/${new_upper}/g; s/${old_snake}/${new_snake}/g; s/${old}/${new}/g" "$f"
done

# Unit, service and packaging files are named after the package, not just
# containing it.
if [ "$dry" != "--dry-run" ]; then
  while IFS= read -r p; do
    git mv "$p" "${p//$old/$new}"
  done < <(git ls-files | grep -F "$old" || true)
  git status --short | head -20
  echo "now: set 'name' in Cargo.toml, rebuild, run ./ci.sh"
fi
