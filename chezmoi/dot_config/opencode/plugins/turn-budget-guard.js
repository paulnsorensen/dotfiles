// turn-budget-guard opencode plugin — best-effort sub-agent budget adapter.
//
// The shared turn-budget-guard logic is authoritative. This plugin only adapts
// opencode tool events when they carry a stable sub-agent identity; otherwise it
// records a fail-open decision and lets the tool run.

import { createRequire } from "node:module";
import { homedir } from "node:os";
import { join } from "node:path";

const require = createRequire(import.meta.url);

function loadGuard() {
  const v = (process.env.CLAUDE_TURN_BUDGET_GUARD || "").trim().toLowerCase();
  if (v === "0" || v === "false" || v === "off" || v === "no") return null;
  const root = process.env.DOTFILES_DIR || join(homedir(), "Dev", "dotfiles");
  try {
    return require(join(root, "agents", "lib", "turn-budget-guard.js"));
  } catch {
    return null;
  }
}

function firstString(...values) {
  for (const value of values) {
    if (typeof value === "string" && value.trim()) return value;
  }
  return "";
}

function eventFor(ctx, input, output, hook_event_name) {
  const args = output?.args || {};
  const meta = input?.metadata || output?.metadata || {};
  const session = input?.session || output?.session || ctx?.session || {};
  const agent = input?.agent || output?.agent || meta.agent || {};

  return {
    harness: "opencode",
    hook_event_name,
    session_id: firstString(input?.session_id, input?.sessionID, session.id, meta.session_id),
    agent_id: firstString(input?.agent_id, input?.agentID, agent.id, meta.agent_id),
    agent_type: firstString(input?.agent_type, input?.agentType, agent.type, meta.agent_type),
    transcript_path: firstString(input?.transcript_path, session.transcript_path, meta.transcript_path),
    agent_transcript_path: firstString(input?.agent_transcript_path, agent.transcript_path, meta.agent_transcript_path),
    cwd: ctx?.directory || ctx?.worktree || process.cwd(),
    tool_name: input?.tool || "unknown",
    tool_input: args,
  };
}

export const TurnBudgetGuard = async (ctx) => {
  const guard = loadGuard();
  if (!guard) return {};

  const emit = {
    deny: (reason) => { throw new Error(reason); },
    nudge: () => {},
  };

  return {
    "tool.execute.before": async (input, output) => {
      guard.handle(eventFor(ctx, input, output, "PreToolUse"), emit);
    },
    "tool.execute.after": async (input, output) => {
      guard.handle(eventFor(ctx, input, output, "PostToolUse"), emit);
    },
  };
};
