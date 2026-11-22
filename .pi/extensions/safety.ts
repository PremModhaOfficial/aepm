/**
 * safety — the rules that must never depend on a model remembering them.
 * Adapted from Pi's example extensions (permission-gate.ts, protected-paths.ts),
 * narrowed to this repo's hard safety rules in AGENTS.md.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";

const PROTECTED = [".env", ".git/", ".gpg/", "node_modules/", "id_rsa", "id_ed25519"];

// Never allowed, no confirmation offered: these break a hard rule or destroy work.
const NEVER = [
  { re: /\bgit\s+push\b[^\n]*(--force|-f\b)[^\n]*\b(main|master)\b/, why: "force-push to the default branch" },
  { re: /\bgit\s+push\b[^\n]*\b(main|master)\b/, why: "push to the default branch" },
  { re: /\bgh\s+pr\s+merge\b[^\n]*--admin/, why: "merge bypassing branch protection (--admin)" },
  { re: /\bgh\s+api\b[^\n]*-X\s*(DELETE|PATCH|PUT)\b[^\n]*\/protection/, why: "editing branch protection" },
  { re: /\b(pacman|yay|makepkg|paccache|pacdiff)\b/, why: "pacman/yay/makepkg on the development host (sim/run.sh only)" },
  { re: /\bsystemctl\b\s+(enable|start|restart|disable|stop)\b/, why: "systemd state change on the development host" },
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
