# Reviewer decision: open-code-review vs pr-agent

Question: between `alibaba/open-code-review` (OCR) and `qodo-ai/pr-agent`
(already wired in this repo), which single reviewer should this repo keep?

Every claim below carries the command or the `file:line` that produced it. A
claim I could not prove is marked **UNPROVEN** with what would prove it.

Read now, at this HEAD:

| Fact | Command | Value |
|---|---|---|
| repo HEAD | `git -C /home/prm/project/aur-prefetch rev-parse --short HEAD` | `b186b66` |
| OCR upstream clone | `git -C /tmp/ocr-src describe --tags` | `v1.14.0` (latest tag) |
| OCR pinned here | `git show ci/ocr-shadow:.github/workflows/ocr-shadow.yml` | `OCR_VERSION: v1.13.13` (line 57) |
| pr-agent pinned here | `.github/workflows/pr-agent.yml:117` | `pragent/pr-agent@sha256:548e894a…` (0.50.0) |
| required checks | `gh api repos/PremModhaOfficial/aepm/branches/main/protection --jq .required_status_checks.contexts` | `["CI (Linux)","Arch simulation","Review Gate"]` |

---

## Part 1 — OCR capability inventory, from upstream

Sources: `/tmp/ocr-src` at tag `v1.14.0`
(`git clone --depth 50 https://github.com/alibaba/open-code-review ocr-src`),
plus the repo's own pin `v1.13.13`, whose release binary was downloaded and
hash-verified for Part 3.

### 1.1 Every action input and its default

`awk '/^inputs:/,/^outputs:/' action.yml`, defaults read from the `default:`
line under each input. "—" means the input declares no default.

| Input | Default | `action.yml` |
|---|---|---|
| `llm_url` | — (required) | 11-13 |
| `llm_auth_token` | — (required) | 14-16 |
| `llm_model` | — | 17-19 |
| `llm_use_anthropic` | — → **empty is treated as `true`** (Anthropic) | 20-27, applied at 623-632 |
| `llm_protocol` | — | 28-36 |
| `llm_auth_header` | — | 37-39 |
| `llm_extra_headers` | — | 40-42 |
| `llm_extra_body` | `{"thinking": {"type": "disabled"}}` | 43-52 |
| `llm_reasoning_effort` | `''` | 53-65 |
| `language` | `English` | 66-71 |
| `llm_timeout` | `300` | 72-75 |
| `review_task_timeout` | `15` (minutes) | 76-79 |
| `github_token` | `${{ github.token }}` | 80-83 |
| `ocr_version` | `latest` | 84-87 |
| `review_concurrency` | — | 88-90 |
| `background` | — | 91-93 |
| `rule` | — | 94-96 |
| `effort` | `''` (CLI default `medium`) | 97-103 |
| `max_tokens_budget` | `''` = unlimited | 104-116 |
| `stream_progress` | `false` | 117-125 |
| `upload_artifacts` | `true` | 126-132 |
| `sticky_summary` | `true` | 133-138 |
| `incremental` | **`false`** | 139-146 |
| `incremental_overlap_threshold` | `0.6` | 147-156 |
| `resolve_outdated` | `false` | 157-174 |
| `review_comment_batch_size` | `50` | 175-183 |
| `route_severity_below` | `''` | 184-194 |
| `route_categories` | `''` | 195-206 |
| `checkpoint_range` | `false` | 207-218 |
| `full_review` | `false` | 219-225 |
| `base_ref` | — | 226-230 |
| `head_sha` | — | 231-233 |
| `pr_number` | `''` | 234-243 |
| `node_version` | `24` | 244-247 |

Two defaults that surprise: `incremental` is **off**, and an empty
`llm_use_anthropic` selects the **Anthropic** protocol (action.yml:623-632).
The second is the trap the repo already hit once:
`ci/ocr-shadow:.github/workflows/ocr-shadow.yml:149-152` records that with only
`OCR_LLM_*` env vars the CLI POSTs `<base>/v1/messages` and this endpoint
answers 404, so `protocol openai` must be set explicitly.

### 1.2 Inline review comments — yes

- `scripts/github-actions/post-review-comments.js:644`: "Publish a single
  bounded batch of inline comments via one createReview call".
- `post-review-comments.js:495-500`: findings are sorted before partitioning so
  identical reruns produce identical batches; that sorting is what makes
  per-batch reconciliation against already-posted fence IDs work.
- `post-review-comments.js:167-168`: HTML-comment fence IDs are the idempotency
  marker, so a `createReview` that landed before a retry is not posted twice.
- Batch size default 50 (action.yml:175-183).
- A summary comment is also posted (an issue comment), per
  `examples/github_actions/README.md:66`.

### 1.3 Dedupe across pushes

| Knob | Default | Behaviour (quoted) | Line |
|---|---|---|---|
| `incremental` | `false` | "only append inline comments whose (path, line range) does not overlap an existing bot review comment… History is never deleted" | 139-146 |
| `incremental_overlap_threshold` | `0.6` | IoU threshold for multi-line overlap; single-vs-multi never match | 147-156 |
| `sticky_summary` | `true` | "update an existing summary comment in place (sticky) instead of posting a new one each run" | 133-138 |
| `resolve_outdated` | `false` | `false` "does nothing and makes no API calls"; `report` logs only; `true` resolves, and **requires the caller's workflow to grant `contents: write`** or GitHub returns FORBIDDEN | 157-174 |
| `checkpoint_range` | `false` | with it on, review only the range since the last checkpoint, with a fail-closed `range_mode` of `full` on `base_changed`/`config_changed`/`not_ancestor` | 207-218, 282-307 |

So out of the box: sticky summary on, incremental comment dedupe **off**,
thread resolution **off**, range checkpointing **off**.

### 1.4 Batching

One `createReview` per batch of up to `review_comment_batch_size` (default 50)
comments; batches are sorted and chunked from a deterministic order
(`post-review-comments.js:495-533`). `route_severity_below` / `route_categories`
can move a finding out of the inline path into the summary instead
(action.yml:184-206); it is mutually exclusive with the inline modes
(action.yml:262-264).

### 1.5 SARIF

The **CLI** can emit it: `ocr review --help` →
`--format string   output format: text, json, or sarif (default "text")`.
The **action** does not upload it: `rg -n -i sarif action.yml` returns zero
hits, and the post step only calls `createReview` and the summary comment.
No `github/codeql-action/upload-sarif` step exists anywhere in `action.yml`.
**Answer: no SARIF upload.**

### 1.6 Non-zero CLI exit

- `action.yml:1036-1041` — step "Fail job on OCR error", `if: env.OCR_EXIT_CODE != '0'`, `exit "${OCR_EXIT_CODE}"`. The job goes red.
- `action.yml:1043-1044` — step "Post review comments", `if: env.OCR_EXIT_CODE == '0'`. On a non-zero exit **nothing is posted**.
- `action.yml:113-115` (in the `max_tokens_budget` description): "On a non-zero exit, the Action can upload the raw output as an artifact but skips posting PR comments."
- `action.yml:110-111`: "A budget-only partial review with usable coverage exits 0." A truncated review is **green**.
- `action.yml:107-109`: "over-budget and skipped files are reported as failed(budget)".

