# CI architecture

What the checks cost, what they prove, and where the money and the minutes go.
Every number here names the command that printed it. Numbers measured on
2026-11-19 are from the Actions API run on that date; the ones dated 2026-11-21
were re-measured then, because two of them had moved enough to invert a
conclusion. `scripts/check-ci-architecture.sh`, run by `ci.sh`, fails when: a
workflow file's `name:` appears nowhere in this document; the sentence naming the
required checks stops naming all three; the `CI (Linux)` step column stops summing
to its own total; the quoted `ci.sh` invocation count drifts; the workflows
heading starts typing a number; or a named sim scenario matches no file. It
checks this file against the repository — it never calls `gh`, so a change to
branch protection is invisible to it by design, and the header used to claim
otherwise.

Scope: the machinery only — workflow structure, job split, caching, selection,
required-check design, and how a failure explains itself. Review policy lives in
`.github/PR-AGENT.md`, not here.

## 1. What we have, measured

### The workflows

The count is five on `main` and is asserted, not typed: `ci.sh` runs
`scripts/check-ci-architecture.sh`, which fails when a file in
`.github/workflows/` is missing from this table. That is why the heading no longer
carries a number — a workflow-adding PR (there is one open, `ocr-review.yml`) would
turn a typed "five" into a lie on merge, and the gate now catches that instead of
a reader.

| Workflow | Triggers | Jobs | Gating? | Wall clock, successes only (2026-11-21) |
|---|---|---|---|---|
| `CI` | `pull_request`, `push main`, `dispatch` | `MSRV (1.85)`, `CI (Linux)`, `Stable (tip)`, `Coverage (floor enforced)`, `Prototype (web demo matches the goldens)` | `CI (Linux)` only | median 65s, p90 74s, max 256s (n=24) |
| `Sim` | `pull_request`, `push main`, `dispatch` | `Arch simulation` | yes | median 10s, p90 244s, max 636s (n=49) — see the bimodality below |
| `Review Gate` | `workflow_run` of `PR Agent` | `Review Gate` | yes | median 10s, p90 13s, max 19s (n=21) |
| `PR Agent` | `pull_request` (`opened`, `reopened`, `ready_for_review`, `synchronize`), `issue_comment` | `Review` | no (writes the verdict) | median 456s, p90 896s, max 1401s (n=20) |
| `Scheduled audit` | weekly cron, `dispatch` | `Drift checks (pinned + stable)`, `One issue, not one per run` | no | n/a |

The wall clock column is printed by `gh run list --workflow <name> --limit N
--json createdAt,updatedAt`, subtracting `createdAt` from `updatedAt`, successes
only. Prefer this to any figure typed into this table: on 2026-11-19 the same
command gave `PR Agent` a median of 124s and `CI` 60s; two days later `PR Agent`
is 456s and `CI` is 65s. The review chain is the term that moves, and it is the
term every ranking below used to ignore.

The two `Scheduled audit` names are display names; the job ids are `audit` and
`report`.

`gh api repos/{owner}/{repo}/branches/main/protection --jq .required_status_checks`
→ `{"checks":["CI (Linux)","Arch simulation","Review Gate"],"strict":true}`.
`MSRV`, `Stable`, `Coverage` and `Prototype` are advisory: they run on every PR
and cannot block a merge.

### Where a pull request's wall clock goes

`CI` and `Sim` both trigger on `pull_request`, so they are concurrent with each
other. `Review Gate` triggers on `workflow_run` of `PR Agent`, so the review pair
is serial with itself and concurrent with the rest. A PR therefore waits for

```
max(CI, Sim, PR Agent + Review Gate)
```

Measured 2026-11-21, successes only: `CI` 65s, `Sim` 244s at p90, `PR Agent`
456s, `Review Gate` 10s. That is `max(65, 244, 456 + 10)` = **466s, and the
review chain is all of it.**

The previous version of this section concluded `max(CI, Sim)` and "Sim is the
larger term by 3×", measured from these runs:

| Run | CI | Sim |
|---|---|---|
| 44471119834 (`docs/prose-that-lies`) | 67s | 173s |
| 44470431191 (same branch, next head) | 53s | 184s |
| 44470154997 (`main` push) | 51s | 333s |

