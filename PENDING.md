# PENDING.md

What `v0.1.0` does not ship or does not prove, and what would settle each one.
`NEXT.md` is the plan; this file is the residue that the plan cannot close by
writing code. Every row names the command that shows its state today.

Last checked against `972bb94`.

## Publication

Neither of these is a code problem. Both block a user from installing the
package the ordinary way.

| what | state now | what settles it |
|---|---|---|
| AUR upload | `curl -s 'https://aur.archlinux.org/rpc/v5/info/aepm'` → `{"resultcount":0,…}`, so `yay -S aepm` fails | a key AUR accepts. `~/.ssh/id_ed25519.pub` exists (`SHA256:+EIu/u8k8pu0yt8jYA7u4EHPl1kG+Vtm8pmM9yFIZcg`), but `ssh -T aur@aur.archlinux.org` answers `Permission denied (publickey)`, so it is not registered on the account |
| crates.io | no `~/.cargo/credentials.toml`, so `cargo publish` has no token | `cargo login`, then `cargo publish --locked` from `972bb94` |

The `PKGBUILD` itself is ready: `scripts/gate-pkgbuild-version.sh` prints
`pkgver=0.1.0`, `_tag=v0.1.0` and `0.1.0 matches Cargo.toml`. Nothing about the
upload needs a change to the tree.

## Not proven, on purpose

Named here so no later reader mistakes them for covered ground. Both are stated
at the work too: `sim/README.md`, "Traps this level cost hours on", and the
release notes.

| gap | why it is not proven | what it would take |
|---|---|---|
| the GRUB menu | GRUB 2.16-1 in the sim lands on its own `grub>` prompt instead of loading its config, so the guest boots its kernel straight from `/boot`. The kernel, initramfs and default subvolume — where a rollback takes effect — are covered | a bootloader image that loads its config on a serial console |
| `SPACE_LIMIT`'s unmet branch | btrfs reports a parent qgroup's exclusive usage as zero, so 700 MiB of snapshot-only data still satisfies a 600 MiB limit. Scenario 62 asserts today's behaviour and goes red when that closes | a btrfs that reports parent usage, or a different quota mechanism |

## Open work, with the issue that owns it

| item | why it is open |
|---|---|
| #93 C3 | the palette / `ascii: bool` sweep, 52 call sites, 35 functions taking both, 14 `#[allow(clippy::too_many_arguments)]` in `src/tui/render.rs`. Deferred out of `v0.1.0`: mechanical, no user-visible change, and the highest conflict surface in the tree |
| #41, #47 | partial upgrade was implemented in `feat/partial-upgrade-refusal`: the refusal compares the last fetch's pending names against `pacman -Qu` after the upgrade, exit 2, sim 54. What is left is the report side - `check`'s `PartialUpgrade` still reads `pacman.log` rather than the state file's set, so the two evidence paths can disagree. #47 is closed; `docs/STATE-MACHINES.md` names what remains, and `scripts/gate-state-machines.sh` holds 23 line anchors so the document cannot drift |
| #29 | the TUI v2 shell. Not planned: the tree pays for panels nobody asked for |

## Housekeeping

- The `Review` workflow runs on `pull_request` open, reopen and ready — not on
  push. A PR that is opened and then pushed to keeps the review of its first
  commit only.
- `shellcheck` is not installed on this host and `ci.sh` does not run it, so
  nothing checks the shell in `sim/`. Scenario scripts are covered by running
  them and by `scripts/gate-scenarios.sh`; the VM scripts under `sim/vm/` are
  covered only by running them.
