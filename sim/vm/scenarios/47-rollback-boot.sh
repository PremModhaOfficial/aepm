#!/usr/bin/env bash
# Scenario 47 — VM: snapshot, a broken install, and `snapper rollback`.
#
# Runs in the installed system (stage 46). It publishes a package that destroys
# the boot artifact on purpose, installs it through the real CLI, and then rolls
# back to the snapshot taken first. The driver reboots afterwards; scenario 48
# proves the reboot really landed on the rolled-back system.
BASE=${VM_BASE_URL:?VM_BASE_URL is not set}
curl -fsS "$BASE/sim/lib.sh" -o /tmp/sim-lib.sh || { echo "cannot reach $BASE" >&2; exit 1; }
source /tmp/sim-lib.sh

echo "scenario 47: snapshot, broken install, rollback"

running=$(uname -r)
assert_true "the installed system is up on the disk's kernel $running" \
    test -e "/usr/lib/modules/$running"
assert_true "/boot holds a bootable kernel" test -s /boot/vmlinuz-linux

# --- 1. the snapshot is taken before the risky install ----------------------
before=$(snapper -c root create -c number -d "vm before broken install" --print-number 2>/dev/null)
if [[ -n ${before:-} ]]; then
    pass "snapshot $before taken before the install"
else
    fail "snapper could not create the pre-install snapshot"
fi
assert_contains "$(snapper -c root list 2>/dev/null)" "vm before broken install" \
    "the snapshot is listed"

# --- 2. a package that breaks the running system ---------------------------
# Nothing here is a simulation hook: the package's post_install wipes the
# modules tree and installs modules for a kernel that does not exist, which is
# the state `uname -r` and `/usr/lib/modules` disagree in. /boot is ext4 and
# outside the snapshot, so GRUB keeps working and the machine keeps booting:
# the thing being restored is /usr, which is the whole point of a rollback.
build_broken() {
    local dir=/tmp/broken/simapp-3.0.0
    rm -rf "$dir"
    mkdir -p "$dir/usr/bin" "$dir/usr/share/simapp"
    printf '#!/bin/sh\necho "simapp 3.0.0"\n' >"$dir/usr/bin/simapp"
    chmod 755 "$dir/usr/bin/simapp"
    printf '3.0.0\n' >"$dir/usr/share/simapp/version"
    # pacman runs post_install for a fresh install and post_upgrade for an
    # upgrade; the harness upgrades, so both hooks have to exist or the break
    # silently does nothing.
    cat >"$dir/.INSTALL" <<'EOF'
break_the_system() {
    rm -rf /usr/lib/modules/*
    mkdir -p /usr/lib/modules/9.9.9-vm
}
post_install() { break_the_system; }
post_upgrade() { break_the_system; }
EOF
    cat >"$dir/.PKGINFO" <<EOF
pkgname = simapp
pkgbase = simapp
pkgver = 3.0.0-1
pkgdesc = Breaks the boot on purpose (aepm VM scenario 47)
url = https://example.invalid/aepm/sim
builddate = $(date -u +%s)
packager = aepm vm harness
size = 1024
arch = x86_64
license = MIT
EOF
    (cd "$dir" && bsdtar -czf .MTREE --format=mtree \
        --options='!all,use-set,type,uid,gid,mode,time,size,md5,sha256,link' usr)
    (cd "$dir" && bsdtar -c --zstd -f /srv/simrepo/simapp-3.0.0-1-x86_64.pkg.tar.zst \
        .PKGINFO .MTREE .INSTALL usr)
    repo-add -q /srv/simrepo/sim.db.tar.gz \
        /srv/simrepo/simapp-3.0.0-1-x86_64.pkg.tar.zst >/dev/null
}

build_broken
pacman -Syy --noconfirm >/dev/null 2>&1
# -Qu names the installed version; -Si names the one in the repo.
assert_eq "$(pacman -Si simapp 2>/dev/null | sed -n 's/^Version *: *//p')" "3.0.0-1" \
    "the broken version is published as the repo's version"

runuser -l sim -c 'aepm fetch' >/root/fetch.log 2>&1
assert_eq "$?" "0" "aepm fetch exits 0 with the broken version pending"

runuser -l sim -c 'aepm install --yes' >/root/install.log 2>&1
assert_eq "$?" "0" "aepm install reports success, because nothing can know the package is hostile"

assert_eq "$(pacman -Q simapp 2>/dev/null | awk '{print $2}')" "3.0.0-1" \
    "the broken version is installed"
assert_false "/usr/lib/modules/$running is gone: the install destroyed the running kernel's modules" \
    test -d "/usr/lib/modules/$running"
assert_true "modules for a kernel that does not exist are installed" \
    test -d /usr/lib/modules/9.9.9-vm
assert_true "/boot is outside the snapshot, so the machine can still boot" \
    test -s /boot/vmlinuz-linux

# --- 3. rollback -----------------------------------------------------------
default_before=$(btrfs subvolume get-default / | awk '{print $NF}')
# --ambit classic: snapper's automatic ambit only recognises a default
# subvolume that is already one of its own snapshots, and on a fresh system the
# default is the root subvolume itself. Classic is the documented path for the
# first rollback: it snapshots the current system, makes a writable copy of the
# target snapshot, and sets that copy as the btrfs default subvolume - which is
# exactly what the next boot follows, because the kernel command line carries no
# rootflags.
snapper --ambit classic -c root rollback "${before:-0}" >/root/rollback.log 2>&1
rollback_status=$?
((rollback_status == 0)) || sed -e 's/^/    /' /root/rollback.log | tail -10
assert_eq "$rollback_status" "0" "snapper rollback exits 0"
default_after=$(btrfs subvolume get-default / | awk '{print $NF}')
assert_ne "$default_after" "$default_before" \
    "the default subvolume moved ($default_before -> $default_after)"
assert_contains "$(cat /root/rollback.log)" "Setting default subvolume to snapshot" \
    "snapper made the rolled-back snapshot the default subvolume"

# The rollback only takes effect on reboot: the running system still has the
# broken /usr. Scenario 48 is what proves the reboot.
assert_false "the running system is still broken until the reboot" \
    test -d "/usr/lib/modules/$running"

cat >/root/vm-rollback.env <<EOF
BEFORE_SNAPSHOT=${before:-0}
DEFAULT_BEFORE=$default_before
DEFAULT_AFTER=$default_after
KERNEL=$running
EOF

finish
