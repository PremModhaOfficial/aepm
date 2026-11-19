#!/usr/bin/env bash
# The lock gate: a live pacman blocks; a stale lock blocks too and is never
# deleted.
source /usr/local/lib/sim/lib.sh

echo "scenario: fetch refuses while pacman holds the lock"

lock_log=$(mktemp)
stale_log=$(mktemp)

touch /var/lib/pacman/db.lck
# Inode, size and mtime: a lock that was deleted and recreated is a different
# file, and that is the theft this scenario is about.
lock_id=$(stat -c '%i %s %Y' /var/lib/pacman/db.lck)

# A process whose comm is exactly "pacman", without shadowing the real binary.
cp /bin/sleep /tmp/pacman
/tmp/pacman 300 &
holder=$!
sleep 0.2

runuser -l builder -c 'aepm fetch' >"$lock_log" 2>&1
status=$?

assert_eq "$status" "1" "fetch refused while the lock was held"
assert_contains "$(cat "$lock_log")" "pacman is running" "the refusal names the running process"
assert_contains "$(cat "$lock_log")" "/var/lib/pacman/db.lck" \
    "the refusal names the lock it refused on"
assert_false "nothing was downloaded" bash -c 'compgen -G "/var/cache/pacman/pkg/simapp-2.0.0*" >/dev/null'
assert_true "the lock file still exists" test -f /var/lib/pacman/db.lck
assert_true "the live lock was not stolen: its holder is still running" kill -0 "$holder"
assert_eq "$(stat -c '%i %s %Y' /var/lib/pacman/db.lck)" "$lock_id" \
    "the live lock file is the same file, untouched"

kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true

# The same file with no live pacman is stale. pacman would refuse anyway, so
# the gate must block with exit 1 and must not remove the file.
runuser -l builder -c 'aepm fetch' >"$stale_log" 2>&1
status=$?

assert_eq "$status" "1" "a stale lock blocked with exit 1"
assert_contains "$(cat "$stale_log")" "stale lock" "the refusal calls the lock stale"
# Not a generic failure: the message carries the path, so the user knows which
# file to check before removing it.
assert_contains "$(cat "$stale_log")" "stale lock /var/lib/pacman/db.lck" \
    "the stale refusal names the lock by path"
assert_contains "$(cat "$stale_log")" "verify and remove it yourself" \
    "the refusal hands the removal to the user, not to the tool"
assert_false "the stale lock downloaded nothing" bash -c 'compgen -G "/var/cache/pacman/pkg/simapp-2.0.0*" >/dev/null'
assert_true "the stale lock was left alone" test -f /var/lib/pacman/db.lck
assert_eq "$(stat -c '%i %s %Y' /var/lib/pacman/db.lck)" "$lock_id" \
    "the stale lock is the same file, not a recreated one"

finish
