# PR Agent decision record

Scope: the review bot added in `.github/workflows/pr-agent.yml` and
`.pr_agent.toml`. Mode: **Full** (network, credentials, multiple components).

Everything below is tagged:

- `[VERIFIED: source]` — read from an official doc, shipped config, or source.
- `[MEASURED: how]` — observed in a run on 2026-11-07.
- `[UNVERIFIABLE]` — no source; treat as an open risk.

## Components

GitHub Actions workflow, pr-agent 0.49.0 (Docker action), LiteLLM (inside
pr-agent), Command Code Provider API, model `deepseek/deepseek-v4.1-flash`,
repository secret, `.pr_agent.toml` policy.

## Done ledger

| # | Knob | Decision | Why | Source |
|---|---|---|---|---|
| D1 | Deployment | GitHub Action on GitHub's runner | Zero infra; the repo is public, so minutes are free; no server to expose | `[VERIFIED: pr-agent README v0.49.0, "GitHub Action (Recommended)"]` |
| D2 | API surface | `https://api.commandcode.ai/provider/v1` | Official OpenAI-compatible surface; replaces the earlier translation bridge | `[VERIFIED: https://commandcode.ai/docs/provider, Endpoints table]` |
| D3 | Auth | `Authorization: Bearer`, key in `COMMAND_CODE_API_KEY` | The documented scheme; API access needs a plan other than Go | `[VERIFIED: Provider API Quickstart and Errors table]` |
| D4 | Model | `openai/deepseek/deepseek-v4.1-flash` | User directive; served on `/chat/completions` | `[VERIFIED: GET /provider/v1/models, supported_endpoints=["/chat/completions","/responses"], context_length=1000000]` |
| D5 | Reasoning | `reasoning_effort = "max"` | User requires the highest effort | `[VERIFIED: CLI model registry, reasoningEfforts=["off","low","high","max"]]`; `[MEASURED: max 498-509s / 70,483 reasoning tokens; low 118-417s; off 22s]` |
| D6 | Reasoning passthrough | `additional_reasoning_effort_models = ["openai/deepseek/deepseek-v4.1-flash"]` | LiteLLM does not know the id; pr-agent only forwards the effort when listed | `[VERIFIED: configuration.toml v0.49.0 line 125; litellm_ai_handler.py reasoning gate]` |
| D7 | Context window | `custom_model_max_tokens = 1000000` | pr-agent refuses an unknown id without a declared window | `[MEASURED: "Model ... is not defined in MAX_TOKENS ... set config.custom_model_max_tokens"]`; `[VERIFIED: live models list context_length=1000000]` |
| D8 | Input cap | `max_model_tokens = 256000` | Input and output share this budget; 256k leaves 128k of input after the 128k output cap. The measured prompt is ~14k | `[VERIFIED: configuration.toml line 50 meaning]`; `[MEASURED: "leaves no input capacity" at 64k/64k]` |
| D9 | Output cap | `max_output_tokens = 128000` | Max reasoning consumed 70,483 tokens; a 64k cap returned empty content with `finish_reason=length`, 128k finished | `[VERIFIED: configuration.toml line 60]`; `[MEASURED: 64k empty, 128k success]` |
| D10 | Request timeout | `ai_timeout = 900`, `retry_same_model_on_timeout = false` | Measured max review: 400-509s. Worst case is primary + one fallback entry (same model) = 2 x 900s = 30 min, under the 45-minute job timeout. Same-model replay on timeout would make it 4 attempts = 60 min | `[VERIFIED: configuration.toml line 27 default 120; _should_retry_same_model; retry_with_fallback_models]`; `[MEASURED: 400s on PR #19, 498-509s locally]` |
| D11 | Fallback | Same model only | Failures retry the chosen model; no silent switch to another vendor | `[VERIFIED: configuration.toml fallback_models]` |
| D12 | Auto tools | `/describe` and `/review` on open; `/improve` manual | Chosen by the user; lowest quota, no committable suggestions | `[VERIFIED: github_action_config.auto_* defaults in github_action_runner.py]` |
| D13 | Failure semantics | A recorded tool failure fails the check | No green check without a review | `[VERIFIED: github_action_runner.py _fail_on_recorded_tool_error, default true]` |
| D14 | Repo rules | Read `AGENTS.md`, `NEXT.md`, `context.md` from `main` | Reviewers must judge by the repo's safety and honesty rules, and a PR cannot rewrite them | `[VERIFIED: configuration.toml repo_context_files and repo_context_from_default_branch]` |
| D15 | Triggers | `pull_request` opened/reopened/ready_for_review/**synchronize**, `issue_comment` created; `github_action_config.handle_push_trigger = true` with `push_commands = ["/review"]` | Standard review-bot surface, plus the push trigger #115 needs (D31). The event alone is not the fix: the action logs `Skipping action: synchronize` and returns unless `handle_push_trigger` is on and `push_commands` is non-empty. Drafts and forks are still skipped by the job guard | `[VERIFIED: pr-agent GitHub Action template and runner event handling]`; `[MEASURED: run 44461713521, a green synchronize run that reviewed nothing, log "Skipping action: synchronize", 2026-11-19]` |
| D16 | Fork PRs | Skipped | Secrets are not passed to fork PR workflows | `[VERIFIED: GitHub Docs, "Using secrets in GitHub Actions"]` |
| D17 | Comment auth | `author_association` in OWNER/MEMBER/COLLABORATOR and body starts with `/` | Prevents anyone spending credits with a comment | `[VERIFIED: upstream pr-agent-review.yaml `if` condition]` |
| D18 | Permissions | `contents: read`, `pull-requests: write`, `issues: write` | Enough to read the PR and post comments; no write to code | `[VERIFIED: pr-agent action usage and the tools enabled]` |
| D19 | Checkout | Default branch only, for the reviewed-SHA skip | The runner itself reads PR data and settings through the API and needs no checkout. One step checks out the default branch before it, because the skip predicate is `scripts/review-state.sh --gate` and a PR must not be able to hand the reviewer's side its own copy of that script | `[VERIFIED: upstream pr-agent-review.yaml steps; github_provider.get_repo_settings uses the API]`; `[VERIFIED: D31]` |
| D20 | Image pin | `pragent/pr-agent@sha256:b1ed6e8d…` | Immutable; matches tag `0.49.0-github_action` | `[VERIFIED: Docker Hub tag API, manifest digest, 2026-10-25]` |
| D21 | Concurrency | Per PR/issue, no cancel | A skipped command must not cancel a queued review | `[VERIFIED: upstream pr-agent-review.yaml comment]` |
| D22 | Policy file | `.pr_agent.toml` with repo-specific blocking rules | Carries the pacman invariants from AGENTS.md and context.md into every review | `[VERIFIED: repo files and configuration.toml key names]` |
| D23 | Finding shape | `inline_key_issues = true` | Findings as file:line comments an agent can act on, not prose buried in a summary | `[VERIFIED: configuration.toml line 200]` |
| D24 | Verdict fields | `require_risk_assessment = true`, `require_merge_recommendation = true` | Typed risk level and merge verdict, so an agent gets a decision without parsing prose | `[VERIFIED: configuration.toml lines 183-184]` |
| D25 | Large PRs | `enable_large_pr_chunking = true`, `max_number_of_calls = 3` | Chunk instead of skip or truncate. Chunks beyond the cap land in `remaining_files_list`, and the coverage footer lists them; the footer stays enabled so a partial review is never silent | `[VERIFIED: configuration.toml lines 216-217; pr_processing.py _pack_pr_multi_diffs; pr_reviewer.py coverage footer]` |
| D26 | AX contract | `AGENTS.md` section "Agent review surface" | An agent entering the repo learns triggers, commands, output fields, authority, and failure semantics without reading the workflow | `[VERIFIED: AGENTS.md]` |
| D27 | Output trim | `require_estimate_effort_to_review = false`, `require_ticket_analysis_review = false`, `enable_intro_text = false` | Drop rows that only help human triage; keep findings, tests, security, risk, and verdict | `[VERIFIED: configuration.toml lines 176, 181, 211]` |
| D28 | Agent state CLI | `scripts/review-state.sh` | Reads the `pr-agent-review-state:v1` typed block: head staleness, coverage, finding counts, `path:line`; TOON-ish output, exit codes, `--help`, `--version`; `--gate` for the verdict and `--reviewed` for whether another run is worth a model call | `[VERIFIED: review comment state block; scripts/check-review-gate.sh]` |
| D29 | Coverage gate | `.github/workflows/review-gate.yml` + `review-state.sh --gate` | 3 of 12 sampled merged PRs had no review comment (#92, #83, #82, all force-pushed); the review bot has no `synchronize` trigger. The trigger is the review run, not the comment: the bot posts with `GITHUB_TOKEN` and GitHub starts no workflow for events that token creates, so an `issue_comment` trigger never fires for it (`workflow_run` on `PR Agent` does). That is the only trigger: a `pull_request` one would execute the PR's own copy of the workflow, which is the copy it is judged by. The gate fails on a missing, stale or incomplete review and on any verdict other than `No concerns found` (`REVIEW_GATE_VERDICT` overrides it), runs only the default branch's copy of the script, never the PR head's and never the PR's base ref, so a PR aimed at another branch cannot choose the script that judges it, and makes no model call, so it spends no credits. Only the bot's own comment counts (`REVIEW_BOT_LOGIN`, default `github-actions[bot],github-actions`), and it must carry the typed block; the guide header is not enough, because `/describe` prints it too: the marker text alone is forgeable by any commenter, and the looser `Risk level` alternation let a newer `/describe` comment shadow the review. Before it lands the check does not run at all: `workflow_run` fires only for a workflow that exists on the default branch. A base without `--gate` fails loudly rather than passing, because a neutral result counts as a pass.  | `[MEASURED: 100 pr-agent runs, 55 success; 3/12 merged PRs with zero comments, 2026-11-17; review round on #99 found the red-gate and forgeable-comment holes, 14/14 cases after]` |
| D30 | Usage telemetry | `output_run_details = true`; pr-agent `0.50.0-github_action` | Tokens and duration were unobservable: the job log prints prompt tokens only, so a cost claim had no source. 0.50.0 renders model, tokens in/out/total, prompt cache, duration, and AI calls on the review comment, which is the record the gate and the decision table can cite. `output_run_cost` stays off because litellm has no price for this model id and would print "unavailable" on every review | `[VERIFIED: pr_agent/algo/run_output.py show_run_details @ 0.50.0; Docker Hub digest 548e894a...]` |
| D31 | Push coverage | `pr-agent.yml` trigger `synchronize` + `github_action_config.handle_push_trigger` with `push_commands = ["/review"]` + a reviewed-SHA skip step that runs `review-state.sh --reviewed --sha <pushed sha>` | #115: a head that received a commit after the PR opened got no review at all and nothing said so; #112 rebased, listed six checks, none of them a review, and merged. A pushed commit is what a merge decides on, so it needs a review of its own; the earlier "one review per PR" decision (N9) was written for a surface that judged the PR, not the commit. The trigger is only half of it: with `handle_push_trigger` off, the action logs `Skipping action: synchronize`, exits 0, and reviews nothing — a green run that proves nothing (run 44461713521). Three bounds keep it from becoming a model call per push: the job guard skips drafts and forks, the action itself skips merge commits and a bot's push, and a head that already carries a complete review of that exact commit skips the model step. The skip reuses the gate's predicate (`--reviewed`) instead of a second definition of "reviewed", and an error in it reads as "not reviewed", so a broken check costs a model call rather than silently leaving the head unreviewed | `[MEASURED: #112 rollup: six checks, no review, merged CLEAN, 2026-11-18; run 44461713521 "Skipping action: synchronize", 2026-11-19]`; `[VERIFIED: github_action_runner.py @ 0.50.0 lines 385-425; scripts/check-review-gate.sh --reviewed cases]` |
| D32 | Head-anchored verdict | `review-gate.yml`: resolve the PR head once, judge it with `review-state.sh --gate --sha <head>`, and write the verdict onto that commit with the Checks API (`checks: write`) | Measured, and it settles where a gate check can go: a `workflow_run`-triggered workflow runs on the default branch, and its own check is attached to the default branch's HEAD, not to the commit the review run checked out. So the gate's own check can never gate a PR head — that is why #112 had six checks and no `Review` — and it must never fail on a review verdict, which would leave a red `Review Gate` on `main` outliving the PR it described (#111, run 44247662200). The verdict is written onto the PR head instead: a push run writes it for the head it reviewed, a `/review` run (which checks out the default branch but reviewed the PR) writes it for the head too, and a push run whose head moved on reports nothing, because that head has its own run. That is what N13 rejected as unreachable and N14 named as the prerequisite for requiring the check: a check anchored on a pushed head once can never be revised, but one written onto the head by every later `/review` can | `[MEASURED: 20/20 `Review Gate` runs listed `headBranch: main` on 2026-11-19, including run 44461071558 whose `workflow_run.head_sha` was PR #132's head 5ca51d0, whose `Resolve` step passed and whose `gh pr checks` at that head listed 7 checks and no `Review Gate`]`; `[VERIFIED: scripts/gate-review-selfcheck.sh 9/9]` |

## Not-done ledger

| # | Item | Why not | Source |
|---|---|---|---|
| N1 | Docker webhook / GitHub App deployment | Needs an always-on public endpoint; conflicts with the no-exposure constraint | `[VERIFIED: pr-agent Docker deployment docs]` |
| N2 | Local proxy or tunnel | Prohibited by the user; also unnecessary once the official Provider API exists | `[VERIFIED: user instruction; Provider API docs]` |
| N3 | Fork PR review | `pull_request` gives no secrets; `pull_request_target` with PR code is a pwn-request risk | `[VERIFIED: GitHub Docs secrets note; repo ci.yml comment F15]` |
| N4 | `/update_changelog`, `/add_docs`, committable suggestions | Would need `contents: write`; out of the requested scope | `[VERIFIED: permission surface above]` |
| N5 | Branch protection requiring `Review Gate` | Adding the check to the ruleset is a one-time repository setting, not a workflow change, and it is owned outside this change: `main` requires `["CI (Linux)", "Arch simulation"]` and stays that way until #115 merges. It is now safe to require: every head that has a review run of its own gets a `Review Gate` conclusion on itself (D32), so the check blocks an unreviewed head only until its review lands. A force-pushed head's older check stays on the older commit, which no rollup reads, because checks are per-commit. The earlier warning against requiring it (a push started no review; a `/review` anchored on the default branch) described the behaviour before D31/D32 | `[VERIFIED: GitHub branch protection docs; AGENTS.md "Agent review surface"]`; `[MEASURED: required checks on main, 2026-11-19]` |
| N6 | Ollama or another local model | Needs an always-on host; user chose Command Code | `[VERIFIED: user directive]` |
| N7 | Auto-merge or auto-approve | Review is advisory; approval stays human | `[VERIFIED: enable_auto_approval default false]` |
| N8 | `workflow_run` CI-conclusion trigger | Doubles runs; the chosen trigger set matches the user's "describe + review on open" choice | `[VERIFIED: github_action_runner.py workflow_run branch]` |
| N9 | ~~Review on every push (`synchronize`)~~ | Withdrawn by #115: the trigger now includes `synchronize` (D31). The earlier decision answered "one review per PR is enough" for a surface that judged a PR; the gate judges a commit, and a pushed commit with no review merged unreviewed (#112). Bounded by the reviewed-SHA skip, so a push that does not change the diff spends no model call | `[VERIFIED: user instruction, superseded 2026-11-19]`; `[MEASURED: #112]` |
| N10 | Path filters for `target/**`, `Cargo.lock` | User: those paths are reviewed too | `[VERIFIED: user instruction]` |
| N11 | Per-directory `.pr_agent.toml` rules | Not requested; one global policy is enough | `[VERIFIED: user instruction]` |
| N12 | TOON for the bot's own PR comment | The comment format is pr-agent's; the state command emits the compact form instead | `[VERIFIED: pr_reviewer prompts and renderer]` |
| N13 | ~~Checks API, to anchor the gate on the PR head after a `/review` refresh~~ | Adopted by #115 as D32. The objection was that the job writing the check could be made to run the PR head's copy of the gate during bootstrap, so a PR could forge its own verdict. It cannot here: the trigger is `workflow_run`, which loads this workflow and `scripts/review-state.sh` from the default branch (D29), and the write is one check run named `Review Gate` on one commit | `[MEASURED: workflow_run anchoring on #99, 2026-11-17; superseded 2026-11-19]` |
| N14 | ~~A required check for a pushed head~~ | Closed by D32. Its reasoning held while a check on a pushed head was anchored there once and nothing could revise it. Now every push produces a review run whose gate check lands on that head, and a `/review` writes the verdict onto the head too, so requiring `Review Gate` blocks an unreviewed head until its review lands instead of for good. The setting itself is N5 | `[VERIFIED: review-gate.yml; scripts/gate-review-selfcheck.sh]`; `[MEASURED: 44458773859, 2026-11-18]` |

## Coverage

| Component | Knobs covered | Knobs deliberately defaulted |
|---|---|---|
| Workflow | triggers, permissions, concurrency, guards, timeout, image pin, env | runner choice, retry of the job itself |
| pr-agent | model, fallback, custom_model_max_tokens, max_model_tokens, max_output_tokens, reasoning_effort, additional_reasoning_effort_models, ai_timeout, repo context, auto tools, response language | temperatures, seeds, callbacks, labels, score/effort sections |
| Provider API | base URL, endpoint, auth, model, reasoning effort | ZDR header, Responses API, Anthropic Messages |
| Secrets | name, scope, fork policy | environment-scoped secrets |
| Policy | reviewer/description/suggestion instructions, ignore rules via repo context | per-directory settings, global org settings |
| Everything else in `configuration.toml` | `[N/A]` — webhooks, callbacks/telemetry, vector DB, chat integrations, publishing cosmetics, OpenRouter controls, per-directory/global settings | Not reachable from this deployment |

Coverage script: `coverage_diff.py` against `configuration.toml` reported many
`GAP` rows for the `[N/A]` group above and `SINGLE-SOURCE` because only one
machine-readable source was supplied. Both are recorded here, not hidden. The
Provider API facts were checked against the live endpoint instead of a file.

## Agent experience (AX)

The surface is built agent-first: a coding agent reads the PR comment and acts;
a human reads it second. The contract lives in `AGENTS.md` under "Agent review
surface".

| Role | How it is served |
|---|---|
| Reader | `.github/PR-AGENT.md` is the reference; policy loads from `main`; repo context bounded at 900 lines |
| Developer | Inline file:line findings, typed risk and merge verdict, one persistent comment, deterministic `/review` and `/describe` commands |
| End user (agent) | Machine-readable state over prose; merge stays a human action; CI and Sim remain the gates |

Invariants applied:

- Typed contracts over prose: `require_risk_assessment`,
  `require_merge_recommendation`, `inline_key_issues`, and the
  `pr-agent-review-state:v1` block the bot embeds in its comment.
- State command: `scripts/review-state.sh` turns that block into compact state:
  head staleness, coverage, finding counts, and `path:line` rows.
- Recovery-shaped failures: a failed tool fails the check and posts a failure
  comment; it never turns green.
- Machine-readable state: one persistent comment with stable keys, not a thread
  an agent has to reconstruct.
- Trust boundary closed by default: rules and config from `main`, fork PRs
  skipped, commands limited to OWNER, MEMBER, COLLABORATOR.
- Prose guides, gates guarantee: the bot advises; CI and Sim enforce.

## Verification

| Check | Result |
|---|---|
| YAML parse, TOML parse | pass |
| Live models list | `deepseek/deepseek-v4.1-flash`, 1,000,000 context, `/chat/completions` |
| Direct API, small prompt, reasoning high/low/off | content returned, `finish_reason=stop` |
| Exact review prompt, reasoning low, 64k cap | 118s, 14,540 completion tokens, valid YAML |
| Exact review prompt, reasoning max, 64k cap | failed: 64,000 reasoning tokens, empty content, `finish_reason=length` |
| Exact review prompt, reasoning max, 128k cap | 498s, 70,483 reasoning tokens, valid YAML |
| pr-agent review, reasoning low, 32k cap | failed: empty content, `finish_reason=length` |
| pr-agent review, reasoning low, 64k cap, 64k model budget | failed: no input capacity |
| pr-agent review, reasoning low, 64k cap, 128k model budget | 238s, review generated, not published |
| pr-agent `doctor` | 3/3 (config, key, completion) |
| pr-agent `describe` on PR #12 | generated, not published |
| pr-agent `review` on PR #12, reasoning off | completed in 22s |
| Env spelling `CONFIG__MODEL`, `CONFIG__REASONING_EFFORT`, `CONFIG__ADDITIONAL_REASONING_EFFORT_MODELS`, `GITHUB_ACTION_CONFIG__AUTO_IMPROVE`, `OPENAI__API_BASE` | all read by `get_settings()`; same spelling as upstream's own workflow |
| Full review with the exact workflow env, dunder names, reasoning max | 509s, review generated, not published |
| New AX fields (`inline_key_issues`, risk, merge verdict, chunking) | keys verified in configuration.toml; first live run is the next PR after merge |
| Workflow on PR #19 | success, 400s, all 6 checks passed, review comment posted |
| `scripts/review-state.sh` on PR #20 | 1 finding, stale true, coverage full, `path:line` table |
| State command empty / usage / error paths | 0-PR message exit 0; unknown flag exit 2; missing PR exit 1 |
| `scripts/check-review-gate.sh` | 24/24: gate fail-closed on a missing, stale, untracked or incomplete review and on every verdict that did not clear the merge; `--sha` pins the commit judged; `--reviewed` ignores the verdict |
| `scripts/gate-review-selfcheck.sh` | 9/9: the reporting block extracted from `review-gate.yml` and run against a fake `gh` — a push verdict lands on the head through the job's own check, a `/review` verdict is written onto the head, a superseded run reports nothing, an unreadable head fails |
| Control: `review-gate.yml` reverted to `origin/main` | `gate-review-selfcheck.sh` exits 1 with `FAIL report-on-head`, `FAIL anchor-decision`, `FAIL checks-write` |

## Open items

1. Reasoning latency: max measured 400s on PR #19 and 498-509s locally on the
   same diff. The retry budget is 2 x 900s = 30 min, under the 45-minute job
   timeout. A larger diff can still time out; the check fails loudly. Watch for
   `finish_reason=length` in the Action log. `[UNVERIFIABLE]` without a larger PR.
2. Docker Hub anonymous pull limits on GitHub runners. `[UNVERIFIABLE]`; a limit
   fails the job loudly.
3. Provider API access is plan-gated (every plan except Go). The key used for
   local tests and PR #19 worked; the CI key must come from a plan with API
   access. `[VERIFIED: Provider API docs]` + `[MEASURED: live calls succeeded]`.

## Rollback

Delete `.github/workflows/pr-agent.yml`, `.pr_agent.toml`, and
`.github/PR-AGENT.md`; remove the `COMMAND_CODE_API_KEY` secret. No runtime
state, no deployed service, no data to clean up.
