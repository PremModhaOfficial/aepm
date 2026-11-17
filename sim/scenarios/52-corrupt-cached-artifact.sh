#!/usr/bin/env bash
# The cached artifact goes bad after the prefetch, before the install.
#
# The cache is ordinary disk between the fetch and the install: a bad sector, a
# truncated copy or a stray edit leaves a package whose size is right and whose
# bytes are wrong. pacman verifies a cached artifact before it uses it, so the
# tool must end up installing the real bytes, never the corrupt copy, and must
# never turn a corrupt cache into an AUR rebuild.
source /usr/local/lib/sim/lib.sh

echo "scenario: a corrupt cached artifact is re-fetched, never installed as is or rebuilt"

cache=/var/cache/pacman/pkg
package=simapp-2.0.0-1-x86_64.pkg.tar.zst
source=/srv/simrepo/$package

state_files() { find /home/builder/.local/state -type f -printf '%P\n' 2>/dev/null | sort; }

# 1. A prefetch that worked, so the only fault is the one the scenario injects.
fetch_log=$(mktemp)
runuser -l builder -c 'aepm fetch' >"$fetch_log" 2>&1
assert_eq "$?" "0" "the prefetch succeeded"
assert_contains "$(cat "$fetch_log")" "fetch: ok" "the prefetch reported success"
assert_true "the cache holds the real artifact" cmp -s "$cache/$package" "$source"

# 2. The fault: the size stays right, one byte in the middle is wrong.
size=$(stat -c %s "$cache/$package")
printf '\xff' | dd of="$cache/$package" bs=1 seek="$((size / 2))" conv=notrunc \
    status=none
assert_false "the cached artifact is no longer the repo artifact" \
    cmp -s "$cache/$package" "$source"

# 3. The read-only commands read this cache and write nothing.
before_usr=$(usr_state)
before_pkgs=$(pkg_state)
before_sync=$(sync_db_state | sha256sum)
before_state=$(state_files)

check_log=$(mktemp)
runuser -l builder -c 'aepm check' >"$check_log" 2>&1
assert_eq "$?" "1" "check exits 1 on the pending update"
doctor_log=$(mktemp)
runuser -l builder -c 'aepm doctor' >"$doctor_log" 2>&1
assert_eq "$?" "1" "doctor exits 1 on the unconfigured container"

assert_eq "$(sync_db_state | sha256sum)" "$before_sync" "check and doctor wrote no sync DB"
assert_eq "$(state_files)" "$before_state" "check and doctor wrote no state"

# 4. Install over the corrupt cache. The helper runs as installer; make its log
#    writable for this container.
touch /var/log/sim-yay.log
chmod 0666 /var/log/sim-yay.log

before_usr=$(usr_state)
before_pkgs=$(pkg_state)

install_log=$(mktemp)
runuser -l installer -c 'aepm install --yes' >"$install_log" 2>&1
status=$?

# pacman verifies a cached artifact before it uses it, so the install stops at
# the verification and nothing is extracted. The tool reports it as an
# execution error and names the command that failed.
assert_eq "$status" "2" "install refuses the corrupt cache (exit 2, D6)"
assert_contains "$(cat "$install_log")" "invalid or corrupted package (checksum)" \
    "the failure names the verification that refused the artifact"
assert_contains "$(cat "$install_log")" "yay -Syuu exited 1" \
    "the failure names the command that died"
assert_eq "$(installed_version)" "1.0.0-1" "the corrupt artifact was not installed"
assert_eq "$(usr_state)" "$before_usr" "the refused install wrote nothing to /usr"
assert_eq "$(pkg_state)" "$before_pkgs" "the refused install changed no package"

# 5. The corrupt copy is not left for the next run to trust.
assert_false "the corrupt artifact is gone from the cache" \
    test -e "$cache/$package"

# 6. Retry: with the bad copy discarded, the transfer brings the real bytes and
#    the install completes. The failure was the cache, not the tool's state.
retry=$(mktemp)
runuser -l installer -c 'aepm install --yes' >"$retry" 2>&1
status=$?

assert_eq "$status" "0" "the retry installs"
assert_eq "$(installed_version)" "2.0.0-1" "the package upgraded"
assert_eq "$(payload_version)" "2.0.0" "the payload on disk is the new version"
assert_true "the cache holds the real artifact" \
    cmp -s "$cache/$package" "$source"

# 7. A corrupt cache never turns into a rebuild: both installs escalated only
#    the scoped helper, and the AUR build path never ran.
assert_eq "$(grep -c '^-n /usr/bin/pacman -Syuw --noconfirm$' /var/log/sim-sudo.log)" "1" \
    "the prefetch escalated the allowed fetch argv once"
assert_eq "$(grep -c '^-n /usr/local/bin/sim-upgrade$' /var/log/sim-sudo.log)" "2" \
    "both installs escalated only the scoped helper"
assert_contains "$(yay_log)" "-Syuu" "yay was asked for the full upgrade"
assert_false "install ran no AUR build" yay_built_something

finish
