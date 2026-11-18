#!/usr/bin/env bash
# Which sim scenarios must run for a change.
#
#   scripts/gate-scenarios.sh --check-map      every src/ path has a row
#   scripts/gate-scenarios.sh --list <base>    scenarios for <base>...HEAD
#
# The map is sim/scenario-map.tsv. Both modes exit 1 when a path under src/ has
# no row there: a src file nothing exercises is the drift this gate exists for,
# so it fails the build instead of merging green.
#
# `--list` prints scenario paths, one per line, and exits 0 with no output when
# the change touches nothing the harness covers (a docs-only branch). The
# caller decides what an empty list means.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

MAP=sim/scenario-map.tsv
WORKFLOW=.github/workflows/sim.yml

die() {
    printf 'gate-scenarios: %s\n' "$*" >&2
    exit 1
}

# The gate is only worth anything while the workflow calls it. Checked here so
# deleting the step from sim.yml is a red build, not a silent skip.
[[ -f $MAP ]] || die "missing $MAP"
grep -q 'gate-scenarios.sh --list' "$WORKFLOW" \
    || die "$WORKFLOW no longer runs 'scripts/gate-scenarios.sh --list', so the map selects nothing"

# Longest matching prefix in column 1 wins, so a file row beats a directory row.
# Prints the scenario list from column 2, or nothing.
lookup() {
    awk -F'\t' -v path="$1" '
        /^#/ || NF < 2 { next }
        index(path, $1) == 1 && length($1) > best { best = length($1); list = $2 }
        END { if (best) print list }
    ' "$MAP"
}

# "all" or "09,12" -> scenario paths. A number with no file is a map typo.
expand() {
    local list=$1 num hits
    if [[ $list == none ]]; then
        return
    fi
    if [[ $list == all ]]; then
        local -a suite=()
        shopt -s nullglob
        suite=(sim/scenarios/*.sh)
        shopt -u nullglob
        ((${#suite[@]} > 0)) || die "no scenarios found under sim/scenarios/"
        printf '%s\n' "${suite[@]}"
        return
    fi
    local IFS=,
    for num in $list; do
        hits=(sim/scenarios/"$num"-*.sh)
        [[ -f ${hits[0]} ]] || die "$MAP names scenario $num, which does not exist"
        printf '%s\n' "${hits[@]}"
    done
}

check_map() {
    local status=0 path
    # Every tracked src file must match a row.
    while IFS= read -r path; do
        if [[ -z $(lookup "$path") ]]; then
            printf 'UNMAPPED %s has no row in %s: nothing in sim/ runs it\n' "$path" "$MAP" >&2
            status=1
        fi
    done < <(git ls-files src | sort)

    # Every row must match a path that still exists, so the map cannot rot.
    while IFS=$'\t' read -r path scenarios _why; do
        [[ $path == \#* || -z ${scenarios:-} ]] && continue
        if ! compgen -G "${path%/}*" >/dev/null; then
            printf 'STALE %s names %s, which does not exist\n' "$MAP" "$path" >&2
            status=1
        fi
        expand "$scenarios" >/dev/null || status=1
    done < "$MAP"

    ((status == 0)) || die "the src-to-scenario map is incomplete (see the lines above)"
    printf 'gate-scenarios: %s covers %s src file(s), %s scenario(s)\n' \
        "$MAP" "$(git ls-files src | wc -l)" \
        "$(shopt -s nullglob; set -- sim/scenarios/*.sh; echo $#)"
}

list() {
    local base=${1:-}
    [[ -n $base ]] || die "usage: $0 --list <base-ref>"
    git rev-parse --verify --quiet "$base^{commit}" >/dev/null \
        || die "unknown base ref: $base"

    local -a changed=() unmapped=() scenarios=()
    local file list scenario
    local -A picked=()
    mapfile -t changed < <(git diff --name-only "$base"...HEAD)

    for file in "${changed[@]}"; do
        # Scenarios this branch edits always run, whatever the map says.
        if [[ $file == sim/scenarios/*.sh ]]; then
            picked["$file"]=1
            continue
        fi
        [[ $file == src/* ]] || continue
        # A deleted file has no scenario left to run; --check-map catches the
        # row it leaves behind.
        [[ -e $file ]] || continue
        list=$(lookup "$file")
        if [[ -z $list ]]; then
            unmapped+=("$file")
            continue
        fi
        out=$(expand "$list") || die "$MAP row for $file is broken"
        # A `none` row (module notes, the map itself) expands to nothing, and a
        # herestring of nothing is one empty line: `picked[""]` is a bad array
        # subscript, so a docs-only change under src/ used to crash the gate.
        [[ -n $out ]] || continue
        mapfile -t scenarios <<< "$out"
        for scenario in "${scenarios[@]}"; do
            picked["$scenario"]=1
        done
    done

    if ((${#unmapped[@]} > 0)); then
        printf 'UNMAPPED %s\n' "${unmapped[@]}" >&2
        die "${#unmapped[@]} changed path(s) under src/ have no row in $MAP: add the scenario(s) that prove them, or the row"
    fi

    ((${#picked[@]} == 0)) && exit 0
    printf '%s\n' "${!picked[@]}" | sort
}

case ${1:-} in
--check-map) check_map ;;
--list) shift; list "${1:-}" ;;
*) die "usage: $0 --check-map | --list <base-ref>" ;;
esac
