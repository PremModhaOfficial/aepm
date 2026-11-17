#!/usr/bin/env bash
# check with a pending update: exit 1, name the package, write nothing.
source /usr/local/lib/sim/lib.sh

echo "scenario: check reports a pending update"

log=$(mktemp)
before_usr=$(usr_state)
before_pkgs=$(pkg_state)
before_cache=$(cache_files)

runuser -l builder -c 'aepm check' >"$log" 2>&1
status=$?

assert_eq "$status" "1" "check exited 1"
assert_contains "$(cat "$log")" "simapp" "check named the pending package"
assert_contains "$(cat "$log")" "official updates: 1" "check counted one official update"
assert_eq "$(usr_state)" "$before_usr" "check left /usr unchanged"
assert_eq "$(pkg_state)" "$before_pkgs" "check installed nothing"
assert_eq "$(cache_files)" "$before_cache" "check left the cache unchanged"
assert_false "check wrote no state" test -e /home/builder/.local/state/aepm/state.json

# The JSON surface is the machine-readable twin of the text report. Same
# verdict, same exit code, one line on stdout, and no colour: ci.sh unit tests
# cover the rendering, this proves the shipped binary prints it and disagrees
# with nothing the text report said. The human summary stays on stderr.
json_log=$(mktemp)
json_err=$(mktemp)
runuser -l builder -c 'aepm check --json' >"$json_log" 2>"$json_err"
status=$?

assert_eq "$status" "1" "check --json exited 1 on a pending update"
assert_eq "$(wc -l <"$json_log")" "1" "check --json printed exactly one line on stdout"
assert_contains "$(cat "$json_err")" "item(s) need attention" "the stderr summary agreed with the JSON verdict"
assert_contains "$(cat "$json_log")" '"command":"check"' "check --json named the command"
assert_contains "$(cat "$json_log")" '"verdict":"action_needed"' "check --json carried the text verdict"
assert_contains "$(cat "$json_log")" '"simapp"' "check --json named the pending package"
assert_false "check --json printed no ANSI" grep -q $'\033' "$json_log"
assert_eq "$(usr_state)" "$before_usr" "check --json left /usr unchanged"

finish
