# AGENTS.md

Rules for anyone (human or agent) changing this repo. They exist because this
tool changes pacman state, and because an earlier session burned a run printing
"Done" instead of stopping.

## Read this first

Before planning or writing code, read [`NEXT.md`](NEXT.md). It is the
authoritative order of work. If a chat summary, `context.md`, or an old plan
disagrees with it, `NEXT.md` wins.

Current position: all six commands are implemented and sim-covered. Phases 4
(chaos), 5 (the VM level in `sim/vm/`) and 6 (packaging) are all closed. Phase 7 T0
(the report layer),
the T1 read-only shell, the DAG execution model, and its pure frontier reducer
are landed. T2's prefetch badges, real cache scan, pure bottom-up forest view
(T2a), the pure live grammar/palette (T2b), and the synthetic byte bars and
viewport (T2c) are landed. T2d's real cache observation source is landed in
`src/fetch_source.rs`. T2e runs the real fetch from `F`: `src/tui/fetch_session.rs`
streams the command on a worker, polls the real cache, and redraws on real
changes; sim 34 proves it under a pty. T2f adds the repair card on a real
failure and the `g` ledger; sim 35 proves both. T3a adds the fetch PRE-FLIGHT
gates and the `l` log; T3b adds the read-only install gate and T3c wires the
attached install; T3d adds the post-install receipt. T2 and T3 are closed; T4
polish is next.

If you are picking up mid-work, read [`HANDOFF.md`](HANDOFF.md) for the current
state and the first concrete move.

## Hard safety rules

1. Never run `pacman`, `yay`, `makepkg`, `aurto`, `paccache`, `pacdiff`, or
   `systemctl enable/start/restart` against the development host. The dev
   machine is not a test machine.
2. Exercise runtime behaviour only through `./sim/run.sh`: a disposable Arch
   container, `--network none`, local pacman repo, fake `yay`.
3. Never install a sudoers rule, timer, or service on the host while developing.
4. Do not commit key material, `.gpg/`, container images, or `target/`.
5. Invariants that must hold after every change:
   - `fetch` writes only to the pacman sync DB and the download cache. It never
     writes to `/usr`, `/etc`, or `/var/lib/pacman/local`.
   - `check` and `doctor` write nothing at all.
   - `install` never rebuilds a package that was already built.
   - Nothing runs `yay`/`makepkg` as root.

## Definition of done

- `./ci.sh` green: fmt, clippy with `-D warnings`, tests, cargo-deny, and the
  `src/` → scenario map.
- `bash scripts/gate-coverage.sh` green: line coverage at or above the measured
  floor in `coverage-floor.txt`.
- `bash scripts/gate-scheduled-audit.sh` green before a release: cargo-deny,
  cargo audit, and `cargo build --locked` on the pin and on stable.
- `./sim/run.sh` green, or the mapped scenarios from
  `bash scripts/gate-scenarios.sh --list <base>` green.
- Any change that touches pacman behaviour has a scenario in `sim/scenarios/`.
  Unit tests with a fake runner are not enough for side-effect claims.
- `README.md` updated when a command, flag, or path changes.
- The matching `NEXT.md` checkbox is ticked in the same commit.

## Agent non-interactive rules

A command waiting for input hangs a session that has no keyboard, and the hang is
silent: no output, no error, no exit. Three hours have been lost to this twice.

1. Source `scripts/agent-env.sh` before any command that could open an editor or
   a pager: `GIT_EDITOR=true`, `GIT_SEQUENCE_EDITOR=true`,
   `GIT_TERMINAL_PROMPT=0`, `PAGER=cat` and friends.
2. Close stdin: `command </dev/null`. A heredoc whose terminator is missing then
   fails at once instead of reading forever.
3. Put a timeout on anything that can block: `timeout 600 <command>`.
4. Never open a heredoc (`cat > f <<EOF`) unless the terminator is in the same
   command you send. Prefer the file-write tool.
5. Commit as soon as something passes. An uncommitted hour disappears with the
   hang.
6. Prefer a merge over an interactive rebase: one conflict resolution, no editor
   per commit.
7. A delegate whose last activity is more than 15 minutes old is hung, not
   thinking. Check it; do not wait longer.
