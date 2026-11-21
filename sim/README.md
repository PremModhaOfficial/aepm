# sim: Arch simulation harness

A disposable Arch container that can run the CLI against a real pacman without
touching your machine.

`ci.sh` only proves the Rust compiles and lints. It cannot tell you whether
`fetch` upgraded the system by mistake. This harness can.

## Run it

```bash
./sim/run.sh                    # build image, run every scenario
./sim/run.sh --build-only       # just build
./sim/run.sh --no-cache         # rebuild from scratch, no layer cache
./sim/run.sh sim/scenarios/01-download-only-keeps-usr.sh
SIM_IMAGE=aepm-sim:mine ./sim/run.sh   # override the image tag
```

Requires Docker or Podman. The container runs with `--network none`.

Each scenario runs under a timeout (`SIM_SCENARIO_TIMEOUT`, default 300s) and
writes one log into a directory `run.sh` prints on stdout
(`sim-logs/<utc-timestamp>/` unless `SIM_LOG_DIR` says otherwise). CI uploads
that directory as the `sim-logs-*` artifact, so a failed or timed-out run keeps
its evidence. A timeout fails that one scenario with its name and elapsed
seconds; it does not hang the job.

Scenario numbers are a shared namespace across everything under `sim/`, so
`run.sh` refuses to start when two files share one, and CI runs
`sim/check-scenario-numbers.sh` on its own first.

If the host's BuildKit cannot create the build sandbox ("failed to add the
host (veth…) <=> sandbox (veth…) pair interfaces", or BuildKit enabled with no
`buildx`),
`run.sh` says so and retries the build once with `DOCKER_BUILDKIT=0 --network
host`. `sim/check-build-retry.sh` proves the retry fires on that wording and
that a Dockerfile error still fails instead of being retried. That flag belongs to the build only; the scenario argv is asserted to
carry `--network none`, and `run.sh` exits 1 rather than run a container
without it.

The image tag defaults to `aepm-sim:<worktree directory>-<8 hex of
its path>`, with the directory sanitised to docker's tag characters, a leading
dot or dash dropped, and `worktree` used when the name leaves nothing usable.
Two worktrees running the sim at the same time therefore build into and run
from separate images instead of executing each other's binary. `SIM_IMAGE`
overrides the tag outright. `sim/check-image-tag.sh`, run by `./ci.sh`, proves
the derived tag, the override, that the tag stays valid for any directory name,
and that the build and the container use the same one.

After any source change, rebuild the image without the cache before running:

```bash
./sim/run.sh --no-cache
```

The classic docker builder caches `COPY --from=builder`, so a plain
`./sim/run.sh` can silently test the previous binary (measured 2026-11-14:
`strings <binary> | grep` returned 0 for a symbol the source had). There is no
buildx on the current host, so `--no-cache` is the only reliable way to get a
fresh image.

## What the image contains

- `archlinux:base-devel`
- A local pacman repo at `/srv/simrepo` served over `file://`
- `simapp 1.0.0-1` installed, `simapp 2.0.0-1` available as the pending update
- An empty download cache
- `builder`, a non-root user whose only passwordless sudo command is
  `/usr/bin/pacman -Syuw --noconfirm`
- `installer`, a sim-only user whose only sudoers rule is
  `/usr/local/bin/sim-upgrade ""`, so the command and an empty argument list
  are both pinned. The helper always performs exactly `pacman -Syu
  --noconfirm`; no direct pacman argv is allowed through sudo, and scenario 19
  proves the rule is exactly that narrow
- `/usr/local/bin/yay`, a fake helper that logs every call to
  `/var/log/sim-yay.log`, upgrades through `sudo -n sim-upgrade`, and fails
  with exit 97 if asked to build from the AUR or exit 98 if run as root
- `/usr/local/bin/sudo`, a proxy that logs the exact argv to
  `/var/log/sim-sudo.log` and then execs the real sudo, so a scenario can prove
  which escalations actually happened
