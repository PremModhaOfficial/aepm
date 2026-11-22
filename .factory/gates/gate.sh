#!/usr/bin/env bash
# gate.sh — the deterministic gate. Exit code is truth; an agent's opinion is not.
#
#   gate.sh all    --ticket T-1     # everything (what the builder must pass)
#   gate.sh fast   --ticket T-1     # scope + secrets + diff size + fmt (seconds)
#   gate.sh build  --ticket T-1     # clippy -D warnings + build
#   gate.sh test   --ticket T-1     # the test suite
#   gate.sh --self-test             # prove this gate can fail
#
# Checks: diff size, changes only inside the ticket scope, secret scan of added
# lines, cargo fmt, clippy -D warnings, build, tests. Writes
# .factory/gates/last-gate.json. Exits non-zero on the first failing phase.
set -uo pipefail
FACTORY="${GATE_FACTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ROOT="${GATE_ROOT:-$(cd "$FACTORY/.." && pwd)}"
PHASE="${1:-all}"
shift || true
TICKET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ticket) TICKET="$2"; shift 2 ;;
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
  mkdir -p "$FACTORY/gates"
  jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg phase "$1" \
    --arg status "$2" --arg detail "$3" --arg ticket "${TICKET:-none}" \
    --arg head "$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo none)" \
    '{ts:$ts,ticket:$ticket,phase:$phase,status:$status,detail:$detail,head:$head}' \
    >"$RESULT_FILE"
  [ -n "${FACTORY_LEDGER:-}" ] && printf '%s\n' "$(cat "$RESULT_FILE")" >>"$FACTORY_LEDGER"
  return 0
}

cfg() { # config.yml value with its trailing comment stripped
  sed -n "s/^ *$1: *//p" "$FACTORY/config.yml" | head -1 | sed 's/[[:space:]]*#.*//; s/[[:space:]]*$//'
}

exempt() { # factory bookkeeping is not the ticket's product change
  case "$1" in .factory/*|*/.factory/*) return 0 ;; esac
  return 1
}

scope_list() { # ticket scope value -> newline separated prefixes
  [ -n "$TICKET" ] || return 0
  awk 'NR==1{next} /^---$/{exit} {print}' "$FACTORY/tickets/$TICKET.md" \
    | sed -n 's/^scope: *//p' | head -1 | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^$'
}

base_ref() {
  git -C "$ROOT" rev-parse --verify -q origin/main >/dev/null \
    && git -C "$ROOT" merge-base HEAD origin/main \
    || git -C "$ROOT" rev-parse HEAD~1 2>/dev/null \
    || git -C "$ROOT" hash-object -t tree /dev/null
}

phase_scope() {
  local base changed f bad=0 allowed
  base="$(base_ref)"
  changed="$(git -C "$ROOT" diff --name-status --no-renames "$base"...HEAD 2>/dev/null; \
    git -C "$ROOT" status --porcelain | awk '{print "M\t"$2}' | grep -v "\.factory/" || true)"
  [ -n "$changed" ] || { pass scope "no changes to judge"; return 0; }
  allowed="$(scope_list)"
  if [ -z "$allowed" ]; then
    fail scope "$(printf '%s\n' "$changed" | wc -l) file(s) changed but the ticket declares no scope"
  fi
  while IFS=$'\t' read -r st f; do
    [ -n "$f" ] || continue
    exempt "$f" && continue
    local ok=1
    while IFS= read -r a; do
      case "$f" in "$a"*) ok=0 ;; esac
    done <<<"$allowed"
    if [ "$ok" = 1 ]; then
      echo "  outside scope: $st $f" >&2
      bad=1
    fi
  done <<<"$changed"
  [ "$bad" = 0 ] || fail scope "change(s) outside the ticket mandate (allowed: $(echo "$allowed" | tr '\n' ' '))"
  pass scope "$(printf '%s\n' "$changed" | wc -l) file(s) inside the mandate"
}

phase_size() {
  local max_lines max_files base stat lines files
  max_lines="$(cfg diff_lines_max)"; max_lines="${max_lines:-600}"
  max_files="$(cfg diff_files_max)"; max_files="${max_files:-30}"
  base="$(base_ref)"
  stat="$(git -C "$ROOT" diff --numstat --no-renames "$base" 2>/dev/null | grep -v "\.factory/" || true)"
  lines="$(printf '%s\n' "$stat" | awk '{a+=$1; d+=$2} END{print a+d+0}')"
  files="$(printf '%s\n' "$stat" | awk 'NF' | wc -l | tr -d ' ')"
  [ "${lines:-0}" -le "$max_lines" ] || fail size "diff is ${lines} lines, cap ${max_lines}"
  [ "${files:-0}" -le "$max_files" ] || fail size "diff touches ${files} files, cap ${max_files}"
  pass size "${lines} lines across ${files} files (cap ${max_lines}/${max_files})"
}

phase_secrets() {
  # Scan ADDED lines only: a secret already in history is a different ticket.
  local base hits
  base="$(base_ref)"
  hits="$(git -C "$ROOT" diff -U0 --no-renames "$base" 2>/dev/null | grep -E '^\+' \
    | grep -vE '^\+\+\+' \
    | grep -inE 'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|xox[baprs]-[A-Za-z0-9-]{10,}|(api[_-]?key|secret|token|passwd|password)[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"']{12,}' \
    | grep -viE 'example|placeholder|redacted|your[_-]|xxx+|changeme|\$\{|\$[A-Z_]+' || true)"
  [ -z "$hits" ] || fail secrets "possible secret in added lines: $(printf '%s' "$hits" | head -3 | cut -c1-120 | tr '\n' ' ')"
  pass secrets "no secret pattern in added lines"
}

