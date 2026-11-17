#!/usr/bin/env bash
# The mirror serves a corrupt package: the right size, one wrong byte.
#
# A bad mirror, a truncated upload or a proxy that rewrote the body produces an
# artifact pacman's own checksum check rejects. The `corrupt` fault flips one
# byte in the middle of the transfer, so the failure is pacman refusing the
# bytes, not the download stopping early. The tool must report it, keep no
# artifact, install nothing, and fetch the real bytes on the retry.
source /usr/local/lib/sim/lib.sh

echo "scenario: a corrupt download is rejected by pacman and never installed"

cache=/var/cache/pacman/pkg
package=simapp-2.0.0-1-x86_64.pkg.tar.zst
source=/srv/simrepo/$package

cp /usr/local/lib/sim/fixtures/pacman-slow-xfer.conf /etc/pacman.conf
echo corrupt >/etc/sim/xfer-fault

rm -f /var/lib/pacman/sync/sim.db /var/lib/pacman/sync/sim.db.part

before_usr=$(usr_state)
before_pkgs=$(pkg_state)
before_local=$(local_db_state | sha256sum)

log=$(mktemp)
runuser -l builder -c 'aepm fetch' >"$log" 2>&1
status=$?

# 1. The rejection is an execution error, and it names pacman's verdict.
assert_eq "$status" "2" "the rejected artifact is an execution error (exit 2, D6)"
assert_false "fetch never claims success" \
    bash -c 'grep -q "fetch: ok" "$1"' _ "$log"
assert_contains "$(cat "$log")" "invalid or corrupted package (checksum)" \
    "pacman rejected the artifact it was handed"
assert_contains "$(cat "$log")" "no packages were upgraded" \
    "pacman committed nothing from the rejected artifact"

# 2. The corrupt bytes are gone, not cached for the next run to trust.
assert_false "no final artifact was written" test -e "$cache/$package"
assert_false "no partial artifact was kept" test -e "$cache/$package.part"

# 3. The lists did arrive, and pacman exited on its own: no lock.
assert_true "the failed fetch still delivered the package lists" \
    cmp -s /var/lib/pacman/sync/sim.db /srv/simrepo/sim.db.tar.gz
assert_false "the rejected transfer left no lock" test -f /var/lib/pacman/db.lck

# 4. Nothing outside the cache and the sync DB moved.
assert_eq "$(usr_state)" "$before_usr" "the failed fetch wrote nothing to /usr"
assert_eq "$(pkg_state)" "$before_pkgs" "the failed fetch installed nothing"
assert_eq "$(local_db_state | sha256sum)" "$before_local" \
    "the local package DB is untouched"

# 5. Retry: the fault disarmed itself, so this transfers the real bytes and the
#    tool only trusts them after pacman verified them again.
retry=$(mktemp)
runuser -l builder -c 'aepm fetch' >"$retry" 2>&1
status=$?

assert_eq "$status" "0" "the retry on the same cache succeeds"
assert_contains "$(cat "$retry")" "fetch: ok" "the retry reports success"
assert_eq "$(cache_files)" "$package" "the cache now holds exactly the one package"
assert_true "the retried bytes are the repo artifact, not the corrupt ones" \
    cmp -s "$cache/$package" "$source"
assert_eq "$(usr_state)" "$before_usr" "the retried fetch wrote nothing to /usr"
assert_eq "$(pkg_state)" "$before_pkgs" "the retried fetch installed nothing"

# 6. Invariants: one escalation per fetch with the allowed argv, no AUR path.
assert_eq "$(grep -c . /var/log/sim-sudo.log)" "2" "each fetch escalated once"
assert_eq "$(grep -vc '^-n /usr/bin/pacman -Syuw --noconfirm$' /var/log/sim-sudo.log)" "0" \
    "both escalations are the exact fetch argv"
assert_eq "$(yay_log)" "" "no fetch reached yay"
assert_false "nothing ran an AUR build" yay_built_something

finish
