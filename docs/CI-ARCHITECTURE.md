# CI architecture

What the checks cost, what they prove, and where the money and the minutes go.
Every number here names the command that printed it. Numbers measured on
2026-11-19 are from the Actions API run on that date; re-measure before quoting
them later.

Scope: the machinery only — workflow structure, job split, caching, selection,
required-check design, and how a failure explains itself. Review policy lives in
`.github/PR-AGENT.md`, not here.

## 1. What we have, measured

### The five workflows

| Workflow | Triggers | Jobs | Gating? | Wall clock (n=20) |
|---|---|---|---|---|
| `CI` | `pull_request`, `push main`, `dispatch` | `MSRV (1.85)`, `CI (Linux)`, `Stable (tip)`, `Coverage (floor enforced)`, `Prototype (web demo matches the goldens)` | `CI (Linux)` only | median 60s, 49–83s |
| `Sim` | `pull_request`, `push main`, `dispatch` | `Arch simulation` | yes | median 183s, 7–646s (plus one 1162s outlier, below) |
| `Review Gate` | `workflow_run` of `PR Agent` | `Review Gate` | yes | median 10s, 1–557s |
| `PR Agent` | `pull_request` (`opened`, `reopened`, `ready_for_review`, `synchronize`), `issue_comment` | `Review` | no (writes the verdict) | median 124s, 1–425s, 3 of 20 skipped |
| `Scheduled audit` | weekly cron, `dispatch` | `audit`, `report` | no | n/a |

`gh api repos/{owner}/{repo}/branches/main/protection --jq .required_status_checks`
→ `{"checks":["CI (Linux)","Arch simulation","Review Gate"],"strict":true}`.
`MSRV`, `Stable`, `Coverage` and `Prototype` are advisory: they run on every PR
and cannot block a merge.

### Where a pull request's wall clock goes

A PR waits for `max(CI, Sim)`, and Sim is the larger term by 3×:

| Run | CI | Sim |
|---|---|---|
| 44471119834 (`docs/prose-that-lies`) | 67s | 173s |
| 44470431191 (same branch, next head) | 53s | 184s |
| 44470154997 (`main` push) | 51s | 333s |

Median `CI` 60s, median `Sim` 183s. Any CI speed work is therefore worth **zero**
PR wall clock until Sim is under 60s. That single sentence should decide the
priority order of everything below.

### The Sim job, decomposed

`gh run view <id> --json createdAt,updatedAt` per run, and the step log's own
`sim: build: ok` / `sim: PASS: <scenario> (Ns)` lines:

| Part | Measured |
|---|---|
| Image build (`docker build`, no cache) | median 118s, 99–130s over the 13 sample runs that built at all |
| Scenarios, per-scenario | 3.6s average; slowest 53s (`53-package-install`), 23s (`43-delete-db-lck`), 14s (`40-tui-keymap`) |
| Scenarios, whole suite (56) | 203s typical |
| Job total, PR with 8 scenarios | ~194s |
| Job total, `main` push, 56 scenarios | ~330s |
| Job total, docs-only PR (0 scenarios) | ~10s |
| **Outlier, run 44464311286** (`main` push, 56 scenarios) | build **539s**, scenarios **597s**, job **1157s**, wall clock **1162s** — 3.5× the same shape on another runner |

The 1162s outlier is outside the 20-run sample in the workflow table: it was the 20th run when that sample was taken and two new runs pushed it out of the re-measurement twenty minutes later, which is why one range ends at 646s and this row exists. It is the tail ranked change #2 is sized against.

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
| `Run CI script` (`ci.sh`: 8 self-tests, clippy, test, doc-test, fmt, cargo-deny, build-retry checks) | 21.9s |
| `Package (cargo publish --dry-run)` | 16.1s |
| `dtolnay/rust-toolchain` | 7.9s |
| `Swatinem/rust-cache` restore | 3.6s |
| checkout + setup + cargo-deny install + log upload | 4.5s |

Other CI jobs: `Prototype` 42.5s (37.3s of it the browser verify), `Stable` 38.0s,
`Coverage` 36.5s, `MSRV` 27.3s. They run in parallel, so they cost no wall clock;
they cost four compiles and four test runs of the same tree per PR, and they are
the four places a flake can appear.

### Cache behaviour

- `Swatinem/rust-cache`: **20 of 20 runs, in all five CI jobs, restored on a
  full key match** (`Restored from cache key "…" full match: true.` in the job
  log). Restore costs 3.6–9.7s per job. This part needs nothing.
- Repository cache: `gh api repos/{owner}/{repo}/actions/caches` → **34 entries,
  4.0 GB** of the 10 GB allowance, all of them rust-cache keys (the same eight
  keys repeated once per branch — rust-cache is branch-scoped).
- The sim image: **0 of 20 runs reused a single layer.** Nothing is cached.

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
costs 3.6s**, so over-selection is not a problem worth solving. What is missing
is that the selected list is written to a `mktemp` path outside `sim-logs/`, so
the uploaded artifact never records what the run chose.

### Flake inventory

`gh run list --status failure --limit 60`, grouped by workflow and failed step:

| Workflow | Failing runs | Where |
|---|---|---|
| `Review Gate` | 35 | the review machinery, not the build (23 from `workflow_run`, 12 from an old `pull_request` trigger) |
| `CI` | 5 | `Run CI script` (4), `Package (cargo publish --dry-run)` (1) |
| `Sim` | 2 | `Build sim image and run scenarios` |

