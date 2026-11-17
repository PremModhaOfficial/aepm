#!/usr/bin/env bash
# Cargo.toml is the one place a release number is typed, but a PKGBUILD cannot
# read it: an AUR checkout has only PKGBUILD and the .install file in the parse
# directory. So pkgver and _tag stay literal, and this gate is what keeps them
# equal to the crate version. A version bump without both PKGBUILD lines fails
# here (#9).
#
#   scripts/gate-pkgbuild-version.sh              # the repository
#   scripts/gate-pkgbuild-version.sh <repo-root>  # a copy, for a fail test
set -euo pipefail

root=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
cargo_toml=$root/Cargo.toml
pkgbuild=$root/PKGBUILD

fail() {
    echo "::error::$*" >&2
    exit 1
}

[[ -f $cargo_toml ]] || fail "$cargo_toml is missing"
[[ -f $pkgbuild ]] || fail "$pkgbuild is missing"

version_line=$(awk -F'"' '/^version = "/{print NR; exit}' "$cargo_toml")
[[ -n $version_line ]] || fail "$cargo_toml has no version = \"...\" line"
version=$(awk -F'"' '/^version = "/{print $2; exit}' "$cargo_toml")
[[ -n $version ]] || fail "$cargo_toml:$version_line: cannot read the version"

expected_pkgver=${version//-/_}
expected_tag=v$version

pkgver_line=$(awk '/^pkgver=/{print NR; exit}' "$pkgbuild")
tag_line=$(awk '/^_tag=/{print NR; exit}' "$pkgbuild")
[[ -n $pkgver_line ]] || fail "$pkgbuild has no pkgver= line"
[[ -n $tag_line ]] || fail "$pkgbuild has no _tag= line"
actual_pkgver=$(awk -F= '/^pkgver=/{sub(/^pkgver=/, ""); print; exit}' "$pkgbuild")
actual_tag=$(awk -F= '/^_tag=/{sub(/^_tag=/, ""); print; exit}' "$pkgbuild")

echo "Cargo.toml:$version_line: version = \"$version\""
echo "PKGBUILD:$pkgver_line: pkgver=$actual_pkgver (want $expected_pkgver)"
echo "PKGBUILD:$tag_line: _tag=$actual_tag (want $expected_tag)"

[[ $actual_pkgver == "$expected_pkgver" ]] ||
    fail "PKGBUILD:$pkgver_line: pkgver=$actual_pkgver; Cargo.toml:$version_line needs $expected_pkgver (Arch has no hyphen in pkgver)"
[[ $actual_tag == "$expected_tag" ]] ||
    fail "PKGBUILD:$tag_line: _tag=$actual_tag; Cargo.toml:$version_line needs $expected_tag"

echo "pkgbuild version: $version matches Cargo.toml"
