// git-guard opencode plugin — block destructive git ops against a dirty tree.
//
// opencode has no shell-command *hook* like Claude/Codex/Cursor/Copilot, but
// it has a plugin system whose `tool.execute.before` fires for every tool
// call — including the `bash` tool. We intercept that and throw on a
// destructive-to-uncommitted git op, which is opencode's deny path (a thrown
// Error aborts the tool call and feeds the message back to the agent).
//
// Detection is the shared Node classifier (agents/lib/git-guard.js, the
// source-of-truth used by every other harness's adapter) — this plugin does
// NOT re-implement it. We resolve the dotfiles clone via $DOTFILES_DIR
// (exported by zsh/core.zsh), falling back to ~/Dev/dotfiles.
//
// Fail-open everywhere: if the shared lib can't be loaded the plugin no-ops,
// so a broken guard never blocks a clean op. Opt out with CLAUDE_GIT_GUARD=0.

import { createRequire } from "node:module";
import { homedir } from "node:os";
import { join } from "node:path";

const require = createRequire(import.meta.url);

function loadGuard() {
  const v = (process.env.CLAUDE_GIT_GUARD || "").trim().toLowerCase();
  if (v === "0" || v === "false" || v === "off" || v === "no") return null;
  const root = process.env.DOTFILES_DIR || join(homedir(), "Dev", "dotfiles");
  try {
    return require(join(root, "agents", "lib", "git-guard.js"));
  } catch {
    return null; // fail-open: lib missing → no guard
  }
}

export const GitGuard = async (ctx) => {
  const guard = loadGuard();
  if (!guard) return {}; // disabled or lib unavailable → no-op

  return {
    "tool.execute.before": async (input, output) => {
      if (input.tool !== "bash") return;
      const command = (output.args && output.args.command) || "";
      const cwd = ctx.directory || ctx.worktree || process.cwd();
      let hit;
      try {
        hit = guard.shouldBlock(command, cwd);
      } catch {
        return; // fail-open on any classifier error
      }
      if (hit) throw new Error(guard.denyReason(command, hit));
    },
  };
};
