#!/usr/bin/env bash
# Scenario 60 — VM: base install on btrfs, snapper config, prefetch, install.
#
# Runs inside the live Arch ISO with /mnt as the target disk. This is the setup
# the other two VM scenarios need, and it proves the CLI works on a real
# rolling-release system, not only against the container's synthetic repo.
BASE=${VM_BASE_URL:?VM_BASE_URL is not set}
DISK=${VM_DISK:-/dev/vda}

# The same assertion helpers the container scenarios use, so a failure here
# reads the same way and is counted the same way.
curl -fsS "$BASE/sim/lib.sh" -o /tmp/sim-lib.sh || { echo "cannot reach $BASE" >&2; exit 1; }
source /tmp/sim-lib.sh

echo "scenario 60: btrfs base install, snapper config, real prefetch and install"

# Every step is logged, and a failed assertion prints the tail of the log that
# explains it. A silent `>/dev/null` here would turn a broken install into a
# mystery.
show_log() { sed -e 's/^/    /' "$1" 2>/dev/null | tail -15; }

# --- btrfs root with a subvolume root, and an ext4 /boot --------------------
# snapper only works when / is a subvolume: a snapshot of the filesystem root
# would swallow the rest of the disk and could not be rolled back. /boot is a
# plain ext4 partition, so GRUB only has to read a filesystem it has never
# failed at; the kernel therefore survives a rollback untouched, which is what
# scenario 61 needs - the break has to be in /usr, not in GRUB's own path.
wipefs -af "$DISK" >/dev/null
# 2048 sectors = 1MiB: the gap below the first partition is where a BIOS
# grub-install embeds core.img, and without it grub exits 0 having written no
# boot sector at all. The assertion below catches exactly that.
printf 'label: dos\n2048,512M,c\n,,83\n' | sfdisk -q "$DISK" >/dev/null
mkfs.ext4 -q -L aepmboot "${DISK}1"
mkfs.btrfs -q -f -L aepm "${DISK}2"
mount "${DISK}2" /mnt
btrfs subvolume create /mnt/@ >/dev/null
# / follows the *default* subvolume, not a subvol= pinned in fstab or on the
# kernel command line: `snapper rollback` works by flipping the default, and a
# pinned subvolume would keep booting the broken one.
subvol_id=$(btrfs subvolume show /mnt/@ | sed -n 's/^[[:space:]]*Subvolume ID:[[:space:]]*//p')
btrfs subvolume set-default "$subvol_id" /mnt
umount /mnt
mount -o compress=zstd "${DISK}2" /mnt
mkdir -p /mnt/boot
mount "${DISK}1" /mnt/boot

assert_eq "$(btrfs subvolume show /mnt | sed -n 's/^[[:space:]]*Name:[[:space:]]*//p')" "@" \
    "/ is the btrfs subvolume @"
assert_eq "$(findmnt -no FSTYPE /mnt)" "btrfs" "the target root is btrfs"
assert_eq "$(findmnt -no FSTYPE /mnt/boot)" "ext4" "/boot is a filesystem GRUB reads without help"

# --- base install -----------------------------------------------------------
pacstrap -K -c /mnt base linux btrfs-progs grub snapper sudo pacman-contrib \
    curl dhcpcd >/root/pacstrap.log 2>&1
if [[ -e /mnt/boot/vmlinuz-linux ]]; then
    pass "pacstrap installed a kernel into /boot"
else
    fail "pacstrap installed no kernel"
    show_log /root/pacstrap.log
fi
# pacstrap does not carry DNS into the new root; the repo step below needs it.
cp -L /etc/resolv.conf /mnt/etc/resolv.conf

genfstab -U /mnt >>/mnt/etc/fstab
# fstab keeps subvol=/@: snapper reads the rollback ambit from it and refuses
# to roll back without one (`--ambit` or a subvolume on /). The *kernel command
# line* is what decides which subvolume / comes from at boot, and that is left
# empty so the default subvolume - the one a rollback flips - is used.
assert_contains "$(awk '$2 == "/"' /mnt/etc/fstab)" "subvol=/@" \
    "fstab names the root subvolume for snapper's ambit"

