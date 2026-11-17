#!/usr/bin/env bash
# The mirror answers 500 for the package transfer.
#
# A mirror that is up but broken (a reverse proxy erroring, a signature
# mismatch page) never delivers a byte of the body. The `http500` fault makes
# the transfer hook exit the way curl --fail does, so pacman sees a downloader
# that failed for the whole file, not an interrupted one. The tool must say so,
# keep the lists it already received, install nothing, and recover when the
# mirror does.
source /usr/local/lib/sim/lib.sh

echo "scenario: a mirror that answers 500 fails the fetch and installs nothing"

cache=/var/cache/pacman/pkg
package=simapp-2.0.0-1-x86_64.pkg.tar.zst

cp /usr/local/lib/sim/fixtures/pacman-slow-xfer.conf /etc/pacman.conf
echo http500 >/etc/sim/xfer-fault

# Remove the sync DB so "the lists arrived" means "this fetch fetched them".
# The fault only fires on a package transfer, so the database transfer is real.
rm -f /var/lib/pacman/sync/sim.db /var/lib/pacman/sync/sim.db.part

state_files() { find /home/builder/.local/state -type f -printf '%P\n' 2>/dev/null | sort; }

before_usr=$(usr_state)
before_pkgs=$(pkg_state)
before_local=$(local_db_state | sha256sum)

log=$(mktemp)
runuser -l builder -c 'aepm fetch' >"$log" 2>&1
status=$?

# 1. The refusal is an execution error, and the tool quotes what it got.
assert_eq "$status" "2" "the refused transfer is an execution error (exit 2, D6)"
assert_false "fetch never claims success" \
    bash -c 'grep -q "fetch: ok" "$1"' _ "$log"
assert_contains "$(cat "$log")" "500 Internal Server Error" \
    "the failure names what the mirror answered"
assert_contains "$(cat "$log")" "failed to retrieve some files" \
    "pacman reports the transfer it could not finish"
assert_contains "$(cat "$log")" "error invoking external downloader" \
    "the failure is the downloader, not the transaction"

# 2. A 500 delivers no bytes: no partial artifact to retry from, no final one.
assert_eq "$(cache_files)" "" "the refused transfer left nothing in the cache"
assert_false "no final artifact was written" test -e "$cache/$package"

# 3. The lists were fetched first, so the version the transfer failed on is the
#    one the tool now knows about, and pacman exited on its own: no lock.
assert_true "the failed fetch still delivered the package lists" \
    cmp -s /var/lib/pacman/sync/sim.db /srv/simrepo/sim.db.tar.gz
assert_contains "$(pacman -Qu 2>&1)" "simapp 1.0.0-1 -> 2.0.0-1" \
    "the new lists carry the pending update"
assert_false "the refused transfer left no lock" test -f /var/lib/pacman/db.lck

# 4. Only the cache and the sync DB were ever in scope, and neither the local
#    package DB nor /usr moved.
assert_eq "$(usr_state)" "$before_usr" "the failed fetch wrote nothing to /usr"
assert_eq "$(pkg_state)" "$before_pkgs" "the failed fetch installed nothing"
assert_eq "$(local_db_state | sha256sum)" "$before_local" \
    "the local package DB is untouched"

# 5. The read-only commands stay read-only in the state the failure left behind:
#    lists newer than the cache, a pending update, a broken mirror.
before_sync=$(sync_db_state | sha256sum)
before_cache=$(cache_files | sha256sum)
before_state=$(state_files)

check_log=$(mktemp)
runuser -l builder -c 'aepm check' >"$check_log" 2>&1
assert_eq "$?" "1" "check exits 1 on the pending update"
assert_contains "$(cat "$check_log")" "simapp" "check names the pending package"

doctor_log=$(mktemp)
runuser -l builder -c 'aepm doctor' >"$doctor_log" 2>&1
assert_eq "$?" "1" "doctor exits 1 on the unconfigured container"

assert_eq "$(sync_db_state | sha256sum)" "$before_sync" "check and doctor wrote no sync DB"
assert_eq "$(cache_files | sha256sum)" "$before_cache" "check and doctor wrote no cache entry"
assert_eq "$(state_files)" "$before_state" "check and doctor wrote no state"

# 6. The retry after the mirror recovers (the fault disarmed itself) completes
#    from the same cache: the failure was the mirror, not the tool's state.
retry=$(mktemp)
runuser -l builder -c 'aepm fetch' >"$retry" 2>&1
status=$?

assert_eq "$status" "0" "the retry against the recovered mirror succeeds"
assert_contains "$(cat "$retry")" "fetch: ok" "the retry reports success"
assert_eq "$(cache_files)" "$package" "the retry cached exactly the one package"
assert_true "the retried bytes match the repo artifact" \
    cmp -s "$cache/$package" "/srv/simrepo/$package"
assert_eq "$(usr_state)" "$before_usr" "the retried fetch wrote nothing to /usr"
assert_eq "$(pkg_state)" "$before_pkgs" "the retried fetch installed nothing"

# 7. Invariants: each fetch escalated exactly the allowed argv, and no fetch
#    reached the AUR upgrade path. (`check` and `doctor` legitimately read the
#    AUR query and `sudo -l` in step 5, so only pacman escalations are counted.)
assert_eq "$(grep -c '^-n /usr/bin/pacman -Syuw --noconfirm$' /var/log/sim-sudo.log)" "2" \
    "each fetch escalated exactly once, with the allowed argv"
assert_eq "$(grep -c '^-n /usr/bin/pacman ' /var/log/sim-sudo.log)" "2" \
    "no fetch escalated any other pacman argv"
assert_false "no fetch asked yay for an upgrade" \
    bash -c 'grep -q -- "-Syuu" /var/log/sim-yay.log'
assert_false "nothing ran an AUR build" yay_built_something

finish
