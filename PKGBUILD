# Maintainer: the aepm maintainers
# AUR package: https://aur.archlinux.org/packages/aepm
#
# This PKGBUILD ships the same binary `cargo install` builds and the same two
# user units `aepm init` writes, system-wide under
# /usr/lib/systemd/user so a fresh account gets `aepm.timer`
# without running init first. Enabling the timer is still a user decision, so
# packaging/aepm.install prints the commands; the package cannot run
# `systemctl --user` for the account that will own the timer. `aepm init
# --apply` remains the path that also installs the sudoers rule and points the
# unit at a $HOME binary instead.

pkgname=aepm
# Literal, because an AUR checkout puts only this file and the .install at the
# parse directory: there is no Cargo.toml to read there. Cargo.toml stays the
# one typed release number, and scripts/gate-pkgbuild-version.sh fails CI when
# these two drift. Arch forbids a hyphen in pkgver, so the semver pre-release
# separator is `_`; the git tag keeps the hyphen.
pkgver=0.1.0_pre1
_tag=v0.1.0-pre1
pkgrel=1
install=packaging/aepm.install
pkgdesc='Split Arch updates: download in the background, install in the foreground'
arch=('x86_64' 'aarch64')
url='https://github.com/PremModhaOfficial/aepm'
license=('MIT' 'Apache-2.0')
depends=('pacman' 'glibc' 'gcc-libs')
makedepends=('cargo' 'git')
optdepends=(
  'aurto: build AUR packages in a clean chroot before install'
  'yay: AUR update list and the foreground install step'
)
# The tag must exist before this PKGBUILD is pushed to the AUR; makepkg pins
# the commit it resolves. SKIP is the AUR norm for a git source, which has no
# reusable tarball checksum.
source=("git+$url.git#tag=$_tag")
sha256sums=('SKIP')

build() {
  cd "$pkgname"
  # --locked: the committed Cargo.lock is the dependency set this release was
  # tested with. The `sim-hooks` feature is test-only and never enabled here.
  cargo build --release --locked
}

package() {
  cd "$pkgname"
  # The units go where systemd's user manager reads them for every account.
  # /etc/systemd/user is an administrator's override directory, not package
  # content; a package that writes there shadows itself on the next edit.
  install -Dm755 target/release/aepm "$pkgdir/usr/bin/aepm"
  install -Dm644 packaging/aepm.service \
    "$pkgdir/usr/lib/systemd/user/aepm.service"
  install -Dm644 packaging/aepm.timer \
    "$pkgdir/usr/lib/systemd/user/aepm.timer"
  install -Dm644 LICENSE-MIT "$pkgdir/usr/share/licenses/$pkgname/LICENSE-MIT"
  install -Dm644 LICENSE-APACHE "$pkgdir/usr/share/licenses/$pkgname/LICENSE-APACHE"
}