8. Merge with `gh pr merge --squash --match-head-commit <sha you reviewed>`.
   Required checks already refuse a head CI never saw; the flag refuses a merge
   GitHub accepted on a head you did not read.
9. Wait for CI with `gh run watch <id> --exit-status` or `gh pr checks --watch`,
   never `sleep`. A watch returns; a sleep only delays the next poll.

## Claims

More than one orchestrator works this repo at once (T3 Code threads, Traycer
agents, hand-driven sessions). A branch is not a claim: nothing lists branches
before work starts, and a worktree made for the same issue cannot be seen from
the other one. The tracker is the only medium both sides read, so the claim
lives there, in the `claimed` label.

1. Claim before you branch, and never work an issue that already carries the
   label:

   ```sh
   gh issue view <n> --json labels --jq '[.labels[].name]'   # stop if "claimed"
   gh issue edit <n> --add-label claimed
   gh issue comment <n> --body "> *This was generated by AI during triage.*

   Claimed by <t3|traycer> `<branch>` in `<worktree>`. Release on merge."
   ```

2. Release on merge, on abandonment, and when you hand off:
   `gh issue edit <n> --remove-label claimed`.
3. A claim whose branch has no new commit for 15 minutes is hung, not thinking
   (rule 7 above). Say so in a comment, then reclaim. Do not silently duplicate.
4. Files, not just issues: two sessions on one file collide even under different
   issues. List the files your change owns in the claim comment when the issue
   does not already name them.
5. `claimed` is not `blocked`. `blocked` means the work cannot start; `claimed`
   means it has started somewhere.

## Honesty rules

- Never turn a gate into a silent skip that still prints success. If a check
  cannot run, fail loudly. `ci.sh` already does this for cargo-deny.
- Do not call stubbed behaviour "done". Say it is a stub and name what is
  missing.
- Do not pad a finished answer with repeated acknowledgements. One closing
  line, then stop.
- If blocked, state exactly what blocks you once. Do not loop.
- A report that contradicts the proof (`./ci.sh` red, `scripts/proof.sh` failing,
  a conflict it did not mention) is a failed report, not a partial pass.

## Proof rules

Every claim about this repo is anchored to a proof taken now, not remembered.

1. `scripts/proof.sh` is the anchor: git head, ahead/behind `origin/main`, every
   open PR's mergeable state and check counts, open issues, plan percentage, and
   the age of the newest evidence file. It exits 1 when a proof cannot be taken.
2. A number in chat, a commit message, a PR body or an issue comment names its
   source: `scripts/proof.sh`, a `/tmp/*.log` from this HEAD, or the command that
   printed it. No source, no number.
3. Evidence older than the current HEAD is not proof. Re-run, or say it is stale.
4. A worker's report is a claim until its log is read. `DONE` without a log path
   and exit code is not done.
5. When a proof contradicts an earlier claim, the proof wins and the correction
   is stated plainly.

## Agent review surface

The PR review is a machine surface first, human second. Read it, decide, act.

- **Trigger:** PR open, reopen, ready-for-review, and push (`synchronize`). One
  persistent comment per PR, updated in place. A push reviews the head it
  created, bounded twice: a draft is skipped, and a head that already carries a
  complete review of that exact commit is not reviewed again, so a rebase that
  changes nothing spends no model call. The trigger alone is not enough: the
  action drops a bare `synchronize`, so `github_action_config.handle_push_trigger`
  and `push_commands = ["/review"]` are set too (`PR-AGENT.md` D31).
- **Commands** (PR comment): `/review`, `/describe`, `/improve`, `/ask <q>`.
  Only OWNER, MEMBER, COLLABORATOR; anyone else is ignored.
- **Output:** inline `file:line` findings, a typed risk level, and a merge
  verdict: `no_concerns_found`, `needs_review`, or `changes_required`.
- **State:** one persistent comment, updated in place. Do not reconstruct a
  thread. The gate's ledger rows are the one exception: they are separate
  comments, appended once per judged head and never edited, because a block the
  review's own rewrite erased has to remain on record somewhere.