- Stubs for `systemctl`, `journalctl`, `loginctl`, `aurto`, `paccache`, and
  `pacdiff`, plus `snapper` for the optional doctor checks. Each logs argv to
  `/var/log/sim-<tool>.log`; a scenario sets the
  reply with `/etc/sim/<tool>.out`, `.err`, and `.exit`. `paccache` forwards to
  the real tool; `pacdiff` never runs for real. Its stub stands in for the
  receipt's attached `sudo pacdiff`, and `/etc/sim/pacdiff.removes-pacnew`
  makes it delete the `.pacnew` files it "reviewed", so a scenario can assert
  that the receipt re-read the count.
- Pacman config fixtures for default, multiple, empty, and moved `CacheDir`
  under `/usr/local/lib/sim/fixtures`
- A slow `XferCommand` fixture (`sim-xfer` plus `pacman-slow-xfer.conf`) that
  writes a package `.part` in two chunks and carries the optional `kill`,
  `fill`, `corrupt` and `http500` faults. Scenarios 34, 41, 43, 46, 50, 51 and 52
  install it. pacman still chooses the argv, verifies the package, and renames
  the final file
- `/usr/local/bin/make-pkg.sh`, which publishes an ad-hoc package with a blob
  of any size into the sim repo, for the chaos scenarios that need a payload
  worth interrupting
- `/usr/local/bin/aepm`, built inside the image so the glibc matches
- `rust`, `git`, the builder stage's crate registry, the source tree at
  `/usr/local/lib/sim/pkg-src`, and an AUR-style checkout at
  `/usr/local/lib/sim/pkg-repo` (PKGBUILD and its `.install`, no `Cargo.toml`).
  Scenario 53 runs the real `makepkg` offline: pkg-src becomes a local git
  repo, and the PKGBUILD's github URL is rewritten to it. The build recompiles
  the crate with `--locked` against the cached registry

The sim binary is built with the `sim-hooks` feature. It adds one env-gated
forced panic after the terminal guard is active, used to prove the panic hook
restores the pty. A packaged build does not enable the feature.

No mirrors, no keys, no network at scenario time. If a scenario needs another
package, add it to `sim/make-repo.sh`, do not open the network.

## Scenarios