The failure guard therefore distinguishes *crashed* from *did not look*. It does
not distinguish *looked at nothing* from *looked and found nothing*: both are
exit 0 with an empty `comments` array. This is measured in Part 3 (#156).

### 1.7 Does it need `pull_request_target` for forks?

The upstream demo says yes, and uses it:

- `examples/github_actions/ocr-review.yml:56-61`: "Use pull_request_target
  instead of pull_request so that secrets are available even for PRs from forks.
  This is safe because the reusable action only reads the diff and does not
  execute any code from the PR."
- `examples/github_actions/README.md:63`: "When a PR is opened, the workflow
  triggers (uses `pull_request_target` for fork secret access)."

The safety argument is structural and checkable: the action checks out the
**base**, not the head, and fetches the head's git objects separately
(`action.yml:414-431`, "Checkout the trusted base, not the PR head… the head
commit's blobs are fetched separately so they are resolvable without
materializing untrusted PR files into the working tree"). Fork-safe head fetch
is `git fetch origin pull/<n>/head`, not the merge ref (action.yml:423-431).

What that argument does **not** cover: the untrusted diff text still reaches a
model that has tools (`code_search`, `file_read` — measured in Part 3), on a
runner holding the model key. That is prompt-injection surface, not code
execution. It is the reason Part 5 keeps `pull_request` and skips forks.

### 1.8 Minimum `ocr_version`

- `v1.9.6` — the floor; the action fails below it (`action.yml:569-574`,
  message "v1.9.6 or newer is required").
- `v1.9.8` — required when `stream_progress: true` (`action.yml:586-594`).
- `v1.10.0` — required when `effort` is set (`action.yml:576-584`).

The `ocr_version` input defaults to `latest` (action.yml:84-87), and
`examples/github_actions/README.md:27-41` states the consequence: pinning the
action reference alone does **not** freeze behaviour, because the action
`npm install -g`s the CLI at run time — so "pin both".

---

## Part 2 — pr-agent parity, from this repo

What the current setup actually uses. Files: `.pr_agent.toml`,
`.github/workflows/pr-agent.yml`, `.github/workflows/review-gate.yml`,
`scripts/review-state.sh`.

| Capability | Used? | Where |
|---|---|---|
| Inline comments (each finding as an inline comment) | yes | `.pr_agent.toml:61` `inline_key_issues = true`; upstream default is `inline_key_issues=false` (`configuration.toml:202`, inside the pinned image — see the note under this table), so this repo's line is the override |
| One persistent comment, updated in place | yes | `configuration.toml:193` under `[pr_reviewer]` (`persistent_comment=true`); used at `pr_reviewer.py:448-486`. (`:275` is the same key in `[pr_code_suggestions]`, a different tool) |
| Typed state block (`<!-- pr-agent-review-state:v1 … -->`) | yes — **emitted by the image natively**, with this repo's workflow appending one only when the image produced none | image: `persistent_finding_state=true` (`configuration.toml:196`) + `pr_agent/algo/review_finding_state.py:181`; fallback append `pr-agent.yml:191-195` (returns early if a block exists) and `pr-agent.yml:222-231`; parsed `review-state.sh:231-240`. The #140 gap was the **clean-review** path, not the capability |
| Review Gate integration (model-free verdict on the PR head) | yes | `review-gate.yml:23-26` (`workflow_run` on `PR Agent`), verdict written with the Checks API `review-gate.yml:143-149`, decided by `scripts/review-state.sh --gate` |
| Incremental skip (do not re-review a reviewed commit) | yes | `pr-agent.yml:92-106` calls `review-state.sh "$PR" --reviewed --sha "$SHA"`; trigger `synchronize` `pr-agent.yml:26`; `handle_push_trigger` + `push_commands` `pr-agent.yml:134-135` and `.pr_agent.toml:143-145` |
| Skipping by head identity, not by diff overlap | yes | the skip is commit-keyed (`review-state.sh --reviewed`), so a rebase that changes no diff still costs a model call only if the commit changed; contrast OCR's line-range IoU dedupe (action.yml:147-156) |
| Repo rules as context, from the default branch | yes | `.pr_agent.toml:44-46` `repo_context_files`, `repo_context_from_default_branch = true`, `repo_context_max_lines = 900` |
| Patch trimming / call caps | yes | `.pr_agent.toml:73-74` `enable_large_pr_chunking = true`, `max_number_of_calls = 3`; `.pr_agent.toml:57` `num_max_findings = 5` |
| Token/cost telemetry on the comment | yes | `.pr_agent.toml:52` `output_run_details = true` (model, tokens in/out/total, duration, AI calls); this repo's own cost table is built from it |
| Config cannot be rewritten by the PR | yes | config read from a default-branch checkout `pr-agent.yml:78-83`; rules from default branch `.pr_agent.toml:45` |
| SARIF | no | nothing consumes it; the merge signal is `Review Gate` |

**Note on `pr_agent/...` and `post-review-comments.js` citations.** None of those
paths exist in this repository (`git ls-files | rg -c 'pr_agent/'` → `0`). They
are inside the pinned image `pragent/pr-agent@sha256:548e894a…`
(`pr-agent.yml:113`); OCR's are inside the upstream checkout. A row citing one is
resolved by reading the image tag `0.50.0-github_action` or `/tmp/ocr-src` at
the tag named in Part 1, not by a path in this tree.

### OCR capability → pr-agent verdict

| OCR capability (Part 1) | pr-agent | Verdict |
|---|---|---|
| Inline review comments, batched (`post-review-comments.js:644`, batch 50 @ action.yml:175-183) | `.pr_agent.toml:61` + `configuration.toml:202` | **native** |
| Sticky summary updated in place (action.yml:133-138) | `configuration.toml:193`, `pr_reviewer.py:448-486` | **native** |
| Incremental append across pushes (action.yml:139-146, default off) | `synchronize` + `push_commands` + reviewed-SHA skip (`pr-agent.yml:26,92-106,134-135`) | **native + script**, and keyed on commit instead of line overlap |
| Resolve outdated threads (action.yml:157-174: tri-state `false`/`report`/`true`, default `false`; `true` additionally needs `contents: write` in the caller, action.yml:163-171) | `resolve_outdated_inline_threads = false` (`configuration.toml:405`); `pr-agent.yml:30-33` grants `contents: read` only | **parity** — both off, and neither could resolve without widening permissions |
| Range checkpointing (action.yml:207-218, default off) | the `--reviewed` skip + `pull_request` trigger | **native**, different mechanism |
| File types covered | markdown is excluded before the model sees it (`exclude_reason: "unsupported_ext"`, measured §3.1) | the whole diff, chunked (`.pr_agent.toml:73-74`) | **pr-agent**; this repo argues in prose |
| Typed machine-readable state | image-native (`configuration.toml:196`), workflow fallback (`pr-agent.yml:191-195`) → `review-state.sh:231-240` | **native + fallback** |
| Catches what the incumbent missed | one measured instance: `.github/PR-AGENT.md` D38 / PR #160 (§3.5) | n/a | **OCR, once** — no mechanism to repeat it |
| Job red when no review happened | `_fail_on_recorded_tool_error` (PR-AGENT.md D13) + gate `unrecorded` → fail (D34) | **native + gate**; OCR's action treats `skipped` as green (Part 3) |
| SARIF upload | none | **does not have it** — and nothing needs it |

Parity holds on every capability that decides a merge: pr-agent has each one
natively or this repo already implements it. The typed block is native to the
image (`persistent_finding_state=true`) — the workflow appends one only on the
clean-review path where the image emits none — and it is the only thing the
required check reads.

---

## Part 3 — cost and failure, measured

### 3.1 OCR, run locally against the same endpoint pr-agent uses

Binary: the repo's own pin, hash-verified.

```
curl -fsSL -o /tmp/ocr-bin \
  https://github.com/alibaba/open-code-review/releases/download/v1.13.13/opencodereview-linux-amd64
sha256sum /tmp/ocr-bin
→ e3eb634c8205a120c16e9943de00aef895e2cd86d6b13c38e25427c924275ec8
```
That equals `OCR_SHA256` in `git show ci/ocr-shadow:.github/workflows/ocr-shadow.yml:59`.
`/tmp/ocr-bin --version` → `open-code-review v1.13.13 (445ad9de) linux/amd64`.

Endpoint: `https://api.commandcode.ai/provider/v1`, model
`deepseek/deepseek-v4.1-flash`, `llm.protocol=openai` — the same subscription
and model `.pr_agent.toml:9` uses. Connectivity proven first:
`/tmp/ocr-bin llm test` → "✓ Connection test successful / ✓ Tool-call round trip
verified" (the tool-call round trip matters: the review is agentic).

Diffs: local clones of two real PR heads, merge-base against real
`origin/main` (`d9a00ef`), so the range is the PR's own:

| PR | merge-base | diff |
|---|---|---|
| #158 `ci/pr-conflict-watchdog` head `b186b66` | `99d5e03` | 7 files, +521/−2 |
| #156 `docs/prose-claim-rule` head `4d7f06d` | `3888b91` | 1 file, +10 |

Command shape for each (detached, so nothing blocked):

```
ocr review --from <merge-base> --to HEAD --format json --output ocr-<tag>.json \
  --audience agent --concurrency 4 --max-tokens-budget 0 --timeout 12 \
  --effort <high|low>
```

`ocr review --help` (v1.13.13) defines `--timeout int` / "concurrent task budget
in minutes" (default 15), so it is not a wall-clock cap on the whole run: the
high-effort run passed `--timeout 12` and was still cancelled at 899.9 s by my
own 900 s wrapper, while the low-effort run passed the same value and finished
at 719 s. The wrapper's cap, not OCR's budget, is what ended the first run.

The only flag that differs between the two #158 rows is `--effort`: `high` for
the first (which did not complete), `low` for the second (which did).

| Run | exit | status | `comments` | `total_tokens` in/out | files | tool calls | elapsed |
|---|---|---|---|---|---|---|---|
| #158, `--effort high` | 0 (wrapper) | `failed` | **0** | **619,588** (505,523 / 114,065; 315,264 cache-read) | 5 selected, **0 completed, 5 failed**, 2 excluded | 19 (`code_search` 9, `file_read` 10), `failure: 0` | 899.9 s |
| #158, `--effort low` | 0 | **`complete`** | **6** | **1,476,472** (1,308,776 / 167,696; 922,496 cache-read) | 5 reviewed, 2 excluded | 50 (`code_search` 24, `file_read` 19, `code_comment` 3, `file_read_diff` 3, `file_find` 1) | 719 s (11m59s) |
| #156, `--effort high` | 0 | `skipped` | 0 | 0 | 0 selected, 1 excluded | 0 | 13 ms |

Read from `/tmp/ocr-158.json`, `/tmp/ocr-158low.json`, `/tmp/ocr-156.json`:
`jq '{status, summary, tool_calls: .tool_calls.total}'`.

What those two rows mean, precisely:

- **#158 @ `--effort high`**: `"message": "Review failed (cancelled): 0 finding(s); 5 of 5 selected
  item(s) failed."` and `coverage.failed` lists `ci.sh`,
  `scripts/check-pr-conflicts.sh`, `scripts/check-ci-architecture.sh`,
  `.github/workflows/pr-conflicts.yml`, `scripts/check-pr-conflicts-workflow.sh`
  — each one now reports `{"classification": "cancelled", "reason": "file review
  was cancelled"}` (no `error` key), while `tool_calls.failure = 0`. So the tool
  calls succeeded and the *items* were cancelled — the cancellation the next
  paragraph attributes to my 900 s wrapper. Zero findings on a 521-line diff for
  620k tokens.
  **Bound to state honestly**: the run was killed by my own 900 s wrapper
  (`ELAPSED 899,944 ms`, stderr `Error: review failed: context canceled`), so
  this row measures "did not finish inside 15 minutes", not "would never
  finish". What it does prove: at `--effort high` with no token ceiling, 15
  minutes and 620k tokens did not produce one completed file review.
- **#158 @ `--effort low`**: the same diff with the same binary and endpoint
  **completes**: `status: complete`, `comments: 6`, `files_reviewed: 5`.
  The six are real, on-diff, and carry `path`, `start_line`, `end_line`,
  `content`, `existing_code`, `suggestion_code`, `severity`. One, on
  `scripts/check-ci-architecture.sh:94-95`, is substantive: it argues that
  `scripts_actual` is measured over every *mention* of a `scripts/` path in
  `ci.sh` rather than over invocations, so a commented-out gate raises the
  count, and the only way to make the gate green is to bump the doc's number —
  "exactly the wrong typed number the block was added to prevent".
  So the tool **can** review a multi-file diff; it does so at low effort, in 12
  minutes, for **1.48 M tokens**. Every earlier statement in this repo that it
  "has never completed a review of more than one changed file"
  (`PR-TRIAGE.md:120-121`) is true only of the configurations that were tried,
  and this run supersedes it.
- **#156**: a 10-line docs change. `status: skipped`,
  `"Review skipped: no items were selected."`, `excluded: [{path: "AGENTS.md",
  exclude_reason: "unsupported_ext"}]`. **Exit 0, 0 tokens, 13 ms, no comment.**
  This is the silent-green shape Part 5 has to answer for, and it is the exact
  class of PR (prose claims) that motivated the shadow reviewer:

  `ci/ocr-shadow:.github/workflows/ocr-shadow.yml:8-11` — "pr-agent emits no
  typed block on a zero-finding review, so a clean pull request can never
  satisfy Review Gate (#141/#142), and its recall is unmeasured.
  open-code-review always emits a `comments` array, empty or not."

  Measured: on a docs-only diff it emits an empty array **and reviews nothing**,
  so the array's existence is not evidence a review happened.

Excluded on #158 as well: `docs/CI-ARCHITECTURE.md` and `.github/PR-AGENT.md`,
both `unsupported_ext`. Two of the seven files this repo's reviewer must judge
are invisible to OCR — the policy documents are markdown.

### 3.2 OCR, from its own GitHub history (independent of my runs)

```
gh api 'repos/PremModhaOfficial/aepm/actions/workflows/425179381/runs?per_page=100'
→ 11 runs: **7 success, 4 failure**
  (`gh api .../runs --jq '[.workflow_runs[].conclusion] | group_by(.) | map({(.[0]): length}) | add'`
  → `{"failure":4,"success":7}`)
```
Durations of every run: 10s, 17s, 21s, 135s, 145s, 167s, 171s, 198s, 384s, 388s, 815s.
The fast failures are the signal. First-hand log, run `44897913174`:

```
gh run view 44897913174 --log
→ "input_tokens": 349,
  "budget_exceeded": true
  Error: review failed: 4 of 4 selected item(s) failed
```
Run `44789504504` produced the identical pair. 349 input tokens against a
120,000 budget, `budget_exceeded: true`, and **every** selected item failed.
That is not a budget being reached; that is the accounting failing. Same shape
as `PR-TRIAGE.md:65-75` records, reproduced here from the API rather than quoted.

### 3.3 pr-agent, from its own runs and comments

Durations — `gh run list --workflow "PR Agent" --limit 40 --json createdAt,updatedAt,conclusion`:

| n | window | min | median | p90 | max |
|---|---|---|---|---|---|
| 40 | 2026-11-21T13:29:40Z → 2026-11-22T04:20:06Z | 2.0 s | 436.5 s | 592.0 s | 1938.0 s |

That window is **not** the one `docs/CI-ARCHITECTURE.md:36` records
("median 452s, p90 849s, max 2376s (n=20)"), and PR-AGENT.md D10 records a
third figure from per-call data ("p50 325s, p95 414s, max 848s" over 23 calls).
Three samples, three windows; this table names its own and supersedes nothing.
Anyone quoting a duration should quote with its window, or the numbers disagree
for no visible reason.

Conclusions over those 40: 30 `success`, 3 `failure`, 3 `cancelled`,
2 `skipped`, 2 still running. **Failure rate 3/40 = 7.5%**, or 3/33 = 9.1% of
runs that reached a conclusion and were not deliberately skipped.

Tokens — the `run details` section of every bot review comment, across the 30
most recent PRs (`gh api --paginate .../issues/$n/comments`, grep `^- Tokens:`):

| metric | value |
|---|---|
| reviews recorded | 30 |
| median total | **52,933** |
| p90 total | 64,063 |
| max total | 79,047 |
| median in / out | 22,614 / 32,815 |

Two conventions, so the numbers can be re-derived rather than argued: n=30
totals, and the median of an even set is the mean of the 15th and 16th values —
here `(52,366 + 53,500) / 2 = 52,933` — so `52,933`, `22,614` and `32,815` are
interpolated and appear in no single comment; the p90 (64,063) and max (79,047)
are nearest-rank and do appear verbatim. Sorted totals, for anyone who wants to
recompute: 17,996 23,015 27,525 28,432 32,563 35,164 37,735 38,576 38,913 39,117
39,769 48,051 49,825 50,498 52,366 53,500 55,737 56,020 56,295 57,560 59,734
59,930 62,073 63,390 63,455 63,645 64,063 66,375 77,356 79,047.

### 3.4 pr-agent on the *same* diff, for a like-for-like figure

Everything above compares OCR against pr-agent's median across PRs. The
defensible comparison is the same PR. PR #158 carries a pr-agent review
(`gh pr view 158 --json comments`, the body with
`<!-- pr-agent-review-state`), at commit `d22ce1f` (one before the head OCR was
pointed at):

```
- Model: openai/deepseek/deepseek-v4.1-flash
- Tokens: 30,839 in / 33,224 out / 64,063 total
- Time cost: 439.1s
- AI calls: 1
```
and its typed block holds **16 findings**, 14 `RESOLVED` and 2 `ACTIVE`, across
`scripts/check-pr-conflicts.sh`, `scripts/check-pr-conflicts-workflow.sh`,
`.github/workflows/pr-conflicts.yml`, `ci.sh`, **`docs/CI-ARCHITECTURE.md`** and
**`.github/PR-AGENT.md`**. The last two are the markdown OCR excludes.

**A fairness bound on that 16.** pr-agent's block accumulates across the PR's
pushes: 14 of the 16 are `RESOLVED`, i.e. raised by an earlier run and fixed in
a later commit, and 2 are `ACTIVE` at the reviewed head. Each entry carries
`first_seen`/`resolved_at`, so the number is a history, not one pass. OCR ran
once, at the head, and raised 6. The honest comparison is therefore **cost of
one pass on the same diff** (23.0×, below), not a ratio of findings per token —
those two counts cover different numbers of runs and I do not ratio them.

### 3.5 The one thing OCR did catch, recorded against my own verdict

A reviewer that never wins is not a reviewer, and OCR has one measured win that
this document must carry or it is dishonest:

`.github/PR-AGENT.md` D38, as added by the **open** PR #160
(`gh pr diff 160`), ends:

> "Found by the second reviewer, not by this one: open-code-review v1.14.0, run
> locally on the same diff, reported that `medium` was absent from D5's
> `[off,low,high,max]` and would be forwarded unvalidated"

That is a real defect class: the gateway answers `200` for an unlisted
`reasoning_effort` value and silently swallows it, so `medium` would have
shipped unvalidated. **What is OCR's and what is not**: the *list omission* is
OCR's finding. The measurement that the gateway swallows an unlisted value is
not — D38 says it "was measured with three direct gateway calls", by the session
that wrote the row. And "pr-agent did not report it" needs its exact scope:
pr-agent's review of #160 (`gh pr view 160 --json comments`) filed "**Unmeasured
effort claim**" on `.github/PR-AGENT.md:62` and "**Stale effort claim**" on
`.pr_agent.toml:20` — both about this same effort question. It flagged the
*claims*; it did not catch that `medium` was missing from the registry list.

So the correct statement is the narrow one: **OCR reported one thing pr-agent
missed — a missing value in a documented list — and it completed one multi-file
review, at `--effort low`, in this investigation (§3.1). Every `--effort high`
run has produced zero completed files.**

**Unique coverage is smaller than that one win suggests.** The finding this
document calls "substantive" in §3.1 — the gate counts mentions of `scripts/`
paths in `ci.sh` rather than invocations — is the same class as a finding
pr-agent already has open on #158: `docs/CI-ARCHITECTURE.md:177` "**Stale script
count**" and `scripts/check-pr-conflicts-workflow.sh:196` "**Unchecked D38 prose
count**", both `ACTIVE` in the same block. So the unique coverage OCR bought here
is §3.5 alone: one finding, on one diff, about a list.

This also bounds UNPROVEN #5 below: v1.14.0 has been run locally at least once,
by that session, on PR #158's diff. What is still unproven is only whether
v1.14.0 fixed the `budget_exceeded` accounting.

### 3.6 The comparison

Like-for-like, both reviewers on PR #158's diff:

| | OCR (`--effort low`, one pass) | pr-agent (one pass) |
|---|---|---|
| tokens | **1,476,472** | **64,063** |
| wall time | 719 s | 439.1 s |
| findings raised by that pass | 6 comments | not isolable from the block (§3.4) |
| findings visible on the PR now | 6 (untriaged) | 16 total, 2 `ACTIVE` |
| docs/ prose files examined | **no** — 2 of 7 excluded as `unsupported_ext` | yes |
| output at `--effort high` (the quality setting) | none: 15 min, 620k tokens, 0 completed files | n/a — one call, no effort ladder |

Across all reviews, not just #158:

| | OCR | pr-agent |
|---|---|---|
| cost per review | 1,476,472 tokens when it completes | **52,933** median |
| failure rate | 4/11 = **36%** on its own workflow | 3/40 = **7.5%** |
| does it review prose | no — `unsupported_ext` (#156: 100% of the diff; #158: 2 of 7) | yes — plain diff chunks |
| silent skip on a docs-only PR | yes — #156, exit 0, 0 comments, 13 ms | the gate fails `unrecorded` instead |
| has it ever caught something the incumbent missed | **yes, once, measured** (§3.5) | — |

**23.0× the tokens and 1.64× the wall time, for one pass on the same diff** — and
it cannot read the two files where this repo argues its claims, while pr-agent
filed findings in both.

---

## Part 4 — the decision

Ranked argument, strongest first.

### 4.1 Output per token

Same diff, both tools (Part 3.4, §3.6). OCR, at the only effort at which it
completed, spent **1,476,472 tokens in 719 s**. pr-agent spent **64,063 tokens
in 439.1 s** on the same pull request. That is 23.0× the tokens and 1.64× the
wall time for one review pass.

I deliberately do **not** divide by findings: OCR raised 6 in one pass, while
pr-agent's 16 is a history across pushes (§3.4), so a tokens-per-finding ratio
would compare different numbers of runs. The defensible statement is the cost of
a pass, and it is 23×.

And the effort that would plausibly improve OCR's findings is the effort that
did not finish: at `--effort high`, no file completed in 15 minutes for 619,588
tokens (bounded: my own 900 s wrapper cancelled it — UNPROVEN #1). The cost is
not a tuning artifact on one side; it is where the two tools sit.

The honest counterweight is §3.5: OCR did find one thing pr-agent missed. That
is a real argument for a second reviewer. It is not an argument for *this* one
at *this* price, and Part 3.1 is the measurement that a second OCR reviewer
would add 1.48 M tokens per PR to a pipeline whose critical path is already the
review chain (`docs/CI-ARCHITECTURE.md:36`).

### 4.2 It cannot see the claims this repo argues about

`unsupported_ext` excludes markdown before the model sees anything. Measured:
#156 (AGENTS.md only) → `skipped`, 0 items, exit 0. #158 → 2 of 7 files
excluded, including `docs/CI-ARCHITECTURE.md` and `.github/PR-AGENT.md`
(Part 3.1). Meanwhile pr-agent reviewed those exact two files on #158 and filed
findings in both (Part 3.4). The failure class the shadow reviewer was built for
is prose claims on claim-change PRs (`PR-TRIAGE.md:126-127`), and prose is
exactly what OCR drops. On a docs-only PR it does not merely miss the claim, it
returns `skipped` and exits 0 — measured, #156.

### 4.3 Its failure accounting is unreliable, and its own action reports green

`budget_exceeded: true` at 349 input tokens of a 120,000 budget, on two separate
runs, with all selected items failed (Part 3.2). And the action's contract makes
`status: skipped` a green job that posts nothing (action.yml:1036-1044), so the
one case that matters — a review that did not happen — is the case the action
does not fail on. That is the failure mode this repo's own rules name and
forbid: "Never turn a gate into a silent skip that still prints success"
(`AGENTS.md`, Honesty rules).

### Verdict

**Keep pr-agent as the single reviewer. Drop open-code-review.**

The three measured reasons, strongest first:

1. **Cost for one pass on the same diff: 1,476,472 tokens against 64,063 — 23.0× raw, and 8.6× once OCR's cache-read tokens (922,496 of its total) are deducted** (Part 3.4, §3.6). That deduction is stated because 62% of OCR's bill is cache reads; the honest range is 8.6×–23.0× depending on how the provider prices them.
2. **It cannot read the files this repo argues in.** 2 of 7 files on #158 excluded as `unsupported_ext`, including `docs/CI-ARCHITECTURE.md` and `.github/PR-AGENT.md`, where pr-agent filed findings (Part 3.1, 3.4); on a docs-only PR it returns `skipped` and exits 0 (#156).
3. **Its failure accounting is unreliable and its action reports green through it.** `budget_exceeded: true` at 349 input tokens of a 120,000 budget on two runs with every item failed (Part 3.2); `status: skipped` is a green job that posts nothing (action.yml:1036-1044). 4 of 11 runs failed on its own workflow (Part 3.2).

What does **not** decide it: OCR's quality. It completed one multi-file review
and produced 6 real, on-diff findings with line numbers and patches (§3.1), and
it found one real defect pr-agent missed (§3.5). It is not a bad reviewer. It is
a reviewer that costs 23× what the incumbent costs, cannot read prose, and
fails 36% of the time.

**What this verdict does and does not say.** It says OCR should not be the
reviewer, and should not run on every PR: at 8.6×–23.0× an incumbent pass, on the
critical path, it is not a candidate for the slot. It does **not** say the second
opinion is worthless — §3.5 is a measured instance of it finding something
pr-agent missed. Part 5 therefore separates the two questions: who reviews (pr-agent,
only), and whether a cheap operator-dispatched second opinion survives (it can,
for one word's change, off the pipeline).

**What breaks if pr-agent is dropped** — these are the files that exist because
it exists, each one a required-check or gate dependency:

- `.github/workflows/pr-agent.yml` — the `workflow_run` source. `review-gate.yml:23-26` triggers on `workflows: ["PR Agent"]`; no such workflow name, no gate run, and the required `Review Gate` check never appears, blocking every PR forever.
- `scripts/review-state.sh` — the only reader of the typed block and the source of `--gate` / `--reviewed` (`pr-agent.yml:101`, `review-gate.yml:132`). Thread `9c075c1c` owns this file.
- `.github/workflows/review-gate.yml` — writes the verdict onto the PR head (`:143-149`); required check.
- `.pr_agent.toml` — the blocking rules that carry the pacman invariants (`.pr_agent.toml:84-104`) into every review.
- `.github/PR-AGENT.md` — the decision record the gate's bounds are stated in (D29, D32-D37).
- The `AGENTS.md` "Agent review surface" section — the contract other sessions read.
- Cost telemetry (`output_run_details`, `.pr_agent.toml:52`) — the only source of the numbers in Part 3.3.
- Gates that would red: `scripts/check-pr-agent-state-block.sh` (extracts the block step from the workflow), `scripts/check-review-gate.sh`, `scripts/gate-review-selfcheck.sh`.

Dropping OCR breaks nothing: it is on no default-branch workflow. Proven:
`git ls-tree --name-only origin/main .github/workflows/` → `ci.yml`, `pr-agent.yml`,
`review-gate.yml`, `scheduled-audit.yml`, `sim.yml` — **five** files, and no OCR
workflow among them. (`.github/workflows/pr-conflicts.yml` is not on `main`
either; it is the open PR #158's own addition, which is why the working tree at
`b186b66` has six.) It is on no required check, and no file on `main`.

---

## Part 5 — recipe

The winner is already wired, so "replacing the loser with the winner" is a
cleanup plus a parity proof, not a new workflow. The full YAML is included as
the rejected alternative, because a recipe that only says "keep it" cannot be
reviewed.

*(See "Adversarial review of this recipe" for what changed after review.)*

### Recipe A — chosen: pr-agent is the only reviewer; the second opinion lives off-pipeline

Two options. Both leave branch protection, every required check, and every file
in Part 4 untouched. They differ in one thing: whether OCR survives as an
operator-dispatched *measurement* — not a reviewer, no comment, no check.

**A1 — recommended, and already applied. PR #161 keeps the shadow and changed
one word.**

The shadow already exists and is already the right shape:
`workflow_dispatch`-only, posts no comment, is not a required check, and its
guard goes red on six shapes of "no review happened"
(`ci/ocr-shadow:.github/workflows/ocr-shadow.yml:1-30`). It differed from the
configuration measured to **complete** by exactly one flag: `:194-197` passed
`--effort high`, and §3.1 shows `high` produced 0 completed files in 15 minutes
while `low` completed 5 files in 12 minutes with 6 findings. #161 head
`163b4c4` passes `low` (`grep -n 'effort' .github/workflows/ocr-shadow.yml`).

```diff
-            --effort high --concurrency 4 --max-tokens-budget 0 \
+            --effort low  --concurrency 4 --max-tokens-budget 0 \
```

Why this is the cheapest option that keeps the capability: a dispatch costs about
1.48 M tokens raw / 0.55 M non-cached (§3.6), is paid only when an operator asks,
never runs on a push, and sits on no critical path. It also needs **no new
workflow file**, so `scripts/check-ci-architecture.sh` keeps its one-row-per-file
count (the file already has its row, `docs/CI-ARCHITECTURE.md:253`). Dispatch it
on claim-change PRs — the class §3.5 measured it winning.

Accept the bound: A1 keeps a workflow that this document has measured as 36%
failing (§3.2). Its red is advisory by design and gates nothing, so a red there
is a measurement that did not happen, which is what the guard says.

**A2 — no extra machinery. Close PR #161 and delete the branches.**

Steps 1–2 below. Choose this if a 1.48 M-token dispatch with a 36% failure rate
is not worth one finding per few months. Record it in the PENDING row (step 4)
that the second opinion is gone on purpose.

Order matters: nothing below touches a required check, so any step can be
reverted alone.

1. **A2 only — close PR #161** (`ci/ocr-shadow`, open). It adds
   `.github/workflows/ocr-shadow.yml`, a dispatch-only shadow reviewer.
   Verify it is not on main: `git ls-tree --name-only origin/main .github/workflows/`
   → `ci.yml pr-agent.yml review-gate.yml scheduled-audit.yml sim.yml`. Note the
   plain form of that command prints only the tree object
   (`040000 tree 29be7f3… .github/workflows`), so `--name-only` and the trailing
   slash are required. Two citations in this document come from that branch (the
   `OCR_VERSION`/`OCR_SHA256` pin and the `total_tokens` self-correction); both
   are quoted in Part 1 and §3.1 above, but keep the branch as a tag if you want
   the raw file to survive.
2. **A2 only — delete the three OCR branches**, local and remote. Two of them exist on
   `origin`; `feat/ocr-shadow-reviewer` is local only. One is checked out in a
   worktree, so removing that worktree comes first or the delete fails with
   "cannot delete branch … checked out at":
   ```
   git worktree remove /home/prm/.t3/worktrees/aur-prefetch/t3-64f75695-ff09fde0f8089063
   git branch -D ci/ocr-advisory-review ci/ocr-shadow feat/ocr-shadow-reviewer
   git push origin --delete ci/ocr-advisory-review ci/ocr-shadow
   ```
   `git branch -a --list '*ocr*'` currently prints 3 local refs and 2 remote
   refs. Deletion is safe *because* no required check depends on them: the merge
   decision reads `Review Gate`, which reads `scripts/review-state.sh` on `main`.
   `feat/ocr-shadow-reviewer` is local-only and 4 commits ahead of `origin/main`,
   so `-D` discards it; if that history matters, `git tag archive/ocr-shadow-reviewer
   f92b1f3` first.
3. **A1 and A2 both — fix what the decision makes false.** *Done separately, not
   here: #166 merged as `a358188` deletes the parenthetical below, because this
   document is prose and that sentence is a lie on `main`. The remainder of this
   step is a follow-up.* `docs/CI-ARCHITECTURE.md` (read from
   `main`) line 27 read: "a workflow-adding PR (there is one open,
   `ocr-review.yml`)". That sentence was **already false** as of #149's close
   (`gh pr view 149 --json state,closedAt` → `CLOSED`, `2026-11-21T12:47:12Z`),
   and `scripts/check-ci-architecture.sh` does not read it — its assertions are a row
   per workflow *file* (`:27-47`), not a sentence — so the gate stays green while
   the doc lies. Rewrite that parenthetical in the same change. Separately decide
   the dated flake row `docs/CI-ARCHITECTURE.md:253`
   (`OCR Review (advisory) | 4 | unmerged (PR #149)`): under A1 it stays and its
   trigger cell becomes "`workflow_dispatch`"; under A2 keep it as dated history
   or drop it, but do not leave it reading as a live count.
4. **Record the unmeasured thing** in `PENDING.md`, in the `## Not proven, on
   purpose` table (`PENDING.md:23`), whose columns are `gap | why it is not proven
   | what it would take` (:29-30) — not in the publication table, whose rows are
   the only ones that carry a live command. Put the settling command in the
   `what it would take` cell: `gh api --paginate
   "repos/$REPO/issues/$n/comments?per_page=100"` filtered to the bot's review
   bodies, i.e. the query §3.3 used. Update the `Last checked against` stamp
   (`PENDING.md:7`). The gap: pr-agent's recall on claim-change PRs is unmeasured.
   This document already carries one measured counter-example — PR #160's D38,
   §3.5 — so the row cites it rather than claiming the gap is unexampled.
   Record the second residue too, because A1 and A2 differ on it: under A2 the
   second opinion is gone, and §3.5 is the measured instance of the class
   pr-agent misses; under A1 it survives, dispatch-only, at ~1.48 M tokens per
   dispatch. A row that lists only recall under-records what the decision gave up.
5. **Change nothing else.** Specifically not `.github/workflows/pr-agent.yml`,   `.pr_agent.toml`, `.github/workflows/review-gate.yml`,
   `scripts/review-state.sh`, or branch protection. Required contexts stay
   `["CI (Linux)","Arch simulation","Review Gate"]` — proven above by
   `gh api .../branches/main/protection`.
   One caveat on line numbers: open PR #160 rewrites `.pr_agent.toml`
   (`ai_timeout` 900 → 1500, `fallback_models` → `[]`, `max_model_tokens`
   256000 → 1000000; `gh pr diff 160 .pr_agent.toml`), so every `.pr_agent.toml`
   citation in this document is pinned to a file another PR owns. The keys are
   stable; the line numbers are not.
6. **What is red when no review happened**, so nobody has to guess: two
   observables, in two places.
   - The `Review` job inside the `PR Agent` run (`pr-agent.yml:37`) — red on a
     recorded tool error (PR-AGENT.md D13).
   - The `Review Gate` check-run, conclusion `failure`, written onto the **PR
     head** through the Checks API (`review-gate.yml:136-150`). This is the one
     that matters, because it is the required check.
   Read them with `gh pr checks <pr> --json name,conclusion`.
   One accepted false-red, and it is the incumbent's own: a clean, zero-finding
   review still has to *record* a run, and PR-AGENT.md D34 makes an unrecorded
   clean review fail until a run records one. #153's append step is what records
   it (`pr-agent.yml:145-233`); when it cannot (no merge recommendation, no
   head), the gate fails closed on purpose. That is a known red, not a bug.
7. **Fork PRs get neither secret nor review nor gate check.** Because
   `pr-agent.yml:41-49` skips a fork head and `review-gate.yml:54-57` skips the
   same heads, a fork PR receives no `Review Gate` check at all and cannot merge
   under `strict: true`. That is already true today, is not introduced here, and
   the fix is a policy decision (review forks with a read-only token, or accept
   that external contributions need a maintainer branch), not a file change. It
   is stated so the recipe does not claim to leave no unfed check.
8. **Verify before closing the loop**, because two of these steps touch a
   document a gate reads:
   ```
   bash scripts/check-ci-architecture.sh   # expect: 15 assertions hold, 0 failed
   ./ci.sh                                 # AGENTS.md, Definition of done
   ```
   Measured now: the architecture gate prints `ci-architecture self-test: 15
   assertions hold, 0 failed`, exit 0, on this tree (`b186b66`, which carries PR
   #158's sixth workflow); on a clean extract of `origin/main` it prints `13
   assertions hold, 0 failed`. No `NEXT.md` item names the reviewer
   (`rg -n -i 'ocr|reviewer' NEXT.md` → no reviewer hits), so no checkbox applies.
9. **Commit this document and cite it.** It was untracked
   (`git status --porcelain docs/research/` → `?? docs/research/`), so every
   number above would have lived on one machine. It is committed by #167 with
   the decision row (D40 in `.github/PR-AGENT.md`), not with the `PENDING.md`
   row: the `:27` fix landed first as #166 (`a358188`), so those two cannot
   share a commit with this file, and the `PENDING.md` row (step 4) is a
   follow-up on the same PR that cites this document by path.

Parity is Parts 2's table: every OCR capability that decides a merge is either
native to pr-agent or already implemented here, and the one thing it lacks
natively (the typed block) is the thing `scripts/review-state.sh` reads.

### Recipe B — rejected: OCR as the single reviewer

This is the YAML a swap would need, adapted to this repo's constraints, so the
experiment is not repeated. It is documented, not proposed.

Why it is rejected, measured — the numbers that decide it are §3.6:

- **23.0× the tokens for one pass** on the same diff: 1,476,472 tokens / 719 s
  against 64,063 tokens / 439.1 s (Part 3.4). Pass cost only — §3.4 explains why
the findings counts are not ratioed.
- **It will not be red when it reviews nothing.** On #156 it exits 0 with
  `status: skipped` (`unsupported_ext`), 0 comments, in 13 ms. The YAML above
  therefore needs the explicit guard step; the tool's contract provides none
  (`action.yml:1036-1044`).
- **`--effort high` did not finish** in 15 minutes for 619,588 tokens on #158
  (bounded — UNPROVEN #1), so the effort setting is a real choice between "no
  output" and "23× the output price", not a knob to tune later.
- **Its own workflow failed 4 of 11 runs** (`budget_exceeded: true` at 349 input
  tokens, `4 of 4 selected item(s) failed`, Part 3.2).

This is not a claim that OCR reviews badly: on this diff it produced 6 real,
line-anchored findings (§3.1) and it once caught a defect pr-agent missed
(§3.5). The rejection is on price, prose coverage, and failure rate.

```yaml
# The workflow NAME must stay "PR Agent": review-gate.yml:24-26 triggers on
# `workflows: ["PR Agent"]`, so any other name leaves the required `Review Gate`
# check unfed and every PR unmergeable. This is the constraint that makes the
# swap a file-body change, not a new workflow.
name: PR Agent
run-name: "Review PR #${{ github.event.pull_request.number || github.event.issue.number }}"
on:
  pull_request:
    types: [opened, reopened, ready_for_review, synchronize]
  issue_comment:
    types: [created]
permissions:
  contents: read
  pull-requests: write
  issues: write
concurrency:
  group: review-${{ github.event.pull_request.number || github.event.issue.number }}
  cancel-in-progress: ${{ github.event.action == 'synchronize' }}
jobs:
  review:
    name: Review
    if: >-
      github.event.sender.type != 'Bot' &&
      (github.event_name != 'issue_comment' ||
        (github.event.issue.pull_request != null &&
         contains(fromJSON('["OWNER","MEMBER","COLLABORATOR"]'),
                  github.event.comment.author_association) &&
         startsWith(github.event.comment.body, '/review'))) &&
      (github.event_name != 'pull_request' ||
        (github.event.pull_request.draft == false &&
         github.event.pull_request.head.repo.full_name == github.repository))
    runs-on: ubuntu-latest
    timeout-minutes: 40
    steps:
      # Fork safety for the `issue_comment` half: the job guard above only
      # checks head.repo on `pull_request`, so an authorized `/review` on a FORK
      # PR would otherwise run with the model key in the environment. This is the
      # refusal ci/ocr-shadow:.github/workflows/ocr-shadow.yml:89-90 already
      # writes, and pr-agent.yml:41-49 has the same gap by inheritance.
      - name: Refuse a fork head before the key is used
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          PR: ${{ github.event.pull_request.number || github.event.issue.number }}
        run: |
          set -euo pipefail
          if [[ "$(gh pr view "$PR" --json isCrossRepository --jq .isCrossRepository)" != "false" ]]; then
            echo "::error::PR #$PR is a fork; refusing to run with the model key"
            exit 1
          fi
      - uses: alibaba/open-code-review@{{PIN_THE_FULL_SHA}}   # README:27-41: pin the action AND the CLI
        with:
          llm_url: https://api.commandcode.ai/provider/v1
          llm_auth_token: ${{ secrets.COMMAND_CODE_API_KEY }}
          llm_model: deepseek/deepseek-v4.1-flash
          llm_protocol: openai          # action.yml:623-632: empty means Anthropic, which 404s here
          ocr_version: '1.13.13'        # the version Part 3 measured; v1.14.0 unproven for the budget bug
          effort: low                   # action.yml:97-103; `low` is the only value measured to complete (§3.1)
          max_tokens_budget: '0'        # action.yml:104-116; 0 = unlimited, what Part 3.1 ran
          review_task_timeout: '20'     # action.yml:76-79
          sticky_summary: 'true'        # action.yml:133-138
          incremental: 'true'           # action.yml:139-146; default is false
          resolve_outdated: 'false'     # action.yml:157-174; 'true' needs contents: write
          upload_artifacts: 'true'      # action.yml:126-132
      - name: Fail when OCR reviewed nothing
        # Illustrative shape, not copy-paste: read the artifact, do not exit 1
        # unconditionally. OCR's own action already fails a non-zero exit
        # (action.yml:1036-1041) and already skips posting on one (:1043-1044);
        # the case it does NOT fail is exit 0 with status=skipped (#156).
        if: always()
        run: |
          set -euo pipefail
          jq -e '.status == "complete" and ((.comments|length) > 0)' ocr.json \
            || { echo "::error::no review happened"; exit 1; }
```

`{{PIN_THE_FULL_SHA}}` is deliberately a placeholder: this document measured
`v1.13.13` by its release binary's sha256 and has **not** resolved the action's
commit sha, so writing one here would be a fabricated pin. Take it from the
releases page and keep the `# vX.Y.Z` comment beside it, per
`examples/github_actions/README.md:27-41`.

**Trigger: `pull_request`, not `pull_request_target`.** Upstream's demo chooses
`pull_request_target` for fork secret access
(`examples/github_actions/ocr-review.yml:56-61`) and is right that the action
only reads the diff. This repo still refuses it, for the reason already written
in `.github/workflows/pr-agent.yml:15-17`: don't hand a runner holding the model
key to a fork's diff. The cost is that fork PRs get no review — the same trade
pr-agent already makes (`pr-agent.yml:41-49`, PR-AGENT.md D16/N3).

**Permissions: `contents: read`, `pull-requests: write`, `issues: write`** —
the same three pr-agent uses (`pr-agent.yml:30-33`). No `checks: write`: the
verdict is written by `review-gate.yml`, not by the reviewer. No
`contents: write` unless `resolve_outdated: 'true'`, which this recipe leaves
off.

**Model key:** `secrets.COMMAND_CODE_API_KEY`, the existing repository secret
(`pr-agent.yml:121`). No new secret. On a fork PR under `pull_request`, GitHub
does not expose secrets, so the job must skip before the key is needed — the
`head.repo.full_name == github.repository` guard above.

**Typed verdict mapping — what `Review Gate` needs to keep working unchanged.**
It needs nothing from the reviewer except a comment, authored by
`REVIEW_BOT_LOGIN` (default `github-actions[bot],github-actions`, a
comma-separated list validated at `review-state.sh:166-167`), whose body carries
`<!-- pr-agent-review-state:v1` at column 0 followed by one JSON line and a
`-->` line alone (`review-state.sh:231-240`), with `last_run.complete` (:236),
`last_run.excluded_files` (:237), `findings[]` (:238-239) and
`last_run.head_sha` (:240).
`schema_version` is **not read by any script here** (`grep -c schema_version
scripts/review-state.sh` → `0`), but it is not ignored everywhere: the pinned
image's own parser validates it (`pr_agent/algo/review_finding_state.py:112`).
A second producer must therefore write the image's schema, not only the gate's
four fields.
`is_review` (`review-state.sh:193`) also accepts the guide marker
`<!-- pr-agent:review:full|incremental`.

One correction to the framing that this bridge is "forging" pr-agent: this
document previously said pr-agent never emits findings and the block is always
`findings: []`. That is **false**, and #158 is the counter-example: its block
carries 16 findings with `finding_id`, `first_seen` and `state`. The mechanism:
the image emits the block itself, and the workflow's append step is a
*fallback* — it returns early when a body already carries
`pr-agent-review-state:v1` (`pr-agent.yml:191-195`), which is why the
workflow's hard-coded `'{findings: [], …}'` (`pr-agent.yml:222-223`) only ever
appears on the clean-review path that #140 described. So the block can carry
findings, and a second producer would have to emit real ones, not an empty
array.

That makes the parity question wider than two fields, and the options are:

- **Forging the block from the workflow** keeps `review-state.sh` untouched but makes a second producer of the two fields the gate trusts (`complete`, `head_sha`, `review-state.sh:236-240`). PR-AGENT.md D34/D37 exist precisely to keep one producer of those.
- **Teaching `review-state.sh` a second shape** is a change to
  `scripts/review-state.sh`. Per this task's brief, thread `9c075c1c` owns that
  file — I am reporting that ownership as given, not proving it: a thread id is
  not a tracker claim, and `AGENTS.md` "Claims" makes the `claimed` label the
  only medium both orchestrators read. If this recipe is ever adopted, hand the
  mapping to that thread rather than editing the file from another one.

**Required-check story.** No new job name. The check that gates a merge is
`Review Gate`, and it is fed by
`workflow_run: workflows: ["PR Agent"]` (`review-gate.yml:23-26`) — a *workflow
name*, not a job name. So the option that does not change branch protection is:
**keep the workflow named `pr-agent.yml` / `PR Agent`**, whatever runs inside
it. Adding a workflow under a new name is what forces a change elsewhere —
`scripts/check-ci-architecture.sh:42-46` requires exactly one
`docs/CI-ARCHITECTURE.md` row per workflow file ("workflow table has N rows but
the repository has M workflow files"), and that row plus the workflow would be
two owners of one fact under `AGENTS.md` "One PR, one of these". The check the
recipe must satisfy is still `Review Gate`, so **branch protection is
unchanged**: `["CI (Linux)","Arch simulation","Review Gate"]`.

**Failure guard.** What is red when no review happened: for pr-agent,
`_fail_on_recorded_tool_error` (PR-AGENT.md D13) plus the gate's `unrecorded` →
fail (D34). For OCR, the contract only fails on a non-zero exit
(`action.yml:1036-1041`) and posts only when the exit is 0
(`action.yml:1043-1044`); its own documentation says "A budget-only partial
review with usable coverage exits 0" and "On a non-zero exit, the Action can
upload the raw output as an artifact but skips posting PR comments"
(`action.yml:110-115`). Measured consequence: PR #156, exit 0, `status:
skipped`, 0 comments, 13 ms. A swap therefore needs the explicit guard in the
YAML above, because the tool will not provide one.

**Cost guard.** pr-agent, as configured: `ai_timeout = 900`
(`.pr_agent.toml:39`), `max_output_tokens = 128000` (`:21`),
`max_model_tokens = 256000` (`:17`), `num_max_findings = 5` (`:57`),
`max_number_of_calls = 3` (`:74`), `enable_large_pr_chunking = true` (`:73`).
OCR's equivalents: `max_tokens_budget` (`action.yml:104-116`, empty = unlimited),
`review_task_timeout` default 15 min (`:76-79`), `llm_timeout` default 300 s
(`:72-75`). Part 3.1 is what "no ceiling" produced at `--effort high`:
619,588 tokens and no completed file in 15 minutes; at `--effort low` it
completed in 719 s for 1,476,472 tokens. A swap would therefore need a token
ceiling the incumbent does not need, because the incumbent's median is 52,933.

---

## Part 6 — why the previous attempt failed

Blunt, with hashes. Two attempts, not one.

**1. A decision was closed on measured evidence and then re-litigated by
building more machinery, one day later.**
PR #149 was closed on 2026-11-21T12:47:11Z with "Dropped on measured evidence,
not preference, per PR-TRIAGE.md" (`gh pr view 149 --json comments`). `PR-TRIAGE.md:116-132`
had already written the conclusion: "it has never completed a review of more
than one changed file. 3 of 3 failures are 'all N items failed'". One day later
the same repo produced `ci/ocr-shadow` (`857fceb`, `de43236`) and PR #161, a
shadow reviewer that re-asks the question with new machinery. Nothing in
`PR-TRIAGE.md` was refuted in between; the evidence in Part 3 is the same
evidence that closed #149.

**2. Both attempts broke the repo's own "one PR, one of these" rule, and its own
reviewer said so.**
`AGENTS.md` (Honesty rules) allows a PR to touch at most one of {a workflow, the
gate script that checks it, the document that describes it} per concern. #149
shipped `.github/workflows/ocr-review.yml` **and** `.github/ocr/*` **and**
`docs/OCR-REVIEW.md` **and** `scripts/check-ocr-review.sh` **and** `ci.sh`
(`PR-TRIAGE.md:26`). #161 repeated it: the finding on PR #161 reads
"**Two owners for one fact** — This PR adds the workflow and also adds the
`OCR Shadow` row to `docs/CI-ARCHITECTURE.md`… Split the doc row into a
follow-up PR rebased on this one, or drop it here." That finding is still
`ACTIVE` (`gh api .../issues/161/comments`, `state: ACTIVE`).

**3. The measurement instrument was unmeasured, and the first cost number came
from a field that did not exist.**
`ci/ocr-shadow:.github/workflows/ocr-shadow.yml:16-19` records it against
itself: "`total_tokens` lives at `.summary.total_tokens`; the top-level field
this report used to read does not exist in a v1.13.13 artefact, so it printed
`missing` on every run." A cost claim was built on a field that was never there.

**4. The guard shipped as a hypothesis, and the reviewer caught it as a
silent-green risk.**
#149's body admits twice: "**Unproven until this PR's own run** … This PR is the
first live test of itself" (`gh pr view 149 --json body`). The guard was then
written and the repo's own pr-agent review failed it on PR #161 — "**Silent
green on a no-op review** … Add a second condition that fails red on a
degenerate review" — a finding still `ACTIVE` today. Part 3.1 (#156: exit 0,
0 comments, 13 ms) is that risk, realised.

**5. The cost ceiling was raised on an unmeasured failure.**
#149 bounded cost with "`--effort low`, `--max-tokens-budget 120000`" (its own
body). When that failed, `ocr-shadow.yml:194-197` went the other way —
`--effort high --max-tokens-budget 0` ("No token ceiling … a ceiling is exactly
what truncated the previous attempt"). The ceiling is not what failed: the
`budget_exceeded: true` at 349 tokens (Part 3.2) says the accounting was, so
raising the ceiling spent more on the same defect. Part 3.1 is the bill: at
`high`, 619,588 tokens and no completed file.

**6. Neither attempt had a stop condition, so both re-litigated the same fact
instead of measuring it.**
The fact is "it does not finish a multi-file diff at the effort we asked for".
#149 hit it three times, #161 shipped without measuring it, and my own Part 3
reproduction hit it again on the first real diff at `--effort high`. The
`--effort low` run then showed the other half of the story that no PR in this
history records: it *does* finish — at 1.48 M tokens, 23× the incumbent. One
trial run of two configurations, before any workflow existed, would have cost
about 2 M tokens once instead of a closed PR (#149), an open PR (#161), two
branches, a workflow, a doc row, a gate script, and this document.

---

## UNPROVEN

1. **OCR at `--effort high` with a wrapper long enough for its own budget.** My
   #158 high-effort run was killed by my own 900 s `timeout`, so 899.9 s /
   619,588 tokens is "did not finish in 15 minutes", not "never finishes".
   *What would prove it:* the same command with `timeout 2400` and
   `--timeout 20`, and a recorded `status` that is not `failed`. The
   `--effort low` run is the completed counter-example (§3.1), not a substitute.
2. **OCR's recall.** It completed exactly one run here (low effort, #158, 6
   findings), and no completed run with a labelled ground truth exists. So "6
   findings vs 16" is a count, not recall: nobody measured how many of the 22
   are true. *What would prove it:* a replay scorecard with each finding
   adjudicated true/false, on ≥2 diffs.
3. **pr-agent's recall** — the number this whole comparison would want. It is
   unmeasured in this repo (Part 5, step 3 records it as such). *What would
   prove it:* the replay scorecard described in the brief at `/tmp/replay2/`
   (`table.tsv`, `score.md`). **That directory does not exist**
   (`ls /tmp/replay2/` → "No such file or directory"), so the requested
   findings-total / off-diff-citation / zero-finding-on->200-line comparison
   could not be run and is not claimed.
4. **`total_tokens` comparability.** pr-agent's figure is its own run-details
   total (in+out, one AI call per review); OCR's is the CLI's
   `.summary.total_tokens`, which for the low-effort run includes 922,496
   cache-read tokens out of 1,476,472. The 23.0× ratio is a ratio of the two
   tools' own totals, not a normalised price. *What would prove a normalised
   figure:* price both against the provider's per-token rates, which is out of
   scope here.
5. **OCR v1.14.0 behaviour.** Part 1 was read at `v1.14.0` (latest tag), but
   Part 3 measured `v1.13.13` (the repo's pin). Whether `v1.14.0` fixed the
   `budget_exceeded` accounting is **UNPROVEN**. *What would prove it:* the same
   two-diff run against the v1.14.0 release binary, hash-verified.

---

## Adversarial review of this recipe

Mechanism: the `egm-review-loop` skill and its three reviewer personas from
`/home/prm/.pi/agent/git/github.com/google/elephant-goldfish-model/agents/`
(`codebase_details.md`, `implementation_readiness.md`, `zoom_out.md`). Each ran
as a **separate delegated agent in a fresh context**, told to attack rather than
approve, one perspective each, with instructions to keep working until it had
findings. Round 1 reviewed a draft recipe; round 2 re-ran only the perspectives
that raised BLOCKER or MAJOR, against this document. Cap: 2 rounds.

Every finding had to cite `file:line` or a URL; unanchored findings were
discarded. Severity: BLOCKER / MAJOR / MINOR. Only BLOCKER and MAJOR changed the
recipe.

### Round 1 — 47 findings, 12 BLOCKER, 25 MAJOR, 10 MINOR

| Perspective | BLOCKER | MAJOR | MINOR |
|---|---|---|---|
| `codebase_details` | 3 | 6 | 5 |
| `implementation_readiness` | 5 | 11 | 3 |
| `zoom_out` | 4 | 8 | 2 |

Fixed in round 2 (the ones that changed the document):

- **`git ls-tree origin/main .github/workflows` printed a tree object, and main has five workflows, not six.** `pr-conflicts.yml` is PR #158's own addition. Both reviewers found it independently. Fixed: `--name-only` + the trailing slash, five names.
- **Recipe B's `name: Review` would have left the required `Review Gate` unfed.** `review-gate.yml:24-26` triggers on `workflows: ["PR Agent"]`, so the recorded YAML contradicted its own "Required-check story" paragraph. Fixed: `name: PR Agent` with the constraint as a comment.
- **`incremental` defaults to `false`, not `true`** (`action.yml:146`). My draft had it wrong; corrected everywhere, including Part 1's own table.
- **Branch deletion was not executable:** `ci/ocr-shadow` is checked out in a live worktree, so `git branch -D` fails; and only 2 of the 3 branches have origin refs. Fixed: worktree removal first, then the ordered delete, with the local-only branch flagged as discardable (tag `f92f1b3` first).
- **`persistent_comment` was cited at `configuration.toml:275`** — that key belongs to `[pr_code_suggestions]`; the reviewer's is `:193`. Fixed.
- **`schema_version` is written but never read.** `grep -c schema_version scripts/review-state.sh` → `0`. Fixed: the field is marked not-read-by-any-script-here (round 2 then narrowed this further: the pinned image's own parser does validate it, and the offsets were off by one — see round 2).
- **`REVIEW_BOT_LOGIN` defaults to two logins**, `github-actions[bot],github-actions`, not one. Fixed.
- **"11 runs, 5 failures" was wrong — it is 4 failures / 7 successes.** Fixed from the API aggregate, and the failure rate corrected from 45% to 36%.
- **`pr_agent/...` citations are not in this tree** (`git ls-files | rg -c 'pr_agent/'` → `0`). Fixed: Part 2 now says those paths are inside the pinned image `pragent/pr-agent@sha256:548e894a…`.
- **`docs/CI-ARCHITECTURE.md:27` becomes false once #149 closes** ("there is one open, `ocr-review.yml`"), and the architecture gate does not read prose, so it would stay green while the doc lies. Fixed: a step now rewrites that line.
- **This document was untracked**, so its numbers lived on one machine while a PENDING row would cite them. Fixed: a commit step, ordered with the PENDING row.
- **Durations had a third copy with no window.** `docs/CI-ARCHITECTURE.md:36` records median 452 s / p90 849 s / max 2376 s (n=20); PR-AGENT.md D10 records per-call p50 325 s. Fixed: this document names its own window (the 40 most recent runs, 2026-11-21T13:29Z → 2026-11-22T04:20Z) and supersedes nothing.

Contested, with reasons (not changed):

- **"Recipe B drops `synchronize`."** Not true of the YAML: it has `types: [opened, reopened, ready_for_review, synchronize]`. The reviewer was reading a draft line that also had it. Discarded as misread, not as wrong in substance.
- **"`inline_key_issues` at `configuration.toml:202` is quoted as if it were the evidence for inline posting."** Part 2 already distinguishes the upstream default (`false`) from this repo's override (`.pr_agent.toml:61`). The finding is right about the *draft* and wrong about the document.
- **"The trigger choice is never justified."** Part 5 has a "Trigger: `pull_request`, not `pull_request_target`" paragraph citing `pr-agent.yml:15-17`; the reviewer read the draft, which lacked it.
- **"Closing #161 defers the only live question."** I did not close it on the reviewer's reasoning alone, but round 2's `zoom_out` argued the same point better (round 2, finding 8), and that did change the recommendation.

### Round 2 — `zoom_out` returned 13 findings, 3 BLOCKER, 6 MAJOR, 4 MINOR

All three BLOCKERs were real and were errors I had introduced:

- **The verdict still contained the findings ratio I had just deleted** ("246,079 tokens per finding against 4,004") while §3.4 said the two counts cover different numbers of runs. Fixed: the verdict keeps the pass-vs-pass ratio only, and now carries **8.6×** as well as 23.0× — because 922,496 of OCR's 1,476,472 tokens are cache reads (`jq .summary /tmp/ocr-158low.json`), so non-cached is 553,976, i.e. 8.6× against pr-agent's 64,063.
- **§3.5 said "has never completed a multi-file review"**, contradicting §3.1 two pages earlier. Fixed.
- **"pr-agent never emits findings" was false.** #158's block carries 16 findings, because `pr-agent.yml:191-195` returns early when a body already carries `pr-agent-review-state:v1` — so the image's block is the one in place and the workflow's `findings: []` is only the clean-review fallback. Fixed: the bridge paragraph now says a second producer must emit real findings, not an empty array. **This one mattered**: it was load-bearing for my earlier claim that the block was only a verdict.

Also fixed from round 2:

- **"pr-agent did not report it" was an unanchored negative.** pr-agent filed "Unmeasured effort claim" on `.github/PR-AGENT.md:62` and "Stale effort claim" on `.pr_agent.toml:20` about the same effort question. Scoped: it missed the *registry list omission*, not the topic.
- **The gateway-200 measurement was re-attributed to OCR.** D38 says that was measured with three direct calls by the session that wrote the row. Only the list omission is OCR's.
- **Recipe B was pinned to `--effort high`** — the configuration that produced 0 completed files — which attacks a strawman. Now `--effort low`, the one measured to complete.
- **The "substantive" §3.1 example duplicates an open pr-agent finding** (`docs/CI-ARCHITECTURE.md:177`, `scripts/check-pr-conflicts-workflow.sh:196`, both `ACTIVE`). Added: unique coverage is §3.5 alone.
- **The guard step in Recipe B was `exit 1` unconditionally** — a comment, not a guard. Now reads the artifact's `status` and `comments`.

**The finding that changed the recommendation, not just the text** (round 2,
`zoom_out` #8):

> "The recommendation should be: drop the **swap** (correct), keep the **shadow**
> — flip `--effort low`, dispatch only on claim-change PRs, artifacts only, never
> a required check … Dropping OCR entirely abandons the second opinion on the
> strength of a price nobody proposed paying."

That is right, and it is the reason Part 5 no longer says "close #161". The
1.48 M-token figure is the price of a review **pass**, and no one proposed paying
it per PR; a `workflow_dispatch`-only shadow pays it only when an operator asks.
Recipe A is now A1 (keep the shadow, change one word — recommended) and A2 (close
it — the no-machinery option), with the cost and the 36% failure rate stated for
both.

### What the loop did not settle

`codebase_details` round 2 returned after the round-2 section above was written,
with **1 BLOCKER, 3 MAJOR, 5 MINOR**; it also verified 9 of its own 9 round-1
blockers/majors resolved. Its findings were applied:

- **BLOCKER: the typed block is native to pr-agent, not to this repo.**
  `persistent_finding_state=true` (`configuration.toml:196`) plus
  `pr_agent/algo/review_finding_state.py:181` mean the image emits the block, and
  `pr-agent.yml:191-195` returns early when one exists — so the workflow's append
  is the clean-review fallback, not the capability. Part 2's row and the parity
  paragraph both said the opposite and now say this one. This strengthens the
  verdict: pr-agent loses nothing to OCR on typed state.
- **MAJOR: the failed items carry a `classification`/`reason`, not `error: null`.**
  Corrected to the real fields, which say more: `"classification": "cancelled"`.
- **MAJOR: Recipe B still carried the findings comparison** that §3.4 withdrew.
  Removed; pass cost only.
- **MINOR (applied):** the `review-state.sh` offsets were +1 throughout (real:
  parse `231`, `complete` `236`, `excluded` `237`, `findings` `238-239`,
  `head_sha` `240`); `schema_version` is read by the image's parser even though no
  script here reads it; `#149` is already closed, so that sentence is already
  false; and `--timeout` is a per-task budget, not a wall-clock cap.

**Contested: the token medians.** The reviewer reported that 52,933 does not
reproduce and offered 54,432.5. It does reproduce, and the reviewer's own
description of it ("`(sorted[13]+sorted[14])/2`") is not what produces 52,933 —
that pair gives 51,432. With n=30 sorted totals, the median is the mean of the
15th and 16th values, `(52,366 + 53,500) / 2 = 52,933`. What was missing was
the convention, not the number, so the fix was to publish the convention and the
full sorted series (Part 3.3) rather than to change the figure. The reviewer is
right that `22,614` appears in no comment: it is an interpolated median of the
input series, and the table now says so.

Round 1 of `implementation_readiness` also raised two things I accepted as
remaining bounds rather than fixes, and they are stated in the text instead: a
`/review` on a fork PR was a hazard in pr-agent (inherited, `pr-agent.yml:41-49`),
and fork PRs receive no `Review Gate` check at all under `strict: true`
(step 7 of Recipe A). Both are pre-existing policy questions, not defects in this
recipe.

### Round 2 totals, and what remains open

| Round | Perspective | BLOCKER | MAJOR | MINOR | BLOCKER+MAJOR applied |
|---|---|---|---|---|---|
| 1 | `codebase_details` | 3 | 6 | 5 | all but 1 contested |
| 1 | `implementation_readiness` | 5 | 11 | 3 | all |
| 1 | `zoom_out` | 4 | 8 | 2 | all but 2 contested |
| 2 | `codebase_details` | 1 | 3 | 5 | all |
| 2 | `zoom_out` | 3 | 6 | 4 | all |

Round 2's surviving BLOCKER was the typed-block ownership (fixed above); no
BLOCKER is left open in this document. Two defects of mine that the loop caught
were substantive, not cosmetic — the block's true producer, and the false
"pr-agent never emits findings" — and both had been load-bearing for earlier
conclusions in this same file. That is the argument for the loop: it found the
things I had already decided were true.
