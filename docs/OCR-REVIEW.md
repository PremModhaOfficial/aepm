# The advisory second reviewer

`.github/workflows/ocr-review.yml` runs [open-code-review][ocr] beside pr-agent.
It is **advisory**: it is not a required check, it never fails a PR because of a
finding, and it does not replace `Review Gate`. It exists because two numbers
were missing and neither could be measured from the existing reviewer's output.

[ocr]: https://github.com/alibaba/open-code-review

## Why it is here

| measured problem | number |
|---|---|
| reviews that returned zero findings | 4 of 11, three on diffs ≥ 70 lines |
| defect class pr-agent structurally cannot report | a clean review emits **no** typed block, so `Review Gate` reads "no review comment" forever (#141, #142) |
| reviewer cost | ~62,000 tokens per review, recall never measured |

open-code-review always emits a `comments` array, empty or not, plus a
`session_id`, and can write SARIF. That is the primitive `review-state.sh` has to
reconstruct from prose today.

## Measured limit, before adopting it for anything load-bearing

It excludes any file whose extension is outside its code set, as
`unsupported_ext`, **before** the model sees the diff:

| | |
|---|---|
| PRs where every changed file was excluded | 5 of 15 (#147, #128, #143, #133, #119) |
| files reviewable / excluded | 28 / 27 |
| #134 — two prose claims plus tests | reviews the 2 test files; both prose files excluded |

So: **it cannot verify a prose claim.** On #134 it would return zero findings
because the claims are not in its input — a stronger failure than pr-agent's.
The workflow counts reviewable files with `--preview` (no model call) and skips
without spending tokens when the count is zero.

It also cannot gate a merge on its own: `ocr review --help` states that
budget-limited partial reviews exit `0`. Exit `0` means *completed*, not *no
defect*. Any use of this as a real check needs a verdict step written here.

## Cost

Bounded three ways: `--effort low`, `--max-tokens-budget 120000` (per run), and
the reviewable-file skip. A run that hits the budget still exits `0` and reports
partial coverage. On the sampled corpus that is at most 10 of 15 PRs.

## Credentials

Reuses the existing subscription: `secrets.COMMAND_CODE_API_KEY` with
`OCR_LLM_URL=https://api.commandcode.ai/provider/v1` and
`OCR_LLM_MODEL=deepseek/deepseek-v4.1-flash`, the same endpoint and model as
`.pr_agent.toml`. No new secret. Fork PRs are skipped, because a fork gets a
read-only token and the key should not be exposed to one.

## Turn it off

Delete the workflow file. Nothing else references it, no required check names
change, and no state is written anywhere but the PR comment. To keep it but stop
spending, set `on.pull_request` to nothing — `workflow_dispatch` remains.

## Run it locally

```sh
# free: no model call, just the file filter
ocr review --from origin/main --to <ref> --preview

# with a key in the environment
OCR_LLM_URL=... OCR_LLM_TOKEN=... OCR_LLM_MODEL=deepseek/deepseek-v4.1-flash \
  ocr review --from origin/main --to <ref> --format json --audience agent \
  --effort low --max-tokens-budget 120000
```

## The incident this workflow caused first time out

Its first live run reported **success** while the review's own status was
`failed`, and it posted a comment reading "0 finding(s) … No findings". The guard
only treated a *missing* JSON file as failure, so a failed review that still
wrote an envelope passed as a clean one — the identical false green this workflow
exists to measure, reproduced in its first attempt.

Two changes came out of it, and both stay:

1. `ocr llm test` runs before the review. A bad credential or model now costs one
   tiny call and fails with the endpoint's own error, instead of being
   indistinguishable from a review that found nothing.
2. A review counts as having happened only when `status == "completed"` **and**
   the `comments` key is present. Every other outcome is loud and posts nothing,
   because a comment that says "no findings" over a review that never ran is
   worse than a red check.

The general lesson, which predates this file: "the command exited 0" is not
"the review ran". Verify the artefact, not the exit code.

## The endpoint needs its protocol named

With only `OCR_LLM_URL` / `OCR_LLM_TOKEN` / `OCR_LLM_MODEL` set, the CLI speaks the
**Anthropic** protocol and POSTs `<base>/v1/messages`. Against an OpenAI-compatible
gateway whose base already ends in `/v1`, that becomes `/provider/v1/v1/messages` and
returns `404 … is not a registered API route`.

The protocol has no environment variable. It comes from a provider, so the workflow
writes one before reviewing:

```sh
ocr config set provider cc-gateway
ocr config set custom_providers.cc-gateway.url  "$OCR_LLM_URL"
ocr config set custom_providers.cc-gateway.protocol openai
ocr config set custom_providers.cc-gateway.api_key "$OCR_LLM_TOKEN"
ocr config set model "$OCR_LLM_MODEL"
```

Proven without the real key: with `protocol: openai` the same call becomes
`POST /provider/v1/chat/completions`, and the gateway answers `401 Invalid
'Authorization' header or token` — reachable, right route, key refused. `llm test`
takes no provider flag, so the config file is the only non-interactive way to pin it.
