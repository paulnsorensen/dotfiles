// turn-budget-guard opencode plugin — sub-agent budget adapter.
//
// The shared turn-budget-guard logic (agents/lib/turn-budget-guard.js) is
// authoritative; this adapter's only job is mapping opencode's plugin hooks
// onto the shared event shape.
//
// Identity: opencode's `tool.execute.before`/`.after` hook payloads carry
// only `{tool, sessionID, callID}` (+ `args`) — no agent identity field
// (verified against sst/opencode v1.17.14, packages/plugin/src/index.ts
// L266-281). Sub-agent dispatch creates a *child session* with `parentID`
// (caller session) and `agent` (sub-agent type name) set at creation
// (packages/opencode/src/tool/task.ts L142-158). This adapter resolves
// identity per call via `ctx.client.session.get({path:{id: sessionID}})`
// and caches the result in memory (this module lives for the opencode
// process). `parentID` alone doesn't disambiguate sub-agents from plain
// session forks (both set it), so a session only counts as a sub-agent when
// BOTH `parentID` and a non-empty `agent` are present. Any client error or
// missing fields fails open — no identity means the shared guard's own
// `no-agent-id` no-op fires.
//
// Byte signal: opencode exposes no transcript path, so the shared guard's
// byte probe always resolves to 0 here — enforcement is turn-ceiling-only
// on opencode. Not building a message-based byte estimator (YAGNI, out of
// this adapter's scope).
//
// Cleanup: the `event` hook watches `session.idle`/`session.deleted` for any
// sessionID cached as a sub-agent, emits a SubagentStop to the shared guard,
// then evicts the cache entry.
//
// Deny gate: `tool.execute.before` throwing is safe to keep as the deny
// mechanism. The trigger call site (packages/opencode/src/session/tools.ts
// L106-120, v1.17.14) runs inside the AI SDK tool's `execute()` (package
// `ai`, pinned to `ai@6.0.168`). That package's `executeToolCall`
// (packages/ai/src/generate-text/execute-tool-call.ts, vercel/ai tag
// ai@6.0.168) wraps the whole `execute()` call — including our thrown deny —
// in a try/catch that converts any thrown/rejected error into a
// `{type: "tool-error", ...}` tool output, which flows into the model-visible
// tool result exactly like any other tool error. It does not crash the turn.
// `emit.deny = throw` stays wired.
//
// The nudge stays a stub: opencode has no context-injection channel for a
// completed tool call.

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

// Resolve {parentID, agent} for `sessionID` via the opencode client, caching
// both hits and misses (including client errors) so repeat tool calls in the
// same session don't re-fetch. Returns null when the session isn't a
// sub-agent (no parentID/agent) or the lookup failed — either way the caller
// fails open.
async function resolveIdentity(client, cache, sessionID) {
  if (cache.has(sessionID)) return cache.get(sessionID);
  let identity = null;
  try {
    const res = await client.session.get({ path: { id: sessionID } });
    const info = res?.data;
    if (info && info.parentID && typeof info.agent === "string" && info.agent.trim()) {
      identity = { parentID: info.parentID, agent: info.agent };
    }
  } catch {
    identity = null;
  }
  cache.set(sessionID, identity);
  return identity;
}

async function eventFor(ctx, cache, input, output, hook_event_name) {
  const sessionID = typeof input?.sessionID === "string" ? input.sessionID : "";
  const identity = sessionID && ctx?.client ? await resolveIdentity(ctx.client, cache, sessionID) : null;

  return {
    harness: "opencode",
    hook_event_name,
    session_id: identity ? identity.parentID : "",
    agent_id: identity ? sessionID : "",
    agent_type: identity ? identity.agent : "",
    transcript_path: "",
    agent_transcript_path: "",
    cwd: ctx?.directory || ctx?.worktree || process.cwd(),
    tool_name: input?.tool || "unknown",
    tool_input: output?.args || input?.args || {},
  };
}

export const TurnBudgetGuard = async (ctx) => {
  const guard = loadGuard();
  if (!guard) return {};

  const cache = new Map();
  const emit = {
    deny: (reason) => { throw new Error(reason); },
    nudge: () => {},
  };

  return {
    "tool.execute.before": async (input, output) => {
      guard.handle(await eventFor(ctx, cache, input, output, "PreToolUse"), emit);
    },
    "tool.execute.after": async (input, output) => {
      guard.handle(await eventFor(ctx, cache, input, output, "PostToolUse"), emit);
    },
    event: async ({ event }) => {
      const type = event?.type;
      if (type !== "session.idle" && type !== "session.deleted") return;
      const sessionID = type === "session.idle" ? event.properties?.sessionID : event.properties?.info?.id;
      if (!sessionID || !cache.has(sessionID)) return;
      const identity = cache.get(sessionID);
      cache.delete(sessionID);
      if (!identity) return;
      guard.handle({
        harness: "opencode",
        hook_event_name: "SubagentStop",
        session_id: identity.parentID,
        agent_id: sessionID,
        agent_type: identity.agent,
      }, emit);
    },
  };
};
