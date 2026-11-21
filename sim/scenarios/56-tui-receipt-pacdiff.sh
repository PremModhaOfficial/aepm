#!/usr/bin/env bash
# The receipt's `p` runs `sudo pacdiff` attached: the TUI leaves the terminal,
# the tool's one real side effect happens, the TUI comes back, and the receipt
# re-reads the `.pacnew` count instead of keeping the number from before. The
# pacdiff stub stands in for the interactive tool. This is the disposable
# container, never the host.
source /usr/local/lib/sim/lib.sh

echo "scenario: the receipt's p runs sudo pacdiff attached and re-reads the count"

state_dir=/home/installer/.local/state/aepm
screen=$(mktemp)
driver=$(mktemp)
before_p=$(mktemp -d)

mkdir -p /etc/aurto
printf 'maintainer\n' >/etc/aurto/trusted-users

# Exactly one .pacnew waiting for review: any file the image shipped is removed
# first, so the receipt's count is the one this scenario made.
find /etc -name '*.pacnew' -delete
printf '# sim\n' >/etc/aepm-sim.conf.pacnew
touch /etc/sim/pacdiff.removes-pacnew

rm -rf "$state_dir"
: >/var/log/sim-sudo.log
: >/var/log/sim-yay.log
: >/var/log/sim-yay-build.log

before_pkgs=$(pkg_state)

cat >"$driver" <<'EOF'
#!/bin/bash
script -qec 'stty rows 40 cols 120; aepm tui; rc=$?; stty -a | grep -q icanon && test "$rc" = 0' /dev/null
EOF
chmod 755 "$driver"

# i opens the gate, space attests, enter runs the attached install, eight
# seconds for the upgrade and the receipt frame. The state directory is copied
# as it stands BEFORE p, then p runs pacdiff, and q closes the receipt and
# quits.
( sleep 1; printf 'i'; sleep 1; printf ' '; sleep 1; printf '\r'; sleep 8
  cp -a "$state_dir" "$before_p/copy" 2>/dev/null
  printf 'p'; sleep 3; printf 'q' ) \
    | timeout 60 runuser -l installer -c "$driver" >"$screen" 2>&1
status=$?
assert_eq "$status" "0" "the TUI exited 0 and restored the terminal"

clean=$(sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' -e 's/\x1b[()][A-Za-z0-9]//g' "$screen" | tr -d '\r')

# 1. The success receipt offered the attached run on the files it found.
assert_contains "$clean" "Post-install" "the receipt is shown"
assert_contains "$clean" "exited 0" "the receipt carries the real exit"
assert_contains "$clean" "1 .pacnew file(s); press p to run sudo pacdiff" \
    "the receipt offers p on a success receipt with a .pacnew"

# 2. p reached sudo as the exact argv, and the stub did pacdiff's side effect.
assert_eq "$(grep -c '^pacdiff$' /var/log/sim-sudo.log)" "1" \
    "sudo ran pacdiff once, as the whole argv"
assert_true "the pacdiff stub ran instead of the real tool" test -s /var/log/sim-pacdiff.log
assert_false "the stub removed the .pacnew it reviewed" test -f /etc/aepm-sim.conf.pacnew

# 3. The TUI came back and the receipt re-read the count: the receipt that
#    offered one file now reports none, from a fresh read of /etc.
assert_contains "$clean" "no .pacnew files" "the receipt re-read the count"

# 4. p ran nothing else: no second upgrade, no AUR build, no state write.
assert_eq "$(grep -c -- '-Syuu' /var/log/sim-yay.log)" "1" "yay ran the upgrade once"
assert_false "the receipt's p never reaches the AUR build path" yay_built_something
assert_true "the state file existed before p" test -f "$before_p/copy/state.json"
assert_eq "$(cd "$before_p/copy" && tree_state .)" "$(cd "$state_dir" && tree_state .)" \
    "p did not change the state file"
assert_eq "$(installed_version)" "2.0.0-1" "the upgrade installed the pending package"
assert_ne "$(pkg_state)" "$before_pkgs" "the package database changed once"

finish
