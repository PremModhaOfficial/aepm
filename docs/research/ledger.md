# The machinery ledger

Every workflow, gate script, document, `pr-agent` setting and required check is a
**hypothesis**: it costs something and prevents something. This file holds one row
per artifact so a verdict can be re-opened with a measurement instead of an
opinion. No deletions came out of this pass — verdicts and proposed pull requests
only, one change per PR, each with its rollback in the row.

**How to read it.** `cost` and `benefit` are measured where a number exists, and
say so; `evidence` is `measured` (a run id, a PR, a command), `anecdotal` (a
commit message, a memory of an incident) or `none`. English in these rows is a
claim about this repo on **2026-11-19**, not a general statement.

Commands behind the numbers below:

| number | command |
|---|---|
| failing runs, classified | `gh run list --status failure --limit 60` then `gh run view <id> --log-failed` |
| job wall clock | `gh api repos/{owner}/{repo}/actions/runs/<id>/jobs` |
| cache inventory | `gh api repos/{owner}/{repo}/actions/caches --jq '.actions_caches|length'` |
| required checks | `gh api repos/{owner}/{repo}/branches/main/protection` |
| review cost | the `Agent run details` block in a review comment |
| why an artifact exists | `git log --oneline --diff-filter=A -- <path>` |

---

## 1. Required checks and workflows

