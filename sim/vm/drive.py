#!/usr/bin/env python3
"""Serial-console driver for the Phase 5 VM scenarios (46, 47, 48).

The guest cannot reach the host filesystem, so each stage is a shell script
served by `run.sh` over qemu's user network. The driver boots the ISO with an
injected `console=ttyS0`, installs, then boots the installed disk and runs the
remaining stages. A stage reports its verdict through its exit code; the
assertion lines it prints stay in the transcript.

Two phases, two qemu runs:
  1. the ISO, with its own kernel extracted from the image so the console is
     the serial port (an ISO cannot be given a kernel cmdline any other way);
  2. the installed disk, which reboots itself once after `snapper rollback`.
"""

import os
import re
import shlex
import socket
import struct
import subprocess
import sys
import time

QEMU = "qemu-system-x86_64"
CPUS = os.environ.get("SIM_VM_CPUS", "4")
MEM = os.environ.get("SIM_VM_MEM", "4096")
BOOT_TIMEOUT = int(os.environ.get("SIM_VM_BOOT_TIMEOUT", "900"))
STAGE_TIMEOUT = int(os.environ.get("SIM_VM_STAGE_TIMEOUT", "3600"))

ISO = os.environ["SIM_VM_ISO"]
DISK = os.environ["SIM_VM_DISK"]
SOCK = os.environ["SIM_VM_SOCK"]
MON = SOCK + ".mon"
LOG_PATH = os.environ["SIM_VM_LOG"]
BASE = os.environ.get("SIM_VM_BASE_URL", "http://10.0.2.2:8765")


def die(message):
    print(f"drive: {message}", file=sys.stderr)
    sys.exit(1)


def iso_label(path):
    """Volume id of an ISO9660 image; archiso needs it to find the squashfs."""
    with open(path, "rb") as handle:
        handle.seek(16 * 2048 + 40)
        return handle.read(32).decode("ascii", "replace").strip()


def extract(kernel, initrd, out_dir):
    """Pull the ISO's kernel and initramfs out of the image without mounting."""
    os.makedirs(out_dir, exist_ok=True)
    wanted = {
        "arch/boot/x86_64/vmlinuz-linux": kernel,
        "arch/boot/x86_64/initramfs-linux.img": initrd,
    }
    for member in wanted:
        subprocess.run(
            ["bsdtar", "-xf", ISO, "-C", out_dir, member],
            check=True,
        )
    return (
        os.path.join(out_dir, "arch/boot/x86_64/vmlinuz-linux"),
        os.path.join(out_dir, "arch/boot/x86_64/initramfs-linux.img"),
    )


