/**
 * git-checkpoint — adapted from Pi's example. One stash checkpoint per turn so a
 * bad turn can be recovered without losing the previous one.
 *
 * Deliberately quiet: no restore prompt mid-run (the factory is unattended).
 * `/factory-restore` applies the newest checkpoint by hand.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  const checkpoints: string[] = [];

  pi.on("agent_start", async () => {
    try {
      const { stdout } = await pi.exec("git", ["stash", "create"], { timeout: 15000 });
      const ref = stdout.trim();
      if (ref) {
        checkpoints.push(ref);
        if (checkpoints.length > 20) checkpoints.shift();
      }
    } catch {
      /* not a git repo, or nothing to stash: not an error */
    }
  });

  pi.registerCommand("factory-restore", {
    description: "Apply the newest git checkpoint (or the Nth newest with a number)",
    handler: async (args, ctx) => {
      const n = Number.parseInt(args || "1", 10);
      const ref = checkpoints[checkpoints.length - n];
      if (!ref) return ctx.ui.notify("no checkpoint recorded this session", "warning");
      const ok = await ctx.ui.confirm("Restore checkpoint?", `git stash apply ${ref}`);
      if (!ok) return;
      const res = await pi.exec("git", ["stash", "apply", ref], { timeout: 30000 });
      ctx.ui.notify(res.code === 0 ? `restored ${ref}` : `failed: ${res.stderr.slice(0, 200)}`, res.code === 0 ? "info" : "error");
    },
  });
}
