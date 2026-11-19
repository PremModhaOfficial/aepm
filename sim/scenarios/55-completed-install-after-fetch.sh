#!/usr/bin/env bash
# The other half of scenario 44: pacman's log holds a fetch followed by an
# install, and the install finished the whole upgrade. Nothing is pending, so
# `check` must not read that log as a pending upgrade or as a mixed system.
#
# The fixture is real evidence, not a written log: a download-only fetch is
# recorded in the state file and as a `-Syuw` line, then a hand upgrade appends
# its own `[ALPM] upgraded` line after it. sc44 proves the mixed case is
# detected from those same positions; this proves a completed one is not
# invented out of them.
source /usr/local/lib/sim/lib.sh

echo "scenario: an install that finishes the upgrade is not a pending upgrade"

log=/var/log/pacman.log
cache=/var/cache/pacman/pkg
package=simapp-2.0.0-1-x86_64.pkg.tar.zst
state=/home/builder/.local/state/aepm/state.json

# A known starting point: current lists, one known pending package.
pacman -Syy --noconfirm >/dev/null
assert_eq "$(pacman -Qu simapp)" "simapp 1.0.0-1 -> 2.0.0-1" \
    "one known package is pending"

# 1. The fetch. It downloads, records itself, and installs nothing.
fetch_log=$(mktemp)
runuser -l builder -c 'aepm fetch' >"$fetch_log" 2>&1
status=$?

assert_eq "$status" "0" "the fetch succeeded"
assert_contains "$(cat "$fetch_log")" "fetch: ok" "the fetch reported success"
assert_true "the artifact is in the cache" test -f "$cache/$package"
assert_true "the fetch was recorded in the state file" test -f "$state"
assert_eq "$(installed_version)" "1.0.0-1" "the fetch installed nothing"

# 2. Before the install the system is genuinely pending, and a bare fetch is
#    not itself a partial upgrade.
before_log=$(mktemp)
runuser -l builder -c 'aepm check' >"$before_log" 2>&1
status=$?

assert_eq "$status" "1" "check exits 1 while the update is pending"
assert_contains "$(cat "$before_log")" "official updates: 1" \
    "check counts the pending update"
assert_false "a fetch alone is not a partial upgrade" \
    bash -c 'grep -qi "partial upgrade" "$1"' _ "$before_log"

# 3. The install that finishes the whole upgrade, by hand, in the window.
pacman -Syu --noconfirm >/dev/null
status=$?

assert_eq "$status" "0" "the install succeeded"
assert_eq "$(installed_version)" "2.0.0-1" "the upgrade is complete"
assert_eq "$(pacman -Qu | wc -l | tr -d ' ')" "0" "nothing is pending any more"

# 4. The fixture state, asserted rather than assumed: the real log holds the
#    download-only fetch and an install after it. Positions, because pacman
#    appends.
fetch_line=$(grep -n -- '-Syuw' "$log" | tail -1 | cut -d: -f1)
install_line=$(grep -nE '\[ALPM\] (installed|upgraded)' "$log" | tail -1 | cut -d: -f1)
assert_contains "$(sed -n "${fetch_line}p" "$log")" "-Syuw" \
    "the log holds the download-only fetch"
assert_contains "$(sed -n "${install_line}p" "$log")" "upgraded simapp" \
    "the log holds the upgrade that finished it"
assert_true "the install is later than the fetch ($fetch_line < $install_line)" \
    test "$install_line" -gt "$fetch_line"

# 5. The claim. Both records are in the log and the install completed them, so
#    there is no pending update and no partial upgrade to report.
before_usr=$(usr_state)
before_pkgs=$(pkg_state)
before_state=$(sha256sum "$state")
after_log=$(mktemp)
runuser -l builder -c 'aepm check' >"$after_log" 2>&1
status=$?

assert_eq "$status" "0" "check exits 0 on the completed install"
assert_contains "$(cat "$after_log")" "check: clean" "check calls the system clean"
assert_false "a completed install is not counted as pending" \
    bash -c 'grep -q "updates: 1" "$1"' _ "$after_log"
assert_false "a completed install is not a partial upgrade" \
    bash -c 'grep -qi "partial upgrade" "$1"' _ "$after_log"
assert_false "check asks for no action" \
    bash -c 'grep -q "action needed" "$1"' _ "$after_log"

# 6. Read-only, and the fetch record is what check read rather than a rewrite
#    of it. The prefetched artifact is the version that is now installed, so the
#    cache is current too, not a stale copy reported as pending work.
assert_eq "$(usr_state)" "$before_usr" "check left /usr unchanged"
assert_eq "$(pkg_state)" "$before_pkgs" "check installed nothing"
assert_eq "$(sha256sum "$state")" "$before_state" "check wrote no state"
assert_true "the prefetched artifact is still the installed version" \
    test -f "$cache/$package"

finish