| File | Proves |
|---|---|
| `01-download-only-keeps-usr.sh` | `pacman -Syuw` downloads `simapp-2.0.0` and leaves `/usr` byte-identical |
| `02-full-upgrade-changes-usr.sh` | `pacman -Syu` does change `/usr`, so the detector in 01 is not blind |
| `03-binary-readonly-safety.sh` | `check`/`doctor` write nothing, `fetch` never touches `/usr`, nothing triggers an AUR build |
| `04-sudo-contract.sh` | `builder` may run exactly `pacman -Syuw --noconfirm`; another argv and blanket sudo are refused |
| `05-fetch-download-only.sh` | `fetch` as `builder` downloads, records state, and leaves `/usr` and the package DB untouched |
| `06-fetch-lock-gate.sh` | a live pacman blocks with exit 1; a stale lock warns, proceeds, and is never deleted |
| `07-fetch-free-space-gate.sh` | a floor larger than the filesystem refuses before pacman runs |
| `08-stub-contract.sh` | stubs replay `.out`/`.err`/`.exit`, `builder` can append to logs, `paccache` honors a configured failure, and `yay` rejects root on every path |
| `09-check-pending.sh` | `check` exits 1, names the pending package, and writes nothing |
| `10-check-clean.sh` | `check` exits 0 and writes nothing when the system is current |
| `11-doctor-missing-setup.sh` | `doctor` exits 1 and names the timer, sudoers, trust, and repo problems |
| `12-doctor-configured.sh` | `doctor` exits 0 on a configured container, as root and as the unprivileged user reading the rule through `sudo -l` |
| `13-clean-dry-run.sh` | `clean` changes nothing without `--apply`; with it, only an installed package's old build is removed |
| `14-install-upgrades.sh` | `install --yes` upgrades `/usr` through yay and runs no AUR build |
| `15-install-gate.sh` | `install` without `--yes` on a non-TTY stops at the news gate |
| `16-init-setup.sh` | `init` renders without writing, applies with `visudo` approval, and never runs `aurto` |
| `17-install-noop.sh` | `install` on a current repo exits 0, changes nothing, and builds nothing |
| `18-yay-build-loud.sh` | a direct yay build and `install` both surface the AUR failure loudly; install exits 2 and does not report success |
| `19-installer-sudo-scope.sh` | `installer` may run only `/usr/local/bin/sim-upgrade` through sudo; direct pacman argv and helper arguments are refused |
| `20-init-as-builder.sh` | `init --apply` as `builder` escalates only `visudo`, `install`, and `mv` with the recorded argv, writes a `builder` rule, and refuses to run under `sudo`; the fixture grants no wildcard sudo |
| `21-doctor-wildcard-sudoers.sh` | a broader sudoers grant is not accepted as the exact rule |
| `22-doctor-low-disk.sh` | a disk floor larger than the filesystem makes `doctor` exit 1 |
| `23-doctor-snapper-timers.sh` | snapper without scheduled timers makes `doctor` exit 1 |
| `24-doctor-cache-permissions.sh` | a cache the `alpm` user cannot write makes `doctor` exit 1 |
| `25-check-missing-cache-dir.sh` | a missing `CacheDir` makes `check` exit 1 instead of failing on `df` |
| `26-install-root-refuses.sh` | `install` exits 1 with no command run and `/usr` unchanged for plain root and for the sudo shape (real UID user, effective UID root) |
| `27-doctor-journald-dropin.sh` | a `journald.conf.d` drop-in sets persistence and the size cap |
| `28-doctor-symlinked-cache.sh` | a symlinked `CacheDir` is resolved before checking `alpm` traversal |
| `29-init-visudo-root.sh` | root `visudo -cf` accepts the user-owned temp rule that `init` validates through sudo |
| `30-doctor-missing-aurto.sh` | an `Include` line whose aurto file is missing makes `doctor` exit 1 |
| `31-tui-readonly.sh` | `tui --render-once` is read-only, a pipe is rejected, and pty quit, Ctrl-C, forced panic, and Ctrl-Z all restore the terminal |
| `32-tui-install-gate.sh` | `i` opens the install gate, `space` attests the news for the session, `esc` cancels, and `/usr`, the package DB, the cache, the state file and the sudo log are untouched; `yay -Syuu` never runs |
| `33-tui-prefetch.sh` | the prefetch frame reads the real cache: missing, cached, stale, partial and built, with no writes |
| `34-tui-live-fetch.sh` | `F` runs the real fetch under a pty, shows the PRE-FLIGHT gates, opens the captured log with a real pacman line, shows real `.part` bytes and a bar, finishes from the final artifact, never reads a zero exit as frozen, leaves `/usr` and the package DB unchanged, writes only the state file, and escalates only the allowed argv |
| `35-tui-failure-freeze.sh` | a corrupted repo artifact behind the paced transfer makes the real fetch fail: the running row freezes, the repair card names the evidence and the hint, `/usr` is unchanged, no state is written, and only the allowed argv is escalated |
| `36-tui-install-attached.sh` | the attested install gate runs the exact attached `yay -Syuu` path as the sim installer: the package upgrades, the scoped helper is the only escalation, no AUR build happens, the state file records the install, the terminal is restored, and the post-install receipt shows the exit, kernel and pacnew state |
| `40-tui-keymap.sh` | `[keys]` in `tui.conf` is the keymap: `quit = x` makes `q` dead and `x` quit, a missing file restores the default, and an unknown action name exits 2 with the file and line before a frame is drawn |
| `37-fetch-refuses-during-a-build.sh` | `fetch` refuses with exit 1 while any of `pacman`, `yay`, `makepkg`, `aurto` runs, even with no `db.lck`, and `check` reports the live process |
| `38-check-and-fetch-share-the-floor.sh` | `check` refuses on the same 5 GiB snapshot floor `fetch` refuses on, so its verdict matches fetch's |
| `39-fetch-state-unwritable.sh` | a download that completed exits 0 with a loud warning when the state file cannot be written, instead of turning the timer red |
| `41-fill-cache-mid-download.sh` | the `CacheDir` fills during the transfer (a 2 MiB tmpfs and a fault that writes until the kernel refuses): `fetch` exits 2, never claims success, leaves no final artifact and no lock, still delivers the lists, writes nothing to `/usr` or either DB, and completes on a retry after the user frees the space |
| `42-kill-mid-install.sh` | a file-size rlimit SIGKILLs pacman inside the extraction of a package upgrade: `install` exits 2 and names the killed command, the payload is truncated at the limit, the local DB records the new version with no file list, `pacman -Qk` calls that clean and `pacman -Qkk` reports size and checksum mismatches (it is the honest one), a retry exits 0 without repairing it, and clearing the broken entry plus `--overwrite` does |
| `43-delete-db-lck-under-pacman.sh` | `db.lck` is deleted under a live, paced `pacman -Syuw`: `check` and `fetch` still name the running pacman because their gate is the process list, and nothing else broke. `doctor` reads the same lock and the same process list, so it names the transaction and reports the missing `db.lck` as a problem instead of calling the system healthy |
| `44-partial-upgrade-window.sh` | one package is installed by hand between fetch and install, so the system is half upgraded and the prefetched artifact for the rest is still cached: `check` names the pending update and leaves everything read-only. `check` fills `report::PartialUpgrade` from pacman's log and prints the partial upgrade with the evidence it read |
| `45-stale-aurto-foreground-build.sh` | a local aurto repo one version behind the AUR with an AUR update pending: `install` exits 0 and asks for the full upgrade. `install` prints the foreground-build warning the TUI already carries, from one shared sentence, before `yay -Syuu` runs |
| `47-tui-install-trust-gate.sh` | `/etc/aurto/trusted-users` is missing, so the install gate blocks instead of arming: `enter` installs nothing, `yay -Syuu` never runs, `/usr`, the package DB, the state file and the sudo log are untouched, and the CLI refuses the same state on a real terminal with exit 1 and the `--yes` it requires |
| `46-kill-mid-download.sh` | the paced transfer SIGKILLs pacman after the first half: the `.part` is a real prefix of the repo artifact, no final artifact exists, the lock and the refreshed lists are left behind, the next fetch refuses on the stale lock without removing it, and the retry after the user removes it fetches the real bytes |
| `48-doctor-shares-the-fetch-floor.sh` | a 1 MiB configured floor and a snapper config dir on a pinned 64 MiB `/dev/shm` `CacheDir`: only the 5 GiB snapshot floor can refuse, `doctor` exits 1, names the filesystem and that floor as its only problem, and `fetch` refuses on the same disk on the same machine, so the two verdicts cannot disagree |
| `49-tui-log-dismiss.sh` | the log belongs to its session: `l` opens it on a finished fetch, a `makepkg` appears so the next `F` is refused by the lock gate, and one `esc` still dismisses the notice, so the refused-`F` path clears the open-log flag before its notice; `/usr` and the package DB stay unchanged and the app exits 0 instead of aborting on the loop's session/log assertion |
| `50-mirror-500.sh` | the `http500` fault makes the package transfer fail the way a broken mirror does: `fetch` exits 2, quotes the 500, never claims success, keeps the lists it already received, leaves nothing in the cache and no lock, writes nothing to `/usr` or the local DB, `check` and `doctor` stay read-only, and the retry after the mirror recovers fetches the real artifact |
| `51-corrupt-download.sh` | the `corrupt` fault flips one byte in the transfer, so pacman's own checksum check rejects the artifact: `fetch` exits 2 and quotes the rejection, keeps neither a final nor a partial artifact, still delivered the lists, leaves no lock, writes nothing to `/usr` or the local DB, and the retry fetches bytes that match the repo |
| `52-corrupt-cached-artifact.sh` | a prefetched artifact is corrupted in place before the install: `check` and `doctor` stay read-only, `install --yes` discards the invalid cache file, transfers the real bytes and upgrades, pacman's log records the discarded copy, and the corrupt cache never turns into an AUR rebuild or an unverified install |
| `53-package-install.sh` | a real `makepkg` builds the AUR package offline in an AUR-style directory (PKGBUILD and `.install`, no `Cargo.toml`), with its literal `pkgver` and source tag matching the crate version; `pacman -U` installs `/usr/bin/aepm` and both units in `/usr/lib/systemd/user`, with nothing under `/etc/systemd`, and the `.install` scriptlet prints how to enable the timer instead of enabling it |
| `55-completed-install-after-fetch.sh` | pacman's log holds a download-only fetch and, after it, the hand upgrade that finished the whole upgrade: `check` exits 0 and calls the system clean, counting no pending update and naming no partial upgrade, while writing nothing; the same log with updates still pending is the partial upgrade 44 reports |
| `56-tui-receipt-pacdiff.sh` | the receipt's `p` runs `sudo pacdiff` attached as the sim installer: sudo logs `pacdiff` as the whole argv, the stub removes the `.pacnew` it reviewed, the TUI comes back and the receipt re-reads the count to zero, `yay` ran once, no AUR build happened, and the state file is byte-identical across `p` |

