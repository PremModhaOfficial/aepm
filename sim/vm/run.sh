#!/usr/bin/env bash
# Phase 5, VM level: btrfs + snapper, snapshot, rollback, boot, snapper limits.
#
#   ./sim/vm/run.sh --probe     report the capabilities this level needs
#   ./sim/vm/run.sh             boot the VM, run scenarios 60, 61 and 62
#
# A container cannot snapshot or reboot, so this level needs a real kernel: an
# Arch ISO boots under KVM, installs a btrfs root with snapper, runs the real
# CLI against a local repo, snapshots, installs a package that destroys the
# kernel, rolls back, and reboots to prove the rollback boots.
#
# Nothing here needs root on the host. The guest does the partitioning, the
# btrfs work and the bootloader install; the host only runs qemu and serves
# the repo over loopback. The cheap alternative - a privileged container with a
# btrfs loop device - is refused loudly when the host cannot do it, because a
# silent skip is worse than no coverage.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

CACHE=${SIM_VM_CACHE:-$HOME/.cache/aepm-vm}
LOG=${SIM_VM_LOG:-/tmp/vm-sim.log}
PORT=${SIM_VM_PORT:-8765}
BINARY=${SIM_VM_BINARY:-target/release/aepm}
DISK_SIZE=${SIM_VM_DISK_SIZE:-12G}
KEEP=0

case "${1:-}" in
    --probe) PROBE=1 ;;
    --keep) PROBE=0; KEEP=1 ;;
    "") PROBE=0 ;;
    *) echo "usage: $0 [--probe] [--keep]" >&2; exit 2 ;;
esac

# --- capability probe ------------------------------------------------------
# Every entry is a hard requirement. A missing tool aborts with its own name;
# it never turns into a skipped stage that still prints PASS.
missing=()
for tool in qemu-system-x86_64 qemu-img python3 curl bsdtar debugfs cargo; do
    command -v "$tool" >/dev/null 2>&1 ||
        missing+=("$tool (packages: qemu-full, python, curl, libarchive, e2fsprogs, rust)")
done
[[ -r /dev/kvm && -w /dev/kvm ]] || missing+=("writable /dev/kvm (KVM; TCG makes pacstrap take hours)")
[[ -w $(dirname "$CACHE") ]] || mkdir -p "$CACHE" 2>/dev/null || missing+=("writable cache dir $CACHE")

if ((${#missing[@]})); then
    echo "vm: this host lacks the Phase 5 VM capability:" >&2
    printf 'vm:   %s\n' "${missing[@]}" >&2
    echo "vm: refusing to skip silently (a skipped gate that prints PASS is worse than none)" >&2
    exit 1
fi

need_kb=$((14 * 1024 * 1024))
free_kb=$(df -Pk "$CACHE" | awk 'NR == 2 { print $4 }')
if ((free_kb < need_kb)); then
    echo "vm: $CACHE has ${free_kb}KiB free, need $((need_kb / 1024))MiB for the ISO and the guest disk" >&2
    exit 1
fi

if [[ ${PROBE:-0} == 1 ]]; then
    echo "vm: probe ok"
    echo "vm:   qemu=$(qemu-system-x86_64 --version | head -1)"
    echo "vm:   kvm=/dev/kvm rw"
    echo "vm:   cache=$CACHE free=$((free_kb / 1024 / 1024))GiB"
    echo "vm:   note: the host itself needs no loop device and no snapper;"
    echo "vm:         the guest owns both, which is why this level is a VM."
    exit 0
fi

# --- host-side artifacts ---------------------------------------------------
ISO=${SIM_VM_ISO:-$CACHE/archlinux.iso}
DISK=$CACHE/disk.qcow2

if [[ ! -s $ISO ]]; then
    echo "vm: fetching the Arch ISO once into $ISO (the only step that needs the network)"
    curl -fL --retry 3 -C - -o "$ISO" \
        https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso
fi
# A truncated ISO downloads fine but boots into nothing; fail here, not 10
# minutes into a boot timeout.
iso_bytes=$(stat -c %s "$ISO")
((iso_bytes > 700 * 1024 * 1024)) || { echo "vm: $ISO is only $iso_bytes bytes; delete it and rerun" >&2; exit 1; }

echo "vm: building $BINARY"
cargo build --release --locked
# Ask cargo where it actually put the binary: a target directory from the
# environment is not the one this script would guess, and guessing wrong shows
# up as a 404 ten minutes into the run.
target_dir=$(cargo metadata --format-version 1 --no-deps |
    python3 -c 'import json, sys; print(json.load(sys.stdin)["target_directory"])')
binary_path=$target_dir/release/aepm
[[ -x $binary_path ]] || { echo "vm: no executable at $binary_path" >&2; exit 1; }
# The guest fetches everything over HTTP from one directory, so the binary is
# staged next to a link to sim/ rather than served from the checkout itself.
share=$CACHE/share
mkdir -p "$share/target/release"
ln -sfn "$PWD/sim" "$share/sim"
cp -f "$binary_path" "$share/target/release/aepm"
: >"$LOG"

# Always start from a blank disk: a leftover install would make the run depend
# on the previous one. --keep only decides whether it survives the run.
rm -f "$DISK"
qemu-img create -f qcow2 "$DISK" "$DISK_SIZE" >/dev/null

# The guest fetches every stage script from the host over qemu's user network,
# which reaches host loopback as 10.0.2.2. Read-only, never leaves the machine.
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$share" >/dev/null 2>&1 &
server=$!
cleanup() {
    kill "$server" 2>/dev/null || true
    [[ ${KEEP:-0} == 1 ]] || rm -f "$DISK" "$CACHE/serial.sock"
}
trap cleanup EXIT

for _ in $(seq 1 50); do
    if python3 - "$PORT" <<'PY' 2>/dev/null
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=1)
s.close()
PY
    then break; fi
    sleep 0.2
done

echo "vm: driving scenarios 60-62, transcript in $LOG"
set +e
SIM_VM_BASE_URL="http://10.0.2.2:$PORT" \
SIM_VM_ISO=$ISO \
SIM_VM_DISK=$DISK \
SIM_VM_SOCK=$CACHE/serial.sock \
SIM_VM_LOG=$LOG \
    python3 sim/vm/drive.py
rc=$?
set -e

if ((rc != 0)); then
    echo "vm: FAILED (exit $rc); transcript: $LOG" >&2
    exit "$rc"
fi
echo "vm: PASS - scenarios 60, 61 and 62 are green; transcript: $LOG"
