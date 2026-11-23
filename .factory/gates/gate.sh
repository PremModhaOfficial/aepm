#!/usr/bin/env bash
# gate.sh — the deterministic gate. Exit code is truth; an agent's opinion is not.
#
#   gate.sh all    --sha <40-hex> --ticket-file <ticket>   # everything (the builder passes this)
#   gate.sh fast   --sha <40-hex> --ticket-file <ticket>   # scope + secrets + diff size + fmt (seconds)
#   gate.sh build  --sha <40-hex> --ticket-file <ticket>   # clippy -D warnings + build
#   gate.sh test   --sha <40-hex> --ticket-file <ticket>   # the test suite
#   gate.sh --self-test             # prove this gate can fail
#
# Both flags are required for a verdict: --sha names the tree judged,
# --ticket-file the mandate. Run it from a checkout that is not the head judged.
#
#   --sha <40-hex>    judge THAT commit (a clean `git worktree` of it), not $ROOT
#   --ticket-file <p> read the mandate from <p> instead of $FACTORY/tickets/<T>.md
#   --base <ref>      the base a change is measured against; GATE_BASE is the same fact in an env prefix this repo's guard refuses on shape
#
# Checks: changes only inside the ticket scope, diff size, secret scan of added
# lines, cargo fmt, clippy -D warnings, build, tests. Writes
# .factory/gates/last-gate.json. Exits non-zero on the first failing phase.
# A file the diff refuses to show as text is a failure, not a skip: its lines
# cannot be counted and its bytes cannot be scanned.
#
# Two rules keep the gate from judging itself:
#   1. What the gate reads about its own policy (config.yml: the caps) and its
#      own state (the ticket) comes from the JUDGE, never from the judged tree.
#      So a commit cannot raise its own line cap.
#   2. Only runtime state is exempt from the scope check, and .factory/ code is
#      counted in the size phase like any other code. So a commit cannot neuter
#      gate.sh and pass: replacing the gate is a change, and changes are judged.
set -uo pipefail
FACTORY="${GATE_FACTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
JUDGED_REPO="${GATE_ROOT:-$(cd "$FACTORY/.." && pwd)}"
ROOT="$JUDGED_REPO"
PHASE="${1:-all}"
shift || true
TICKET=""
TICKET_FILE=""
SHA=""
BASE_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ticket) [ $# -ge 2 ] || { echo "--ticket needs a value" >&2; exit 2; }; TICKET="$2"; shift 2 ;;
    --ticket-file) [ $# -ge 2 ] || { echo "--ticket-file needs a value" >&2; exit 2; }; TICKET_FILE="$2"; shift 2 ;;
    --sha) [ $# -ge 2 ] || { echo "--sha needs a value" >&2; exit 2; }; SHA="$2"; shift 2 ;;
    --base) [ $# -ge 2 ] && [ -n "$2" ] || { echo "--base needs a ref" >&2; exit 2; }; BASE_ARG="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

# Box rule: 9.6 of 16 cores for agents. Never -j 16.
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-6}"
export RUST_TEST_THREADS="${RUST_TEST_THREADS:-4}"
export CI="${CI:-}" # keep ci.sh's own job defaults intact, we set jobs here

fail() { echo "GATE FAIL [$1]: $2" >&2; record "$1" "fail" "$2"; exit 1; }
pass() { echo "GATE OK   [$1]: $2"; }

RESULT_FILE="$FACTORY/gates/last-gate.json"
record() { # phase status detail
  # `--ticket-file` carries no id, so read it from the ticket: the record names it.
  local tid="${TICKET:-}"
  if [ -z "$tid" ] && [ -n "$TICKET_FILE" ] && [ -f "$TICKET_FILE" ]; then
    tid="$(awk 'NR==1{next} /^---$/{exit} {print}' "$TICKET_FILE" | sed -n 's/^id: *//p' | head -1)"
  fi
  mkdir -p "$FACTORY/gates"
  jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg phase "$1" \
    --arg status "$2" --arg detail "$3" --arg ticket "${tid:-none}" \
    --arg head "$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo none)" \
    '{ts:$ts,ticket:$ticket,phase:$phase,status:$status,detail:$detail,head:$head}' \
    >"$RESULT_FILE"
  [ -n "${FACTORY_LEDGER:-}" ] && printf '%s\n' "$(cat "$RESULT_FILE")" >>"$FACTORY_LEDGER"
  return 0
}

cfg() { # config.yml value with its trailing comment stripped; the JUDGE's config
  sed -n "s/^ *$1: *//p" "$FACTORY/config.yml" | head -1 | sed 's/[[:space:]]*#.*//; s/[[:space:]]*$//'
}

# Only runtime state is exempt: what the factory writes about itself while it
# works. Code is never exempt — gate.sh, scripts/, roles/, config.yml and rules
# are judged like any other file, or a commit could rewrite its own judge.
exempt() {
  case "$1" in
    .factory/state.md|*/.factory/state.md) return 0 ;;
    .factory/ledger.jsonl|*/.factory/ledger.jsonl) return 0 ;;
    .factory/guard.log|*/.factory/guard.log) return 0 ;;
    .factory/gates/last-gate.json|*/.factory/gates/last-gate.json) return 0 ;;
    .factory/tickets|.factory/tickets/|.factory/tickets/*|*/.factory/tickets/*) return 0 ;;
    .factory/inbox|.factory/inbox/|.factory/inbox/*|*/.factory/inbox/*) return 0 ;;
    .factory/research/*|*/.factory/research/*) return 0 ;;
  esac
  return 1
}

ticket_path() { # where the mandate lives; machine-local state, not the commit
  if [ -n "$TICKET_FILE" ]; then printf '%s\n' "$TICKET_FILE"; return 0; fi
  [ -n "$TICKET" ] || return 1
  printf '%s\n' "$FACTORY/tickets/$TICKET.md"
}

scope_list() { # ticket scope value -> newline separated prefixes
  local tf
  tf="$(ticket_path)" || return 0
  [ -f "$tf" ] || return 0
  awk 'NR==1{next} /^---$/{exit} {print}' "$tf" \
    | sed -n 's/^scope: *//p' | head -1 | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^$'
}

ticket_field() { # a front-matter value from the ticket (the JUDGE's copy)
  local tf
  tf="$(ticket_path)" || return 0
  [ -f "$tf" ] || return 0
  awk 'NR==1{next} /^---$/{exit} {print}' "$tf" | sed -n "s/^$1: *//p" | head -1
}

base_ref() { # the commit a change is measured against
  # Named (`--base` or GATE_BASE): a base that cannot be resolved is a refusal,
  # never a silent fallback to merge-base — that is the defect, not the fix.
  if [ -n "${BASE_ARG:-}${GATE_BASE:-}" ]; then
    git -C "$ROOT" rev-parse --verify -q "${BASE_ARG:-$GATE_BASE}^{commit}" 2>/dev/null && return
    return 1
  fi
  if git -C "$ROOT" rev-parse --verify -q origin/main >/dev/null 2>&1; then
    git -C "$ROOT" merge-base HEAD origin/main && return
  fi
  git -C "$ROOT" rev-parse --verify -q HEAD~1 2>/dev/null
}

# A phase that diffs needs a base: the empty tree as a base judged nothing.
need_base() {
  local st
  BASE="$(base_ref)"; st=$?
  if [ -n "${BASE_ARG:-}${GATE_BASE:-}" ] && [ "$st" != 0 ]; then
    fail base "a base named '${BASE_ARG:-${GATE_BASE:-}}' is not a commit in $ROOT"
  fi
  if [ -n "$BASE_ARG" ] && [ -n "${GATE_BASE:-}" ] \
    && [ "$BASE" != "$(git -C "$ROOT" rev-parse --verify -q "$GATE_BASE^{commit}" 2>/dev/null)" ]; then
    fail base "--base '$BASE_ARG' and GATE_BASE='$GATE_BASE' are different commits: refusing rather than choosing one"
  fi
  [ -n "$BASE" ] \
    || fail base "no base commit to diff against in $ROOT (no origin/main, no HEAD~1): pass --base <ref>, or run where the default branch is fetched"
}