41-46 are the Phase 4 chaos level from `NEXT.md`; they need the fault
injection below. 43, 44 and 45 each drive a real fault and assert the detection
it needs: `doctor` on the deleted lock, `check` on the hand install, `install`
on the stale aurto repo. 50-52 are the same level for a mirror that answers 500
and for bytes that are wrong, on the wire and already in the cache. 53 is the
packaging level: a real `makepkg` and `pacman -U` against the checkout.

The fault fixtures `NEXT.md` lists are those same states, asserted where they
land rather than injected a second time: 06 for a stale and a live `db.lck`, 41
for the `ENOSPC` `.part`, 45 for the stale aurto repo, and 44 with 55 for
a `pacman.log` that holds an install after a fetch - 44 the mixed system it
reports, 55 the completed one it must not.

01 and 02 are a pair. Passing 01 alone would prove nothing if the harness could
not detect a real install at all.

## Which scenarios a change must run

`sim/scenario-map.tsv` names, for every path under `src/` and for the harness
itself, the scenarios that exercise it. A pull request runs exactly that set,
plus every scenario it edits:

```bash
./sim/run.sh $(scripts/gate-scenarios.sh --list origin/main)
```

CI passes the pull request's own head, because the runner checks out the
synthetic merge commit instead and that commit also carries whatever `main`
gained after the event's `base.sha` was frozen:

