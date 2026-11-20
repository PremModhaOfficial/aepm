# Review background: aepm

`aepm` (`aur-prefetch`, binary `aepm`) is a Rust CLI that makes pacman's update
preview honest. Six subcommands: `init`, `check`, `fetch`, `install`, `clean`,
`doctor`, plus the `tui` surface. It changes pacman state, so a mistake is a broken
machine, not a bad afternoon.

## What it must never do

- `fetch` writes only to the pacman sync database and the download cache. Never
  `/usr`, `/etc`, or `/var/lib/pacman/local`.
- `check` and `doctor` write nothing at all.
- `install` never rebuilds a package that was already built.
- Nothing runs `yay` or `makepkg` as root.
- `pacman`, `yay`, `makepkg` are never run on the development host. Runtime is
  exercised only through `./sim/run.sh` (disposable Arch container, `--network none`).

## How this repo decides things

- Measurement over intuition. A number without a command, log, or file behind it
  is not evidence, and "probably right" is not a source.
- Gates are deterministic and quiet. 14 shell gates run in `./ci.sh`; each one
  exists because something specific went wrong once.
- The simulation is the proof for anything that touches pacman. Unit tests with a
  fake runner are not proof of a side effect.
- A red check means "the check did not run", not "the change is bad". Confusing
  those two has cost more time in this repo than any other mistake.

## Failure modes that have actually happened here

- A gate that silently skipped its work and still printed success.
- A reviewer that reported "no concerns" on a PR whose only purpose was to make a
  prose claim true, without reading the claim.
- A measurement copied from an earlier commit and presented as current.
- Scenario selection that selected nothing because a file path fell outside a
  filter, so a PR ran zero scenarios and passed.

## How to review here

Report a finding when the code contradicts a claim, the claim has no source, an
invariant is broken, a gate can pass without running, or a behaviour change has no
scenario. Do not report formatting, naming taste, or "consider adding tests" as a
finding on its own. Prefer few findings with `file:line` over many vague ones; an
empty finding list is a legitimate answer when the diff is sound.
