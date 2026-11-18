#!/usr/bin/env bash
# A stale aurto repo with an AUR update pending: the install that follows would
# build that package in the foreground, and the user has to be told.
#
# aurto builds AUR packages into a local pacman repo; the point of the whole
# prefetch/install split is that the slow part happens off the terminal. When
# the local repo is behind what the AUR offers, `yay -Syuu` cannot satisfy the
# pending AUR package from it and builds instead - in the foreground, with a
# PKGBUILD nobody has read and the terminal held for as long as the build takes.
#
# The harness makes that state real rather than mocking it: a local aurto repo
# holding auronly 1.0.0, an AUR list offering 2.0.0. The tool sees the AUR
# update - `check` counts it - and `install` carries the same warning the TUI
# does, from one shared sentence, so a foreground build is never a surprise.
source /usr/local/lib/sim/lib.sh

echo "scenario: a stale aurto repo is a foreground build risk install reports"

pkgname=auronly
repo=/srv/aurto-repo
cache=/var/cache/pacman/pkg

# The local AUR repo, one version behind what the AUR offers. make-pkg.sh
# publishes into the sim repo; the artifact is then copied into a repo of its
# own, which is what aurto would have built.
make-pkg.sh "$pkgname" 1.0.0 4096 >/dev/null
mkdir -p "$repo"
cp "/srv/simrepo/$pkgname-1.0.0-1-x86_64.pkg.tar.zst" "$repo/"
repo-add "$repo/aurto.db.tar.gz" "$repo/$pkgname-1.0.0-1-x86_64.pkg.tar.zst" >/dev/null
printf '[aurto]\nServer = file://%s\n' "$repo" >/etc/pacman.d/aurto
printf 'Include = /etc/pacman.d/aurto\n' >>/etc/pacman.conf

# The AUR itself offers a newer version, so the local repo is stale.
printf '%s 1.0.0-1 -> 2.0.0-1\n' "$pkgname" >/etc/sim/yay-qua.out

# A configured trust file, so the install below is gated only by --yes and the
# warning under test is the one this scenario is about.
mkdir -p /etc/aurto
printf 'maintainer\n' >/etc/aurto/trusted-users

pacman -Syy --noconfirm >/dev/null

# The stale state, asserted rather than assumed: the repo pacman reads has the
# old version, and the tool's own view of the AUR has the new one.
assert_eq "$(pacman -Sl aurto | awk '{print $2, $3}')" "$pkgname 1.0.0-1" \
    "the local aurto repo only holds the old version"
check_log=$(mktemp)
runuser -l builder -c 'aepm check' >"$check_log" 2>&1
assert_contains "$(cat "$check_log")" "check: aur updates: 1" \
    "check sees the pending AUR update, so install can see it too"
assert_eq "$(installed_version)" "1.0.0-1" "nothing has been installed yet"

# The artifact the local repo holds is 1.0.0 and the AUR offers 2.0.0, so the
# only honest badge for it is an older build. aurto builds into its own cache,
# so that is where the stale artifact goes; "built" would claim the update is
# satisfied when the repo cannot satisfy it.
cache=/var/cache/pacman/aurto
mkdir -p "$cache"
cp "/srv/simrepo/$pkgname-1.0.0-1-x86_64.pkg.tar.zst" "$cache/"
frame=$(mktemp)
runuser -l builder -c 'aepm tui --render-once' >"$frame" 2>&1
assert_contains "$(cat "$frame")" "older build 1.0.0-1" \
    "the artifact the local repo holds reads as an older build"
assert_false "a stale local repo is never reported as built" \
    bash -c 'grep "$1" "$2" | grep -q built' _ "$pkgname" "$frame"
assert_false "check never calls the AUR package built" \
    bash -c 'grep -q "built" "$1"' _ "$check_log"

# The install. It is legal and it succeeds: the risk is not a failure, it is
# that a build may now hold the terminal and nothing said so.
log=$(mktemp)
runuser -l installer -c 'aepm install --yes' >"$log" 2>&1
status=$?

assert_eq "$status" "0" "install exits 0"
assert_contains "$(yay_log)" "-Syuu" "install asked yay for the full upgrade"

# The deliverable: the CLI says what the TUI already said, so a build that may
# now hold the terminal is announced before yay is asked to run it.
assert_true "install reports the stale aurto repo" \
    grep -qi "aurto is stale" "$log"

# The other half of the claim: no build happened here, because the simulated
# helper cannot build. That is exactly why the warning is the only protection.
assert_false "the simulated helper ran no AUR build" yay_built_something
assert_eq "$(grep -vc '^-n /usr/local/bin/sim-upgrade$' /var/log/sim-sudo.log)" "0" \
    "the scoped helper is the only escalation"

finish
