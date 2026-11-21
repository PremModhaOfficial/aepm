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
| `CI (Linux)` — required | a tree that does not build, lint or test | deterministic | ~60s wall, 4 legs compile the same tree, ~1 flaky surface per leg | caught every compile/test break in the sample: 4 runs, all three legs red for one defect | measured (43045640650, 42488229442, 42487635874, 42452318081) | **KEEP**, no action on the four legs (`docs/CI-ARCHITECTURE.md` §4 item 11) | high; flips if a leg stops catching anything only it can see |
| `Arch simulation` — required | behaviour claims that FakeRunner units cannot make: pacman side effects, install paths, TUI under a pty | deterministic | 183s median per PR, 266–330s on main pushes, 118–128s of it an image build | 56 scenarios; the only red in the window was a real chaos-scenario failure (43434768093) | measured | **KEEP** | high; flips if scenario selection is ever wrong in the *unsafe* direction (a `sim/` change selecting nothing ran until #144) |
| `Review Gate` — required | a merge while the review holds an unresolved blocking finding | deterministic wrapper around an LLM verdict | 26 of 43 red runs were not about the change: 17 stale-after-rebase, 9 false; 775 lines of shell | **0 independent catches** — it restates the reviewer's verdict; it never found anything the reviewer had not | measured + documented root cause (§8) | **KEEP required, reduce its noise**: the staleness is `strict: true`, not the gate; merge queue would fix it but is unavailable to a user-owned repo (§8). Options A/B/C in §3 item 5 | medium; flips to DEMOTE if option C (block on findings, report staleness) is refused and the noise stays |
| `PR Agent` (review) | an agent-authored change merging with a defect a human would have caught | LLM | 62,073 tokens / 1 AI call per review; 1–8 min latency; paid subscription; **substrate now a community legacy fork** of Qodo's, pinned by digest (§8) | real catches: #146 6 findings, 3 active, all real and fixed (pagination, unguarded API call, regex FP); #99 32; #133 7; #145 5. **False negatives, measured 2026-11-19: 4 of 11 reviews returned zero findings, 3 of them on diffs ≥70 lines** — #144 (234 lines, 7 files, a shell rewrite) drew a 775-byte "No concerns found", while #146 (410 lines, the same surface) drew 6 | measured | **KEEP for code-change PRs; it is blind on claim-change PRs** — its unit of work is a finding, so a PR whose only job is to make a prose claim true cannot be reviewed by it at all (#134: two claims, 0 findings, 18,312 in / 19,623 out). ADD §4a-1 and §4a-2 | high; flips if `extra_instructions` gains claim verification and the zero-finding rate on ≥70-line diffs does not fall |
| `Scheduled audit` | lockfile, toolchain and advisory drift that no PR touches | deterministic | one run a week, ~0 minutes | **0 runs**: added 2026-11-17, first cron Monday 2026-11-23. No issue ever opened | measured (workflow state `active`, 0 runs) | **UNPROVEN — shadow** | medium; flips when the first drift opens one issue, or a seeded drift fails to |
| `Dependabot` | dependency rot | deterministic | monthly PRs, each costing a full CI+Sim run | not measured here | none | **KEEP** (out of scope) | — |

## 2. Gate scripts — fifteen deterministic checks

All fifteen are deterministic, and **none fired in the last 60 red runs**: every
red was a compile, test, fmt, packaging, image-build, provider or review-gate
failure. That is the correct shape for a cheap check that names an incident in
its introducing commit, so the default verdict is KEEP — with three rows where the
cost is duplication rather than runtime.

They do **not** all run in one place, and the `runs in` column is the point: a
gate that runs nowhere surfaces nowhere, so where it executes decides whether a
failure is visible at all. Most are steps of `bash ci.sh`, and so one red `Run CI
script` step inside `CI (Linux)`. The exceptions: `gate-coverage.sh` is its own
`ci.yml` job; `sim/check-scenario-numbers.sh` runs in `Sim`;
`gate-scheduled-audit.sh` in the `scheduled-audit` workflow; `review-state.sh` in
the two review workflows; `proof.sh` in no workflow at all.

| artifact | prevents | cost | real catches | evidence | verdict | runs in |
|---|---|---|---|---|---|
| `scripts/gate-coverage.sh` + `coverage-floor.txt` | coverage quietly falling below a measured floor | ~12s | introduced in #83, which exists because three drifts shipped green | anecdotal (commit), measured (job step 11.6s avg) | **KEEP** — floor is out of scope to lower | `ci.yml` (its own `Coverage (floor enforced)` job) |
| `scripts/gate-scenarios.sh` | a `src/` change with no scenario, or scenarios the diff cannot reach | 0.1s to select | caught the case that motivated it: a docs diff selecting 27 of 56 scenarios (218s) | measured (#143, #144) | **KEEP** — this is the strongest value-per-second in the ledger | `ci.sh`, and `sim.yml` for selection |
| `scripts/gate-pkgbuild-version.sh` | `pkgver` drifting from `Cargo.toml` | <1s | #9/#94 | anecdotal | **KEEP** | `ci.sh` |
| `scripts/gate-state-machines.sh` | an undocumented state machine, or a doc drifting from code | ~1s incl. `--self-test` | #45/#47 | anecdotal | **KEEP** | `ci.sh` |
| `scripts/gate-scheduled-audit.sh` | the release-time audit being skipped | <1s | the driver of §1's scheduled audit | anecdotal | **KEEP** | `scheduled-audit.yml` |
| `scripts/gate-review-selfcheck.sh` | the gate's reporting block losing its shape | ~1s plus 210 lines to maintain | #112 (an unreadable head read as superseded) | measured (the fix), anecdotal (the cost) | **MERGE** into a script the workflow calls (§3 item 2) | `ci.sh` |
| `scripts/check-review-gate.sh` | the gate's reader regressing | ~2s plus 237 lines and its own fake `gh` | #99; and it caught the prose-quoted-marker defect on #146 | measured | **KEEP**, MERGE the two fake-`gh` adapters (§3 item 1) | `ci.sh` |
| `scripts/check-sim-numbers.sh` | a duplicate scenario number | <1s | #61/#64 | anecdotal | **MERGE** into `sim/check-scenario-numbers.sh`, which covers more (§3 item 3) | `ci.sh` |
| `scripts/review-state.sh` | merging on a stale or missing review | 328 lines for one question | #99, #111, #112, #115 | measured | **KEEP pending the §1 `Review Gate` decision** — it is the gate's whole implementation | `pr-agent.yml`, `review-gate.yml` |
| `sim/check-scenario-numbers.sh` | duplicate numbers across `sim/scenarios/` **and** `sim/vm/` | <1s | #82 | anecdotal | **KEEP** — strictly stronger than the row above | `sim.yml`, `sim/run.sh` |
| `sim/check-image-tag.sh` | two concurrent worktrees colliding on one image tag | <1s | #60/#63 | anecdotal | **KEEP** | `ci.sh` |
| `sim/check-build-retry.sh` | the BuildKit retry being silently deleted | <1s | #91 | anecdotal | **KEEP** | `ci.sh` |
| `scripts/proof.sh` | a claim made without a head, an ahead/behind count, or a fresh evidence file | ~2s | the honesty rules it anchors | anecdotal | **KEEP**, CUT its plan-percentage section (§3 item 4) | nothing — run by hand |
| `scripts/gate-doc-claims.sh` | `docs/CI-ARCHITECTURE.md` or `docs/research/ledger.md` disagreeing with their own arithmetic, their own tables, or where a check actually runs | ~1s | #147: four of them in prose no reader had checked against the tables | measured (#147) | **KEEP** | `ci.sh` |
| `ci.sh` | any of the above being skipped | 96 lines, 11 shell checks in sequence; the only place that knows the order | runs on every local gate and inside `CI (Linux)` | measured | **KEEP**, MERGE the ordering into the gate module (§3 item 5) | `ci.yml` (`CI (Linux)` job) |

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
5. **`Review Gate`'s noise**, not the gate itself. *Cost:* 26 of 43 red runs were
   not about the change, and 775 lines of shell support it. *Benefit:* 0
   independent catches, but the comment beside it is the factory's brake #2 and
   does have catches. The documented cause of the noise is `strict: true` plus no
   merge queue (§8), so three options, cheapest first: **A** stop demanding
   up-to-date branches (drops all 17 stale reds; cost: a merge against an older
   base, and a semantic conflict handled by the merge commit); **B** keep strict
   and auto-request a review on each rebase (cost: 2× 62k tokens per PR);
   **C** block only on unresolved findings and report staleness without blocking
   (a semantics change, so it needs the owner's approval). Rollback for all three
   is the current setting. **Not mine to decide**: branch protection and the
   review workflows belong to thread `9c075c1c`.

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

## 4a. Promoted by measurement, 2026-11-19

1. **Claim verification as a required output, not a hoped-for finding.** A PR that
   only asserts something — a glossary row, a state-machine paragraph, a gate's
   own documentation — has no defect for a finding-hunter to find, so it gets zero
   findings and an unearned "No concerns found". Measured on #134: two prose
   claims, +49 lines of test asserting them, zero findings, and the reviewer
   neither confirmed nor refuted either claim (the claims do hold; the review did
   not check). **ADD** one instruction: for every claim the diff asserts, state
   `confirmed` or `refuted` with a `file:line`. Cost: a few output tokens. Benefit:
   the repo's most common PR shape becomes reviewable. Owner: `.pr_agent.toml`
   (`extra_instructions` is all Rust safety rules today), which is the review
   thread's surface, not mine.
2. **A prose-only diff must not read as approval.** With (1) in place, the
   `--gate` reader can distinguish "no findings because nothing is wrong" from
   "no findings because findings cannot exist here". **ADD** to the gate report:
   when the diff touches no `src/`, `tests/` or `sim/` path, say `not applicable`
   rather than `passed`. Cheap, and it removes the false green that (1) would
   otherwise leave behind.

Also recorded: the reviewer **deletes** the comment it updates. All five
"Persistent review updated to latest commit" notices on #134 point at
`#issuecomment-7000612126`, now `404`. A dead pointer is a silent "no review", and
it is why #134's gate reads "no review comment" rather than "stale". Not
configurable from here; recorded for the review thread.

## 5. Shadow-mode plan — measure before demoting or deleting

| experiment | what | window | success criteria | rollback |
|---|---|---|---|---|
| E1 `Review Gate` advisory | report the verdict, do not block, for 20 PRs; count merges whose review held an ACTIVE finding | 20 PRs or 3 weeks | ≤1 merge with an unfixed ACTIVE finding; red-run noise falls ≥20 | re-require the check |
| E2 reviewer recall | 3 seeded bugs on a throwaway branch, 3 reviews; recall and false positives | 3 reviews | recall ≥ 2/3, FP ≤ 1 per review | none needed (throwaway branch) |
| E3 `AGENTS.md` ablation | 3 real tasks with and without the review-surface section, watching for forbidden-file edits | 3 pairs | the section changes behaviour ≥ 1 time, else CUT it to a pointer | restore the section |
| E4 scheduled audit fires | wait for the Monday cron, then inject one drift and check it opens exactly one issue | 1 cron + 1 injection | one issue, correct body, closed on recovery | disable the workflow |
| E5 scenario fan-out | 4-way fan-out of the serial loop, 3 harness-change runs | 3 runs | scenarios 179–199s → under 90s, no new flake | revert to the serial loop |

## 6. What would flip each verdict

- `CI (Linux)` KEEP → **no action on the four legs**, which is what
  `docs/CI-ARCHITECTURE.md` §4 item 11 already decided: 0s wall clock and $0
  against a 4× flake surface, an accepted trade rather than plan work. A leg flips
  only if it stops catching anything its siblings cannot.
- `Review Gate` → **DEMOTE** if option A or C is refused and the 17 stale reds
  stay; **KEEP required** if E1 finds a merge that shipped a real ACTIVE finding.
  **Deepen** (typed record) if E2 shows high recall and the only problem is the
  comment seam. Merge queue, which would have settled it, is unavailable here: the
  repo owner is a user account, not an organization (§8).
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
repo with fewer than ~10 gates; at 15 gates, 5 workflows and 26 false red runs, it
paid for itself once. Shrink it next time by keeping only §1, §2's duplicate rows
and §5.

## 8. External corrections, 2026-11-19

Facts that arrived from a clean-context research thread after the verdicts above
were written. Each one is sourced and dated; where a claim is unverified it says
so, and the verdict that depends on it is named.

| claim | source, read date | effect on this ledger |
|---|---|---|
| Merge queue is available to **public repositories owned by an organization**; personal-account public repos are excluded. | GitHub docs, gated-features reusables, 2026-11-19 | **Does not apply here**: `PremModhaOfficial` is a `User` (verified `gh api users/PremModhaOfficial`). §3 item 5's A/B/C stand. |
| A merge queue replaces "require branches to be up to date", and each required check must also handle `merge_group`. | docs.github.com, Managing a merge queue, 2026-11-19 | The 17 stale-after-rebase reds would vanish here *if* the repo were org-owned. Recorded as the reason `strict: true` is the cause, not the gate. |
| Job checks from a `workflow_run`-triggered workflow **do not satisfy a required status check**, even on the head commit; checks written with the Checks API to the head do. | docs.github.com, Troubleshooting required status checks, 2026-11-19 | Confirms `review-gate.yml`'s Checks-API-on-head design as the only correct shape. The gate is not badly built; it is correctly built over a slow seam. |
| Cache: 10 GB/repo, 7-day unused eviction, now **evicted hourly**; exceeding 10 GB needs a paid account. PR-created caches are scoped to `refs/pull/.../merge` and restorable only by that PR's re-runs. | github.blog changelogs 2025-09-29 and 2025-11-20; docs.github.com caching reference, read 2026-11-19 | **Strengthens the #145 park**: a 3.5 GB image cache is a third of a non-shareable budget, and the measured 70s was a same-ref re-run — a mechanism the docs predict, so it was never evidence of a main-seeded steady state. |
| `pr-agent` supports `--json-output <path>` for `review` in v0.50.0; the project is now a community-maintained legacy fork of Qodo's, and Qodo Merge carries a sunset notice. | `pr_agent/cli.py` at v0.50.0, released 2026-11-07; repo README; docs.qodo.ai, read 2026-11-19 | The 775-line markdown parser is **optional**, not forced — this is the deepening in §4 item 3, now with a flag name. New risk: the substrate is unmaintained; the digest pin is what protects us, and upgrading it is no longer a routine. |
| CodeRabbit's OSS plan covers public repos at zero cost; Copilot code review needs a paid plan or an org. | docs.coderabbit.ai pricing; github.blog 2026-04-27, read 2026-11-19 | No change: this repo already has a reviewer, and a second LLM on the same diff doubles cost for unmeasured recall. Recorded as the fallback if the fork dies. |
| `cargo nextest` 0.9.152 (2026-11-13) has nothing new that lowers the break-even for a 22s suite. | nexte.st changelog, 2026-11-19 | V4 unchanged. |
| Required checks behind `paths:` filters stay Pending. | docs.github.com, Triggering a workflow, 2026-11-19 | V5 unchanged. |

| **Measured in this repo (not an external claim):** of 11 reviews, 4 returned zero findings — #112 (77 lines), #134 (74), #137 (26), #144 (234, 7 files). Same reviewer, same surface, opposite result on #146 (410 lines, 6 findings). | `gh pr view --json additions,deletions,changedFiles` plus the review comment's byte size and finding count, 2026-11-19 | Recall is not merely unmeasured, it is **inconsistent on similar inputs**. V2 is re-priced as "keep for code changes, blind on claim changes". |

**What this cost and bought.** One delegate, ~10 minutes. It overturned the *fix*
for V1 (merge queue, unavailable here — worth knowing before proposing it) and
moved V2's seam from "unavoidable parsing" to "a flag we are not using". It
confirmed V3 and V4. No verdict flipped on a claim without a source.

## 9. open-code-review (Alibaba), measured 2026-11-19

`alibaba/open-code-review` v1.13.13, static `linux-amd64` binary (no npm needed).
Everything below was run from this checkout; `--preview` needs no model key and
costs nothing, so the coverage numbers are free and exact.

**The gate contract is still ours.** `ocr review --help`: *"Budget-only partial
reviews with usable coverage exit 0."* Exit 0 means completed, **not** "no
defect"; 1 means fatal. So it cannot sit behind a required check any more than
pr-agent can. Its `--format json` envelope does carry `comments: []` **always
present** with a `session_id`, which is precisely the primitive the zero-finding
review lacks — so it proves the gate fix is a flag (`--json-output`), not a
775-line subsystem.

**It cannot read the prose, and this repo is half prose.** Files with an
extension outside the code set are dropped as `unsupported_ext` before review:

| | value |
|---|---|
| PRs where **every** changed file is excluded | **5 of 15** (#147, #128, #143, #133, #119) |
| files reviewable / files excluded | **28 / 27** |
| #134 (two prose claims + tests) | 2 reviewed — the two test files; GLOSSARY.md and docs/STATE-MACHINES.md excluded |

So on #134 it would return zero findings for a *stronger* reason than pr-agent
did: the claims are not in the input. The two reviewers' blind spots are
**different, not ranked** — pr-agent reads prose but emits nothing when it finds
nothing; OCR has the contract but cannot see prose at all. "Alongside" is real
and asymmetric: 9 code-visible PRs, not 15.

**The key blocker is gone.** Delegate mode uses the *host* agent's model and
credentials (`README` L157: "No separate LLM configuration or credentials are
needed in OCR"), so a shadow pass costs no new key. It does confound the
comparison — pr-agent runs `deepseek-v4.1-flash`, the host runs something else —
so a same-model A/B still needs a provider key, and a delegate-mode pass measures
*pipeline* (diff selection, rule matching, output contract), not model.

**Corrected from §9's first draft** (written before the preview pass): the replay
is not "blocked on a key". It is blocked on nothing for 9 PRs, and on a key only
for a like-for-like model comparison.
