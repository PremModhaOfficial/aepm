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
 *     read-only allowlist, with no git write verb anywhere behind it. A
 *     substring test let `echo pwn > src/main.rs` and `ls && git commit -am x`
 *     through; a first-word-only test let `git remote add` through as "remote".
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
    re: /^git\s+(?:-C\s+\S+\s+|--no-pager\s+)*(?:status|log|show|diff|rev-parse|merge-base|ls-files|cat-file|worktree\s+list|for-each-ref|describe)\b/,
    what: "read-only git",
  },
  // `git remote` alone lists; `git remote add|set-url` writes, and `remote` used
  // to be allowed by name, so the first word after `git` decided it was a read.
  {
    re: /^git\s+(?:-C\s+\S+\s+|--no-pager\s+)*remote(?:\s+(?:-v|--verbose|get-url|show)\b|\s*$)/,
    what: "git remote listing",
  },
  // `git branch` and `git tag` are judged by readOnlyBranchOrTag below, never by
  // a shape: `git branch -v <name>` creates <name>.
  {
    re: /^(?:rg|fd|ls|cat|head|tail|wc|stat|file|jq|date|pwd|which|grep|comm|cut|tr|diff|basename|dirname|realpath|seq|echo|printf|uniq)\b/,
    what: "a read-only filter",
  },
  // find -delete/-exec and sort -o write; they are not read-only. `-o` is
  // matched attached as well as spaced: `sort -oout` writes a file too.
  { re: /^find\b(?!.*\s-(?:delete|exec|execdir|ok|fprint|fprintf|fls)\b)/, what: "find without -delete/-exec" },
  { re: /^sort\b(?!.*\s-[a-zA-Z]*o)/, what: "sort without -o" },
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

// A shape match reads one bare word after `git`, so a write verb can sit behind
// it (`git remote add`). Any write verb left in the argv refuses the command.
// The boundary is `(?![-\w])`, not `\b`: a hyphen is a word boundary, so `merge`
// matched `git merge-base` and a read-only plumbing command was refused.
const GIT_WRITE_VERB =
  /(?:^|\s)(?:add|am|apply|checkout|cherry-pick|clean|clone|commit|config|fetch|filter-branch|gc|init|merge|mv|notes|prune|pull|push|rebase|reflog|remove|rename|reset|restore|revert|rm|set-url|stash|submodule|switch|symbolic-ref|update-ref)(?![-\w])/;

// `git branch -v <name>` CREATES <name>: -v, -a and -r are not exclusive with a
// name, so "starts with a listing flag" proved nothing and a branch create hid
// behind the listing shape. A read shape is: only these flags, each taking at
// most the one pattern/commit it documents and no other word.
const BRANCH_TAG_READ_FLAG = new Set([
  "-a", "-r", "-v", "-vv", "-av", "-ar", "-rv", "-arv", "--all", "--remotes", "--verbose",
  "--show-current", "--list", "-l", "-n", "--merged", "--no-merged", "--contains", "--no-contains",
]);
const TAKES_ONE_WORD = new Set(["--list", "-l", "-n", "--merged", "--no-merged", "--contains", "--no-contains"]);

function readOnlyBranchOrTag(argv: string[]): boolean {
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!BRANCH_TAG_READ_FLAG.has(a)) return false;
    const next = argv[i + 1];
    if (TAKES_ONE_WORD.has(a) && next !== undefined && !next.startsWith("-")) i++; // its pattern/commit
  }
  return true;
}

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
  if (/^git\b/.test(bare) && GIT_WRITE_VERB.test(bare.replace(/^git\s+/, ""))) {
    return { allow: false, reason: "it carries a git write verb, and the Router does not commit" };
  }
  if (/^git\b/.test(bare)) {
    const listing = bare.match(/^git\s+(?:(?:-C\s+\S+|--no-pager)\s+)*(?:branch|tag)(?:\s+([\s\S]*))?$/);
    if (listing) {
      const argv = (listing[1] ?? "").trim().split(/\s+/).filter(Boolean);
      return readOnlyBranchOrTag(argv)
        ? { allow: true, reason: "" }
        : {
            allow: false,
            reason:
              "it is not a read-only branch/tag listing: `git branch -v <name>` creates <name>, " +
              "and only -a/-r/-v/--list/--merged style flags with the pattern or commit they document are reads",
          };
    }
  }
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