| artifact | purpose (the failure it prevents) | type | cost | benefit (real catches) | evidence | verdict | confidence / what flips it |
|---|---|---|---|---|---|---|---|
| `CI (Linux)` — required | a tree that does not build, lint or test | deterministic | ~60s wall, 4 legs compile the same tree, ~1 flaky surface per leg | caught every compile/test break in the sample: 4 runs, all three legs red for one defect | measured (43045640650, 42488229442, 42487635874, 42452318081) | **KEEP**, MERGE the four legs (§3) | high; flips if a leg stops catching anything only it can see |
| `Arch simulation` — required | behaviour claims that FakeRunner units cannot make: pacman side effects, install paths, TUI under a pty | deterministic | 183s median per PR, 266–330s on main pushes, 118–128s of it an image build | 56 scenarios; the only red in the window was a real chaos-scenario failure (43434768093) | measured | **KEEP** | high; flips if scenario selection is ever wrong in the *unsafe* direction (a `sim/` change selecting nothing ran until #144) |
| `Review Gate` — required | a merge while the review holds an unresolved blocking finding | deterministic wrapper around an LLM verdict | 26 of 43 red runs were not about the change: 17 stale-after-rebase, 9 false | **0 independent catches** — it restates the reviewer's verdict; it never found anything the reviewer had not | measured | **DEMOTE** (advisory) or deepen (§4 item 1) | medium; flips if the gate blocked a merge that later proved wrong — no such case in the window |
| `PR Agent` (review) | an agent-authored change merging with a defect a human would have caught | LLM | 62,073 tokens / 1 AI call per review; 1–8 min latency; paid subscription | real: #146 3 active findings, all real and fixed (pagination bug, unguarded API call, a regex false positive); #145 4; #143 2; #133 4 | measured | **KEEP as advisory** (already is) | high; flips if a seeded-bug probe shows recall below ~2 of 3 |
| `Scheduled audit` | lockfile, toolchain and advisory drift that no PR touches | deterministic | one run a week, ~0 minutes | **0 runs**: added 2026-11-17, first cron Monday 2026-11-23. No issue ever opened | measured (workflow state `active`, 0 runs) | **UNPROVEN — shadow** | medium; flips when the first drift opens one issue, or a seeded drift fails to |
| `Dependabot` | dependency rot | deterministic | monthly PRs, each costing a full CI+Sim run | not measured here | none | **KEEP** (out of scope) | — |

## 2. Gate scripts — fourteen deterministic checks

All fourteen are deterministic, run inside `bash ci.sh` (so a failure appears as
one red `Run CI script` step), and **none fired in the last 60 red runs**: every
red was a compile, test, fmt, packaging, image-build, provider or review-gate
failure. That is the correct shape for a cheap check that names an incident in
its introducing commit, so the default verdict is KEEP — with three rows where the
cost is duplication rather than runtime.

| artifact | prevents | cost | real catches | evidence | verdict |
|---|---|---|---|---|---|
| `scripts/gate-coverage.sh` + `coverage-floor.txt` | coverage quietly falling below a measured floor | ~12s | introduced in #83, which exists because three drifts shipped green | anecdotal (commit), measured (job step 11.6s avg) | **KEEP** — floor is out of scope to lower |
| `scripts/gate-scenarios.sh` | a `src/` change with no scenario, or scenarios the diff cannot reach | 0.1s to select | caught the case that motivated it: a docs diff selecting 27 of 56 scenarios (218s) | measured (#143, #144) | **KEEP** — this is the strongest value-per-second in the ledger |
| `scripts/gate-pkgbuild-version.sh` | `pkgver` drifting from `Cargo.toml` | <1s | #9/#94 | anecdotal | **KEEP** |
| `scripts/gate-state-machines.sh` | an undocumented state machine, or a doc drifting from code | ~1s incl. `--self-test` | #45/#47 | anecdotal | **KEEP** |
| `scripts/gate-scheduled-audit.sh` | the release-time audit being skipped | <1s | the driver of §1's scheduled audit | anecdotal | **KEEP** |
| `scripts/gate-review-selfcheck.sh` | the gate's reporting block losing its shape | ~1s plus 210 lines to maintain | #112 (an unreadable head read as superseded) | measured (the fix), anecdotal (the cost) | **MERGE** into a script the workflow calls (§3 item 2) |
| `scripts/check-review-gate.sh` | the gate's reader regressing | ~2s plus 237 lines and its own fake `gh` | #99; and it caught the prose-quoted-marker defect on #146 | measured | **KEEP**, MERGE the two fake-`gh` adapters (§3 item 1) |
| `scripts/check-sim-numbers.sh` | a duplicate scenario number | <1s | #61/#64 | anecdotal | **MERGE** into `sim/check-scenario-numbers.sh`, which covers more (§3 item 3) |
| `scripts/review-state.sh` | merging on a stale or missing review | 328 lines for one question | #99, #111, #112, #115 | measured | **KEEP pending the §1 `Review Gate` decision** — it is the gate's whole implementation |
| `sim/check-scenario-numbers.sh` | duplicate numbers across `sim/scenarios/` **and** `sim/vm/` | <1s | #82 | anecdotal | **KEEP** — strictly stronger than the row above |
| `sim/check-image-tag.sh` | two concurrent worktrees colliding on one image tag | <1s | #60/#63 | anecdotal | **KEEP** |
| `sim/check-build-retry.sh` | the BuildKit retry being silently deleted | <1s | #91 | anecdotal | **KEEP** |
| `scripts/proof.sh` | a claim made without a head, an ahead/behind count, or a fresh evidence file | ~2s | the honesty rules it anchors | anecdotal | **KEEP**, CUT its plan-percentage section (§3 item 4) |
| `ci.sh` | any of the above being skipped | 90 lines, 9 sequential calls; the only place that knows the order | runs on every local gate and inside `CI (Linux)` | measured | **KEEP**, MERGE the ordering into the gate module (§3 item 5) |

## 3. Top 5 CUT / DEMOTE / MERGE, with the evidence

1. **`pr-agent.yml:104-135` duplicates `.pr_agent.toml:9-42,127-135`** and says so
   ("Keep both in sync"). Its stated reason — working before the config file
   landed on `main` — expired when the file merged. *Cost:* a permanent second
   source of truth that no test compares; a setting changed in one place is
   silently stale in the other. *Benefit:* none measurable. **MERGE (delete the
   env block; keep the two API-key variables).** Rollback: restore the block.
   Owner is the review-machinery thread, not this one.
2. **`gate-review-selfcheck.sh` slices the workflow's YAML by stripping ten
   spaces** (`l[10:]`) and guards that with four greps. *Cost:* 210 lines and
   five mechanisms to answer "does the workflow call the gate". *Benefit:* it did
   catch #112. **MERGE: move the reporting block into
   `scripts/report-review-gate.sh`**, have the workflow `run:` it, and delete the
   slice, the marker greps and the fake `review-state.sh`.
3. **Two checkers for one namespace.** `ci.sh:15-16` runs
   `scripts/check-sim-numbers.sh` (scans `sim/scenarios/` only, and owns the
   `--self-test`); `sim.yml:30` runs `sim/check-scenario-numbers.sh` (scans
   `sim/scenarios/` **and** `sim/vm/`). *Cost:* they disagree — a duplicate
   between `sim/scenarios/` and `sim/vm/` is **green locally and red in CI**.
   *Benefit:* the weaker one carries the self-test. **MERGE: move `--self-test`
   into the stronger checker, point `ci.sh` at it, then delete the weaker.**
4. **`proof.sh` counts `- [x]` in `NEXT.md` as if it were a data structure.**
   *Cost:* a reworded checkbox silently changes the number every claim anchors
   to. *Benefit:* a real "how much of the plan is done". **CUT the
   plan-percentage section; keep head, ahead/behind, PR state and evidence age.**
   Lower confidence than the rows above — the checkbox list is the plan state.
5. **`Review Gate` as a required check** (row 1 of §1). *Cost:* 26 of 43 red runs
   were not about the change, and 775 lines of shell exist to support it.
   *Benefit:* 0 independent catches. **DEMOTE to advisory** — the factory's brake
   #2 is "automated review", which the comment already provides — or fix the seam
   (typed record). Rollback: re-require the check. **Not mine to decide**: branch
   protection and the review workflows belong to thread `9c075c1c`.

## 4. Top 5 ADD / STRENGTHEN, with the evidence

1. **A guard against a false green: a required check that passes while doing no
   work.** 7 of 20 recent `Sim` runs selected 0 scenarios and went green; #144
   fixes selection but nothing asserts that a required check *did* something.
   **ADD** an assertion that `Sim` ran ≥1 scenario, and that `CI (Linux)` ran the
   suite (not skipped). High severity: a false green is invisible by
   construction.
2. **A local/CI parity check.** The two scenario-number checkers disagree today
   (§3 item 3). Add a test that every check `ci.sh` runs is the same check CI
   runs, where both exist. Detectable now, cheap.
3. **A typed verdict record for the review** (the deepening in the architecture
   review, candidate 1): the reviewer's verdict becomes a check-run annotation
   read with `jq`, not prose parsed with `awk`. Turns 775 lines into ~40 and
   removes the failure class behind #140/#141/#142.
4. **A seeded-bug probe for the reviewer.** The LLM is the only gate whose recall
   is unknown: 62k tokens/review, and no measurement of what it misses. Seed
   three known bugs (safety invariant, error handling, uncovered side effect),
   measure recall and false positives. Cheap, and it is the only way to know
   whether a demote or a keep is right.
5. **A regression guard for the strict-rebase staleness.** 17 of 43 red runs were
   reviews staled by a rebase, and nothing measures that churn. Either request a
   review automatically after a rebase, or report "staled, not rejected"
   distinctly so a red gate does not read as a finding.

## 5. Shadow-mode plan — measure before demoting or deleting

| experiment | what | window | success criteria | rollback |
|---|---|---|---|---|
| E1 `Review Gate` advisory | report the verdict, do not block, for 20 PRs; count merges whose review held an ACTIVE finding | 20 PRs or 3 weeks | ≤1 merge with an unfixed ACTIVE finding; red-run noise falls ≥20 | re-require the check |
| E2 reviewer recall | 3 seeded bugs on a throwaway branch, 3 reviews; recall and false positives | 3 reviews | recall ≥ 2/3, FP ≤ 1 per review | none needed (throwaway branch) |
| E3 `AGENTS.md` ablation | 3 real tasks with and without the review-surface section, watching for forbidden-file edits | 3 pairs | the section changes behaviour ≥ 1 time, else CUT it to a pointer | restore the section |
| E4 scheduled audit fires | wait for the Monday cron, then inject one drift and check it opens exactly one issue | 1 cron + 1 injection | one issue, correct body, closed on recovery | disable the workflow |
| E5 scenario fan-out | 4-way fan-out of the serial loop, 3 harness-change runs | 3 runs | scenarios 179–199s → under 90s, no new flake | revert to the serial loop |

## 6. What would flip each verdict

- `CI (Linux)` KEEP → MERGE the four legs: already recommended; a leg flips only
  if it stops catching anything its siblings cannot.
- `Review Gate` DEMOTE → **KEEP as required** if E1 finds a merge that shipped a
  real ACTIVE finding. **Deepen** instead of demoting if E2 shows high recall and
  the only problem is the comment seam.
- Reviewer KEEP → **DEMOTE to a comment-only habit** if E2 recall is below 2 of 3.
- `scheduled-audit` UNPROVEN → KEEP on its first real catch; **CUT** if two cron
  cycles pass with no run.
- `gate-review-selfcheck.sh` MERGE → cancel if the reporting block must stay in
  YAML for a technical reason (it does not appear to).
- `check-sim-numbers.sh` MERGE → cancel if the two checkers ever diverge in the
  other direction (the stronger one missing a case the weaker one catches).
- `proof.sh` plan percentage CUT → cancel if someone reads that number to decide
  anything; if so, it earns its place and stays.
- Agent context: every `AGENTS.md` line stays unless E3 shows it does not change
  behaviour. No line is deleted on opinion.

## 7. What this lens costs

About half a session and one delegate, and it changed two verdicts I had already
published (the sim cache went from "rank 1" to "parked"; the review gate went from
"deepen" to "demote or deepen, decide first"). It would not be worth running for a
repo with fewer than ~10 gates; at 14 gates, 5 workflows and 26 false red runs, it
paid for itself once. Shrink it next time by keeping only §1, §2's duplicate rows
and §5.
