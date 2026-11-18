#!/usr/bin/env bash
# A helper that exits 0 having installed part of the planned set: install must
# refuse, name what did not move, and write nothing about a finished upgrade.
#
# GLOSSARY promises a partial upgrade is "refused, not resolved silently". The
# pending set is only a set, not a count: `fetch` records the names it planned,
# and after `yay -Syuu` reports success `install` re-reads `pacman -Qu` and
# subtracts. A name on both sides is a package the upgrade left behind.
#
# The helper is made to reproduce exactly that: pacman's own `--ignore` holds
# one of the two planned packages back, so the transaction succeeds and the
# system ends up mixed. Nothing here mocks the tool.
source /usr/local/lib/sim/lib.sh

echo "scenario: a helper that installs part of the planned set is refused, not called done"

pkgname=bigpkg
# One state file both roles read. In production one user runs both commands;
# the harness splits them so the sudo contract stays as narrow as the real
# sudoers rule, and a per-HOME state file would then compare against nothing.
state_dir=/srv/aepm-sim
install -d -m 0777 "$state_dir"
state=$state_dir/state.json
trusted=/etc/aurto/trusted-users

# Two pending packages. One alone would make "the helper left one pending" the
# whole upgrade, and the refusal would prove nothing about set comparison.
make-pkg.sh "$pkgname" 1.0.0 4096 >/dev/null
pacman -Syy --noconfirm >/dev/null
pacman -S --noconfirm "$pkgname" >/dev/null
make-pkg.sh "$pkgname" 2.0.0 8192 >/dev/null
pacman -Syy --noconfirm >/dev/null

# A configured trust file, so the install below is gated only by --yes.
mkdir -p /etc/aurto
printf 'maintainer\n' >"$trusted"

assert_eq "$(pacman -Qu | wc -l | tr -d ' ')" "2" "two packages are pending"

fetch_log=$(mktemp)
runuser -l builder -c "AEPM_STATE=$state aepm fetch" >"$fetch_log" 2>&1
assert_eq "$?" "0" "fetch prefetched both packages"
assert_contains "$(cat "$state")" '"last_fetch_pending":2' "the count is recorded"
assert_contains "$(cat "$state")" '"last_fetch_pending_names"' \
    "the names are recorded, so a set can be compared"
assert_contains "$(cat "$state")" '"simapp"' "the first planned name is in the set"
assert_contains "$(cat "$state")" '"bigpkg"' "the second planned name is in the set"
fetched_state=$(sha256sum "$state" | cut -d' ' -f1)

# The fault: the helper's transaction holds bigpkg back and still exits 0.
printf '%s\n' "$pkgname" >/etc/sim/sim-upgrade-ignore

before_usr=$(usr_state)
install_log=$(mktemp)
runuser -l installer -c "AEPM_STATE=$state aepm install --yes" >"$install_log" 2>&1
status=$?

# The refusal: nonzero, one named reason, and the names that did not move.
assert_eq "$status" "2" "install refuses a partial upgrade with exit 2"
assert_contains "$(cat "$install_log")" "partial upgrade" "the reason is named"
assert_contains "$(cat "$install_log")" "$pkgname" "the package left behind is named"
assert_false "the completed package is not reported as missing" \
    grep -q 'still pending (.*simapp' "$install_log"

# The helper really did run and really did move part of the system; the refusal
# is about calling that finished, not about the transaction failing.
assert_contains "$(yay_log)" "-Syuu" "the helper was asked for the full upgrade"
assert_eq "$(installed_version)" "2.0.0-1" "the other planned package moved"
assert_eq "$(pacman -Q "$pkgname")" "$pkgname 1.0.0-1" "the held package did not"
assert_ne "$(usr_state)" "$before_usr" "the upgrade did change /usr"
assert_eq "$(pacman -Qu | wc -l | tr -d ' ')" "1" "one package is still pending"

# The refusal writes nothing: not the state file, and no package database the
# read-only commands would then report as a finished upgrade.
assert_eq "$(sha256sum "$state" | cut -d' ' -f1)" "$fetched_state" \
    "the refusal left the state file byte for byte"
assert_false "no install time was recorded for a partial upgrade" \
    grep -q '"last_install_unix":[0-9]' "$state"
assert_false "the refusal ran no AUR build" yay_built_something

# Not sticky: once the held package is allowed through, the same command
# completes and the refusal is gone.
rm -f /etc/sim/sim-upgrade-ignore
done_log=$(mktemp)
runuser -l installer -c "AEPM_STATE=$state aepm install --yes" >"$done_log" 2>&1
assert_eq "$?" "0" "the completed upgrade exits 0"
assert_eq "$(pacman -Qu | wc -l | tr -d ' ')" "0" "nothing is pending"
assert_eq "$(pacman -Q "$pkgname")" "$pkgname 2.0.0-1" "the held package moved"
assert_true "the install is recorded once the set is empty" \
    grep -q '"last_install_unix":[0-9]' "$state"
assert_false "no partial upgrade is reported when the set is finished" \
    grep -qi "partial upgrade" "$done_log"
assert_eq "$(grep -c '^-n /usr/local/bin/sim-upgrade$' /var/log/sim-sudo.log)" "2" \
    "each install escalated through the scoped helper only"
assert_eq "$(grep -c '^-n /usr/bin/pacman -Syuw --noconfirm$' /var/log/sim-sudo.log)" "1" \
    "the fetch's own escalation is the download-only argv"
assert_eq "$(grep -vcE '^-n (/usr/local/bin/sim-upgrade|/usr/bin/pacman -Syuw --noconfirm)$' \
    /var/log/sim-sudo.log)" "0" "nothing else ran through sudo"

finish