- **State command:** `scripts/review-state.sh [<pr>]` prints PR state, check
  counts, risk, merge verdict, staleness, coverage, and finding counts.
  `--findings` lists `path:line`, `--full` includes the comment, `--gate` exits 1
  unless a complete review of the head cleared the merge, and `--reviewed` exits
  0 whenever a complete review of the head exists, whatever its verdict.
- **Gate:** the check is evaluated when a review run finishes, which is the only
  trustworthy trigger, and it judges the PR head and nothing else: the head is
  resolved once and pinned with `review-state.sh <pr> --gate --sha <head>`, so
  the commit the verdict is about and the commit it is reported on are the same
  one. It fails closed: no review comment, a review of another commit, an
  incomplete run (`last_run.complete` not true), or a verdict that did not clear
  the merge (anything other than `No concerns found`, override with
  `REVIEW_GATE_VERDICT`) is a failure. It makes no model call, so it spends no
  credits, and it runs only the default branch's copy of the script. Only a
  comment authored by the bot counts (`REVIEW_BOT_LOGIN`), and only its typed
  block identifies one: every other marker is forgeable or shared with
  `/describe`. A clean review (zero findings) carries no typed block at all, so
  the guide marker `<!-- pr-agent:review:full` selects it, its completeness is
  reported as `unrecorded` rather than assumed, and the head comes from the
  commit the comment quotes. The block keeps resolved findings, so a PR that
  still carries one cannot pass on a missing block: the gate fails on it. That
  evidence alone would not survive the review's own rewrite — one comment,
  updated in place, so a run that wrote it without the block erased it — so the
  gate also appends one row per judged head to an append-only ledger comment
  (`<!-- review-gate-ledger:v1 head=… block=… complete=… verdict=… -->`, never
  edited, one line) and reads it back: a row that records a block while the
  review now carries none is a vanished block, not a clean review. A ledger row
  that cannot be written is a `::warning::` on the job and never fails a PR; the
  verdict on the head is the decision. The review selection still matches only
  the typed block and the guide marker, so a ledger comment is never judged as
  the review.