# The change, as one set: STATUS<TAB>path records, each NUL-TERMINATED. Scope and
# size used to compute this separately and disagreed about what "the change" is,
# which is how an untracked file and a rename's new path escaped one of them.
# ONE tree for EVERY phase: the working tree against $BASE (two dots) + untracked.
# It was `$BASE...HEAD` (commits only) while size/secrets diffed `$BASE` (T-15 R11).
# A path is bytes, not a line: it may contain a newline, so a newline-terminated
# record split one path into two, and the caller's line loop then judged a prefix
# that does not exist while the real file was skipped by the size cap and the
# secret scan. Every reader therefore uses `read -d ''`; never a line loop.
changed_paths() {
  local st f rec rc raw
  raw="$(mktemp)"; CHANGED_ERR=""
  # Tracked: with -z the status field is its own NUL-terminated field (no tab),
  # and nothing is quoted, so a path with a newline or a space arrives as bytes.
  git -C "$ROOT" diff --name-status --no-renames -z "$BASE" >"$raw" 2>/dev/null; rc=$?
  [ "$rc" = 0 ] || { rm -f "$raw"; CHANGED_ERR="git diff could not list the change against $(git -C "$ROOT" rev-parse --short "$BASE" 2>/dev/null) (git exit $rc)"; return 1; }
  while IFS= read -r -d '' st; do
    IFS= read -r -d '' f || break
    [ -n "$f" ] || continue
    printf '%s\t%s\0' "$st" "$f"
  done <"$raw"
  # Untracked only: `git status` also lists every modified tracked file, which the
  # diff above already emitted, so emitting those here counted one file twice in
  # the scope phase (T-15 R16, 4658402378). A rename is the diff's D+A pair, so
  # there is never a second path to unpack here.
  git -C "$ROOT" status --porcelain -z -uall >"$raw" 2>/dev/null; rc=$?
  [ "$rc" = 0 ] || { rm -f "$raw"; CHANGED_ERR="git status could not list the tree (git exit $rc)"; return 1; }
  while IFS= read -r -d '' rec; do
    st="${rec:0:2}"; f="${rec:3}"
    [ "$st" = "??" ] || continue
    [ -n "$f" ] || continue
    printf '%s\t%s\0' "$st" "$f"
  done <"$raw"
  rm -f "$raw"
}

# --- pin the judged tree -----------------------------------------------------
# The judge (this script, its config, its ticket) stays put; only the tree that
# gets diffed, built and tested is pinned. A dirty working tree therefore cannot
# stand in for a head, and a head cannot edit the caps it is judged by.
PINNED=""
cleanup_pin() {
  if [ -n "$PINNED" ]; then
    git -C "$JUDGED_REPO" worktree remove --force "$PINNED" >/dev/null 2>&1 || true
    rm -rf "$PINNED" 2>/dev/null || true
  fi
}
trap cleanup_pin EXIT

if [ -n "$SHA" ]; then
  case "$SHA" in
    *[!0-9a-f]*|"") fail pin "--sha needs a full 40-hex commit id (got '$SHA')" ;;
  esac
  [ "${#SHA}" = 40 ] || fail pin "--sha needs a full 40-hex commit id (got '${SHA}', ${#SHA} chars)"
  git -C "$JUDGED_REPO" rev-parse --verify -q "$SHA^{commit}" >/dev/null 2>&1 \
    || fail pin "commit $SHA is not in $JUDGED_REPO — fetch it before judging it"
  PINNED="$(mktemp -d)/head"
  git -C "$JUDGED_REPO" worktree add --detach "$PINNED" "$SHA" >/dev/null 2>&1 \
    || fail pin "could not create a clean worktree of $SHA"
  ROOT="$PINNED"
fi

