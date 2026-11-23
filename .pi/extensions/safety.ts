/**
 * safety — the rules that must never depend on a model remembering them.
 * Adapted from Pi's example extensions (permission-gate.ts, protected-paths.ts),
 * narrowed to this repo's hard safety rules in AGENTS.md.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";
import { statSync } from "node:fs";
import { join } from "node:path";

const PROTECTED = [".env", ".git/", ".gpg/", "node_modules/", "id_rsa", "id_ed25519"];

// The factory's own judge. A builder in its own worktree may change it — that is
// how a guard fix reaches a PR — but in the main checkout the thing that decides
// is not editable by the session it decides about (router-guard's F1 hole; this
// is the second layer, so neither extension alone can be talked out of it).
const MAIN_CHECKOUT_ONLY_PROTECTED = [".pi/"];

function isWorktree(cwd: string): boolean {
  try {
    return statSync(join(cwd, ".git")).isFile();
  } catch {
    return false;
  }
}

// Never allowed, no confirmation offered: these break a hard rule or destroy work.
const NEVER = [
  { re: /\bgit\s+push\b[^\n]*(--force|-f\b)[^\n]*\b(main|master)\b/, why: "force-push to the default branch" },
  { re: /\bgit\s+push\b[^\n]*\b(main|master)\b/, why: "push to the default branch" },
  // `gh` takes global flags before the subcommand (`gh --repo o/r pr merge`), so
  // the word after `gh` is not necessarily `pr`; the words are matched in order
  // anywhere on the line, and `--admin` still has to be on it.
  { re: /\bgh\b[^\n]*\bpr\b[^\n]*\bmerge\b[^\n]*--admin/, why: "merge bypassing branch protection (--admin)" },
  // Editing branch protection in every spelling: `/protection` plus ANY write
  // method or field (-X, --method, -f, -F, --field, --raw-field, --input), in
  // either order. Two patterns because a regex reads left to right; both name
  // the same write set, so a new spelling only has to join it.
  { re: /\bgh\s+api\b[^\n]*\/protection[^\n]*(\s-[XfF]|--method|--input|--field|--raw-field)/, why: "editing branch protection" },
  { re: /\bgh\s+api\b[^\n]*(\s-[XfF]|--method|--input|--field|--raw-field)[^\n]*\/protection/, why: "editing branch protection" },
  // .env is a hard no in every tool, not just the file tools: a shell redirect
  // (`echo SECRET=leaked > .env`) writes the same file. The name is matched as a
  // PREFIX, not a whole word: `.envrc` has no word boundary after `env`, and it
  // holds a direnv script that exports the whole file, so it leaks exactly the
  // same way. Nothing but `.env` and its siblings starts with `.env` here.
  {
    re: /(?:>>?|\bcp\b|\bmv\b|\brm\b|\btee\b|\bdd\b|\bsed\s+-i\b|\binstall\b)[^\n]*\.env[A-Za-z0-9_.-]*/,
    why: "writing .env through a shell command",
  },
  { re: /\b(pacman|yay|makepkg|paccache|pacdiff)\b/, why: "pacman/yay/makepkg on the development host (sim/run.sh only)" },
  // The verb is not always the word after `systemctl`: `--user enable` sits a
  // flag in front of it, so the whole line up to the newline is scanned.
  { re: /\bsystemctl\b[^\n]*\b(enable|start|restart|disable|stop|mask|unmask)\b/, why: "systemd state change on the development host" },
  { re: /\bgit\s+reset\b[^\n]*--hard\b/, why: "git reset --hard (use a checkpoint or a worktree)" },
  { re: /\b(cargo|npm|pnpm)\s+publish\b/, why: "publishing a release needs the owner" },
];

// Always dangerous: confirmable in the TUI, blocked when there is no human to ask.
const CONFIRM = [
  /\brm\s+(-[a-z]*r[a-z]*|--recursive)/i,
  /\bsudo\b/i,
  /\b(chmod|chown)\b.*777/,
  /\bdocker\s+(rm|system)\b/,
];

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event, ctx) => {
    if (isToolCallEventType("bash", event)) {
      const cmd = event.input.command ?? "";
      const never = NEVER.find((n) => n.re.test(cmd));
      if (never) {
        return { block: true, reason: `safety: blocked — ${never.why}. This is a hard rule, not a preference.` };
      }
      const dangerous = CONFIRM.find((re) => re.test(cmd));
      if (dangerous) {
        if (!ctx.hasUI) return { block: true, reason: "safety: dangerous command with no UI to confirm it" };
        const choice = await ctx.ui.select(`Dangerous command:\n\n  ${cmd}\n\nAllow?`, ["No", "Yes"]);
        if (choice !== "Yes") return { block: true, reason: "safety: refused by the operator" };
      }
      return undefined;
    }

    if (event.toolName === "write" || event.toolName === "edit") {
      const path = String((event.input as { path?: string }).path ?? "");
      const hit = PROTECTED.find((p) => path.includes(p));
      if (hit) return { block: true, reason: `safety: "${path}" is a protected path (${hit}).` };
      if (!isWorktree(ctx.cwd)) {
        const guard = MAIN_CHECKOUT_ONLY_PROTECTED.find((p) => path.includes(p));
        if (guard) {
          return {
            block: true,
            reason:
              `safety: "${path}" is the factory's own guard (${guard}). It changes through a ` +
              `builder's PR in a worktree, never from the main checkout that it judges.`,
          };
        }
      }
    }

    return undefined;
  });

  // A factory-created issue or PR carries this marker so the Router ignores its
  // own events instead of looping on them.
  pi.registerCommand("factory-marker", {
    description: "Print the hidden marker the factory puts in its own issues and PRs",
    handler: async (_args, ctx) => {
      ctx.ui.notify("<!-- aepm-factory:auto -->", "info");
    },
  });
}
