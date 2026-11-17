#!/usr/bin/env bash
# doctor on a configured container: exit 0.
source /usr/local/lib/sim/lib.sh

echo "scenario: doctor passes on a configured system"

printf '1\n' >/etc/sim/snapper.exit

mkdir -p /etc/aurto
# pacman 7 downloads as alpm; the configured cache must be writable by it.
chown alpm:alpm /var/cache/pacman/pkg
chmod 0755 /var/cache/pacman/pkg
printf 'root ALL=(root) NOPASSWD: /usr/bin/pacman -Syuw --noconfirm\n' >/etc/sudoers.d/aepm
chmod 0440 /etc/sudoers.d/aepm
printf 'maintainer\n' >/etc/aurto/trusted-users
printf 'Include = /etc/pacman.d/aurto\n' >>/etc/pacman.conf
printf '[Journal]\nStorage=persistent\nSystemMaxUse=500M\n' >/etc/systemd/journald.conf
printf 'Tue 2026-11-11 00:00:00 UTC  aepm.timer\n' >/etc/sim/systemctl.out

log=$(mktemp)
before_usr=$(usr_state)

aepm doctor >"$log" 2>&1
status=$?

assert_eq "$status" "0" "doctor exited 0"
assert_contains "$(cat "$log")" "doctor: ok" "doctor reported ok"
assert_eq "$(usr_state)" "$before_usr" "doctor left /usr unchanged"

# `doctor --json` is the machine-readable twin of the text report: same verdict,
# same exit code, one line, no colour. Checked here, while this container is
# still the configured one, so a failure is about the JSON surface and not
# about the sudoers rewrite below.
json_log=$(mktemp)
json_err=$(mktemp)
aepm doctor --json >"$json_log" 2>"$json_err"
status=$?

assert_eq "$status" "0" "doctor --json exited 0 on a configured container"
assert_eq "$(wc -l <"$json_log")" "1" "doctor --json printed exactly one line on stdout"
assert_eq "$(wc -c <"$json_err")" "0" "doctor --json printed no complaint on stderr"
assert_contains "$(cat "$json_log")" '"command":"doctor"' "doctor --json named the command"
assert_contains "$(cat "$json_log")" '"verdict":"ok"' "doctor --json carried the text verdict"
assert_contains "$(cat "$json_log")" '"problems":0' "doctor --json counted no problems"
assert_false "doctor --json printed no ANSI" grep -q $'\033' "$json_log"
assert_eq "$(usr_state)" "$before_usr" "doctor --json left /usr unchanged"

# The product runs as the user, and a correct 0440 root-owned rule is
# unreadable. Doctor must verify it through sudo -l and still pass.
printf 'builder ALL=(root) NOPASSWD: /usr/bin/pacman -Syuw --noconfirm\n' >/etc/sudoers.d/aepm
chmod 0440 /etc/sudoers.d/aepm
runuser -l builder -c 'aepm doctor' >"$log" 2>&1
status=$?

assert_eq "$status" "0" "doctor as builder exited 0"
assert_contains "$(cat "$log")" "sudo -l matches" "doctor verified the unreadable rule through sudo -l"
assert_eq "$(usr_state)" "$before_usr" "doctor as builder left /usr unchanged"

finish
