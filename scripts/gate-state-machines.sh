#!/usr/bin/env bash
# docs/STATE-MACHINES.md names the machines the code keeps implicit. An implicit
# machine drifts in silence: a variant is added, a precedence branch moves, and
# the table goes on describing the tree it was written against. Fail here
# instead of at the next reader.
#
#   scripts/gate-state-machines.sh              # this checkout
#   scripts/gate-state-machines.sh <root>       # another checkout
#   scripts/gate-state-machines.sh --self-test  # prove the check can fail
#
# Two checks, both against code, never against another document:
#   1. every variant of every listed enum appears in the section headed with
#      that type's name;
#   2. every `path:line` row in the anchor table points at a line that still
#      says exactly the text the row claims.
set -uo pipefail

DOC=docs/STATE-MACHINES.md

# The machines the document must describe. One row per enum whose variants a
# reader has to be able to enumerate: type and the file that declares it.
MACHINES=(
    "GateState:src/gate.rs"
    "Phase:src/tui/fetch_session.rs"
    "Cached:src/report.rs"
    "ArtifactState:src/report.rs"
    "LockState:src/report.rs"
    "YayAction:src/commands/clean.rs"
    "NodeState:src/frontier.rs"
    "Error:src/error.rs"
)

# The document may not shrink its anchor table into nothing and pass.
MIN_ANCHORS=10

# Every variant declared in `pub enum <type>`, one per line, in source order.
variants() { # <file> <type>
    awk -v decl="pub enum $2" '
        index($0, decl) == 1 { inside = 1; next }
        inside && /^}/ { exit }
        inside {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (line == "" || line ~ /^#/ || line ~ /^\/\//) next
            if (match(line, /^[A-Z][A-Za-z0-9_]*/)) print substr(line, 1, RLENGTH)
        }
    ' "$1"
}

# The document lines under the `## ` heading that names `<type>`.
section() { # <doc> <type>
    awk -v want="\`$2\`" '
        /^## / { inside = index($0, want) > 0; next }
        inside
    ' "$1"
}

check() { # <root>
    local root=$1 doc status=0 row entry type file name anchor number text actual
    local -a declared

    doc=$root/$DOC
    if [[ ! -s $doc ]]; then
        echo "::error::$DOC is missing or empty; the machines are undocumented"
        return 1
    fi

    for entry in "${MACHINES[@]}"; do
        type=${entry%%:*}
        file=$root/${entry#*:}
        if [[ ! -f $file ]]; then
            echo "::error::${entry#*:} is missing; the machine table names a file that is gone"
            status=1
            continue
        fi

        section "$doc" "$type" >"$root/.section-$type" 2>/dev/null ||
            { echo "::error::cannot read $DOC"; return 1; }
        if [[ ! -s $root/.section-$type ]]; then
            echo "::error::$DOC has no '## ' section naming \`$type\`; name the machine in its heading"
            status=1
            rm -f "$root/.section-$type"
            continue
        fi

        mapfile -t declared < <(variants "$file" "$type")
        if ((${#declared[@]} == 0)); then
            echo "::error::no 'pub enum $type' found in ${entry#*:}; the machine table is stale"
            status=1
        fi
        for name in "${declared[@]}"; do
            if ! grep -qw -- "$name" "$root/.section-$type"; then
                echo "::error::$type::$name is declared in ${entry#*:} but not listed in the $type table in $DOC"
                status=1
            fi
        done
        rm -f "$root/.section-$type"
    done

    # Anchor rows: | claim | `path:line` | `the line says` |
    local anchors=0
    while IFS= read -r row; do
        anchor=$(grep -o '`src/[^`]*:[0-9][0-9]*`' <<<"$row" | head -1)
        [[ -n $anchor ]] || continue
        anchors=$((anchors + 1))
        anchor=${anchor//\`/}
        file=$root/${anchor%%:*}
        number=${anchor##*:}
        text=$(sed -E 's/^.*`src\/[^`]*:[0-9]+`[[:space:]]*\|[[:space:]]*`(.*)`[[:space:]]*\|[[:space:]]*$/\1/' <<<"$row")
        if [[ ! -f $file ]]; then
            echo "::error::$DOC cites $anchor but ${anchor%%:*} is gone"
            status=1
            continue
        fi
        actual=$(sed -n "${number}p" "$file" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        if [[ $actual != "$text" ]]; then
            echo "::error::$anchor no longer says \"$text\"; it says \"$actual\". Fix the line number or the claim in $DOC."
            status=1
        fi
    done < <(grep '`src/[^`]*:[0-9]' "$doc")

    if ((anchors < MIN_ANCHORS)); then
        echo "::error::$DOC has $anchors anchor row(s); the tables must cite at least $MIN_ANCHORS code lines"
        status=1
    fi

    if ((status == 0)); then
        echo "state machines: ${#MACHINES[@]} machines and $anchors anchors agree with the code"
    fi
    return "$status"
}

if [[ ${1:-} == --self-test ]]; then
    # The real tree is the fixture: a clean copy must pass, a planted omission
    # and a planted line shift must each fail. A checker that cannot fail is
    # not a gate.
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    mkdir -p "$tmp/root"
    cp -r --parents "$DOC" src "$tmp/root" || exit 1

    check "$tmp/root" >/dev/null || {
        echo "self-test: a clean copy was rejected"
        check "$tmp/root"
        exit 1
    }

    sed -i 's/Warn/Warning/g' "$tmp/root/$DOC"
    check "$tmp/root" >/dev/null && { echo "self-test: a dropped variant passed"; exit 1; }

    rm -rf "$tmp/root"
    mkdir -p "$tmp/root"
    cp -r --parents "$DOC" src "$tmp/root" || exit 1
    sed -i 's|`src/error.rs:24`|`src/error.rs:22`|' "$tmp/root/$DOC"
    check "$tmp/root" >/dev/null && { echo "self-test: a shifted anchor passed"; exit 1; }

    echo "self-test: ok"
    exit 0
fi

check "${1:-.}" || exit 1