phase_scope() {
  local f bad=0 allowed tf n st recs
  need_base
  recs="$(mktemp)"
  # Counted from NUL records, never from lines (a path may contain a newline), and
  # from the read's STATUS, never its emptiness (T-15 R18, r4658452342).
  changed_paths >"$recs" || { rm -f "$recs"; fail scope "the change could not be read, so nothing here says it is inside the mandate: $CHANGED_ERR"; }
  n="$(tr -cd '\000' <"$recs" | wc -c | tr -d ' ')"
  [ "${n:-0}" -gt 0 ] || { rm -f "$recs"; pass scope "no changes to judge (head $(git -C "$ROOT" rev-parse --short HEAD) vs base $(git -C "$ROOT" rev-parse --short "$BASE"))"; return 0; }
  allowed="$(scope_list)"
  if [ -z "$allowed" ]; then
    # Name exactly what is missing. The mandate is machine-local state, so a
    # clean clone has no ticket: that is why --ticket-file exists.
    if [ -z "$TICKET" ] && [ -z "$TICKET_FILE" ]; then
      fail scope "$n file(s) changed but no --ticket (or --ticket-file) was given, so nothing declares a mandate"
    fi
    tf="$(ticket_path)"
    if [ ! -f "$tf" ]; then
      fail scope "no ticket file at $tf — the mandate is machine-local state, not part of the commit; pass --ticket-file <path>, or create it: bash $FACTORY/scripts/ticket.sh new <slug> --request '<verbatim>' --scope '<p1,p2>'"
    fi
    fail scope "ticket ${TICKET:-$tf} declares no scope in $tf — an issue ticket starts empty (authority: inferred); the planner proposes the mandate and the Router applies it: bash $FACTORY/scripts/ticket.sh set <T> scope '<p1,p2>'"
  fi
  while IFS=$'\t' read -r -d '' st f; do
    [ -n "$f" ] || continue
    # Only UNTRACKED runtime state is exempt. A path force-added to a commit
    # (`git add -f .factory/tickets/x`) is part of the change, not state the
    # factory wrote while working, so exempting it would land a file outside the
    # mandate behind a green scope line (T-15 R9, b46c4b2b9c65).
    [ "$st" = "??" ] && exempt "$f" && continue
    local ok=1
    while IFS= read -r a; do
      # An entry is that path or its subtree behind a `/`: a raw string prefix
      # (`"$a"*`) let a mandate of `src` admit `srcfoo/evil.txt`.
      a="${a%/}"
      [ "$f" = "$a" ] && ok=0
      case "$f" in "$a"/*) ok=0 ;; esac
    done <<<"$allowed"
    if [ "$ok" = 1 ]; then
      echo "  outside scope: $st $f" >&2
      bad=1
    fi
  done <"$recs"
  rm -f "$recs"
  [ "$bad" = 0 ] || fail scope "change(s) outside the ticket mandate (allowed: $(echo "$allowed" | tr '\n' ' '))"
  pass scope "$n file(s) inside the mandate"
}

# The most bytes this gate will read out of one untracked file, and the most
# added text it will put through eleven regex passes. Past it a path is refused
# by name: an unbounded read is how one 120 MiB untracked line passed the 1-line
# cap and spent 81s in the secret scan.
SCAN_MAX_BYTES=4194304

untracked_lines() { # <path> — sets UNTRACKED_LINES, or fails by name; never skipped
  local p="$ROOT/$1" copy bytes nul
  # A symlink is neither counted nor scanned: following one is unbounded
  # (`/dev/zero` hangs the gate forever) and it can carry bytes from outside the
  # repo that this gate has no mandate over. Refused by name, like every other
  # path it will not read.
  [ -L "$p" ] && fail size "the change is a symlink, which this gate neither counts nor scans: $1"
  [ -f "$p" ] || fail size "the change is not a regular file, so it has no lines to count and no bytes to scan: $1"
  # One read, frozen: the count, the size test and the binary test then describe
  # the same bytes. Two passes over the original file compared two instants, so a
  # file that grew while the gate ran was reported as binary.
  copy="$(mktemp)"
  if ! head -c "$((SCAN_MAX_BYTES + 1))" -- "$p" >"$copy" 2>/dev/null; then
    rm -f "$copy"
    fail size "this path cannot be read, so its lines cannot be counted and its bytes cannot be scanned: $1"
  fi
  bytes="$(wc -c <"$copy" | tr -d ' ')"
  if [ "${bytes:-0}" -gt "$SCAN_MAX_BYTES" ]; then
    rm -f "$copy"
    fail size "this untracked file is over the ${SCAN_MAX_BYTES}-byte scan bound, so it is refused rather than half-read: $1"
  fi
  # A NUL byte is what makes git call a file binary; without this test a 2 MiB
  # blob with no newline counted as the one record awk sees and passed the cap.
  # (`$'\000'` is the empty string in bash, so the test is `tr -dc`, counting the
  # NULs out of the frozen copy: the same bytes awk counts, not a second read.)
  nul="$(LC_ALL=C tr -dc '\000' <"$copy" | wc -c | tr -d ' ')"
  if [ "${nul:-0}" -gt 0 ]; then
    rm -f "$copy"
    fail size "the diff refuses to show these files as text, so their lines cannot be counted and their bytes cannot be scanned: $1"
  fi
  UNTRACKED_LINES="$(awk 'END{print NR+0}' "$copy")"
  rm -f "$copy"
  return 0
}

phase_size() {
  local max_lines max_files stat lines files bin st f errf rc
  max_lines="$(cfg diff_lines_max)"; max_lines="${max_lines:-600}"
  max_files="$(cfg diff_files_max)"; max_files="${max_files:-30}"
  # A ticket may carry its own cap. The mandate is already trusted and lives
  # outside the judged tree, so this cannot be raised by the commit under review;
  # the config default applies when the ticket says nothing.
  local tmax
  tmax="$(ticket_field diff_lines_max)"; [ -n "$tmax" ] && max_lines="$tmax"
  tmax="$(ticket_field diff_files_max)"; [ -n "$tmax" ] && max_files="$tmax"
  need_base
  # No path is dropped here: .factory/ code counts like any other code.
  # A `git diff` that fails — an unreadable tracked file makes it exit 128 and
  # print no numstat at all — used to be swallowed by `|| true`, so a 700-line
  # change with a token counted as "0 lines across 0 files" and passed. It fails
  # by name now: a count that does not exist is not a count of zero.
  errf="$(mktemp)"
  stat="$(git -C "$ROOT" diff --numstat --no-renames "$BASE" 2>"$errf")"; rc=$?
  if [ "$rc" != 0 ]; then
    local why; why="$(head -2 "$errf" | tr '\n' ' ')"; rm -f "$errf"
    fail size "git could not diff this tree against $(git -C "$ROOT" rev-parse --short "$BASE"), so no line count exists (git exit $rc): ${why:-no message}"
  fi
  rm -f "$errf"
  # `-` in a numstat column means git will not show the file as text: its lines
  # are absent from the sum below and its bytes from the scan, so fail, not skip.
  bin="$(printf '%s\n' "$stat" | awk -F'\t' '$1=="-"||$2=="-"{print $3}' | tr '\n' ' ')"
  [ -z "${bin// /}" ] || fail size "the diff refuses to show these files as text, so their lines cannot be counted and their bytes cannot be scanned: ${bin% }"
  lines="$(printf '%s\n' "$stat" | awk 'NF{a+=$1; d+=$2} END{print a+d+0}')"
  files="$(printf '%s\n' "$stat" | awk 'NF' | wc -l | tr -d ' ')"
  # The half `git diff` never shows. An untracked file is scope-checked, so it is
  # the ticket's change and counts here too, or a change grows past the cap by
  # never being added. Runtime state stays exempt: it is not the product change.
  # `git` has no numstat mark for a path it was never told about, so every test
  # `git diff` would have made is made here: symlinks, non-files and unreadable
  # paths are refused by name and an oversized one is refused rather than read.
  while IFS=$'\t' read -r -d '' st f; do
    [ "$st" = "??" ] && [ -n "$f" ] || continue
    exempt "$f" && continue
    untracked_lines "$f"
    lines=$((lines + UNTRACKED_LINES))
    files=$((files + 1))
  done < <(changed_paths)
  [ "${lines:-0}" -le "$max_lines" ] || fail size "diff is ${lines} lines, cap ${max_lines}"
  [ "${files:-0}" -le "$max_files" ] || fail size "diff touches ${files} files, cap ${max_files}"
  pass size "${lines} lines across ${files} files (cap ${max_lines}/${max_files})"
}

phase_secrets() {
  # Scan ADDED lines only: a secret already in history is a different ticket.
  # -oE extracts the SECRET, not the line: a live key beside the word "example"
  # is still a live key, and placeholders are filtered per token, not per line.
  local added pat t hits="" st f dfl errf rc abytes why
  need_base
  # Added lines are read from the hunk and from nothing else. A header filter
  # (`grep -vE '^\+\+\+ (a/|b/|/dev/null)'`) also dropped a CONTENT line whose text
  # begins `++ b/`: the diff writes it as `+++ b/...`, so a token on it was never
  # scanned. Inside a hunk a line starting `+` is content; a header never is.
  # A binary file never reaches here: the size phase already failed it.
  errf="$(mktemp)"; dfl="$(mktemp)"
  git -C "$ROOT" diff -U0 --no-renames "$BASE" >"$dfl" 2>"$errf"; rc=$?
  if [ "$rc" != 0 ]; then
    why="$(head -2 "$errf" | tr '\n' ' ')"; rm -f "$errf" "$dfl"
    fail secrets "git could not diff this tree against $(git -C "$ROOT" rev-parse --short "$BASE"), so no added line could be scanned (git exit $rc): ${why:-no message}"
  fi
  rm -f "$errf"
  added="$(awk '
    /^@@/ { hunk = 1; next }
    !hunk { next }
    /^\+/ { print substr($0, 2); next }
    /^[- ]/ { next }
    { hunk = 0 }
  ' "$dfl")"
  rm -f "$dfl"
  # `git diff` never shows an untracked file, so this half is the only way the
  # bytes of a file the scope phase accepted reach the scan: every non-exempt
  # `??` path is judged by scope, counted and bounded by size, so it is scanned
  # here too. A binary file needs no scan: phase_size refuses both the tracked
  # one (numstat mark) and the untracked one (NUL bytes), so no binary reaches
  # this half.
  while IFS=$'\t' read -r -d '' st f; do
    [ "$st" = "??" ] && [ -n "$f" ] || continue
    exempt "$f" && continue
    untracked_lines "$f"
    added="${added:+$added$'\n'}$(head -c "$((SCAN_MAX_BYTES + 1))" -- "$ROOT/$f")"
  done < <(changed_paths)
  [ -n "$added" ] || { pass secrets "no added lines to scan"; return 0; }
  # Bound the bytes the regex passes read. Eleven -oE passes over one 120 MiB
  # line cost 81s; past the bound the text is refused by name, never half-scanned.
  abytes="$(printf '%s' "$added" | wc -c | tr -d ' ')"
  [ "${abytes:-0}" -le "$SCAN_MAX_BYTES" ] \
    || fail secrets "the added lines are ${abytes} bytes, over the ${SCAN_MAX_BYTES}-byte scan bound, so they are refused rather than half-scanned"
  for pat in \
    'gh[pousr]_[A-Za-z0-9]{20,}' \
    'github_pat_[A-Za-z0-9_]{20,}' \
    'AKIA[0-9A-Z]{16}' \
    'sk-ant-[A-Za-z0-9_-]{16,}' \
    'sk-[A-Za-z0-9]{20,}' \
    'glpat-[A-Za-z0-9_-]{16,}' \
    'xox[baprs]-[A-Za-z0-9-]{10,}' \
    '-----BEGIN [A-Z ]*PRIVATE KEY-----' \
    'postgres(ql)?://[A-Za-z0-9._-]+:[^@[:space:]]+@' \
    '(api[_-]?key|secret|token|passwd|password|OPENAI_API_KEY|ANTHROPIC_API_KEY)[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9_./+@:-]{16,}'
  do
    t="$(printf '%s\n' "$added" | grep -oE "$pat" 2>/dev/null || true)"
    [ -n "$t" ] || continue
    t="$(printf '%s\n' "$t" | grep -viE 'example|placeholder|redacted|dummy|sample|changeme|your[_-]|^x{4,}$|\$\{|\$[A-Z_]+' || true)"
    [ -n "$t" ] || continue
    hits="$hits$t"$'\n'
  done
  [ -z "$hits" ] || fail secrets "possible secret in added lines: $(printf '%s' "$hits" | head -3 | cut -c1-120 | tr '\n' ' ')"
  pass secrets "no secret pattern in added lines"
}

require_cargo() { # a phase that cannot run is a failure, never a skip and exit 0
  [ -f "$ROOT/Cargo.toml" ] && return 0
  fail "$1" "no Cargo.toml at $ROOT — refusing to report success on a phase that did not run"
}

phase_fmt() {
  require_cargo fmt
  ( cd "$ROOT" && cargo fmt --all --check ) >/dev/null 2>&1 \
    && pass fmt "cargo fmt --all --check" \
    || fail fmt "cargo fmt --all --check (run: cargo fmt --all)"
}

phase_build() {
  require_cargo build
  ( cd "$ROOT" && cargo clippy --all-targets --all-features --locked -- -D warnings ) \
    || fail build "cargo clippy -D warnings"
  ( cd "$ROOT" && cargo build --locked --all-features ) \
    || fail build "cargo build --locked --all-features"
  pass build "clippy -D warnings + build"
}

phase_test() {
  require_cargo test
  ( cd "$ROOT" && cargo test --all-targets --all-features --locked ) \
    || fail test "cargo test --all-targets --all-features --locked"
  pass test "cargo test --all-targets --all-features --locked"
}

# Every phase reaches here having run: a phase that could not run fails inside
# itself (require_cargo), so no run can end green over a check nobody made.
summarise() { record "$1" pass "$2"; pass "$1" "$2"; }

case "$PHASE" in
  --self-test)
    # Prove the gate can fail. Hermetic: a throwaway repo in /tmp, no network.
    # Two trees, never one: JUDGE (this gate + its config + the ticket) and REPO
    # (the tree being judged). The whole point of F4/F5 is that they differ.
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    judge="$tmp/judge/.factory"
    mkdir -p "$judge"/{tickets,gates} "$tmp/repo/.factory/gates" "$tmp/repo/.factory/scripts" "$tmp/repo/src" "$tmp/repo/docs"
    cp "$FACTORY/config.yml" "$judge/config.yml"
    cp "$FACTORY/gates/gate.sh" "$judge/gates/gate.sh"
    cp "$FACTORY/config.yml" "$tmp/repo/.factory/config.yml"
    cp "$FACTORY/gates/gate.sh" "$tmp/repo/.factory/gates/gate.sh"
    repo="$tmp/repo"
    # The global config signs commits with an ssh key; a throwaway repo has no
    # agent socket, so signing is off here or every self-test commit fails.
    # origin/main is the base and the second commit is what the first assertion
    # measures: without a base ref that assertion could not fail.
    ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git config commit.gpgsign false \
      && echo 'a' >src/a.txt && echo 'b' >docs/b.txt && printf '[package]\nname = "sandbox"\nversion = "0.1.0"\nedition = "2021"\n' >Cargo.toml \
      && printf 'fn main() {}\n' >src/main.rs && git add -A && git commit -qm base \
      && git update-ref refs/remotes/origin/main HEAD \
      && echo 'in scope' >>src/a.txt && git commit -qam 'in scope' ) \
      || { echo "self-test FAILED: sandbox repo" >&2; exit 1; }
    printf -- '---\nid: T-1\nscope: src/\n---\n# T-1\n' >"$judge/tickets/T-1.md"
    # A ticket outside the judged tree: the mandate is machine-local state, so a
    # clean clone judges a head with a ticket that is not in that head.
    printf -- '---\nid: F-1\nscope: src/,.factory/\n---\n# F-1\n' >"$tmp/tickets-outside.md"
    printf -- '---\nid: F-2\nscope: src/\n---\n# F-2\n' >"$tmp/tickets-src.md"
    # The binary-mark attack also adds `.gitattributes`, so the mandate has to
    # cover it or the scope phase fails first and the size phase is never read.
    printf -- '---\nid: F-3\nscope: src/,.gitattributes\n---\n# F-3\n' >"$tmp/tickets-bin.md"

    # The sandbox is a real crate, and this `cargo` is a spy that writes the argv
    # it was handed and exits ${SPY_EXIT:-0}: the phases below therefore RUN, and
    # what they run is asserted instead of assumed. The drills used to set
    # GATE_ALLOW_NO_CARGO=1 in a tree with no manifest, so fmt, build and test
    # always took the skip path and a wrong flag, a missing --locked or a
    # swallowed clippy failure was invisible (T-15 R15, 24a0e64470a9).
    mkdir -p "$tmp/spy"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/argv"\nexit "${SPY_EXIT:-0}"\n' "$tmp/spy" >"$tmp/spy/cargo"
    chmod +x "$tmp/spy/cargo"
    gs() { # run the JUDGE's gate against ${GS_ROOT:-$repo}; extra args pass through
      # Bounded: a regression that hangs the gate (a symlink is read forever) must
      # fail this self-test, not hang it.
      ( cd "${GS_ROOT:-$repo}" && PATH="$tmp/spy:$PATH" GATE_ROOT="${GS_ROOT:-$repo}" GATE_FACTORY="$judge" \
          timeout 120 bash "$judge/gates/gate.sh" "$@" )
    }
    # Counted in a file: most assertions run inside `$(...)`. The hardcoded "15"
    # had already drifted from the 14 that ran.
    ASSERTIONS="$tmp/assertions"; : >"$ASSERTIONS"
    expect() { # want status, label, remaining args
      local want="$1" label="$2"; shift 2
      local out st=0
      echo . >>"$ASSERTIONS"
      out="$(gs "$@" 2>&1)" || st=$?
      if [ "$want" = ok ]; then
        [ "$st" = 0 ] || { echo "self-test FAILED: $label (exit $st): $(printf '%s' "$out" | tail -2)" >&2; exit 1; }
      else
        [ "$st" != 0 ] || { echo "self-test FAILED: $label (exit 0): $(printf '%s' "$out" | tail -2)" >&2; exit 1; }
      fi
      printf '%s' "$out"
    }

    # The base is real, so this measures a diff and can fail.
    c1="$(expect ok "a clean tree inside scope passes" fast --ticket T-1)"
    printf '%s' "$c1" | grep -q '1 file(s) inside the mandate' \
      || { echo "self-test FAILED: the first assertion judged no diff at all: $(printf '%s' "$c1" | tail -2)" >&2; exit 1; }
    echo "ok  - a clean tree inside scope passes"
    # The fmt phase ran, really: its pass line and the argv cargo was handed.
    printf '%s' "$c1" | grep -q 'GATE OK   \[fmt\]: cargo fmt --all --check' \
      || { echo "self-test FAILED: the fmt phase did not run: $(printf '%s' "$c1" | tail -2)" >&2; exit 1; }
    grep -qx 'fmt --all --check' "$tmp/spy/argv" \
      || { echo "self-test FAILED: the fmt phase invoked something else: $(tr '\n' ';' <"$tmp/spy/argv")" >&2; exit 1; }
    echo "ok  - the fmt phase really invokes cargo fmt --all --check"
    # build: the exact two invocations, --locked and -D warnings included. A
    # wrong flag or a dropped --locked turns this red, which the skip path could
    # never do: the old drill only proved the phase was skipped.
    : >"$tmp/spy/argv"
    out="$(expect ok "the sandbox build phase" build --ticket T-1)"
    for want in 'clippy --all-targets --all-features --locked -- -D warnings' 'build --locked --all-features'; do
      grep -qxF "$want" "$tmp/spy/argv" \
        || { echo "self-test FAILED: the build phase did not run 'cargo $want': $(tr '\n' ';' <"$tmp/spy/argv")" >&2; exit 1; }
    done
    printf '%s' "$out" | grep -q 'GATE OK   \[build\]' \
      || { echo "self-test FAILED: the build phase did not pass: $(printf '%s' "$out" | tail -2)" >&2; exit 1; }
    echo "ok  - the build phase runs clippy -D warnings then build --locked"
    out="$(SPY_EXIT=1 expect fail "a cargo that fails" build --ticket T-1)"
    printf '%s' "$out" | grep -q 'GATE FAIL \[build\]' \
      || { echo "self-test FAILED: a failing cargo did not fail the phase: $(printf '%s' "$out" | tail -2)" >&2; exit 1; }
    echo "ok  - a cargo that fails fails the phase, never a green build"
    : >"$tmp/spy/argv"
    expect ok "the sandbox test phase" test --ticket T-1 >/dev/null
    grep -qxF 'test --all-targets --all-features --locked' "$tmp/spy/argv" \
      || { echo "self-test FAILED: the test phase did not run 'cargo test --all-targets --all-features --locked': $(tr '\n' ';' <"$tmp/spy/argv")" >&2; exit 1; }
    echo "ok  - the test phase runs cargo test --all-targets --all-features --locked"
    # The argv spy proves which invocation; these prove the REAL toolchain is on
    # the other end of it — a real crate that builds, and a real warning that
    # -D warnings turns into a failure.
    crate="$tmp/crate"; mkdir -p "$crate/src"
    printf '[package]\nname = "sandbox-crate"\nversion = "0.1.0"\nedition = "2021"\n' >"$crate/Cargo.toml"
    printf 'fn main() {}\n' >"$crate/src/main.rs"
    ( cd "$crate" && cargo generate-lockfile --offline -q ) \
      || { echo "self-test FAILED: could not prepare the real crate" >&2; exit 1; }
    echo . >>"$ASSERTIONS"; echo . >>"$ASSERTIONS"
    out="$( cd "$crate" && GATE_ROOT="$crate" GATE_FACTORY="$judge" \
      timeout 300 bash "$judge/gates/gate.sh" build 2>&1 )"; st=$?
    { [ "$st" = 0 ] && printf '%s' "$out" | grep -q 'GATE OK   \[build\]'; } \
      || { echo "self-test FAILED: a real crate did not build through the gate: $(printf '%s' "$out" | tail -3)" >&2; exit 1; }
    printf 'fn main() { let unused = 1; }\n' >"$crate/src/main.rs"
    out="$( cd "$crate" && GATE_ROOT="$crate" GATE_FACTORY="$judge" \
      timeout 300 bash "$judge/gates/gate.sh" build 2>&1 )"; st=$?
    { [ "$st" != 0 ] && printf '%s' "$out" | grep -q 'GATE FAIL \[build\]'; } \
      || { echo "self-test FAILED: -D warnings did not fail a real warning: $(printf '%s' "$out" | tail -3)" >&2; exit 1; }
    printf 'fn main() {}\n' >"$crate/src/main.rs"
    echo "ok  - a real crate builds through the phase, and a real warning fails it"
    out="$(expect ok "gate all in the sandbox" all --ticket-file "$judge/tickets/T-1.md")"
    printf '%s' "$out" | grep -q 'GATE OK   \[all\]: scope+size+secrets+fmt+build+test' \
      || { echo "self-test FAILED: gate all did not run every phase: $(printf '%s' "$out" | tail -3)" >&2; exit 1; }
    grep -q '"status":"pass"' "$judge/gates/last-gate.json" \
      || { echo "self-test FAILED: gate all was not recorded as a pass: $(cat "$judge/gates/last-gate.json")" >&2; exit 1; }
    echo "ok  - gate all runs all six phases and records a pass"
    # T-15 round 8, Q4: the record said `ticket:"none"` under --ticket-file.
    grep -q '"ticket":"T-1"' "$judge/gates/last-gate.json" \
      || { echo "self-test FAILED: last-gate.json did not name the ticket under --ticket-file: $(cat "$judge/gates/last-gate.json")" >&2; exit 1; }
    echo "ok  - last-gate.json names the ticket when --ticket-file is used"
    # A phase that cannot run is a failure by name, never a skip and never exit 0:
    # the escape hatch that left both is gone (T-15 R15: 21409ed6be3d, 638795a4c6cf).
    out="$( cd "$crate" && GATE_ROOT="$tmp/nocrate" GATE_FACTORY="$judge" \
      timeout 120 bash "$judge/gates/gate.sh" build 2>&1 )"; st=$?
    [ "$st" != 0 ] \
      || { echo "self-test FAILED: a missing Cargo.toml passed: $(printf '%s' "$out" | tail -3)" >&2; exit 1; }
    printf '%s' "$out" | grep -q 'GATE FAIL \[build\].*refusing to report success' \
      || { echo "self-test FAILED: a missing Cargo.toml was not refused by name: $(printf '%s' "$out" | tail -3)" >&2; exit 1; }
    echo "ok  - a phase that cannot run fails by name and cannot be skipped"
    # One record per path: a tracked file modified in the working tree arrives
    # from the diff AND from `git status`, so the scope phase counted one file as
    # two (T-15 R16, 4658402378).
    echo more >>"$repo/src/a.txt"
    out="$(expect ok "one tracked file, modified" fast --ticket T-1)"
    printf '%s' "$out" | grep -q '1 file(s) inside the mandate' \
      || { echo "self-test FAILED: one modified file counted twice: $(printf '%s' "$out" | grep 'inside the mandate')" >&2; exit 1; }
    ( cd "$repo" && git checkout -- src/a.txt )
    echo "ok  - a tracked file modified in the working tree is one record, not two"
    ( cd "$repo" && cp .git/index "$tmp/idx.bak" && printf junk >.git/index )
    out="$(expect fail "a diff the gate could not produce" fast --ticket T-1)"
    ( cd "$repo" && cp "$tmp/idx.bak" .git/index )
    printf '%s' "$out" | grep -q 'GATE FAIL \[scope\].*could not be read' || { echo "self-test FAILED: a failed diff was not refused by scope: $(printf '%s' "$out" | tail -2)" >&2; exit 1; }
    echo "ok  - a change the gate could not read fails the scope phase by name (r4658452342)"
    # A flag as the last word is refused by name, not an unbound-variable abort:
    # `set -u` alone turned `--sha` with no value into exit 1 and a bash message.
    echo . >>"$ASSERTIONS"
    out="$( cd "$repo" && GATE_ROOT="$repo" GATE_FACTORY="$judge" \
      timeout 120 bash "$judge/gates/gate.sh" fast --ticket T-1 --sha 2>&1 )"; st=$?
    { [ "$st" = 2 ] && printf '%s' "$out" | grep -q -- '--sha needs a value'; } \
      || { echo "self-test FAILED: a flag with no value was not refused by name (exit $st): $(printf '%s' "$out" | tail -2)" >&2; exit 1; }
    echo "ok  - a flag with no value is refused by name, exit 2"
    ( cd "$repo" && echo c >>docs/b.txt && git commit -qam out )
    expect fail "a change outside the ticket scope" fast --ticket T-1 >/dev/null
    echo "ok  - a change outside the ticket scope fails"
    # A staged rename prints `R  old -> new`. Field 2 of that line is the OLD
    # path, so `awk '{print $2}'` judged src/a.txt -> docs/moved.txt from the
    # inside and never saw the new path outside the mandate.
    keep="$(cd "$repo" && git rev-parse HEAD)"
    ( cd "$repo" && git reset -q --hard HEAD~1 && git mv src/a.txt docs/moved.txt )
    out="$(expect fail "a staged rename is judged at its new path" fast --ticket T-1)"
    # Either shape names the new path: `--no-renames` makes the diff's D+A pair,
    # and the assertion is that the NEW path is judged, not how porcelain spells it.
    printf '%s' "$out" | grep -qE 'outside scope: (R|A) *docs/moved.txt' \
      || { echo "self-test FAILED: a staged rename hid its new path: $(printf '%s' "$out" | tail -3)" >&2; exit 1; }
    echo "ok  - a staged rename is judged at its new path"
    ( cd "$repo" && git reset -q --hard "$keep" )
    # T-15 round 8, finding 2: a raw string prefix (`"$a"*`) let `src` admit
    # `srcfoo/evil.txt`. An entry is that path or its subtree behind a `/` (Q2).
    printf -- '---\nid: P-1\nscope: src\n---\n# P-1\n' >"$tmp/tickets-prefix.md"
    ( cd "$repo" && git reset -q --hard HEAD~1 && mkdir -p srcfoo && echo evil >srcfoo/evil.txt && git add -A && git commit -qm sibling )
    out="$(expect fail "a directory that only shares a prefix" fast --ticket-file "$tmp/tickets-prefix.md")"
    printf '%s' "$out" | grep -q 'outside scope: A *srcfoo/evil.txt' \
      || { echo "self-test FAILED: a scope entry admitted a sibling of the same prefix: $(printf '%s' "$out" | tail -3)" >&2; exit 1; }
    echo "ok  - a scope entry admits itself and its subtree, never a sibling of the same prefix"
    # The convention itself: an entry with no trailing slash is that path and its
    # subtree, so a fix cannot pass by refusing every prefix.
    ( cd "$repo" && git reset -q --hard HEAD~1 )
    out="$(expect ok "a subtree under an entry with no trailing slash" fast --ticket-file "$tmp/tickets-prefix.md")"
    printf '%s' "$out" | grep -q 'inside the mandate' \
      || { echo "self-test FAILED: an entry with no trailing slash did not admit its own subtree: $(printf '%s' "$out" | tail -3)" >&2; exit 1; }
    echo "ok  - an entry with no trailing slash still admits its subtree"
    ( cd "$repo" && git reset -q --hard "$keep" )
    # `scope` is read from the front matter only, so a `scope:` line after the
    # closing `---` cannot widen the mandate. Already true at 6f43fe2; kept true.
    printf -- '---\nid: P-2\nscope: src\n---\n# P-2\n\nscope: docs/\n' >"$tmp/tickets-body-scope.md"
    ( cd "$repo" && echo x >>docs/b.txt && git commit -qam body-scope )
    out="$(expect fail "a scope line after the front matter" fast --ticket-file "$tmp/tickets-body-scope.md")"
    printf '%s' "$out" | grep -q 'outside scope: M *docs/b.txt' \
      || { echo "self-test FAILED: a scope line in the ticket body widened the mandate: $(printf '%s' "$out" | tail -3)" >&2; exit 1; }
    echo "ok  - a scope line after the front matter does not widen the mandate"
    ( cd "$repo" && git reset -q --hard "$keep" )
    # T-15 R9, b46c4b2b9c65: runtime state is exempt because the factory writes
    # it while it works. `git add -f` turns one into a committed change, and the
    # exemption then hid a file outside the mandate behind a green scope line.
    ( cd "$repo" && git reset -q --hard origin/main && mkdir -p .factory/tickets \
      && printf 'hidden\n' >.factory/tickets/T-9.md \
      && git add -f .factory/tickets/T-9.md && git commit -qm force-added-ticket )
    out="$(expect fail "a force-added file under .factory/tickets/" fast --ticket T-1)"
    printf '%s' "$out" | grep -q 'outside scope: A *.factory/tickets/T-9.md' \
      || { echo "self-test FAILED: a committed file under .factory/tickets/ was exempt from the scope check: $(printf '%s' "$out" | tail -3)" >&2; exit 1; }
    echo "ok  - a force-added file under .factory/tickets/ is judged, not exempt"
    ( cd "$repo" && git reset -q --hard "$keep" )
    # An untracked file is in the scope check and must be in the size check too:
    # `git diff` never shows one, so 700 lines in src/ used to count as zero.
    ( cd "$repo" && git reset -q --hard HEAD~1 )
    for i in $(seq 1 700); do echo "line $i"; done >"$repo/src/untracked.txt"
    out="$(expect fail "700 untracked lines inside scope" fast --ticket T-1)"
    printf '%s' "$out" | grep -q 'GATE FAIL \[size\]' \
      || { echo "self-test FAILED: an untracked file escaped the size cap: $(printf '%s' "$out" | tail -3)" >&2; exit 1; }
    echo "ok  - 700 lines in an untracked file fail the size cap"
    rm -f "$repo/src/untracked.txt"
    ( cd "$repo" && git reset -q --hard "$keep" )
    # A path git was never told about carries no numstat mark, so the "cannot be
    # counted" refusal above never reached it: a blob with no newline counted as
    # the single record awk sees, and 64 KiB of binary passed a 600-line cap.
    ( cd "$repo" && git reset -q --hard origin/main )
    head -c 65536 /dev/urandom | tr '\n' '\0' >"$repo/src/blob.bin"
    out="$(expect fail "an untracked binary inside scope" fast --ticket T-1)"
    printf '%s' "$out" | grep -q 'GATE FAIL \[size\].*cannot be counted' \
      || { echo "self-test FAILED: an untracked binary was counted as zero lines: $(printf '%s' "$out" | tail -3)" >&2; exit 1; }
    echo "ok  - an untracked binary is refused, not counted as zero lines"
    rm -f "$repo/src/blob.bin"
    ( cd "$repo" && git reset -q --hard "$keep" )
    # The other half of the same hole, in the Router's exact shape: the tree is
    # at the base, so `git diff` has no added line at all, while an untracked
    # file inside scope holds a token. `size` counts it and passes, and the
    # scope phase accepted it, so the scan owes its bytes a look.
    ( cd "$repo" && git reset -q --hard origin/main )
    printf 'ghp_%s\n' "abcdefghijklmnopqrstuvwxyz0123" >"$repo/src/untracked-leak.txt"
    out="$(expect fail "a token in an untracked file inside scope" fast --ticket T-1)"
    printf '%s' "$out" | grep -q 'GATE FAIL \[secrets\]' \
      || { echo "self-test FAILED: a token in an untracked file escaped the secret scan: $(printf '%s' "$out" | tail -3)" >&2; exit 1; }
    echo "ok  - a token in an untracked file inside scope is caught"
    rm -f "$repo/src/untracked-leak.txt"
    ( cd "$repo" && git reset -q --hard "$keep" )

    # T-15 finding 1: a newline in a path split one NUL-in-a-line record into two.
    # The real file was never counted nor scanned, and its first half was a decoy
    # that does exist, so 701 lines and a token read as "2 lines, no secret".
    ( cd "$repo" && git reset -q --hard origin/main )
    mkdir -p "$repo/src/aaa"
    echo decoy >"$repo/src/aaa/x"
    { for i in $(seq 1 700); do echo "line $i"; done
      printf 'ghp_%s\n' "abcdefghijklmnopqrstuvwxyz0123"; } >"$repo/src/aaa/x"$'\n'"y"
    out="$(expect fail "an untracked path containing a newline" fast --ticket T-1)"
    printf '%s' "$out" | grep -q 'GATE FAIL \[size\]' \
      || { echo "self-test FAILED: a newline in a path split the record and escaped the cap: $(printf '%s' "$out" | tail -3)" >&2; exit 1; }
    echo "ok  - a path containing a newline is one record, counted and scanned"
    rm -rf "$repo/src/aaa"

    # T-15 finding 2, tracked half: `git diff` exits 128 and prints no numstat at
    # all for a path it cannot read, so `|| true` counted 700 lines as zero and
    # the scan saw nothing. Root reads a chmod 000 file, so these two drills can
    # only run unprivileged; that is stated, not silently skipped.
    if [ "$(id -u)" = 0 ]; then
      echo "gate self-test: skipped the unreadable-file drills as root (root reads chmod 000)" >&2
    else
      ( cd "$repo" && git reset -q --hard origin/main \
        && for i in $(seq 1 700); do echo "line $i"; done >>src/a.txt \
        && printf 'ghp_%s\n' "abcdefghijklmnopqrstuvwx" >>src/a.txt && git commit -qam big )
      chmod 000 "$repo/src/a.txt"
      out="$(expect fail "an unreadable tracked file with 700 lines behind it" fast --ticket T-1)"
      chmod 644 "$repo/src/a.txt"
      printf '%s' "$out" | grep -q 'GATE FAIL \[size\].*could not diff' \
        || { echo "self-test FAILED: an unreadable tracked file counted as zero lines: $(printf '%s' "$out" | tail -3)" >&2; exit 1; }
      echo "ok  - an unreadable tracked file fails by name, not as zero lines"
      # T-15 finding 6: the untracked half said "binary" for a file it could not
      # read at all, and the shell's own `Permission denied` reached stderr.
      ( cd "$repo" && git reset -q --hard origin/main )
      printf 'secret\n' >"$repo/src/locked.txt"; chmod 000 "$repo/src/locked.txt"
      out="$(expect fail "an unreadable untracked file" fast --ticket T-1)"
      chmod 644 "$repo/src/locked.txt"; rm -f "$repo/src/locked.txt"
      printf '%s' "$out" | grep -q 'cannot be read' \
        || { echo "self-test FAILED: an unreadable untracked file was not refused by name: $(printf '%s' "$out" | tail -3)" >&2; exit 1; }
      printf '%s' "$out" | grep -q 'Permission denied' \
        && { echo "self-test FAILED: the shell's own read error reached stderr" >&2; exit 1; }
      echo "ok  - an unreadable untracked file is refused as unreadable, and says so quietly"
    fi

    # T-15 finding 3: the untracked half followed symlinks with no bound. A link
    # to /dev/zero hung the gate until an external timeout killed it, and a
    # readable link outside the repo was scanned as if it were the change.
    ( cd "$repo" && git reset -q --hard origin/main )
    ln -s /dev/zero "$repo/src/zero"
    out="$(expect fail "a symlink to /dev/zero" fast --ticket T-1)"
    printf '%s' "$out" | grep -q 'is a symlink' \
      || { echo "self-test FAILED: a symlink was followed instead of refused: $(printf '%s' "$out" | tail -3)" >&2; exit 1; }
    rm -f "$repo/src/zero"
    ln -s /etc/hostname "$repo/src/outside"
    out="$(expect fail "a symlink out of the repo" fast --ticket T-1)"
    printf '%s' "$out" | grep -q 'is a symlink' \
      || { echo "self-test FAILED: a symlink out of the repo was scanned: $(printf '%s' "$out" | tail -3)" >&2; exit 1; }
    rm -f "$repo/src/outside"
    echo "ok  - a symlink is refused by name, never followed"

    # T-15 finding 4: one 120 MiB untracked line passed the 1-line cap and spent
    # 81s in eleven regex passes. Past the bound it is refused, not half-read.
    ( cd "$repo" && git reset -q --hard origin/main )
    head -c 5000000 /dev/zero | tr '\0' 'a' >"$repo/src/huge.txt"
    out="$(expect fail "an untracked file over the scan bound" fast --ticket T-1)"
    printf '%s' "$out" | grep -q 'scan bound' \
      || { echo "self-test FAILED: an oversized untracked file was read anyway: $(printf '%s' "$out" | tail -3)" >&2; exit 1; }
    rm -f "$repo/src/huge.txt"
    echo "ok  - an untracked file over the scan bound is refused, not read for a minute"
    ( cd "$repo" && git reset -q --hard "$keep" )

    # T-15 finding 5: a content line whose text begins `++ b/` arrives as
    # `+++ b/...`, and the `^\+\+\+ (a/|b/)` header filter dropped it unscanned.
    ( cd "$repo" && git reset -q --hard HEAD~1 \
      && printf '++ b/ghp_%s\n' "abcdefghijklmnopqrstuvwx" >>src/a.txt && git commit -qam secret-pp )
    out="$(expect fail "a token on a line whose text begins '++ b/'" fast --ticket T-1)"
    printf '%s' "$out" | grep -q 'GATE FAIL \[secrets\]' \
      || { echo "self-test FAILED: a content line beginning '++ b/' was read as a header: $(printf '%s' "$out" | tail -3)" >&2; exit 1; }
    echo "ok  - a token on a line whose text begins '++ b/' is still scanned"
    ( cd "$repo" && git reset -q --hard "$keep" )
    ( cd "$repo" && git checkout -q . && git reset -q --hard HEAD~1 \
      && printf 'k=ghp_%s\n' "abcdefghijklmnopqrstuvwx" >>src/a.txt && git commit -qam secret )
    expect fail "a planted token" fast --ticket T-1 >/dev/null
    echo "ok  - a planted token fails the secret scan"

    # A live key beside the word "example" is a live key: the placeholder filter
    # runs per token, so it cannot drop the whole line.
    ( cd "$repo" && git reset -q --hard HEAD~1 )
    AKIA="AKIA""ABCDEFGHIJKLMNOP"
    printf '// example: prod key is %s\n' "$AKIA" >>"$repo/src/a.txt"
    ( cd "$repo" && git commit -qam secret-example-line )
    expect fail "a live key on an 'example' line" fast --ticket T-1 >/dev/null
    echo "ok  - a live key beside the word example still fails the secret scan"
    SK="sk-""abcdefghijklmnopqrstuvwxyz"
    ( cd "$repo" && git reset -q --hard HEAD~1 )
    printf 'OPENAI_API_KEY=%s\n' "$SK" >>"$repo/src/a.txt"
    ( cd "$repo" && git commit -qam secret-sk )
    expect fail "an unquoted OPENAI_API_KEY=sk-… line" fast --ticket T-1 >/dev/null
    echo "ok  - an unquoted OPENAI_API_KEY=sk-… fails the secret scan"
    GP="glpat-""abcdefghijklmnopqrst"
    PG="postgres://""user:pass@host"
    ( cd "$repo" && git reset -q --hard HEAD~1 )
    printf '%s\n%s\n' "$GP" "$PG" >>"$repo/src/a.txt"
    ( cd "$repo" && git commit -qam secret-gitlab )
    expect fail "a glpat- token and a database URL with an inline password" fast --ticket T-1 >/dev/null
    echo "ok  - a glpat- token and a database URL with an inline password fail the secret scan"

    # A token on a line that itself begins `+++` arrives as `++++...` in the
    # diff. A bare `+++` header filter dropped it, so the scan never saw it.
    ( cd "$repo" && git reset -q --hard HEAD~1 \
      && printf '+++ghp_%s\n' "abcdefghijklmnopqrstuvwx" >>src/a.txt && git commit -qam secret-plus )
    expect fail "a token on a line beginning with +++" fast --ticket T-1 >/dev/null
    echo "ok  - a token on a line beginning with +++ fails the secret scan"

    ( cd "$repo" && git reset -q --hard HEAD~1 \
      && for i in $(seq 1 700); do echo "line $i"; done >>src/a.txt && git commit -qam big )
    expect fail "a 700-line diff" fast --ticket T-1 >/dev/null
    echo "ok  - a 700-line diff fails the size cap"

    # V2: a binary mark shows `-` in both numstat columns and no +/- lines at all.
    ( cd "$repo" && git reset -q --hard HEAD~1 \
      && for i in $(seq 1 700); do echo "line $i"; done >>src/a.txt \
      && printf '%s\n' "$AKIA" >>src/a.txt \
      && printf 'src/a.txt binary\n' >.gitattributes && git add -A && git commit -qm binary-mark )
    out="$(expect fail "700 lines behind a .gitattributes binary mark" fast --ticket-file "$tmp/tickets-bin.md")"
    printf '%s' "$out" | grep -q 'refuses to show these files as text' \
      || { echo "self-test FAILED: a binary-marked file was skipped instead of refused: $(printf '%s' "$out" | tail -3)" >&2; exit 1; }
    echo "ok  - a file the diff refuses to show as text fails instead of being skipped"
    ( cd "$repo" && git reset -q --hard HEAD~1 )

    # F4: .factory/ code is counted. 700 lines of it, with a ticket that allows
    # it, must still hit the cap — otherwise a commit grows itself out of view.
    ( cd "$repo" && git reset -q --hard HEAD~1 && for i in $(seq 1 700); do echo "x $i"; done >>.factory/scripts/evil.sh \
      && git add -A && git commit -qm big-factory )
    expect fail "700 lines of .factory/ code" fast --ticket-file "$tmp/tickets-outside.md" >/dev/null
    echo "ok  - .factory/ code counts against the size cap"
    ( cd "$repo" && git reset -q --hard HEAD~1 )

    # F4: a commit that replaces gate.sh with `exit 0` and raises its own cap.
    # Judged by the pristine gate from the base commit, it must FAIL.
    ( cd "$repo" && printf '#!/usr/bin/env bash\nexit 0\n' >.factory/gates/gate.sh \
      && sed -i 's/^  diff_lines_max:.*/  diff_lines_max: 99999/' .factory/config.yml \
      && git add -A && git commit -qm neuter )
    attack="$(cd "$repo" && git rev-parse HEAD)"
    out="$(expect fail "a commit that neuters gate.sh, judged from the base" fast --ticket-file "$tmp/tickets-src.md" --sha "$attack")"
    printf '%s' "$out" | grep -q '.factory/gates/gate.sh' \
      || { echo "self-test FAILED: the neuter was not named as an out-of-scope change: $(printf '%s' "$out" | tail -3)" >&2; exit 1; }
    echo "ok  - a commit that neuters gate.sh FAILS when judged from the base commit"

    # F5: the tree is judged at the named commit, so a dirty working tree cannot
    # stand in for it: neither to pass (dirty tree), nor to fail (clean tree).
    ( cd "$repo" && git reset -q --hard HEAD~1 )
    clean="$(cd "$repo" && git rev-parse HEAD)"
    ( cd "$repo" && echo dirty >>docs/b.txt )
    expect ok "a dirty out-of-scope tree while --sha names a clean head" fast --ticket-file "$tmp/tickets-src.md" --sha "$clean" >/dev/null
    echo "ok  - --sha judges the named commit, not the working tree"
    ( cd "$repo" && git checkout -q . )

    out="$(expect fail "a shortened sha" fast --ticket-file "$tmp/tickets-src.md" --sha "${clean:0:7}")"
    printf '%s' "$out" | grep -q '40-hex' || { echo "self-test FAILED: a short sha was not refused by name" >&2; exit 1; }
    echo "ok  - --sha refuses anything that is not 40 hex"

    # F5: a missing ticket names exactly what is missing, and a clean clone can
    # still be judged because the mandate may live outside the judged tree.
    ( cd "$repo" && echo dirty >>docs/b.txt )
    out="$(expect fail "no ticket file" fast --ticket-file "$tmp/nope.md")"
    printf '%s' "$out" | grep -q "ticket.sh new" || { echo "self-test FAILED: a missing ticket did not name the create command: $out" >&2; exit 1; }
    echo "ok  - a missing ticket names the file and the command that creates it"
    printf -- '---\nid: T-9\nscope: \n---\n# T-9\n' >"$tmp/tickets-empty.md"
    out="$(expect fail "an empty scope" fast --ticket T-9 --ticket-file "$tmp/tickets-empty.md")"
    printf '%s' "$out" | grep -q "ticket.sh set" || { echo "self-test FAILED: an empty scope did not name the set command: $out" >&2; exit 1; }
    echo "ok  - an empty scope names the command that sets it"
    out="$(expect fail "no --ticket at all" fast)"
    printf '%s' "$out" | grep -q "no --ticket" || { echo "self-test FAILED: a missing --ticket was not named: $out" >&2; exit 1; }
    echo "ok  - no --ticket is named as the reason no mandate exists"

    # A one-commit tree with no origin/main has nothing to diff against: refused
    # by name, not judged as unchanged.
    repo2="$tmp/repo2"; mkdir -p "$repo2/src"
    ( cd "$repo2" && git init -q && git config user.email t@t && git config user.name t \
      && git config commit.gpgsign false && echo a >src/a.txt && git add -A && git commit -qm only ) \
      || { echo "self-test FAILED: sandbox repo2" >&2; exit 1; }
    out="$(GS_ROOT="$repo2" expect fail "a tree with no base commit" fast --ticket T-1)"
    printf '%s' "$out" | grep -q 'no base commit' \
      || { echo "self-test FAILED: a tree with no base was not refused by name: $(printf '%s' "$out" | tail -3)" >&2; exit 1; }
    echo "ok  - a tree with no base commit is refused, not judged as unchanged"

    # T-15 R11: the base could only be named as `GATE_BASE=… bash gate.sh`, which
    # this repo's guard refuses on shape. A flag that parses and is ignored is the
    # same defect, so this asserts the VERDICT it moves: one tree, two bases.
    ( cd "$repo" && git reset -q --hard origin/main \
      && for i in $(seq 1 700); do echo "line $i"; done >src/big.txt && git add -A && git commit -qm big )
    big="$(cd "$repo" && git rev-parse HEAD)"; base="$(cd "$repo" && git rev-parse origin/main)"
    ( cd "$repo" && git reset -q --hard origin/main )
    expect ok "a base pinned before the 700 lines" fast --ticket T-1 --base "$base" >/dev/null
    out="$(expect fail "a base pinned after the 700 lines" fast --ticket T-1 --base "$big")"
    printf '%s' "$out" | grep -q 'GATE FAIL \[size\]' \
      || { echo "self-test FAILED: --base parsed but did not move the base: $(printf '%s' "$out" | tail -3)" >&2; exit 1; }
    echo "ok  - --base is the base: one tree passes or fails by the ref it names"
    out="$(expect fail "a --base that is not a commit" fast --ticket T-1 --base 0000000000000000000000000000000000000000)"
    printf '%s' "$out" | grep -q 'is not a commit' \
      || { echo "self-test FAILED: a --base that is not a commit was ignored, not refused by name: $(printf '%s' "$out" | tail -3)" >&2; exit 1; }
    echo . >>"$ASSERTIONS"
    out="$( cd "$repo" && GATE_BASE="$base" GATE_ROOT="$repo" GATE_FACTORY="$judge" \
      timeout 120 bash "$judge/gates/gate.sh" fast --ticket T-1 --base "$big" 2>&1 )"; st=$?
    { [ "$st" != 0 ] && printf '%s' "$out" | grep -q 'different commits'; } \
      || { echo "self-test FAILED: --base and GATE_BASE disagreed silently: $(printf '%s' "$out" | tail -3)" >&2; exit 1; }
    echo "ok  - a --base that is not a commit, and one that disagrees with GATE_BASE, are both refused by name"

    # T-15 R11: scope diffed `$BASE...HEAD` (commits only) while size and secrets
    # diffed `$BASE`, so a path BASE carries and HEAD does not was judged by size
    # and never by scope. One probe, both directions; the path is IN scope.
    printf -- '---\nid: A-1\nscope: src/,docs/\n---\n# A-1\n' >"$tmp/tickets-docs.md"
    br="$(cd "$repo" && git rev-parse --abbrev-ref HEAD)"
    side="$( cd "$repo" && git reset -q --hard origin/main && git checkout -q --detach \
      && for i in $(seq 1 700); do echo "side $i"; done >docs/side.txt && git add -A && git commit -qm side \
      && git rev-parse HEAD && git checkout -q "$br" )"
    out="$(expect fail "a base that is not an ancestor of the head" fast --ticket-file "$tmp/tickets-docs.md" --base "$side")"
    printf '%s' "$out" | grep -q '1 file(s) inside the mandate' \
      || { echo "self-test FAILED: scope judged a different tree than size: $(printf '%s' "$out" | tail -3)" >&2; exit 1; }
    printf '%s' "$out" | grep -q 'GATE FAIL \[size\]' \
      || { echo "self-test FAILED: size did not count what scope judged: $(printf '%s' "$out" | tail -3)" >&2; exit 1; }
    echo "ok  - scope and size judge the same tree, so the same file set"
    echo "gate self-test: $(wc -l <"$ASSERTIONS" | tr -d ' ') assertions hold"
    ;;
  all)
    phase_scope; phase_size; phase_secrets; phase_fmt; phase_build; phase_test
    summarise all "scope+size+secrets+fmt+build+test"
    ;;
  fast) phase_scope; phase_size; phase_secrets; phase_fmt; summarise fast "everything but build+test" ;;
  build) phase_build ;;
  test) phase_test ;;
  *) echo "usage: gate.sh all|fast|build|test|--self-test [--ticket T-n] [--ticket-file p] [--sha <40-hex>] [--base <ref>]" >&2; exit 2 ;;
esac