def raw_image(disk, scratch):
    """One sparse raw copy of the guest disk, so offsets become plain reads."""
    raw = os.path.join(scratch, "disk.raw")
    subprocess.run(
        ["qemu-img", "convert", "-U", "-O", "raw", "-S", "4k", disk, raw],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    return raw


def disk_partitions(raw):
    """Read the MBR and describe each partition: index, LBA start, sectors."""
    with open(raw, "rb") as handle:
        mbr = handle.read(512)
    parts = []
    for slot in range(4):
        entry = mbr[446 + slot * 16:446 + (slot + 1) * 16]
        if not any(entry):
            continue
        start, sectors = struct.unpack("<II", entry[8:16])
        if start and sectors:
            parts.append({"index": slot + 1, "start": start, "sectors": sectors})
    return parts


def filesystem_at(raw, part):
    """ext4 or btrfs, from the superblock at the start of the partition."""
    with open(raw, "rb") as handle:
        handle.seek(part["start"] * 512)
        head = handle.read(0x10048)
    if len(head) >= 1082 and head[1024 + 56:1024 + 58] == b"\x53\xef":
        return "ext4"
    if len(head) >= 0x10048 and head[0x10040:0x10048] == b"_BHRfS_M":
        return "btrfs"
    return "unknown"


def partition_image(raw, part, out_path):
    subprocess.run(
        ["dd", f"if={raw}", f"of={out_path}", "bs=512",
         f"skip={part['start']}", f"count={part['sectors']}", "status=none"],
        check=True,
    )
    return out_path


def boot_artifacts(disk, scratch, kernel, initrd):
    """Copy the guest's kernel and initramfs out of its /boot, and name the root.

    This level boots the guest kernel directly instead of going through the
    installed bootloader: GRUB 2.16 in this environment lands on its own prompt
    instead of loading its config, and a harness that hangs at `grub>` proves
    nothing. The bootloader is still installed and its config asserted by
    scenario 46; what the VM proves here is the kernel, the initramfs and the
    root subvolume, which is where a rollback takes effect.
    """
    raw = raw_image(disk, scratch)
    parts = disk_partitions(raw)
    boot_part = root_part = None
    for part in parts:
        kind = filesystem_at(raw, part)
        if kind == "ext4" and boot_part is None:
            boot_part = part
        elif kind == "btrfs" and root_part is None:
            root_part = part
    if boot_part is None or root_part is None:
        die(f"found no /boot (ext4) and root (btrfs) partition on {disk}: {parts}")

    image = partition_image(raw, boot_part, os.path.join(scratch, "boot.img"))
    for member, target in (("/vmlinuz-linux", kernel), ("/initramfs-linux.img", initrd)):
        try:
            os.unlink(target)
        except FileNotFoundError:
            pass
        subprocess.run(
            ["debugfs", "-R", f"dump {member} {target}", image],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if not os.path.exists(target) or os.path.getsize(target) == 0:
            die(f"could not read {member} out of {image}")
    os.unlink(image)
    os.unlink(raw)
    return kernel, initrd, f"/dev/vda{root_part['index']}"


class Console:
    """A serial port with a prompt-matching read loop over a unix socket."""

    def __init__(self, path, log):
        self.path = path
        self.log = log
        self.buf = ""
        self.sock = None

    def connect(self, timeout=120):
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.sock.connect(self.path)
                return
            except OSError:
                time.sleep(0.5)
        die(f"serial socket {self.path} never appeared")

    def close(self):
        if self.sock is not None:
            self.sock.close()
            self.sock = None
        self.buf = ""

    def _drain(self, seconds):
        self.sock.settimeout(seconds)
        try:
            data = self.sock.recv(65536)
        except (socket.timeout, TimeoutError):
            return
        if not data:
            return
        text = data.decode("utf-8", "replace").replace("\r\n", "\n").replace("\r", "")
        self.log.write(text)
        self.log.flush()
        self.buf += text

    def wait(self, pattern, timeout, what):
        """Wait for `pattern`, consume through it, and return its match object."""
        regex = re.compile(pattern)
        deadline = time.time() + timeout
        while True:
            match = regex.search(self.buf)
            if match is not None:
                self.buf = self.buf[match.end():]
                return match
            if time.time() > deadline:
                die(f"timed out after {timeout}s waiting for {what} (pattern {pattern!r}); tail:\n{self.buf[-2000:]}")
            self._drain(1.0)

    def send(self, line):
        self.sock.sendall((line + "\n").encode())

    def run(self, command, timeout=STAGE_TIMEOUT):
        """Run one shell line in the guest and return its exit status."""
        self.send(f"{command}; echo VM-EXIT:$?")
        match = self.wait(r"VM-EXIT:(\d+)", timeout, f"exit status of {command.split()[0]}")
        return int(match.group(1))


def qemu(args, serial_sock):
    for stale in (serial_sock, MON):
        try:
            os.unlink(stale)
        except FileNotFoundError:
            pass
    cmd = [
        QEMU,
        "-machine", "q35",
        "-accel", "kvm",
        "-cpu", "host",
        "-smp", CPUS,
        "-m", MEM,
        "-display", "none",
        "-monitor", f"unix:{MON},server=on,wait=off",
        "-serial", f"unix:{serial_sock},server=on,wait=off",
        # No default devices: every device this scenario relies on is named
        # here, so a qemu default cannot quietly change what is being tested.
        "-nodefaults",
        "-netdev", "user,id=n0",
        "-device", "virtio-net-pci,netdev=n0",
        # writeback, not unsafe: the guest's own flushes have to reach the
        # image, or a hard stop could leave the btrfs half written.
        "-drive", f"file={DISK},if=virtio,format=qcow2,cache=writeback",
    ] + args
    return subprocess.Popen(cmd)


def login(console, hostname):
    """Log in on the serial console of a freshly booted system."""
    console.wait(rf"{hostname} login:", BOOT_TIMEOUT, f"the {hostname} login prompt")
    console.send("root")
    match = console.wait(r"(Password:|[#$] )", 60, "the password prompt or a shell")
    if match.group(1) == "Password:":
        console.send("")  # the harness leaves root without a password
        console.wait(r"[#$] ", 60, "a root shell")
    # A login shell on a serial line has no job control; the scenarios do not
    # need it, but bash prints this every time, so swallow it once.
    console.buf = re.sub(r"\[root@[^\]]*\][^\n]*\n", "", console.buf)


def network(console, hostname):
    """Bring the user-mode network up: the guest fetches each stage over it."""
    console.send("dev=$(ls /sys/class/net | grep -v lo | head -1); ip link set \"$dev\" up; "
                 "(dhcpcd -q -w \"$dev\" 2>/dev/null || networkctl up 2>/dev/null); ip -4 -o addr show")
    console.wait(rf"[#$] ", 90, "the network bring-up")
    # DHCP can still be settling: poll the host with a bounded retry instead of
    # one shot, so a slow lease fails loudly only after it is really hopeless.
    for _ in range(30):
        status = console.run(f"curl -fsS -m 5 -o /dev/null {BASE}/sim/vm/run.sh", 60)
        if status == 0:
            return
        time.sleep(2)
    die(f"guest on {hostname} cannot reach {BASE} (curl exit {status})")


def run_stage(console, number, timeout=STAGE_TIMEOUT):
    script = f"{BASE}/sim/vm/scenarios/{number}"
    line = (
        f"curl -fsS {script} -o /root/stage.sh && VM_BASE_URL={BASE} bash /root/stage.sh"
    )
    print(f"drive: stage {number.split('-')[0]}", flush=True)
    status = console.run(line, timeout)
    if status != 0:
        die(f"stage {number} failed with exit {status}")
    print(f"drive: stage {number.split('-')[0]} passed", flush=True)


def stop_vm(console, proc, what, timeout=120):
    """Ask the guest to power off, then quit the emulator if it does not.

    ACPI shutdown from a live ISO does not always stop qemu; waiting on it
    forever turns a green run into a timeout. `quit` on the monitor closes the
    image cleanly, which `cache=writeback` makes safe.
    """
    console.send("systemctl poweroff")
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            console.close()
            return
        time.sleep(1.0)
    try:
        monitor = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        monitor.connect(MON)
        monitor.sendall(b"quit\n")
        monitor.close()
    except OSError:
        pass
    wait_exit(proc, what, 60)
    console.close()


def wait_exit(proc, what, timeout=300):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            return
        time.sleep(0.5)
    proc.kill()
    die(f"{what} did not stop within {timeout}s")


def main():
    log = open(LOG_PATH, "w")
    label = iso_label(ISO)
    kernel, initrd = extract(
        os.path.join(os.path.dirname(ISO), "vmlinuz-linux"),
        os.path.join(os.path.dirname(ISO), "initramfs-linux.img"),
        os.path.dirname(ISO),
    )
    append = " ".join([
        "console=ttyS0,115200",
        "archisobasedir=arch",
        f"archisolabel={label}",
        # The live ISO's writable overlay lives in RAM; pacman's own DB writes
        # are small because pacstrap installs into the disk, but the overlay
        # still needs room for the keyring and hooks.
        "cow_spacesize=2G",
        # archiso enables a getty on tty1 only; the harness talks on ttyS0.
        "systemd.wants=serial-getty@ttyS0.service",
    ])

    # --- phase 1: the ISO installs the system -------------------------------
    proc = qemu(
        [
            "-kernel", kernel,
            "-initrd", initrd,
            "-append", append,
            "-drive", f"file={ISO},media=cdrom,readonly=on",
        ],
        SOCK,
    )
    console = Console(SOCK, log)
    console.connect()
    login(console, "archiso")
    network(console, "archiso")
    run_stage(console, "46-base-install.sh")
    stop_vm(console, proc, "the ISO phase")

    # --- phase 2: the installed system --------------------------------------
    scratch = os.path.dirname(DISK)
    vmlinuz, initramfs, root_device = boot_artifacts(
        DISK, scratch,
        os.path.join(scratch, "guest-vmlinuz-linux"),
        os.path.join(scratch, "guest-initramfs-linux.img"),
    )
    proc = qemu(
        [
            "-kernel", vmlinuz,
            "-initrd", initramfs,
            # No rootflags/subvol: the kernel mounts the default subvolume, so
            # the boot after `snapper rollback` uses the snapshot it made
            # default. That is the property scenarios 47 and 48 turn on.
            "-append", f"root={root_device} rw console=ttyS0,115200",
        ],
        SOCK,
    )
    console = Console(SOCK, log)
    console.connect()
    login(console, "aepm-vm")
    network(console, "aepm-vm")
    run_stage(console, "47-rollback-boot.sh")
    # The stage ends with `snapper rollback`, which only takes effect on reboot.
    console.send("systemctl reboot")
    login(console, "aepm-vm")
    network(console, "aepm-vm")
    run_stage(console, "48-snapper-limits.sh")
    stop_vm(console, proc, "the installed system")
    log.close()
    print("drive: all three stages passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
