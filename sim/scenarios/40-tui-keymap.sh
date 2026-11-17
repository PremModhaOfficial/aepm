#!/usr/bin/env bash
# `tui.conf`'s [keys] section is the keymap: a rebound key acts and the old one
# stops, and a keymap that does not parse stops the binary instead of being
# ignored.
source /usr/local/lib/sim/lib.sh

echo "scenario: key overrides are dispatched, and a bad keymap fails loudly"

conf=/home/builder/.config/aepm/tui.conf
screen=$(mktemp)
mkdir -p "$(dirname "$conf")"

# 1. An unknown action name is a load error, before any frame is drawn.
printf '[keys]\nquits = x\n' >"$conf"
chown -R builder:builder /home/builder/.config
out=$(runuser -l builder -c 'aepm tui --render-once' 2>&1)
status=$?
assert_eq "$status" "2" "an unknown action name exits 2"
assert_contains "$out" 'unknown action `quits`' "the error names the unknown action"
assert_contains "$out" "tui.conf" "the error names the file"

# 1b. A key another action already uses is the same kind of load error, so one
#     key cannot quietly mean two things.
printf '[keys]\nquit = j\n' >"$conf"
chown builder:builder "$conf"
out=$(runuser -l builder -c 'aepm tui --render-once' 2>&1)
status=$?
assert_eq "$status" "2" "a duplicate key exits 2"
assert_contains "$out" 'already bound to `down`' "the error names the action holding the key"

# 2. `quit = x` moves the action: the old key stops working and the new one
#    works. Only the rebinding is written, so the rest is still the default.
printf '[keys]\nquit = x\n' >"$conf"
chown builder:builder "$conf"

if ! command -v script >/dev/null 2>&1; then
    fail "script is missing; the pty checks did not run"
else
    # `q` alone: the tree must still be running when the timeout fires, so the
    # default key no longer quits.
    (sleep 1; printf 'q'; sleep 2) \
        | timeout 5 runuser -l builder -c 'script -qec "stty rows 40 cols 120; aepm tui" /dev/null' \
        >"$screen" 2>&1
    assert_eq "$?" "124" "q is dead while quit is bound to x"

    # `x`: the rebound key is the one that quits, and it exits cleanly.
    (sleep 1; printf 'x'; sleep 1) \
        | timeout 10 runuser -l builder -c 'script -qec "stty rows 40 cols 120; aepm tui" /dev/null' \
        >"$screen" 2>&1
    assert_eq "$?" "0" "the rebound key quits with exit 0"

    # 3. No file means the defaults, so `q` quits again.
    rm -f "$conf"
    (sleep 1; printf 'q'; sleep 1) \
        | timeout 10 runuser -l builder -c 'script -qec "stty rows 40 cols 120; aepm tui" /dev/null' \
        >"$screen" 2>&1
    assert_eq "$?" "0" "the default key works again with no file"
fi

finish
