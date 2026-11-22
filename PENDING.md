# PENDING.md

What `v0.1.0` does not ship or does not prove, and what would settle each one.
`NEXT.md` is the plan; this file is the residue that the plan cannot close by
writing code. Every row names the command that shows its state today.

Last checked against `65daa02`.

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

Named here so no later reader mistakes them for covered
ground. The first two are stated at the work too: `sim/README.md:346` and
`:404-406`.

| gap | why it is not proven | what it would take |
|---|---|---|
| the GRUB menu | GRUB 2.16-1 in the sim lands on its own `grub>` prompt instead of loading its config, so the guest boots its kernel straight from `/boot`. The kernel, initramfs and default subvolume — where a rollback takes effect — are covered | a bootloader image that loads its config on a serial console |
| `SPACE_LIMIT`'s unmet branch | btrfs reports a parent qgroup's exclusive usage as zero, so 700 MiB of snapshot-only data still satisfies a 600 MiB limit. Scenario 62 asserts today's behaviour and goes red when that closes | a btrfs that reports parent usage, or a different quota mechanism |
| the D39 rule's effect | the rule is one paragraph in `.pr_agent.toml`'s `[pr_reviewer] extra_instructions`, and the reviewer reads that file from the default branch (`.github/workflows/pr-agent.yml:82`), so the PR that added it was reviewed by the old rules; afterwards the effect is a model's choice on a later review, and a review that never meets a comment-as-code case looks the same as one where the rule worked. The instance it was written for is finding `691bb9dc9491` at `096c126:235-236`, still reachable from `origin/fix/review-clean-no-block`, so the review can be re-run; what cannot be rebuilt is a `main` without the rule, which is the before half of the settling pair | two logged reviews on a head whose diff carries a comment quoting a retired pattern, one before the rule applied and one after, each read with `gh api --paginate "repos/PremModhaOfficial/aepm/pulls/<n>/comments"`: a finding at that line before and no finding at it after is the pair. One non-finding alone proves nothing, and the counters stay locatable only: `rg -c 'A line inside a comment is not the code' .pr_agent.toml` → `1`, `bash scripts/check-review-gate.sh` → `ok doc-claims-match-code` |

## Not shipped

| what | state now | what settles it |
|---|---|---|
| the receipt's attached `p` | at `99d5e03`: `init` writes one sudoers rule, for `pacman -Syuw --noconfirm` (`sed -n 191,196p src/commands/init.rs`). A `sudo pacdiff` from the receipt would be a second escalation with no rule behind it, so on a real host it prompts for root from inside the TUI, and a passwordless rule for an interactive tool that writes `/etc` widens privilege past the one path `fetch` uses | nothing in this tree. The receipt prints `sudo pacdiff` for the user to run after closing, which needs no privilege from `aepm` |

## Open work, with the issue that owns it

| item | why it is open |
|---|---|
| #93 C3 | the palette / `ascii: bool` pair is gone: one `RenderCtx` replaces it in 33 signatures and 212 call sites, and 4 of the 14 `#[allow(clippy::too_many_arguments)]` went with it (`grep -c too_many_arguments src/tui/render.rs` → 10). The 10 left are not a face-flag problem: `render_live_frame_status` carries 10 arguments and the rest 8 to 11, because each carries the frame's own layout inputs (`width`, `room`, `slots`, `selection`). Folding those is a second input type, not this sweep |
| #41, AUR side | the refusal shipped: `install` compares the last fetch's pending names with `pacman -Qu` and exits 2, `sim 54`, and `check` now reads the same set and names its evidence (#118). One gap remains: AUR packages are outside `fetch`'s plan (`pacman -Qui` only), so a helper can leave an AUR package behind and the refusal will not see it | a plan that covers AUR packages |
| #115 | a review did not follow a push: `PR Agent` ran on open, reopen and ready only, so a rebased head had no review and nothing failed (#112 merged at six checks, none a review). Closed by two changes: the trigger includes `synchronize` with `handle_push_trigger`/`push_commands = ["/review"]`, bounded by a reviewed-SHA skip; and `Review Gate` judges the PR head with `--sha <head>` and writes its verdict onto that commit through the Checks API, because a `workflow_run` check is anchored on the default branch (measured, `.github/PR-AGENT.md` D32). Unproven live until this is on the default branch: the verdict write runs only from the default branch's copy of the gate, and a check run can only be created by a GitHub App, so a local run gets `403 You must authenticate via a GitHub App` (`bash scripts/gate-review-selfcheck.sh` proves the branch; `gh pr checks <pr> --json name,conclusion` on a merged copy proves the deployment) | merge this, then one push and one `/review` on any PR: `gh pr checks <pr> --json name,conclusion` |
| #29 | the TUI v2 shell. Not planned: the tree pays for panels nobody asked for |

## Housekeeping

- The `Review` workflow runs on `pull_request` open, reopen, ready and push. A
  pushed head is reviewed unless it already carries a complete review of that
  exact commit, and `Review Gate` records its verdict on the head that a merge
  decides on (#115).
- `shellcheck` is not installed on this host and `ci.sh` does not run it, so
  nothing checks the shell in `sim/`. Scenario scripts are covered by running
  them and by `scripts/gate-scenarios.sh`; the VM scripts under `sim/vm/` are
  covered only by running them.
