# PR triage — 2026-11-21

State read from the REST API at `main` @ `551afaa`. Every count below names the
command that produced it; re-run before quoting. The pile this describes has
since resolved: `#154` and `#128` merged, `#147` and `#149` closed on
2026-11-21. What follows is the record of that read, not a live plan.

## What the pile actually is

```
gh api 'repos/PremModhaOfficial/aepm/pulls?state=all&per_page=100' --paginate
→ 94 PRs: 86 merged, 4 closed unmerged, 4 open
```

The "~105 refs and a stacked pile" this task was briefed on is one day stale.
`#129`–`#153` almost all merged on 2026-11-19/21. The four unmerged closes are
`#22`, `#75` (superseded product work), `#145` (sim layer cache, failed its own
measurement) and `#146` (typed-block shim, replaced by `#142`).

**Four PRs are open.** That is the whole pile.

| # | state | branch | mergeable | behind | files |
|---|---|---|---|---|---|
| 128 | open | `docs/review-gate-required` | true | 0 | `.github/PR-AGENT.md`, `AGENTS.md`, `scripts/gate-review-selfcheck.sh` |
| 147 | open | `docs/ci-failure-inventory` | **false** | 7 | `ci.sh`, `docs/CI-ARCHITECTURE.md`, `docs/research/*`, `scripts/gate-doc-claims.sh` |
| 149 | open | `ci/ocr-advisory-review` | true | 3 | `.github/ocr/*`, `.github/workflows/ocr-review.yml`, `ci.sh`, `docs/OCR-REVIEW.md`, `scripts/check-ocr-review.sh` |
| 154 | open | `docs/ci-architecture-truth` | true | 0 | `ci.sh`, `docs/CI-ARCHITECTURE.md`, `scripts/check-ci-architecture.sh` |

## Failure classes, with the log line

`gh api '.../actions/workflows/<id>/runs?per_page=100'`, one query per workflow:
`CI` 27 runs / 2 failures, `Sim` 27 / 0, `Review Gate` 23 / 0, `Review PR #<n>`
23 / 2, `OCR Review (advisory)` 3 / 3. Five queries, not one page: each count is
that workflow's own most recent runs, so they share no total and no window. The
brief's "35 Review Gate failures" no longer reproduces — that window closed
when `#142` landed.

**F1 — browser golden flake (infrastructure).**
`Prototype (web demo matches the goldens)`, run `44905058059` on `f451a8e`, a
docs-only PR:

```
FAIL 75/76
 - tui-120x40.txt: spawnSync google-chrome ETIMEDOUT
```

75 of 76 goldens pass; one browser spawn times out. The PR cannot cause this. The
job is not a required check, so it reds `CI` without blocking a merge — noise that
trains people to ignore a red.

**F2 — provider timeout (infrastructure, correctly red).**
`Review`, run `44897913191` on `b518081`, job duration **1835s**:

```
litellm.Timeout: APITimeoutError - Request timed out.
  timeout value=900.0, time taken=900.32 seconds
Failed to generate prediction with openai/deepseek/deepseek-v4.1-flash
WARNING __main__._fail_on_recorded_tool_error - Tool reported success but
  recorded a failure; failing the action
```

Two 900s attempts, then a correct red. The machinery is honest here; the cost is
15 minutes of wall clock per hung call inside a 45-minute job budget.

**F3 — OCR cannot complete a multi-file review (machinery bug).**
Runs `44789504504`, `44897913174`, and one rerun of each:

```
Error: review failed: 4 of 4 selected item(s) failed
"status": "failed", "budget_exceeded": true
```

4 items, 349–451 total input tokens, 3 seconds, `budget_exceeded` at a 120,000
budget. It clears `ocr llm test` (a single trivial call) and fails every real
per-file call. Deterministic, not the documented 1-in-2 flake.

**F4 — a conflicting head runs no workflow at all (machinery, highest severity).**
`#147` head `1f6d484`: `mergeable=false`, and

```
gh api '.../actions/runs?branch=docs/ci-failure-inventory&per_page=5'
→ newest runs are on 6d085d1; nothing on 1f6d484
```