**`CI` and `Sim` have 0 failures in the last 20 runs each**; every non-review
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
**None of the four repos shards its tests**, and none uses path filters on a
required PR workflow.

**Docker layer cache.** `type=gha` stores buildx layers in the same Actions cache
API, with `cache-to: type=gha,mode=max` exporting intermediate stages of a
multi-stage build; it is marked experimental by Docker and consumes the same
10 GB repository allowance
([docker docs](https://docs.docker.com/build/cache/backends/gha/)).

## 3. The gap, in one table

| # | Gap | Measured | Why it matters |
|---|---|---|---|
| G1 | The sim image is built from scratch on every run | 118s of a 194s PR job; 0/20 runs reused a layer | 61% of the only wall clock that a PR actually waits for, and the 539s tail is the same uncached build on a slow mirror |
| G2 | CI speed is inside Sim's shadow | CI 60s vs Sim 183s median | Any CI job tuning moves 0 seconds of PR latency |
| G3 | Four jobs inside `CI` each compile the same tree and run the same suite (`MSRV`, `CI (Linux)`, `Stable`, `Coverage`) | four compiles, four test runs per PR | Free (G3 costs no money and no wall clock) but multiplies the flake surface 4×, and one defect reddens three or four checks |
| G4 | A red `Sim` says one line | `sim: FAIL: sim/scenarios/NN-*.sh exited 1 (log: …)` | Diagnosis requires downloading the artifact; the failing assertion is inside it, not on the run page |
| G5 | The artifact does not record which scenarios were selected | list goes to `mktemp`, outside `SIM_LOG_DIR` | "what did this run actually prove" cannot be answered from the evidence |
| G6 | The load-bearing check names are not written down | `CI (Linux)`, `Arch simulation` | Splitting or renaming either silently un-gates `main` |
| G7 | Selection diffs the frozen `base.sha` against the merge commit the runner checked out | PR #143: three markdown files selected 27 of 56 scenarios, job 218s instead of 6s | A PR pays for the runtime changes it does not contain, and the harness proves less than it claims |

## 4. Ranked changes

Ordered by measured wall clock first, then robustness. "Expected" is a
prediction from the decomposition above, not a measurement; the slice that
lands it carries the real before/after.

| # | Change | Before | After | Win | Risk / status |
|---|---|---|---|---|---|
| 1 | Head-pinned scenario selection: `gate-scenarios.sh --list <base> <head>`, `sim.yml` passes the PR head, the selected list is written into `sim-logs/` | PR #143: 27 of 56 scenarios, job 218s, for three markdown files | 0 scenarios, job 6s (same branch, rebased, after the fix) | up to 212s on any PR that follows a `main` merge; the artifact now records what ran | **landed**, `scripts/check-gate-scenarios.sh` pins both halves |
| 2 | buildx `type=gha` layer cache for the sim image, written by `push` to `main`, read by PRs | 118s build every run, 0 of 20 runs reused a layer | ~45s on a PR (two `pacman -Syu` layers hit, the 34s compile and the 3.5 GB export remain) | ~70s of every PR, and it bounds the 1162s tail | Docker calls `gha` experimental; ~1 GB more of the 10 GB cache; a cache miss falls back to today's build, so it can never make the gate fail |
| 3 | Failure summary: failed scenario names and their last failing lines into `$GITHUB_STEP_SUMMARY` | one line, artifact download to diagnose | the reason on the run page | 0s wall clock; removes the artifact round trip from every diagnosis | none — the log stays the evidence |
| 4 | Pre-compile the dependency graph in the Dockerfile (manifests + dummy `main`, `cargo build`, then `COPY src`) so the registry and dependencies are a cached layer | 33.6s compile, all of it invalidated by a `src/` edit | ~20s for a src-only change | ~15s on top of #2 | a dummy-`main` layer is a known trick, but it must be proven not to ship a stale binary (sim/README already documents that failure mode for the local classic builder) |
| 5 | Shard the **full suite** run (`main` push) 2 ways with two job names, not the required one | 203s of scenarios | ~105s | ~100s on `main` only, no PR benefit | needs a second image build per shard unless #2 lands first; touches the required check name unless done as a matrix under one aggregator |
| 6 | `cargo nextest` | — | — | **reject**: the entire Rust suite is 21.9s inside `ci.sh`; a tool install costs more than the split saves | — |
| 7 | Path filters on `CI`/`Sim` | — | — | **reject**: a filtered workflow leaves a required check Pending forever (sourced above) | — |

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
  machine to patch, and the repo's own rules forbid running pacman on this host.
- **Paid observability** for CI (Datadog CI Visibility, BuildPulse flake
  tracking). The free substitute is `scripts/proof.sh` plus `gh run list
  --status failure`, which is what section 1 used.

## 6. Constraints on any change in this document

1. Never change branch protection. `CI (Linux)` and `Arch simulation` are the
   required names; a split keeps those names or it un-gates `main` silently.
2. Never change `coverage-floor.txt`, `Review Gate` semantics, or
   `sim/scenario-map.tsv` numbering (thread `9c075c1c` owns those).
3. `fetch`/`check`/`doctor`/`install` behaviour is not touched by CI work; a
   change that needs a `src/` edit is a ticket, not a slice.
4. Local work stays under 60% of 16 cores: `CARGO_BUILD_JOBS=6`,
   `RUST_TEST_THREADS=4`, `docker build --cpuset-cpus 0-5`, never parallel sim
   containers.