Those three runs are still accurate. They could not see the review chain, whose
`PR Agent` median was 124s when they were taken and is 456s two days later. The
conclusion that follows is the opposite of the old one: **CI and Sim tuning are
both worth zero seconds of merge latency until the review chain is under `Sim`'s
p90**, because neither can be the last thing a PR waits on while one review takes
7.6 minutes.

Two different Sim medians exist and they are not interchangeable: 10s over all
runs of the last 50, because most PRs are docs-only and select zero scenarios, and
roughly 194s for a PR that touches `src/` and runs 8 scenarios. Both are true. A
ranking that quotes the first and optimises the second is how the layer cache
below came to be ranked first in the previous version of this table.

### The Sim job, decomposed

`gh run view <id> --json createdAt,updatedAt` per run, and the step log's own
`sim: build: ok` / `sim: PASS: <scenario> (Ns)` lines:

| Part | Measured |
|---|---|
| Image build (`docker build`, no cache) | median 118s, 99–130s over the 13 sample runs that built at all |
| Scenarios, per-scenario | 3.6s average; slowest 53s (`53-package-install`), 23s (`43-delete-db-lck-under-pacman`), 14s (`40-tui-keymap`) |
| Scenarios, whole suite (56) | 203s typical |
| Job total, PR with 8 scenarios | ~194s |
| Job total, `main` push, 56 scenarios | ~330s |
| Job total, docs-only PR (0 scenarios) | ~10s |
| **Outlier, run 44464311286** (`main` push, 56 scenarios) | build **539s**, scenarios **597s**, job **1157s**, wall clock **1162s** — 3.5× the same shape on another runner |

The 1162s outlier is outside the 20-run sample in the workflow table: it was the 20th run when that sample was taken and two new runs pushed it out of the re-measurement twenty minutes later, which is why one range ends at 636s and this row exists. It is the tail that the layer-cache change is sized against.

7 of the last 20 Sim runs selected **zero** scenarios and finished in ~10s; they
are docs-only PRs. The other 13 each paid a full image build.

**The image is rebuilt from scratch on every run.** There is no
`docker/build-push-action`, no `actions/cache` entry for image layers, and no
`--cache-from` anywhere in `sim.yml` or `sim/run.sh`; the runner is ephemeral, so
every build starts at `FROM archlinux:base-devel`. That is the measured 118s.

Local breakdown of that build, this host, `docker build --no-cache
--cpuset-cpus 0-5 -f sim/Dockerfile` (each layer timed separately):