- **Where the check lands:** a `workflow_run`-triggered workflow runs on the
  default branch, and its own check is attached to the default branch's HEAD —
  not to the commit the review run checked out. That was measured, not assumed
  (`.github/PR-AGENT.md` D32): it is why a pushed head used to have no `Review
  Gate` check at all. So the gate's own check never gates a PR, and it never
  fails on a review verdict either, which would leave a red mark on `main` that
  outlives the PR it described (#111). The verdict is written onto the PR head
  through the Checks API instead. A push run writes it for the head it reviewed;
  a `/review` run, which checks out the default branch but reviewed the PR,
  writes it for the head too. A push run whose head moved on before it finished
  reports nothing, because that head has its own run and a verdict about it from
  an older review would be a lie; the check it left on the older commit is read
  by no rollup, because checks are per-commit.
- **Authority:** `CI` and `Sim` gate behaviour; `Review Gate` gates coverage and
  the verdict, and it is requireable because every head with a review run of its
  own gets a `Review Gate` conclusion on itself.
  Whether it is a required status check in the `main` ruleset is a one-time
  repository setting and not something this repo can assert (`PR-AGENT.md` N5).
  Until that setting exists the gate reports and the verdict stays advisory. A
  human override is an admin merge, and it is a decision, not a formality.
- **Failure:** a review that could not run fails the `Review` check. A red
  `Review` means "no review happened", not "no findings".
- **Policy:** `.pr_agent.toml`; rules load from `main`, so a PR cannot rewrite
  the rules it is judged by.
- **Usage:** the review comment's run-details section carries model, tokens
  in/out, duration, and AI calls (`output_run_details = true`). The job log
  prints prompt tokens only, so that section is the usage record.
- **Decisions and measurements:** `.github/PR-AGENT.md`.

## Layout

| Path | Role |
|---|---|
| `spec.md` | User-facing, plain-language flow and failure modes |
| `PROGRESS.md` | Prefetch-aware dependency tree: states, edges, replay |
| `TUI.md` | Terminal UI spec: screens, keys, action safety |
| `GLOSSARY.md` | The words this project uses. Test names and commits use these, not synonyms |
| `docs/ANIMATION.md` | DAG execution frontier: readiness, parallel fronts, replay |
| `docs/STATE-MACHINES.md` | Every implicit machine named: states, transitions, who owns precedence |
| `docs/FACTORY.md` | The contract every agent run follows: slots, tasks, brakes, brief shape |
| `docs/CI-ARCHITECTURE.md` | What the checks cost (measured), what good looks like (sourced), the ranked changes |
| `NEXT.md` | Working plan: decisions, phases, acceptance criteria |
| `PENDING.md` | What the release does not ship or prove, each row with the command that shows it |
| `context.md` | Implementation notes and edge cases |
| `src/main.rs` | CLI surface (subcommands) |
| `src/tui/` | Terminal UI (`src/tui/pipeline.md` is the module map): `mod.rs` shell (keys in `src/keymap.rs`), `tree.rs` forest, `live.rs` pure view rows, `fetch_session.rs` live fetch, `render.rs` frames, `guard.rs` terminal restore, `sanitize.rs` untrusted text |
| `PKGBUILD` / `packaging/` | AUR package: binary to `/usr/bin`, user units to `/usr/lib/systemd/user` |
| `ci.sh` | Local mirror of the GitHub checks |
| `sim/` | Arch simulation harness (see `sim/README.md`) |
| `.github/workflows/ci.yml` | Build, lint, test, audit |
| `.github/workflows/sim.yml` | Arch container scenarios |
| `.github/workflows/pr-agent.yml` | Agentic PR review |
| `.github/workflows/review-gate.yml` | The review verdict, on the PR head |
| `.pr_agent.toml` | Review policy |
| `.github/PR-AGENT.md` | Review decisions and measurements |
| `scripts/review-state.sh` | Agent-facing review state, and `--gate` |
| `sim/scenario-map.tsv` | `src/` path → the sim scenarios that exercise it |
| `scripts/gate-scenarios.sh` | The map check and the changed-scenario list |
| `scripts/gate-coverage.sh` / `coverage-floor.txt` | Line-coverage gate and the measured floor |
| `scripts/gate-scheduled-audit.sh` | The weekly deny, audit and `--locked` checks |

## Current status

All six subcommands are implemented and every one has sim coverage. `NEXT.md`
is the authoritative order of work. The TUI is specified in `TUI.md` and
`PROGRESS.md`; its execution model is `docs/ANIMATION.md`. Phase 7 T0 (the
shared report layer), the T1 shell, and the model are landed. The shell is
read-only until `F`; there is no dashboard. The pure reducer is in `src/frontier.rs`;
`src/tui/live.rs` is the pure adapter from the T2a forest and that reducer to
nom rows. The prefetch view is the T2a bottom-up dependency forest: one row per
package, one root per pending package with no pending dependent, display-only
`?` leaves for dependencies outside the pending set, and the real
cached/stale/partial/missing/built badges. The `install N packages` total is
header context, not a tree row. T2b adds the live glyphs, waiting counts,
timers, grouped summary and ANSI-16 palette. T2e streams the real fetch command
and polls the real cache for `.part` bytes. T2f turns a nonzero exit into the
repair card, freezes the failed row and blocked dependents, and adds the `g`
ledger. T3a adds the PRE-FLIGHT gates from `fetch::plan_observed` and the `l`
log of the real captured lines. T3b adds the read-only install gate from
`install::preflight`. T3c runs the attached install with the CLI's exact
`Options` and restores the terminal. T3d adds the read-only post-install
receipt (`post_install::collect`). Sim 32 proves the gate is read-only; sim 33
proves the badges; sim 34 proves the live fetch, the real bytes, the gates, the
log and the one state write; sim 35 proves the failure freeze; sim 36 proves
the attached install, the receipt and the terminal restore.

Next action: T4 is closed except the keymap overrides. `--no-motion`, the ASCII
pass and the 2,000-package performance pass are landed: the budget measures
7.7 ms static and 10.4 ms live against 16 ms, and a sweep test proves every
screen is ASCII in `--ascii`. Still open from T3: the receipt's attached `p`.
The tree reads `check::collect`, `progress::collect` and `fetch::plan`; it does
not collect its own facts.