arch-chroot /mnt /bin/bash -s >/mnt/root/setup.log 2>&1 <<'CHROOT'
set -uo pipefail
step() { printf '== %s\n' "$*"; "$@"; printf '== rc=%s\n' "$?"; }
echo aepm-vm >/etc/hostname
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
echo "en_US.UTF-8 UTF-8" >/etc/locale.gen
locale-gen >/dev/null
echo "LANG=en_US.UTF-8" >/etc/locale.conf
# A test VM: the harness has no keyboard, so the serial console logs itself in.
passwd -d root >/dev/null
mkdir -p /etc/systemd/system/serial-getty@ttyS0.service.d
cat >/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --keep-baud 115200,38400,9600 %I $TERM
EOF
# The harness has no display, so the guest kernel has to talk on the serial
# port from the very first boot of the installed system.
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0,115200"/' /etc/default/grub
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/' /etc/default/grub
# The initramfs has to find the virtio disk the harness boots from.
sed -i 's/^MODULES=()/MODULES=(virtio_blk virtio_pci virtio_net)/' /etc/mkinitcpio.conf
step systemctl enable serial-getty@ttyS0.service
step systemctl enable dhcpcd.service
step grub-install --target=i386-pc /dev/vda
step grub-mkconfig -o /boot/grub/grub.cfg
step mkinitcpio -P
step snapper --no-dbus -c root create-config /
CHROOT

assert_eq "$(cat /mnt/etc/hostname)" "aepm-vm" "the installed system is named aepm-vm"
boot_code=$(dd if="$DISK" bs=512 count=1 2>/dev/null | head -c 440 | tr -d '\0' | wc -c)
if ((boot_code > 0)); then
    pass "grub wrote a boot sector on $DISK"
else
    fail "$DISK has no boot sector: grub-install reported success and wrote nothing"
    show_log /mnt/root/setup.log
fi
if [[ -f /mnt/boot/grub/grub.cfg ]]; then
    pass "grub.cfg exists, so the disk boots itself"
else
    fail "no grub.cfg: the rollback scenarios could not boot"
    show_log /mnt/root/setup.log
fi
# grub-mkconfig carries the subvolume over from fstab on some versions; strip
# it so the boot always mounts the current default subvolume.
[[ -f /mnt/boot/grub/grub.cfg ]] &&
    sed -i 's|rootflags=subvol[^ ]* ||g; s| rootflags=subvol[^ ]*||g' /mnt/boot/grub/grub.cfg
assert_false "the kernel command line pins no subvolume, so a rollback takes effect" \
    grep -q 'rootflags=subvol' /mnt/boot/grub/grub.cfg
assert_contains "$(grep -o 'console=ttyS0[^ ]*' /mnt/boot/grub/grub.cfg 2>/dev/null | head -1)" \
    "console=ttyS0" "the installed kernel logs to the serial port"

# --- snapper ---------------------------------------------------------------
# `snapper create-config` insists on creating .snapshots itself, so it is left
# to do that and the subvolume is then promoted to a sibling of @. A nested
# .snapshots would be swallowed by a rollback of /, which is the one thing
# scenario 62 needs from this layout.
cfg=/mnt/etc/snapper/configs/root
if [[ -f $cfg ]]; then
    pass "snapper created the root config"
else
    fail "snapper create-config wrote no /etc/snapper/configs/root"
    show_log /mnt/root/setup.log
fi
if [[ -d /mnt/.snapshots && ! -d /mnt/@snapshots ]]; then
    mkdir -p /top
    mount -o subvolid=5 "${DISK}2" /top
    mv /top/@/.snapshots /top/@snapshots
    umount /top
    rmdir /top
fi
mkdir -p /mnt/.snapshots
mount -o subvol=/@snapshots "${DISK}2" /mnt/.snapshots
uuid=$(blkid -s UUID -o value "${DISK}2")
if ! grep -q ' /.snapshots ' /mnt/etc/fstab; then
    printf 'UUID=%s /.snapshots btrfs rw,relatime,compress=zstd:3,subvol=/@snapshots 0 0\n' \
        "$uuid" >>/mnt/etc/fstab
fi
assert_eq "$(sed -n 's/^SUBVOLUME="\(.*\)"/\1/p' "$cfg" 2>/dev/null)" "/" \
    "the snapper config snapshots /"
assert_eq "$(findmnt -no FSTYPE /mnt/.snapshots)" "btrfs" \
    "/.snapshots is mounted as its own btrfs subvolume"
# --no-dbus: there is no system bus inside a chroot, and snapper without it
# fails to talk to one even for a read-only list.
assert_true "snapper can list snapshots on the installed system" \
    arch-chroot /mnt snapper --no-dbus -c root list

