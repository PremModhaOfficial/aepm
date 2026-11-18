# The factory this repository runs on

Every agent run on `aepm` is one **run** of one **task**, and every run follows
the same contract. The words are the ones in the `software-factory` skill: a
**task** is a kind of work, a **run** is one execution of it on one **runner**,
and a run ends — it never waits for a human.

This file is the contract a run's brief must satisfy. If a brief disagrees with
it, this file wins.

## Slots

| Service | Filled by | Consequence for a run |
|---|---|---|
| Ticket tracker | GitHub Issues on `PremModhaOfficial/aepm` | a run's work is a numbered ticket, and the ticket is claimed (`claimed` label) before a branch exists |
| Git host | GitHub: branches, PRs, reviews, required checks | a run pushes a branch and opens a PR; it never merges |
| Orchestrator | the T3 Code thread that started the run | it records which runs are queued, in flight and finished |
| Runner | one git worktree per run, disposable | nothing on it survives the run: the only memory is the ticket tracker, the git host and this repository |
| Observability | Actions run pages, plus `scripts/proof.sh` | a claim with no log path is not evidence |

There is no database and no scheduler state to trust. A run that crashed is
found by looking at the ticket tracker and the git host, never by remembering.

## Tasks

Four kinds, each with one owner inside the run, chosen with `ds-help`:

| Task | Trigger | Writes | Next trigger |
|---|---|---|---|
| **implement** | a claimed ticket | a branch and a PR | the review run, and CI |
| **review** | a PR opened or its head pushed | review comments, and a check | the human merge decision |
| **ratchet** | a merged change that raises a measured number | a PR that raises the floor to it | CI |
| **explore** | a human asking what is true, or a claim nobody has re-read | tickets; never code | an implement run per ticket |

`ratchet` exists because a coverage floor only ever moves up by hand; the run
that moves it is mechanical and must not touch code. `explore` exists because
this repository's honesty depends on its plans matching its code, and that
drift is invisible until someone reads for it.

## Brakes

Every trigger is an accelerator, and accelerators without brakes produce
volume, not software. The three brakes, in the order they catch things:

1. **Automated checks** — `./ci.sh` and the Arch simulation, both required on
   `main`, `strict` so a stale branch cannot merge.
2. **Automated review** — a separate run reads the diff cold against
   `GLOSSARY.md` and the ticket, and its verdict is input to a human, never
   permission to merge.
3. **Human review** — a person merges. What the person catches becomes a new
   check or a sharper review prompt; that is the only mechanism by which this
   factory improves.

## What every brief must say

An implement run's brief states all nine, and a brief that omits one is
returned rather than guessed at:

1. **Task and ticket** — which of the four tasks, and the ticket number.
2. **Restatement** — one line naming the goal and the smallest change expected
   to meet it (`ds-mode`).
3. **Read first** — the files and documents the run must read before editing,
   in order.
4. **Skill** — the `ds-help` pick for this work, and one line why.
5. **Acceptance** — what makes it done, as a command whose exit code decides.
6. **Brakes** — the gates to run, with their exit codes and log paths.
7. **Bounds** — the safety rules that do not bend: nothing runs `pacman`,
   `yay`, `makepkg` or `systemctl` against the development host; runtime claims
   come from `./sim/run.sh`; the device is capped at 60% CPU.
8. **Stop condition** — what the run must not do: merge, force-push a shared
   branch, rewrite history, or widen its own scope.
9. **Report** — the shape the final message takes: goal line, changed files,
   each check with its result, and what is unproven.

## Loop caps

- A run that fails the same check twice stops and reports; a third variation of
  the same idea is a wasted runner. `ds-unstick` is the exit.
- A run whose last activity is more than 15 minutes old is hung, not thinking.
  The orchestrator assumes that and reclaims the ticket rather than waiting.
- A ticket carries `claimed` for one run only. Reclaim needs a comment saying
  why the first run is dead.

## What a run must never do

- Merge its own PR, or merge any PR without required checks green.
- Present a same-context review as a fresh-context one.
- Turn a gate into a silent skip that prints success.
- Claim a number without naming the command that printed it.