GitHub cannot build the `refs/pull/N/merge` commit for a conflicting head, so
`pull_request` workflows never start. The PR gets zero checks, the three required
contexts can never appear, and the PR is blocked forever with no visible reason.
This is the one failure mode no dashboard can show, and it is why `#147` shows
no checks at all rather than a red one.

## Per-PR decision

### #154 — MERGE-AS-IS (after its review clears)

Owns `docs/CI-ARCHITECTURE.md` and its gate `scripts/check-ci-architecture.sh`.
Up to date, 23 assertions, `./ci.sh` green. Its last review was `complete: true`,
`coverage: full`, verdict `needs_review` with 4 findings, all fixed in later
commits; the current red is staleness only (`review_head` behind head by two
commits).

### #147 — SUPERSEDED-CLOSE (by #154)

Both edit `ci.sh` and `docs/CI-ARCHITECTURE.md`. `#154` is the later, rebased,
gated version of the same file: it carries the measured baseline, the ranked
changes with Files/Measure/Rollback, and a self-test. `#147` is 7 behind,
conflicting, has zero check runs on its head (F4), and adds
`scripts/gate-doc-claims.sh`, which in that branch is a second, weaker
claim-checker over the same document and the research ledger — two owners for
one fact. The path is now this document's own gate; nothing else checks it.

Its one unique artifact is the research ledger (`docs/research/ledger.md`,
`external-state-2026-11-19.md`). That is history, not machinery: it belongs in
the `#147` branch as a closed record, and the facts that matter were folded into
`#154`.

### #149 — STALE-CLOSE (drop the second reviewer)

Evidence says drop, not merge as advisory:

- F3: it has never completed a review of more than one changed file. 3 of 3
  failures are "all N items failed"; its successes were single-file runs.
- It spends a model call on **every** push to every PR, on the same subscription
  that already times out at 900s (F2). Two reviewers on one endpoint double the
  load that is already the critical path.
- Its value was to be a second, independent signal on claim-change PRs, which is
  the class where pr-agent returned `No concerns found` on a 234-line diff. A
  reviewer that cannot finish a 4-file diff cannot cover a 234-line one.
- Keeping it advisory still costs: a red advisory check on every PR is the noise
  F1 already produces.

`#149`'s genuinely useful output was 13 real findings on its own workflow, all of
which are fixed on that branch and none of which depend on OCR continuing to run.

### #128 — KEEP-WIP (needs its owner)

`mergeable: true`, 0 behind, `CI` and `Sim` green on head `0b81fe4`, `Review PR
#128` in progress. It edits `.github/PR-AGENT.md`, `AGENTS.md` and
`scripts/gate-review-selfcheck.sh` — the review machinery that thread
`9c075c1c` owns. Nothing here blocks it; it needs its review to land. Do not
touch.

## Merge order and why

1. **`#154`** — it owns `docs/CI-ARCHITECTURE.md` and the gate script. Landing it
   first means #147's close is a no-op (its unique work is research history) and
   every later PR inherits a self-checking document.
2. **`#128`** — independent file set (`.github/PR-AGENT.md`, `AGENTS.md`), but it
   is the other thread's; it merges when its review clears.
3. Nothing else. `#147` and `#149` are closed, not merged.

`strict: true` means each merge invalidates the next PR, so no order avoids the
rebase-and-re-review cycle; the order only decides who pays it. `#154` first
leaves `#128` behind `main`, so `#128` needs an update and its pinned review
goes stale — one rebase, one re-review. Closing `#147`/`#149` removes the two
candidates that would otherwise pay it as well, which is why that part is free
and the `#128` part is not.

## The systemic finding, stated once

One of the four open PRs is blocked by F4: `#147`, the only head in the table
whose merge ref cannot be built. The other three are not blocked by anything
they wrote either, but not by F4: `#128` and `#154` are `mergeable: true` and 0
behind, waiting on their own review runs, and `#149` is 3 behind, so `strict:
true` asks for an update before it can merge. That, plus `strict: true` turning
every merge into a rebase for every other PR, is a branch-protection property,
not a code defect, and it is the reason the pile grew in the first place. Section 3 of
`docs/CI-ARCHITECTURE.md` records the options and their costs; changing it is a
one-time admin decision, not a PR.
