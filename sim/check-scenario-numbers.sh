#!/usr/bin/env bash
# Fail when two scenario files share a number anywhere under sim/.
#
# The scenario number is a shared namespace: sim/scenarios/ is the container
# suite and sim/vm/ is the VM suite, and both are read, logged and cited as
# "scenario N". A reused number makes a log line, a README row and a CI
# artifact ambiguous, so it is an error here instead of a note in a report.
#
#   sim/check-scenario-numbers.sh                  # every scenario under sim/
#   sim/check-scenario-numbers.sh a.sh b.sh        # plus these paths
#
# The same path listed twice is not a collision (a glob can name the same file
# twice); two different files with the same number are.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

status=0
files=0
declare -A seen=()
declare -A checked=()

check_one() {
    local file=$1 base number
    base=$(basename "$file")
    # Only a leading number followed by a dash names a scenario.
    [[ $base =~ ^([0-9]+)- ]] || return 0
    [[ -z ${checked[$file]:-} ]] || return 0
    checked[$file]=1
    number=$((10#${BASH_REMATCH[1]}))
    files=$((files + 1))
    if [[ -n ${seen[$number]:-} ]]; then
        printf 'sim: scenario number %d is used more than once:\n  %s\n  %s\n' \
            "$number" "${seen[$number]}" "$file" >&2
        status=1
        return 0
    fi
    seen[$number]=$file
}

while IFS= read -r file; do
    check_one "$file"
done < <(find sim -type f -name '*.sh' | sort)

for file in "$@"; do
    check_one "$file"
done

if ((status != 0)); then
    printf 'sim: scenario numbers must be unique across sim/\n' >&2
    exit 1
fi

printf 'sim: scenario numbers unique across %d file(s)\n' "$files"