require_cargo() { # the real repo is a Cargo crate; only the sandbox may skip it
  [ -f "$ROOT/Cargo.toml" ] && return 0
  [ "${GATE_ALLOW_NO_CARGO:-0}" = "1" ] && { pass "$1" "no Cargo.toml in the sandbox"; return 1; }
  fail "$1" "no Cargo.toml at $ROOT — refusing to report success on a phase that did not run"
}

phase_fmt() {
  require_cargo fmt || return 0
  ( cd "$ROOT" && cargo fmt --all --check ) >/dev/null 2>&1 \
    && pass fmt "cargo fmt --all --check" \
    || fail fmt "cargo fmt --all --check (run: cargo fmt --all)"
}

phase_build() {
  require_cargo build || return 0
  ( cd "$ROOT" && cargo clippy --all-targets --all-features --locked -- -D warnings ) \
    || fail build "cargo clippy -D warnings"
  ( cd "$ROOT" && cargo build --locked --all-features ) \
    || fail build "cargo build --locked --all-features"
  pass build "clippy -D warnings + build"
}

phase_test() {
  require_cargo test || return 0
  ( cd "$ROOT" && cargo test --all-targets --all-features --locked ) \
    || fail test "cargo test --all-targets --all-features --locked"
  pass test "cargo test --all-targets --all-features --locked"
}

case "$PHASE" in
  --self-test)
    # Prove the gate can fail. Hermetic: a throwaway repo in /tmp, no network.
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    mkdir -p "$tmp/.factory"/{tickets,gates} "$tmp/src" "$tmp/docs"
    cp "$FACTORY/config.yml" "$tmp/.factory/config.yml"
    # The global config signs commits with an ssh key; a throwaway repo has no
    # agent socket, so signing is off here or every self-test commit fails.
    ( cd "$tmp" && git init -q && git config user.email t@t && git config user.name t \
      && git config commit.gpgsign false
      echo 'a' >src/a.txt; echo 'b' >docs/b.txt; git add -A && git commit -qm base )
    printf -- '---\nid: T-1\nscope: src/\n---\n# T-1\n' >"$tmp/.factory/tickets/T-1.md"
    st=0
    ( cd "$tmp" && GATE_ALLOW_NO_CARGO=1 GATE_ROOT="$tmp" GATE_FACTORY="$tmp/.factory" bash "$FACTORY/gates/gate.sh" fast --ticket T-1 >/dev/null 2>&1 ) || st=$?
    [ "$st" = 0 ] || { echo "self-test FAILED: clean tree did not pass (exit $st)" >&2; exit 1; }
    echo "ok  - a clean tree inside scope passes"
    ( cd "$tmp" && echo c >>docs/b.txt && git commit -qam out )
    st=0
    ( cd "$tmp" && GATE_ALLOW_NO_CARGO=1 GATE_ROOT="$tmp" GATE_FACTORY="$tmp/.factory" bash "$FACTORY/gates/gate.sh" fast --ticket T-1 >/dev/null 2>&1 ) || st=$?
    [ "$st" != 0 ] || { echo "self-test FAILED: an out-of-scope change passed" >&2; exit 1; }
    echo "ok  - a change outside the ticket scope fails"
    ( cd "$tmp" && git checkout -q . && git reset -q --hard HEAD~1 && printf 'k=ghp_%s\n' "abcdefghijklmnopqrstuvwx" >>src/a.txt && git commit -qam secret )
    st=0
    ( cd "$tmp" && GATE_ALLOW_NO_CARGO=1 GATE_ROOT="$tmp" GATE_FACTORY="$tmp/.factory" bash "$FACTORY/gates/gate.sh" fast --ticket T-1 >/dev/null 2>&1 ) || st=$?
    [ "$st" != 0 ] || { echo "self-test FAILED: a planted token passed the secret scan" >&2; exit 1; }
    echo "ok  - a planted token fails the secret scan"
    ( cd "$tmp" && git reset -q --hard HEAD~1 && for i in $(seq 1 700); do echo "line $i"; done >>src/a.txt && git commit -qam big )
    st=0
    ( cd "$tmp" && GATE_ALLOW_NO_CARGO=1 GATE_ROOT="$tmp" GATE_FACTORY="$tmp/.factory" bash "$FACTORY/gates/gate.sh" fast --ticket T-1 >/dev/null 2>&1 ) || st=$?
    [ "$st" != 0 ] || { echo "self-test FAILED: a 700-line diff passed the size cap" >&2; exit 1; }
    echo "ok  - a 700-line diff fails the size cap"
    echo "gate self-test: 4 assertions hold"
    ;;
  all)
    phase_scope; phase_size; phase_secrets; phase_fmt; phase_build; phase_test
    record all pass "scope+size+secrets+fmt+build+test"
    pass all "every phase green"
    ;;
  fast) phase_scope; phase_size; phase_secrets; phase_fmt; pass fast "everything but build+test" ;;
  build) phase_build ;;
  test) phase_test ;;
  *) echo "usage: gate.sh all|fast|build|test|--self-test [--ticket T-n]" >&2; exit 2 ;;
esac