| Layer | Time |
|---|---|
| builder stage: `pacman -Syu --needed rust` | 43s |
| builder stage: `cargo build --release --locked --features sim-hooks` | 33.6s |
| runtime stage: `pacman -Syu --needed sudo pacman-contrib rust git` | 42s |
| whole build | 252s (legacy builder on this host; the layer-commit overhead is not representative — CI's equivalent whole build is 118s) |

Two `pacman -Syu` layers are 71% of the parts that were timed. The crate
compile is 28%. CI prints no per-step build timing (the legacy builder emits
none), so the 118s cannot be split directly; the pacman share has to be inferred
from the local ratio, and the first slice below measures it by removing it.

### The CI jobs, decomposed

`CI (Linux)`, 57.5s average over 20 runs, by step:

| Step | avg |
|---|---|
| `Run CI script` (`ci.sh`: 11 gate scripts in 13 invocations, clippy, test, doc-test, fmt, cargo-deny) | 21.9s |
| `Package (cargo publish --dry-run)` | 16.1s |
| `dtolnay/rust-toolchain` | 7.9s |
| `Swatinem/rust-cache` restore | 3.6s |
| checkout + setup + cargo-deny install + log upload | 4.5s |
| setup and job scaffolding, not attributed to a step above | 3.5s |
| **total** | **57.5s** |

The scaffolding row is what makes the column sum to the stated 57.5s; without it
the five named parts come to 54.0s and the table silently loses 6% of the job.
The gate count is `grep -cE '^(bash scripts/|\./sim/|bash sim/)' ci.sh` → 13
invocations over 11 scripts today (it was 10 invocations at the commit that first
published this table). The figure is asserted by
`scripts/check-ci-architecture.sh`, which is itself one of those invocations, so
adding a gate fails the build until this sentence is updated — which is exactly
how it was found to be stale the first time.

Other CI jobs: `Prototype` 42.5s (37.3s of it the browser verify), `Stable` 38.0s,
`Coverage` 36.5s, `MSRV` 27.3s. They run in parallel, so they cost no wall clock;
they cost four compiles and four test runs of the same tree per PR, and they are
the four places a flake can appear.

### Cache behaviour

- `Swatinem/rust-cache`: **20 of 20 runs restored on a full key match**
  (`Restored from cache key "…" full match: true.` in the job log), and it is
  wired into **four of the five** `CI` jobs — `msrv`, `ci`, `stable`, `coverage`.
  The fifth, `prototype`, has no Rust, no toolchain and no cache step
  (`grep -c 'Swatinem/rust-cache' .github/workflows/ci.yml` → 4). Restore costs
  3.6–9.7s per job. This part needs nothing.
- Repository cache: `gh api repos/{owner}/{repo}/actions/caches` → **30 entries,
  3.9 GB** of the 10 GB allowance on 2026-11-21, all rust-cache keys. Re-run that
  command rather than quoting this figure: the same query returned 34 entries /
  4.0 GB on 2026-11-19 and 40 entries / 4.8 GB later the same day, so an absolute
  count in prose is stale within hours. What matters for sizing is only that
  rust-cache already occupies roughly a third of the free allowance.
- The sim image: **0 of 20 runs reused a single layer.** Nothing is cached.
- Cache scope has a consequence the ranking below has to respect: a cache written
  by a `pull_request` run is scoped to `refs/pull/.../merge` and can only be
  restored by re-runs of that PR (page cited in section 2), so a PR **cannot seed
  the cache that the next PR reads**. Only a `push` to `main` can.

### Scenario selection

`scripts/gate-scenarios.sh --list <base>` maps changed `src/` paths through
`sim/scenario-map.tsv`. Measured on the last 20 runs:

| Branch | Changed files | Scenarios selected |
|---|---|---|
| `docs/factory-wiring` | no `src/` change | 0 (job 8s) |
| `docs/prose-that-lies` | `src/tui/render.rs` + 3 others | 8 |
| `feat/live-facts-refresh` | `src/tui/*` + `src/fetch*` | 18 |
| `main` push | — | 56 |

Selection is tight, not over-broad: the only 8-scenario PRs are the ones that
touch `src/tui/render.rs`, whose map row is exactly those 8. **One extra scenario
costs 3.6s**, so over-selection is not a problem worth solving.

Two things about selection are worth knowing before reading the gap table, and
both were fixed between this document's first draft and this revision. The list
is now written to `sim-logs/selected-scenarios.txt` (`.github/workflows/sim.yml:55`),
so the artifact records what ran. And the diff is now `--list "$BASE" "$HEAD_SHA"`
(`sim.yml:56`), not a three-dot diff from the frozen `base.sha` against the merge
commit the runner checked out: that version selected by whatever `main` had gained
while the PR sat there, and on #143 it chose 27 of 56 scenarios for three markdown
files. `scripts/check-gate-scenarios.sh` pins both halves.

The zero-scenario row needs one more sentence than it used to have. A required
check that selects nothing passes in ~10s having executed no scenario, and
nothing in the run page says so. Two guards already bound it and this document
never named them: `scripts/gate-scenarios.sh --check-map` (`.github/workflows/sim.yml:46`,
and `ci.sh:27`) fails when a changed `src/` path has no row in
`sim/scenario-map.tsv`, and `sim/check-scenario-numbers.sh` (`sim.yml:27`) keeps
the numbering honest. Without `--check-map` a zero selection is a false green;
with it, a zero selection means no `src/` path changed. That is the difference
between "proved nothing" and "had nothing to prove", and it should be stated
aloud rather than left in the gap table as a note about artifacts.

### Flake inventory

`gh run list --status failure --limit 60`, grouped by workflow, re-run 2026-11-21:

| Workflow | Failing runs | Where |
|---|---|---|
| `Review Gate` | 35 | the review machinery, not the build (23 from `workflow_run`, 12 from an old `pull_request` trigger) |
| `CI` | 7 | `Run CI script` and `Package (cargo publish --dry-run)` |
| `OCR Review (advisory)` | 4 | unmerged (PR #149); the model call, not the build |
| `PR Agent` | 3 | no review happened, which reds the required `Review Gate` |
| `Sim` | 2 | `Build sim image and run scenarios` |

The table now lists every workflow that appears in that query. It used to omit
`PR Agent` and the advisory reviewer, which understated the thesis of this
document: the red mass is the review machinery, and a failed `PR Agent` run is a
second-order `Review Gate` failure rather than a separate problem.

`Sim` has **0 failures in its last 20 runs**; `CI` has 1. Every non-review
failure is 6–12 days old and deterministic on its branch, not a flake. Two
properties of the shape are worth naming anyway:

- One broken commit turns **three to four checks red at once** — runs 42487635874
  and 42488229442 and 43045640650 each failed `CI (Linux)`, `MSRV` and `Stable`
  on the same defect, because those three jobs compile and test the same tree.
  That is G3 in the table below.
- The packaging step fails on its own: run 44085640318 was green everywhere except
  `Package (cargo publish --dry-run)`, which is 16.1s of the 57.5s `CI (Linux)`
  job and a distinct failure mode from `ci.sh`.
- One infrastructure outlier: run 44464311286, a `main` push where the build took
  **539s** instead of 118s and the same 56 scenarios took **597s** instead of
  203s. That is a runner or mirror slowdown on a build that caches nothing, and
  it is the exact failure a layer cache also shortens.

## 2. What good looks like, sourced

**Free tier.** "Standard GitHub-hosted runners in public repositories" are free,
and for public repositories "This usage remains free" — including cache storage
([billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)).
So compute is not the constraint here; wall clock and robustness are.

**Cache limits.** "GitHub will remove any cache entries that have not been
accessed in over 7 days"; the total is "10 GB per repository" by default, and
over the limit entries are evicted "in order of last access date, from oldest to
most recent" ([dependency
caching](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching)).
We are at 4.0 of 10 GB with rust-cache alone.

