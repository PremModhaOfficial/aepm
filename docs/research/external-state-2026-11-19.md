# External state of the art, 2026-11-19

Collected by a clean-context research thread; every claim carries its source and
read date. Verdicts that depend on these facts live in ledger.md §8.

1. Merge queue: public repos **owned by an organization** only; personal-account
   public repos excluded [GitHub docs, gated-features reusables, 2026-11-19].
   Requires each required check to handle `merge_group`; replaces "require
   branches to be up to date" [docs.github.com, Managing a merge queue].
2. Required checks must pass on the latest commit. Job checks from
   `workflow_run`/`workflow_dispatch` **do not** satisfy one, even on the head;
   a check written with the Checks API to the head **does** [docs.github.com,
   Troubleshooting required status checks, 2026-11-19].
3. Cache: 10 GB/repo, 7-day unused eviction, now evicted hourly; more than 10 GB
   needs a paid account. PR-created caches are scoped to `refs/pull/.../merge`
   and restorable only by that PR's re-runs [github.blog 2025-09-29 and
   2025-11-20; docs.github.com caching reference, 2026-11-19]. buildx `type=gha`
   is still the documented in-Actions backend, no deprecation found.
4. `pr-agent` v0.50.0 has `--json-output <path>` for `review` [pr_agent/cli.py
   @ v0.50.0, 2026-11-07]. The project is a community-maintained legacy fork of
   Qodo's; Qodo Merge carries a sunset notice [repo README; docs.qodo.ai].
5. Free reviewers for public repos: CodeRabbit OSS plan (zero cost, PR comments);
   Copilot code review needs a paid plan or an org [docs.coderabbit.ai;
   github.blog 2026-04-27].
6. `cargo nextest` 0.9.152 (2026-11-13) adds nothing that lowers the break-even
   for a 22s suite [nexte.st changelog].
7. Path-filtered required checks stay Pending [docs.github.com, Triggering a
   workflow, 2026-11-19].

Unverified, flagged rather than guessed: whether `strict` can stay enabled
alongside a merge queue; the exact CodeRabbit commit-status semantics; whether
Copilot code review is zero-cost on a user-owned public repo.
