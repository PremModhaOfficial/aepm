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
while [ $# -gt 0 ]; do
  case "$1" in
    --ticket) TICKET="$2"; shift 2 ;;
    --ticket-file) TICKET_FILE="$2"; shift 2 ;;
    --sha) SHA="$2"; shift 2 ;;
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

base_ref() { # the commit a change is measured against; empty means "no base"
  if [ -n "${GATE_BASE:-}" ]; then git -C "$ROOT" rev-parse --verify -q "$GATE_BASE^{commit}" 2>/dev/null && return; fi
  if git -C "$ROOT" rev-parse --verify -q origin/main >/dev/null 2>&1; then
    git -C "$ROOT" merge-base HEAD origin/main && return
  fi
  git -C "$ROOT" rev-parse --verify -q HEAD~1 2>/dev/null
}

# A phase that diffs needs a base: the empty tree as a base judged nothing.
need_base() {
  BASE="$(base_ref)"
  [ -n "$BASE" ] \
    || fail base "no base commit to diff against in $ROOT (no origin/main, no HEAD~1): pass GATE_BASE=<ref>, or run where the default branch is fetched"
}

# The change, as one set: STATUS<TAB>path, with both sides of a rename. Scope and
# size used to compute this separately and disagreed about what "the change" is,
# which is how an untracked file and a rename's new path escaped one of them.
changed_paths() {
  git -C "$ROOT" diff --name-status --no-renames "$BASE"...HEAD 2>/dev/null || true
  # -z: NUL-terminated and unquoted, so a path with a space stays one field. A
  # rename prints its NEW path first and the old one second, and the new path is
  # the one a scope rule has to judge.
  local rec st f
  while IFS= read -r -d '' rec; do
    st="${rec:0:2}"; f="${rec:3}"
    [ -n "$f" ] || continue
    printf '%s\t%s\n' "$st" "$f"
    case "$st" in R*|C*) IFS= read -r -d '' f && printf '%s\t%s\n' "$st" "$f" ;; esac
  done < <(git -C "$ROOT" status --porcelain -z -uall 2>/dev/null)
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
  local changed f bad=0 allowed tf n
  need_base
  changed="$(changed_paths)"
  [ -n "$changed" ] || { pass scope "no changes to judge (head $(git -C "$ROOT" rev-parse --short HEAD) vs base $(git -C "$ROOT" rev-parse --short "$BASE"))"; return 0; }
  allowed="$(scope_list)"
  n="$(printf '%s\n' "$changed" | wc -l)"
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
  pass scope "$n file(s) inside the mandate"
}

phase_size() {
  local max_lines max_files stat lines files bin
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
  stat="$(git -C "$ROOT" diff --numstat --no-renames "$BASE" 2>/dev/null || true)"
  # `-` in a numstat column means git will not show the file as text: its lines
  # are absent from the sum below and its bytes from the scan, so fail, not skip.
  bin="$(printf '%s\n' "$stat" | awk -F'\t' '$1=="-"||$2=="-"{print $3}' | tr '\n' ' ')"
  [ -z "${bin// /}" ] || fail size "the diff refuses to show these files as text, so their lines cannot be counted and their bytes cannot be scanned: ${bin% }"
  lines="$(printf '%s\n' "$stat" | awk 'NF{a+=$1; d+=$2} END{print a+d+0}')"
  files="$(printf '%s\n' "$stat" | awk 'NF' | wc -l | tr -d ' ')"
  [ "${lines:-0}" -le "$max_lines" ] || fail size "diff is ${lines} lines, cap ${max_lines}"
  [ "${files:-0}" -le "$max_files" ] || fail size "diff touches ${files} files, cap ${max_files}"
  pass size "${lines} lines across ${files} files (cap ${max_lines}/${max_files})"
}

phase_secrets() {
  # Scan ADDED lines only: a secret already in history is a different ticket.
  # -oE extracts the SECRET, not the line: a live key beside the word "example"
  # is still a live key, and placeholders are filtered per token, not per line.
  local added pat t hits=""
  need_base
  # A binary file never reaches the secret scan: the size phase already failed it.
  # The header filter is git's exact header shape, never a bare `+++` prefix: a
  # token on a line of its own starting `+++` is an added line, not a header.
  added="$(git -C "$ROOT" diff -U0 --no-renames "$BASE" 2>/dev/null | grep -E '^\+' | grep -vE '^\+\+\+ (a/|b/|/dev/null)')"
  [ -n "$added" ] || { pass secrets "no added lines to scan"; return 0; }
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
      && echo 'a' >src/a.txt && echo 'b' >docs/b.txt && git add -A && git commit -qm base \
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

    gs() { # run the JUDGE's gate against ${GS_ROOT:-$repo}; extra args pass through
      ( cd "${GS_ROOT:-$repo}" && GATE_ALLOW_NO_CARGO=1 GATE_ROOT="${GS_ROOT:-$repo}" GATE_FACTORY="$judge" \
          bash "$judge/gates/gate.sh" "$@" )
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
    ( cd "$repo" && echo c >>docs/b.txt && git commit -qam out )
    expect fail "a change outside the ticket scope" fast --ticket T-1 >/dev/null
    echo "ok  - a change outside the ticket scope fails"
    # A staged rename prints `R  old -> new`. Field 2 of that line is the OLD
    # path, so `awk '{print $2}'` judged src/a.txt -> docs/moved.txt from the
    # inside and never saw the new path outside the mandate.
    keep="$(cd "$repo" && git rev-parse HEAD)"
    ( cd "$repo" && git reset -q --hard HEAD~1 && git mv src/a.txt docs/moved.txt )
    out="$(expect fail "a staged rename is judged at its new path" fast --ticket T-1)"
    printf '%s' "$out" | grep -q 'outside scope: R *docs/moved.txt' \
      || { echo "self-test FAILED: a staged rename hid its new path: $(printf '%s' "$out" | tail -3)" >&2; exit 1; }
    echo "ok  - a staged rename is judged at its new path"
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
    echo "gate self-test: $(wc -l <"$ASSERTIONS" | tr -d ' ') assertions hold"
    ;;
  all)
    phase_scope; phase_size; phase_secrets; phase_fmt; phase_build; phase_test
    record all pass "scope+size+secrets+fmt+build+test"
    pass all "every phase green"
    ;;
  fast) phase_scope; phase_size; phase_secrets; phase_fmt; pass fast "everything but build+test" ;;
  build) phase_build ;;
  test) phase_test ;;
  *) echo "usage: gate.sh all|fast|build|test|--self-test [--ticket T-n] [--ticket-file p] [--sha <40-hex>]" >&2; exit 2 ;;
esac