**Cache scoping decides where a cache must be written.** A cache created by a
`pull_request` run is scoped to `refs/pull/.../merge` and "can only be restored
by re-runs of the pull request". Workflow runs can restore "caches created in
either the current branch or the default branch" (same page). So a cache written
by a PR is useless to the next PR: an image cache has to be **seeded by the
`push` to `main`** and only read by PRs. GitHub's own guidance for a cache that
low-trust triggers may read is "a CI build triggered by a `push` to the default
branch".

**Required checks and filters.** A workflow skipped by path or branch filtering
leaves its checks "in a 'Pending' state", which "block[s] merging", and the docs'
advice is "Avoid requiring workflows that can be skipped". A job skipped by a
conditional does not block ([troubleshooting required status
checks](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-required-status-checks)).
Both `CI` and `Sim` are required, so **neither may ever get a `paths:` filter**;
the correct way to skip work inside them is a step or job condition.

**The conclusion-aggregator pattern.** `rust-lang/cargo` keeps one stable
required check name across a job set that changes: a `conclusion` job that
`needs:` every other job, runs `if: ${{ !cancelled() }}` because "a skipped job
is considered a success by GitHub", and asserts `jq --exit-status 'all(.result ==
"success")' <<< '${{ toJson(needs) }}'`
([`.github/workflows/main.yml`](https://github.com/rust-lang/cargo/blob/master/.github/workflows/main.yml)).
That is the pattern to reach for if a required check ever needs to become a
matrix or be split: keep `Arch simulation` as the aggregator's name.

**Cheap gate first.** `tokio` runs a `basics` job (fmt, docs, no heavy compile)
and every test job declares `needs: basics`, so a formatting mistake does not
spend the matrix
([`ci.yml`](https://github.com/tokio-rs/tokio/blob/master/.github/workflows/ci.yml)).
It also sets `concurrency: cancel-in-progress: true` unconditionally.

**nextest and sharding.** `tokio` uses `cargo nextest run` everywhere and runs
doctests separately because "Cargo nextest does not support doctest"
([nextest#16](https://github.com/nextest-rs/nextest/issues/16)); nextest shards
with `--partition slice:m/n`
([partitioning](https://nexte.st/docs/ci-features/partitioning/)). `ripgrep` uses
one matrix job over OS and target and keeps `rustfmt`, `docs` and `wasm` as
separate small jobs
([`ci.yml`](https://github.com/BurntSushi/ripgrep/blob/master/.github/workflows/ci.yml)).
**None of the three repos shards its tests** — `cargo`, `tokio` and `ripgrep`, the
three that have a workflow quoted above; `nextest` is a tool reference, not a
fourth repository — and none uses path filters on a required PR workflow.

**Docker layer cache.** `type=gha` stores buildx layers in the same Actions cache
API, with `cache-to: type=gha,mode=max` exporting intermediate stages of a
multi-stage build; it is marked experimental by Docker and consumes the same
10 GB repository allowance
([docker docs](https://docs.docker.com/build/cache/backends/gha/)).

## 3. The gap, in one table

| # | Gap | Measured | Why it matters |
|---|---|---|---|
| G1 | The sim image is built from scratch on every run | 118s of a 194s PR job; 0/20 runs reused a layer | 61% of the Sim job, and the 539s tail is the same uncached build on a slow mirror. A `type=gha` layer cache was attempted as PR #145, closed unmerged on 2026-11-19 — its own successful runs were 287s, 351s, 370s and 636s against the 194s it targeted. Any proposal here has to beat that measurement, not the theory |
| G2 | Every ranking in this document was ordered by a term that is not the critical path | `PR Agent` median 456s + `Review Gate` 10s against `CI` 65s and `Sim` p90 244s | The review chain is 466s of a 466s wait. Sim and CI tuning move nothing until it shrinks, so the order of section 4 was wrong, not merely stale |
| G3 | Four jobs inside `CI` each compile the same tree and run the same suite (`MSRV`, `CI (Linux)`, `Stable`, `Coverage`) | four compiles, four test runs per PR | Free in wall clock, since they are parallel, but it multiplies the flake surface 4× and one defect reddens three or four checks. Section 2 already sources the fix (`needs: basics`); it needs a decision, not a measurement |
| G4 | A red `Sim` says one line | three shapes, not one: `sim: build: FAILED…` (`sim/run.sh:81`, `:94`), `sim: TIMEOUT: …` (`:214`), `sim: FAIL: … exited <status>` (`:220`) | Diagnosis requires downloading the artifact; the failing assertion is inside it, not on the run page. A failure summary that assumes one shape will miss two of the three |
| G5 | The artifact does not record which scenarios were selected | **closed**: `sim.yml:55` writes `sim-logs/selected-scenarios.txt` | Kept as a row because the failure it describes is the one G9 below still has, in a different form: without the record, "this run proved nothing" and "this run had nothing to prove" look identical |
| G6 | The required check names are written down twice, and one copy is already short | `docs/FACTORY.md:107` lists all three from `gh api …/branches/main/protection`; `.github/PR-AGENT.md:64` lists only `["CI (Linux)", "Arch simulation"]`; `README.md:307` and `AGENTS.md` mention the names in prose without a list | The drift this row warns about has already happened: the second enumeration is missing `Review Gate`, the one name produced by a Checks-API write rather than a job, so no grep of a workflow catches its loss. `check-ci-architecture.sh` guards only this document's copy — which is why the row stands rather than being closed by it |
| G7 | Selection could diff the wrong commits | **closed**: `--list "$BASE" "$HEAD_SHA"`; #143 selected 27 of 56 scenarios, job 218s, for three markdown files | The frozen `base.sha` against the runner's merge commit selects by whatever `main` gained meanwhile. Worth recording because the symptom (a slow PR) pointed at the suite, not the selection |
| G8 | A head that conflicts with its base starts no workflow at all | PR #144: created conflicting, `gh api …/actions/runs?head_sha=…` returned `total_count: 0`; rebased onto `main`, the same head started `CI`, `Sim` and `Review` | "No checks reported" on a conflicted PR is indistinguishable on the PR page from a workflow bug, and the required checks simply never arrive |
| G9 | A required check can pass having run nothing | `Sim` selects 0 of 56 scenarios on 7 of 20 runs and finishes in ~10s; `CI (Linux)` runs the same shape on every PR | A false green is invisible by construction — it is the one failure mode no dashboard shows. `--check-map` (G1's neighbour in `sim.yml:46`) is the guard that distinguishes "nothing to prove" from "proved nothing", and the failure summary in change #4 should say which happened |

## 4. Ranked changes

Ordered by the wall clock a change actually removes from the path measured in
section 1 — `max(CI, Sim, PR Agent + Review Gate)` — then by robustness. Every
row names the files it touches, the command that says whether it won, and how to
undo it. "Expected" is still a prediction; the difference is that each row now
carries the test that will call the prediction a failure.

| # | Change | Files | Before → expected after | Measure | Rollback | Risk |
|---|---|---|---|---|---|---|
| 1 | Head-pinned scenario selection: `gate-scenarios.sh --list <base> <head>`, the PR head passed explicitly, the chosen list written into `sim-logs/` | `scripts/gate-scenarios.sh`, `.github/workflows/sim.yml` | #143: 27 of 56 scenarios, job 218s, for three markdown files | up to 212s on any PR that follows a `main` merge; the artifact now records what ran | `scripts/check-gate-scenarios.sh` (<- `ci.sh`) | **landed** (#144). Both halves are pinned by the new gate, so a revert fails CI rather than quietly re-selecting foreign scenarios |
| 2 | Decompose the review chain before optimising anything else: it is 466s of a 466s wait | none yet — this row is a measurement, not a patch. `pr-agent.yml` if it becomes one | `PR Agent` median 456s (p90 896s, max 1401s, n=20) | the review comment's own run-details line already records model, tokens in/out, duration and AI calls (`.pr_agent.toml: output_run_details`); n=20 `gh run list --workflow 'PR Agent'` before and after | nothing to revert | this row prescribes no fix. Naming a fix before decomposing is what produced the old ranking |
| 3 | Shard the **full-suite** `main` run two ways under one aggregator named `Arch simulation` | `sim.yml` only: `sim/run.sh` already takes scenarios positionally (`:114-116` `scenarios=("$@")`) and `sim.yml:68` already calls it that way. The work is slicing the selected list into N contiguous runs | 203s of scenarios on `main` | `gh run list --workflow Sim` filtered to `main` pushes, n=10, before/after | revert the commit; the aggregator is what keeps `main` gated, so a revert is safe | 100s on `main` pushes only, **zero PR benefit**. Two shapes look right and are wrong. "Two job names" leaves the required name absent, and a required check that never appears keeps every PR Pending — `main` becomes unmergeable, not unguarded (`:260`). A bare aggregator asserting `all(.result == "success")` is red on **every PR**, because shards gated off a pull request report `skipped`, not `success`. The shape that works: shards `if: github.event_name != 'pull_request'`; an aggregator with no `if:` at all, so it runs on PRs too, named exactly `Arch simulation`, that `needs:` them and asserts `all(.result == "success" or .result == "skipped")` — passing on a PR where everything is skipped, failing on `main` where a dead shard is `failure`. `sim.yml:18` carries that name today |
| 4 | Failure summary: the failing scenario names and their last lines into `$GITHUB_STEP_SUMMARY`, and the selected list into `sim-logs/` | `sim.yml` (`Select scenarios`, `Build sim image and run scenarios`) | one line, artifact download to diagnose | a forced failure: the reason visible on the run page without downloading anything | revert the step | zero seconds, pure robustness. Two details that make it work rather than appear to: `sim-logs/` is created by `sim/run.sh` *after* the select step, so the select step needs its own `mkdir -p` or the upload hits `if-no-files-found: warn` and passes silently; and there are three failure shapes to summarise, not one (`sim/run.sh:81`, `:94`, `:214`, `:220`) |
| 5 | Pre-compile the dependency graph in the Dockerfile (manifests + a dummy entry point, `cargo build`, then `COPY src`) | `sim/Dockerfile`, `sim/README.md`, a new `sim/scenarios/NN-stale-binary.sh` | 33.6s compile, all invalidated by a `src/` edit | build step duration on a src-only change | revert `sim/Dockerfile` | **parked behind #6**: it is only worth 15s if a layer cache exists to hold the result. Its stated precondition ("prove it does not ship a stale binary") names no proof — `grep -in stale sim/README.md` finds only pacman locks and a stale aurto repo. The proof that would admit it is a build-arg carrying the commit sha, asserted through `aepm --version`, but `src/main.rs:7-15` prints `CARGO_PKG_VERSION` only and there is no `build.rs`, so producing that sha needs a `src/` change — a ticket under `§6.3`, not a CI slice. The row stays parked until that ticket exists |
| 6 | buildx `type=gha` layer cache for the sim image, written by `push` to `main`, read by PRs | `sim/run.sh:61` (the build call) and the `DOCKER_BUILDKIT=0` retry at `:89`; `sim.yml`; `sim/check-image-tag.sh` and `sim/check-build-retry.sh` both parse that argv and both are `ci.sh` gates | 118s build every run | median Sim job for `src/`-touching PRs, n=10 | revert commit + `gh cache delete <key>` | **parked, and it was already tried**: PR #145 shipped exactly this and closed unmerged on 2026-11-19 after runs of 287s, 351s, 370s and 636s against the 194s baseline. Independent reasons not to re-rank it: caches are evicted when unused and a PR-scoped write cannot seed `main` (section 2), and the row's two size figures disagreed with each other (3.5 GB vs ~1 GB). The untried alternative is `ghcr.io` + `type=registry` from `push:main` |

Two changes remain rejected, on the same evidence as before:

- **`cargo nextest`** — the entire Rust suite is 21.9s inside `ci.sh`; installing a
tool to split 21.9s does not pay.
- **Path filters on `CI`/`Sim`** — a filtered workflow leaves a required check
Pending forever (sourced in section 2). Note `NEXT.md` still carries a ticked
box claiming docs-only `paths-ignore` shipped; it did not, and it must not.

## 5. Rejected for cost

- **Larger GitHub-hosted runners.** "Larger runners are billed for public
  repositories" ([billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)).
  A 4-core runner would halve the 34s compile and cost money per minute.
- **Cache storage above 10 GB.** "Any usage beyond 10 GB is billed to your
  account"; the Actions Cache Storage SKU is a paid product at $2.80/50 GB/month.
  Slice 1 fits inside the free 10 GB, so this stays rejected.
- **A paid CI product** (BuildJet, Blacksmith, Depot, Namespace) and **a paid
  caching service**, which is what most "fast Rust CI" write-ups are actually
  selling. Free tier only.
- **A self-hosted runner.** Not free in any sense that matters here: it is a
  machine to patch, its cache belongs to that machine, and it becomes another
  thing whose health silently gates `main`. (An earlier version of this bullet
  also said "the repo's own rules forbid running pacman on this host". They do
  not: `AGENTS.md` forbids pacman against the *development* host, and a separate
  runner is not that host. The patching cost is the real reason.)
- **Paid observability** for CI (Datadog CI Visibility, BuildPulse flake
  tracking). The free substitutes are `scripts/proof.sh`, `gh run list --status
  failure`, `gh run view <id> --json/--log` (the step decomposition and the
  per-scenario timings), and `gh api repos/{owner}/{repo}/actions/caches` and
  `…/branches/main/protection` (the cache and required-check facts). Every number
  in section 1 came from one of those five command shapes; naming a subset of
  them was itself a small inaccuracy.

## 6. Constraints on any change in this document

1. Never change branch protection. `CI (Linux)`, `Arch simulation` and `Review
   Gate` are the required names; a split keeps those names or every PR waits
   forever on a check no job produces. `Review Gate` is the fragile one: it is a
   Checks-API write on the PR head, not a workflow job name, so no grep of a
   workflow will catch its loss.
2. Never change `coverage-floor.txt`, `Review Gate` semantics, or
   `sim/scenario-map.tsv` numbering (thread `9c075c1c` owns those).
3. `fetch`/`check`/`doctor`/`install` behaviour is not touched by CI work; a
   change that needs a `src/` edit is a ticket, not a slice.
4. Local work stays under 60% of 16 cores: `CARGO_BUILD_JOBS=6`,
   `RUST_TEST_THREADS=4`, `docker build --cpuset-cpus 0-5`, never parallel sim
   containers.