# --- the repo, the fake helper, and the binary the host builds --------------
mkdir -p /mnt/usr/local/bin
curl -fsS "$BASE/sim/make-repo.sh" -o /mnt/usr/local/bin/make-repo.sh
curl -fsS "$BASE/sim/yay" -o /mnt/usr/local/bin/yay
curl -fsS "$BASE/sim/sim-upgrade" -o /mnt/usr/local/bin/sim-upgrade
curl -fsS "$BASE/target/release/aepm" -o /mnt/usr/local/bin/aepm
chmod 755 /mnt/usr/local/bin/make-repo.sh /mnt/usr/local/bin/yay \
    /mnt/usr/local/bin/sim-upgrade /mnt/usr/local/bin/aepm

# The container harness points no repo at aurto either: `fetch` must work on a
# system that has no AUR mirror configured, and a repo with no database would
# only make pacman's own sync fail.
mkdir -p /mnt/srv/simrepo
printf '[sim]\nSigLevel = Never\nServer = file:///srv/simrepo\n' >>/mnt/etc/pacman.conf

arch-chroot /mnt /bin/bash -s >/mnt/root/users.log 2>&1 <<'CHROOT'
set -uo pipefail
useradd --create-home --shell /bin/bash sim
# The same two narrow escalations the container harness grants: the prefetch,
# and the install helper. No wildcard, and no bare pacman for the install.
printf 'sim ALL=(root) NOPASSWD: /usr/bin/pacman -Syuw --noconfirm\n' >/etc/sudoers.d/sim
printf 'sim ALL=(root) NOPASSWD: /usr/local/bin/sim-upgrade ""\n' >>/etc/sudoers.d/sim
chmod 0440 /etc/sudoers.d/sim
visudo -cf /etc/sudoers.d/sim
mkdir -p /etc/sim
touch /var/log/sim-yay.log /var/log/sim-yay-build.log /var/log/sim-sudo.log
chmod 0666 /var/log/sim-*.log
CHROOT

# --- a real prefetch and a real install -------------------------------------
if [[ -s /mnt/usr/local/bin/aepm ]]; then
    pass "the binary was delivered to the guest"
else
    fail "the binary download wrote nothing (the host served no target/release/aepm)"
fi
# "aepm" alone would match a "command not found" message; require a version.
assert_contains "$(arch-chroot /mnt /usr/local/bin/aepm --version 2>&1)" "aepm " \
    "the host-built binary runs in the guest (glibc matches)"

arch-chroot /mnt /bin/bash /usr/local/bin/make-repo.sh >/mnt/root/repo.log 2>&1
if [[ "$(arch-chroot /mnt pacman -Q simapp 2>/dev/null | awk '{print $2}')" != "1.0.0-1" ]]; then
    show_log /mnt/root/repo.log
fi
assert_eq "$(arch-chroot /mnt pacman -Q simapp 2>/dev/null | awk '{print $2}')" "1.0.0-1" \
    "the repo installs simapp 1.0.0 and publishes 2.0.0 as pending"

before_usr=$(sha256sum /mnt/usr/bin/simapp | cut -d' ' -f1)
arch-chroot /mnt runuser -l sim -c 'aepm fetch' >/mnt/root/fetch.log 2>&1
fetch_status=$?
((fetch_status == 0)) || show_log /mnt/root/fetch.log
assert_eq "$fetch_status" "0" "aepm fetch exits 0 as an unprivileged user"
assert_eq "$(arch-chroot /mnt pacman -Q simapp 2>/dev/null | awk '{print $2}')" "1.0.0-1" \
    "the prefetch installed nothing"
if compgen -G "/mnt/var/cache/pacman/pkg/simapp-2.0.0*" >/dev/null; then
    pass "the prefetch put the 2.0.0 artifact in the cache"
else
    fail "the prefetch did not download simapp 2.0.0"
fi
assert_eq "$(sha256sum /mnt/usr/bin/simapp | cut -d' ' -f1)" "$before_usr" \
    "the prefetch changed no file in /usr"

arch-chroot /mnt runuser -l sim -c 'aepm install --yes' >/mnt/root/install.log 2>&1
install_status=$?
((install_status == 0)) || show_log /mnt/root/install.log
assert_eq "$install_status" "0" "aepm install --yes exits 0"
assert_eq "$(arch-chroot /mnt pacman -Q simapp 2>/dev/null | awk '{print $2}')" "2.0.0-1" \
    "the install upgraded simapp through the helper"
assert_contains "$(cat /mnt/var/log/sim-yay.log 2>/dev/null)" "-Syuu" \
    "the install went through the helper's full upgrade path"
assert_false "the install built nothing from the AUR" test -s /mnt/var/log/sim-yay-build.log

finish