```bash
scripts/gate-scenarios.sh --list "$BASE" "$HEAD_SHA"
```

Without the head argument a three-markdown-file change selected 27 of 56
scenarios on PR #143, because `main` had merged an unrelated `src/tui` change in
between. `scripts/check-gate-scenarios.sh` pins both halves of that: the merge
commit inherits the drift, and a head-pinned docs commit selects nothing.
`ci.sh` runs it.

`scripts/gate-scenarios.sh --check-map` walks `git ls-files src` and fails on a
path with no row, on a row naming a scenario that does not exist, and on a row
for a file that is gone. `ci.sh` runs it, so a new `src/` file that nothing
exercises is a red build instead of a quiet merge. `main` and
`workflow_dispatch` still run the whole suite.

The selection is written to `sim-logs/selected-scenarios.txt` before anything
runs, so the uploaded artifact records what the run chose — including a run that
chose nothing.

The map is a claim about the harness, not a wish: every listed scenario runs
that code path. If a scenario stops touching a file, the change that removes
the last use edits the row.

## Adding a scenario

```bash
#!/usr/bin/env bash
source /usr/local/lib/sim/lib.sh

echo "scenario: what this proves"

assert_eq "$(installed_version)" "1.0.0-1" "still on the old version"

finish
```

Name it `NN-slug.sh`. The number is a namespace every worktree shares, and git
cannot see two PRs adding the same one, so `ci.sh` fails when two files share a
numeric prefix or a file has none ([#61](https://github.com/PremModhaOfficial/aepm/issues/61)).

Each scenario runs in a fresh container, so no cleanup is needed. Helpers live
in `sim/lib.sh`: `assert_eq`, `assert_ne`, `assert_contains`, `assert_true`,
`assert_false`, `installed_version`, `payload_version`, `pkg_state`,
`cache_files`, `usr_state`, `tree_state`, `local_db_state`, `sync_db_state`,
`yay_log`, `yay_built_something`, `sudo_log`, `finish`.

For a state that is large, assert on a digest (`local_db_state | sha256sum`),
not on the state itself: a failing `assert_eq` prints both sides, and the whole
local package DB is thousands of lines of noise.

A TUI scenario reads `script`'s delta stream, which carries only the cells
ratatui changed. A value drawn once and then partially rewritten survives as
digits, not as `49.9%`. Assert a value that is drawn whole, and make the
fixture hand the TUI that state for the first poll instead of relying on which
frame a poll happens to catch.

## Fault injection

The chaos scenarios need a real pacman to misbehave, and the harness provides
four faults rather than a scenario faking the evidence:

- **The control file is `/etc/sim/xfer-fault`.** A scenario writes one word to
  it and runs the command; the fault fires once, disarms itself, and the retry
  the scenario runs next is a clean run. A missing or empty file means no
  fault, so every other scenario runs with the real bytes.
- `sim/fixtures/sim-xfer` is the sim-only `XferCommand` that reads that file.
  It paces a package transfer (`/etc/sim/xfer-delay`, seconds) so a poll can
  see real `.part` growth, and on the paced path its first chunk is renamed
  into place so the `.part` is never observable at zero bytes. pacman does not
  create that path; the hook does, so a plain `head -c ... >"$out"` would hand
  the TUI a few milliseconds of an empty file. The fault branches below write
  the target directly, because a fault wants the partial file on disk, not a
  paced one.

The four words are:

| Word | What a real system does that this copies | Scenario |
|---|---|---|
| `kill` | pacman is SIGKILLed mid-transfer: a `.part` with real bytes, no final artifact, a lock nobody holds | 46 |
| `fill` | the cache filesystem hits `ENOSPC` mid-transfer (capped by `/etc/sim/xfer-fill-max`, default 64 MiB, then the rest append fails for real) | 41 |
| `corrupt` | the mirror delivers the right number of wrong bytes, so pacman's own checksum check rejects the artifact (scenario 52 corrupts the cached copy directly, no fault needed) | 51 |
| `http500` | the mirror answers `500 Internal Server Error` and the body never arrives; the hook exits 22, like `curl --fail` | 50 |

Two harness helpers work with the control file:

- `# sim-run-args: <flags>` in a scenario's header comments passes extra
container flags to that one scenario. The `fill` fault needs a bounded
filesystem to fill, so scenario 41 asks for `--tmpfs
/var/cache/pacman/pkg:size=2m`. **A scenario that fills a disk must carry that
header**: without it the fill runs to the fill cap or, if the cap is raised, to
the container's root filesystem and the host's docker storage.
- `sim/make-pkg.sh NAME VERSION SIZE_BYTES` publishes an ad-hoc package with one
blob of `SIZE_BYTES` zero bytes into the sim repo, because the two `simapp`
versions are too small to interrupt. A `ulimit -f` in the invoking shell then
kills pacman mid-extraction (scenario 42).

## VM level: btrfs, snapper, rollback, boot

A container has no snapshots and cannot reboot, so the Phase 5 items need a real
kernel. `sim/vm/run.sh` boots an Arch ISO under qemu/KVM, installs onto a btrfs
disk, and drives three scenarios over the serial console:

| Script | Proves |
|---|---|
| `sim/vm/scenarios/60-base-install.sh` | a btrfs root with `/` as subvolume `@`, `/.snapshots` on its own subvolume, an ext4 `/boot`, `GRUB` installed with a boot sector actually written, `snapper create-config` on that root, then a real `aepm fetch` and `aepm install --yes` as an unprivileged user: the prefetch downloads and changes nothing installed, the install upgrades through the helper, nothing builds from the AUR |
| `sim/vm/scenarios/61-rollback-boot.sh` | a snapshot before an install, a package whose `post_upgrade` wipes `/usr/lib/modules` and leaves modules for a kernel that does not exist, `aepm install` reporting success anyway (nothing can know a package is hostile), then `snapper --ambit classic rollback` to the snapshot |
| `sim/vm/scenarios/62-snapper-limits.sh` | after the reboot the machine runs the restored kernel, `uname -r` is the only directory in `/usr/lib/modules`, the bogus modules are gone and the package is back to the pre-install version; then `FREE_LIMIT` decides how far `snapper cleanup number` deletes (the same six snapshots stop at `NUMBER_LIMIT`'s maximum with `FREE_LIMIT=0.0` and are cut to its minimum with `FREE_LIMIT=0.99`), and `SPACE_LIMIT` is honoured while its condition is met. **Pins a limitation:** the unmet `SPACE_LIMIT` branch is not reachable in this VM, and the last assertion says so on purpose |

```bash
./sim/vm/run.sh --probe     # report the capabilities this level needs
./sim/vm/run.sh             # boot the VM and run 60, 61, 62
SIM_VM_LOG=/tmp/vm-sim.log  # the transcript (the default)
./sim/vm/run.sh --keep      # keep the guest disk for a manual look
```

What it needs, and refuses to run without: `qemu-system-x86_64` with a writable
`/dev/kvm` (TCG makes `pacstrap` take hours), `python3`, `curl`, `bsdtar`,
`debugfs` (e2fsprogs), a `cargo` build of the binary, and 14 GiB free in
`$SIM_VM_CACHE` (`~/.cache/aepm-vm`) for the ISO and the guest disk. **The host needs no loop
device and no snapper**: the guest owns the btrfs work and the boot, which is
the whole reason this level is a VM. A missing capability is a hard exit with
the capability named, never a skipped stage that still prints `PASS`.

The first run downloads the Arch ISO once (the only step that needs the
network) and keeps it in the cache. Inside the guest, `pacstrap` uses the real
mirrors over qemu's user-mode network: this level is not `--network none` like
the container level, because an installed system has to come from somewhere.

### Deliberate setup choices

- The **kernel command line carries no `rootflags=`/`subvol=`**, so `/` comes
  from the *default* btrfs subvolume. `snapper rollback` works by making a
  snapshot the default subvolume, so a pinned subvolume would keep booting the
  broken system and the scenario would pass for the wrong reason. `openSUSE`
  gets the same effect from its GRUB plugin; this harness uses the
  default-subvolume route so the harness stays plain Arch.
- `snapper --ambit classic rollback` is used for the first rollback, because
  snapper's automatic ambit only recognises a default subvolume that is already
  one of its own snapshots, and on a fresh system the default is the root
  subvolume itself. `classic` is the documented path: it snapshots the current
  system, makes a writable copy of the target, and sets that copy as the
  default.
- **`/boot` is a plain ext4 partition and the harness boots the guest kernel
  directly from it** (`-kernel`/`-initrd`, `root=/dev/vda2`). GRUB is installed
  and its generated config is asserted (`console=ttyS0`, no pinned subvolume),
  but GRUB 2.16-1 in this environment lands on its own `grub>` prompt instead of
  loading its config, and a harness that hangs at `grub>` proves nothing. What
  the boot therefore exercises is the kernel, the initramfs and the root
  subvolume - which is exactly where a rollback takes effect - and **the
  bootloader menu itself is not covered**.
- `/.snapshots` is a separate subvolume, which snapper's rollback ambit
  detection needs.
- Config values go in through `snapper set-config` and are read back through
  `get-config`: the effective value is what the assertions compare, because a
  file that says one thing while snapper uses another is the bug this level
  exists to catch.
- The installed system autologins root on `ttyS0`: the harness has no keyboard
  and this is a throwaway VM. That is why the VM half never runs on the host.

### Traps this level cost hours on

Each of these failed silently or looked like something else first. They are
written down so the next change starts here instead of re-deriving them.

- `qemu-img dd` in this qemu has **no `skip=`**: slice a disk with
  `qemu-img convert -U -O raw -S 4k <qcow2> <raw>` and then plain `dd`.
  (`--sparse` also takes a size here, not a bare flag.)
- A second qemu on the same qcow2 dies with `Failed to get "write" lock`. Copy
  the image (`cp --reflink=auto`) before inspecting it by hand.
- `-nodefaults` guests do not stop on ACPI poweroff: the driver quits them
  through the monitor socket, and `cache=writeback` keeps that safe.
- `mkfs.ext4` prompts when it finds a leftover signature, and a prompt on a
  serial console is a silent hang. Force it (`-F`) and close stdin.
- `sfdisk`'s first field is the **start sector**: `1,512M,c` starts at sector 1
  and leaves no MBR gap, so `grub-install` exits 0 having written no boot
  sector at all. Scenario 46 asserts the boot sector is non-empty.
- `snapper create-config` refuses to run when `/.snapshots` already exists; let
  it create the subvolume, then promote it to a sibling of `@`.
- pacman runs **`post_upgrade`**, not `post_install`, on an upgrade — a break in
  the wrong hook does nothing at all.
- `snapper cleanup number` ignores snapshots younger than `NUMBER_MIN_AGE`
  (1800 s by default) and does it silently.
- Values written into `/etc/snapper/configs/root` with `sed` are not what
  snapper acts on in a chroot-created config. Use `snapper set-config` and read
  back with `get-config`; the assertions compare the effective values.

### What the VM level cannot prove

- **It is not the hardware.** A KVM guest proves the kernel, the bootloader and
  btrfs behave; it says nothing about a specific laptop's NVMe, suspend, or
  firmware. Rollback on a machine that needs a firmware update is still a human
  test.
- **The AUR helper is the harness fake** (`sim/yay` plus `sim-upgrade`), the
  same one the container level uses, so this level proves the snapshot and the
  boot, not that a real `yay` build survives a rollback. There is no `makepkg`
  and no AUR build in the guest.
- **The broken package is deliberate.** It removes the kernel and installs
  modules for a kernel that never existed. A real broken upgrade fails in more
  interesting ways: a half-written file, a dependency that vanished, `pacnew`
  files left in `/etc`. Only rollback and boot are covered.
- **The bootloader menu.** See above: the guest boots its kernel directly from
  `/boot`. A machine whose GRUB cannot read its own config after a rollback is
  not covered here.
- **The unmet `SPACE_LIMIT` branch, deliberately pinned.** Snapper evaluates the
  space condition on the *exclusive* usage of the qgroup it creates, and btrfs
  reports a parent qgroup's exclusive usage as zero however much its child
  subvolumes hold - so even 700 MiB of snapshot-only data against a 600 MiB
  limit leaves the condition met. Scenario  62 asserts today's behaviour and says
  so; it goes red the day the branch becomes reachable, and that is when the
  assertion must be inverted. `FREE_LIMIT`'s unmet branch *is* reachable and is
  proven. Neither covers a filesystem under weeks of real growth, and snapper's
  own documentation warns that cleanup runs asynchronously.
- **One disk, one layout.** No `@home`/`@var` split, no encryption, no swapfile,
  no RAID, no Secure Boot. Each of those changes what a rollback does.

## Limits

This is a real pacman with a synthetic repo. It does not simulate:

- systemd timers, journald, or linger
- aurto's own repository and build chroots
- btrfs/snapper behaviour in a container (see the VM level above for that)

Those still need a real install on real hardware. The VM level above covers
btrfs, snapper and boot; it deliberately does not cover the AUR build path.
The container level catches the
expensive mistakes: accidentally installing during prefetch, running `yay` as
root, deleting a lock while pacman runs, and treating a read-only command as
safe when it is not.

## Why the fake yay fails loudly

A silent AUR stub would make "install did not rebuild" pass for the wrong
reason. Exit 97 plus `/var/log/sim-yay-build.log` turns the gap into a visible
failure instead of false coverage.
