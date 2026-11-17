#!/usr/bin/env bash
# The packaging claim: an AUR-style checkout (PKGBUILD and its .install, no
# Cargo.toml in the parse directory) builds with a real makepkg, and pacman
# installs the binary and the user units where systemd reads them.
#
# The container has no network, so the image's source tree becomes a local git
# repo: the scenario creates the tag the PKGBUILD names and rewrites the
# github URL to it. pkgver and _tag stay literal in the PKGBUILD, because an
# AUR user's parse directory has no Cargo.toml; scripts/gate-pkgbuild-version.sh
# is what keeps those literals equal to the crate version.
source /usr/local/lib/sim/lib.sh

echo "scenario: makepkg builds the package, and pacman installs /usr/bin + user units"

# The AUR checkout: only the files a user gets from the AUR.
work=$(mktemp -d)
cp -a /usr/local/lib/sim/pkg-repo/. "$work/"
assert_false "the AUR checkout has no Cargo.toml at parse time" \
    test -e "$work/Cargo.toml"

# What the PKGBUILD's git source clones: the upstream tree, tagged.
src=$(mktemp -d)
cp -a /usr/local/lib/sim/pkg-src/. "$src/"
version=$(sed -n 's/^version = "\(.*\)"/\1/p' "$src/Cargo.toml" | head -1)
expected_pkgver=${version//-/_}

cd "$src" || exit 1
git init -q
git add -A
git -c user.name=sim -c user.email=sim@example.invalid commit -qm "the package source"
git tag "v$version"

chown -R builder:builder "$work" "$src"
# makepkg sets GIT_CONFIG_GLOBAL=/dev/null and reads only its own system config,
# so an insteadOf rewrite in builder's ~/.gitconfig would never be seen.
mkdir -p /etc/makepkg.d
printf '[url "file://%s/"]\n\tinsteadOf = %s\n' \
    "$src" 'https://github.com/PremModhaOfficial/aepm.git' \
    >/etc/makepkg.d/gitconfig

srcinfo=$(runuser -l builder -c "cd '$work' && makepkg --printsrcinfo" 2>&1)
assert_eq "$(awk '$1 == "pkgver" { print $3 }' <<<"$srcinfo")" "$expected_pkgver" \
    "pkgver matches the crate version"
assert_eq "$(sed -n 's/.*#tag=//p' <<<"$srcinfo")" "v$version" \
    "the source tag matches the crate version"

build_log=$(mktemp)
runuser -l builder -c "cd '$work' && CARGO_NET_OFFLINE=true makepkg -f --noconfirm" \
    >"$build_log" 2>&1
status=$?
assert_eq "$status" "0" "the real makepkg build exited 0"
assert_contains "$(cat "$build_log")" "Finished making: aepm $expected_pkgver-1" \
    "makepkg named the package after the crate version"

pkgfile=$(find "$work" -maxdepth 1 -name "aepm-$expected_pkgver-1-*.pkg.tar.*" -print -quit)
assert_true "the package artifact exists" test -n "$pkgfile"
if [[ -z $pkgfile ]]; then
    finish
fi

install_log=$(mktemp)
pacman -U --noconfirm "$pkgfile" >"$install_log" 2>&1
status=$?
assert_eq "$status" "0" "pacman installed the built package"
assert_eq "$(pacman -Q aepm | awk '{print $2}')" "$expected_pkgver-1" \
    "pacman records the crate version"

files=$(pacman -Qql aepm 2>/dev/null)
assert_contains "$files" "/usr/bin/aepm" "the binary lands in /usr/bin"
assert_contains "$files" "/usr/lib/systemd/user/aepm.service" \
    "the service lands in the systemd user unit directory"
assert_contains "$files" "/usr/lib/systemd/user/aepm.timer" \
    "the timer lands in the systemd user unit directory"
assert_false "nothing is installed under /etc/systemd" \
    bash -c 'pacman -Qql aepm | grep -q "^/etc/systemd"'

assert_eq "$(stat -c %a /usr/bin/aepm)" "755" "the binary is executable"
assert_eq "$(stat -c %a /usr/lib/systemd/user/aepm.service)" "644" "the service is a data file"
assert_eq "$(stat -c %a /usr/lib/systemd/user/aepm.timer)" "644" "the timer is a data file"
assert_eq "$(/usr/bin/aepm --version)" "aepm $version" "the installed binary reports the crate version"
assert_contains "$(cat /usr/lib/systemd/user/aepm.service)" \
    'ExecStart="/usr/bin/aepm" fetch' "the packaged service runs the packaged binary"

# A package cannot enable a user unit for an account it does not run as.
assert_contains "$(cat "$install_log")" \
    "systemctl --user enable --now aepm.timer" \
    "the scriptlet tells the user how to enable the timer"
assert_false "the package enabled nothing itself" \
    grep -q enable /var/log/sim-systemctl.log

finish
