/**
 * router-guard — the factory's structural rule, enforced in code.
 *
 * The Router never implements. A worker always runs in its own worktree. So:
 * when cwd is the MAIN checkout (`.git` is a directory), edits and
 * side-effecting bash are blocked. When cwd is a worktree (`.git` is a file),
 * they are allowed.
 *
 * Two decisions, both fail-closed:
 *   - write/edit: only runtime STATE paths are allowed, never code. `.pi/` and
 *     `.factory/gates/` are code: a write to them is a change, and changes are
 *     a builder's job. (The old rule called `.pi/extensions/` bookkeeping, so
 *     the guard could rewrite itself.)
 *   - bash: judged by SHAPE, not by a substring. A command carrying a shell
 *     metacharacter is refused outright, and the first word must be in a finite
 *     read-only allowlist. A substring test let `echo pwn > src/main.rs` and
 *     `ls && git commit -am x` through, because both contain `/tmp/` or nothing
 *     the denylist knew.
 *
 * This is a guard against a model overreaching, not a sandbox: it reads the
 * command, so anything that hides a write behind an unlisted program is refused
 * by the default-deny list rather than analysed.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";
import { existsSync, statSync, appendFileSync } from "node:fs";
import { join } from "node:path";

// Runtime state the Router owns, relative to the checkout root. Code is never
// in this list.
const STATE_UNDER_ROOT = [
  ".factory/tickets/",
  ".factory/state.md",
  ".factory/ledger.jsonl",
  ".factory/guard.log",
  ".factory/inbox/",
  ".factory/research/",
  ".factory/gates/last-gate.json",
];

// Any shell metacharacter outside single quotes: chain, redirect, subshell,
// expansion, escape, newline. Single-quoted text is inert in the shell, so it
// is stripped before the test — everything else must be plain words.
const SHELL_META = /[;&|<>`$\n(){}!\\]/;
const singleQuoted = (s: string) => s.replace(/'[^']*'/g, "''");

// The finite set of shapes allowed in the main checkout. Default deny.
const ALLOWED_SHAPES: { re: RegExp; what: string }[] = [
  {
    re: /^git\s+(?:-C\s+\S+\s+|--no-pager\s+)*(?:status|log|show|diff|rev-parse|merge-base|ls-files|remote|cat-file|worktree\s+list|for-each-ref|describe)\b/,
    what: "read-only git",
  },
  // `git branch foo` creates, `git branch -D` deletes: only listings.
  { re: /^git\s+branch\s+(?:-[arv]+|--list|--show-current|--merged)(?:\s|$)/, what: "git branch listing" },
  { re: /^git\s+tag\s+(?:-l|--list)(?:\s|$)/, what: "git tag listing" },
  {
    re: /^(?:rg|fd|ls|cat|head|tail|wc|stat|file|jq|date|pwd|which|grep|comm|cut|tr|diff|basename|dirname|realpath|seq|echo|printf|uniq)\b/,
    what: "a read-only filter",
  },
  // find -delete/-exec and sort -o write; they are not read-only.
  { re: /^find\b(?!.*\s-(?:delete|exec|execdir|ok|fprint|fprintf|fls)\b)/, what: "find without -delete/-exec" },
  { re: /^sort\b(?!.*\s-o\b)/, what: "sort without -o" },
  // Neither awk nor sed is here: both can write (`awk system()`, sed's `w`
  // command), so they are not filters. The factory's own scripts use them, and
  // they run as `bash .factory/...`.
  { re: /^command\s+-v\b/, what: "command -v" },
  { re: /^cargo\s+(?:metadata|tree)\b/, what: "cargo metadata/tree" },
  { re: /^cargo\s+fmt\b[^\n]*\s--check\b/, what: "cargo fmt --check" },
  { re: /^bash\s+\.factory\/(?:gates\/gate\.sh|scripts\/[\w.-]+\.sh)\b/, what: "a factory script" },
  { re: /^bash\s+(?:\.\/)?sim\/run\.sh\b/, what: "the simulation harness" },
  { re: /^gh\s+(?:issue|pr|run|repo|api)\s+(?:list|view|diff|checks|status)\b/, what: "read-only gh" },
];
// `git diff --output=x`, `grep --output` etc. write a named file: never allowed.
const WRITES_A_FILE = /(^|\s)--output\b/;

// `gh` writes are the Router's own job (comment, label, merge, report).
const GH_WRITE =
  /^gh\s+(pr\s+(merge|comment|review|edit|create)|issue\s+(comment|edit|create|close|reopen)|run\s+rerun|workflow\s+run)\b/;

function isWorktree(cwd: string): boolean {
  try {
    return statSync(join(cwd, ".git")).isFile();
  } catch {
    return false;
  }
}

const normalise = (p: string) => p.replace(/\\/g, "/");

/**
 * True only for runtime state, and never for a path that escapes with `..`.
 * Inside the checkout only this factory's own state qualifies; outside it, only
 * /tmp scratch does. A plain `.includes("/tmp/")` test said yes to every path in
 * a checkout that happens to live under /tmp.
 */
