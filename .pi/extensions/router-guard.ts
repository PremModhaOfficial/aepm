/**
 * router-guard — the factory's structural rule, enforced in code.
 *
 * The Router never implements. A worker always runs in its own worktree. So:
 * when cwd is the MAIN checkout (`.git` is a directory), edits and
 * side-effecting bash are blocked. When cwd is a worktree (`.git` is a file),
 * they are allowed.
 *
 * Always allowed, in any checkout: reading, `.factory/` bookkeeping, /tmp, and
 * the gate itself.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";
import { existsSync, statSync, appendFileSync, mkdirSync } from "node:fs";
import { join, dirname } from "node:path";

const BOOKKEEPING = [".factory/", "/tmp/", ".pi/extensions/"];
// Read-only or bookkeeping commands: no side effect on the checkout.
const SAFE_BASH = [
  /^(git\s+(status|log|show|diff|branch\s+-a|rev-parse|merge-base|ls-files|remote|cat-file)\b)/,
  /^(rg|fd|ls|cat|head|tail|wc|find|stat|file|jq|date|echo|printf|pwd|which|command\s+-v)\b/,
  /^bash\s+\.factory\/(gates\/gate\.sh|scripts\/)/,
  /^(gh\s+(issue|pr|run|repo|api)\s+(list|view|checks|diff|status))/,
  /^(cargo\s+(metadata|tree|fmt\s+--check)\b)/,
];
const SIDE_EFFECT = /\b(rm|mv|cp|mkdir|touch|tee|dd|truncate|chmod|chown|shred)\b|\bsed\s+-i\b|>>?\s*[^\s|&]/;
// `gh` writes are the Router's own job (comment, label, merge, report).
const GH_WRITE = /^gh\s+(pr\s+(merge|comment|review|edit|create)|issue\s+(comment|edit|create|close|reopen)|run\s+rerun)\b/;
// The Router never writes to the repo; a git command that is not in SAFE_BASH
// is a write. The self-test caught `git commit` slipping between the two rules.
const GIT_READ_ONLY = /^git\s+(status|log|show|diff|branch|rev-parse|merge-base|ls-files|remote|cat-file|worktree\s+list|config\s+--get)\b/;

function isWorktree(cwd: string): boolean {
  try {
    return statSync(join(cwd, ".git")).isFile();
  } catch {
    return false;
  }
}

export default function (pi: ExtensionAPI) {
  const log = (cwd: string, tool: string, detail: string) => {
    try {
      const dir = join(cwd, ".factory");
      if (!existsSync(dir)) return;
      appendFileSync(
        join(dir, "guard.log"),
        `${new Date().toISOString()}\t${tool}\t${detail}\n`,
      );
    } catch {
      /* logging must never block a decision */
    }
  };

  pi.on("tool_call", async (event, ctx) => {
    const cwd = ctx.cwd;
    if (isWorktree(cwd)) return undefined; // a worker's own checkout: not ours to police

    if (event.toolName === "write" || event.toolName === "edit") {
      const path = String((event.input as { path?: string }).path ?? "");
      if (BOOKKEEPING.some((p) => path.includes(p))) return undefined;
      const reason =
        `router-guard: the Router does not edit files in the main checkout (${path}). ` +
        `Dispatch a builder — it works in its own worktree. Bookkeeping under .factory/ is allowed.`;
      log(cwd, event.toolName, path);
      return { block: true, reason };
    }

    if (isToolCallEventType("bash", event)) {
      const cmd = event.input.command ?? "";
      if (BOOKKEEPING.some((p) => cmd.includes(p))) return undefined;
      const trimmed = cmd.trim();
      if (SAFE_BASH.some((r) => r.test(trimmed))) return undefined;
      if (GH_WRITE.test(trimmed)) return undefined;
      const isGitWrite = /^git\b/.test(trimmed) && !GIT_READ_ONLY.test(trimmed);
      if (!isGitWrite && !SIDE_EFFECT.test(trimmed)) return undefined; // e.g. `cargo test` in a scratch dir
      if (cmd.includes("/tmp/")) return undefined;
      const reason =
        `router-guard: the Router does not run state-changing commands in the main checkout ` +
        `(${cmd.slice(0, 80)}). Read-only git, the gate, .factory/ scripts and /tmp are allowed.`;
      log(cwd, "bash", cmd.slice(0, 200));
      return { block: true, reason };
    }

    return undefined;
  });
}