function isStatePath(raw: string, cwd: string): boolean {
  const p = normalise(raw);
  if (/\/\.\.(\/|$)/.test(p) || p.startsWith("../")) return false;
  const root = normalise(cwd).replace(/\/$/, "");
  const rel = p === root ? "" : p.startsWith(root + "/") ? p.slice(root.length + 1) : null;
  if (rel !== null) {
    if (rel === "") return false;
    return STATE_UNDER_ROOT.some((s) => rel === s.replace(/\/$/, "") || rel.startsWith(s));
  }
  return p.startsWith("/tmp/");
}

/** The decision for one bash command in the main checkout. */
function bashDecision(cmd: string): { allow: boolean; reason: string } {
  const trimmed = cmd.trim();
  if (!trimmed) return { allow: true, reason: "" };
  const bare = singleQuoted(trimmed);
  if (SHELL_META.test(bare)) {
    return { allow: false, reason: "it carries a shell metacharacter (chain, redirect, subshell or expansion)" };
  }
  if (WRITES_A_FILE.test(bare)) return { allow: false, reason: "it writes a file with --output" };
  if (GH_WRITE.test(bare)) return { allow: true, reason: "" };
  if (ALLOWED_SHAPES.some((s) => s.re.test(bare))) return { allow: true, reason: "" };
  if (/^git\b/.test(bare)) return { allow: false, reason: "it is a git write, and the Router does not commit" };
  return { allow: false, reason: "it is not in the read-only allowlist" };
}

export default function (pi: ExtensionAPI) {
  const log = (cwd: string, tool: string, detail: string) => {
    try {
      const dir = join(cwd, ".factory");
      if (!existsSync(dir)) return;
      appendFileSync(join(dir, "guard.log"), `${new Date().toISOString()}\t${tool}\t${detail}\n`);
    } catch {
      /* logging must never block a decision */
    }
  };

  pi.on("tool_call", async (event, ctx) => {
    const cwd = ctx.cwd;
    if (isWorktree(cwd)) return undefined; // a worker's own checkout: not ours to police

    if (event.toolName === "write" || event.toolName === "edit") {
      const path = String((event.input as { path?: string }).path ?? "");
      if (isStatePath(path, cwd)) return undefined;
      const reason =
        `router-guard: the Router does not edit files in the main checkout (${path}). ` +
        `Dispatch a builder — it works in its own worktree. Only runtime state ` +
        `(${STATE_UNDER_ROOT.join(", ")}) may be written here; code and .pi/ may not.`;
      log(cwd, event.toolName, path);
      return { block: true, reason };
    }

    if (isToolCallEventType("bash", event)) {
      const cmd = event.input.command ?? "";
      const d = bashDecision(cmd);
      if (d.allow) return undefined;
      const reason =
        `router-guard: the Router does not run state-changing commands in the main checkout ` +
        `(${cmd.slice(0, 80)}) because ${d.reason}. Read-only commands, the gate, ` +
        `.factory/ scripts and /tmp file writes are allowed.`;
      log(cwd, "bash", cmd.slice(0, 200));
      return { block: true, reason };
    }

    return undefined;
  });
}
