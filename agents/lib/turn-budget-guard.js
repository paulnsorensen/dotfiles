#!/usr/bin/env node
// turn-budget-guard.js — per-sub-agent turn + context-byte ceiling.
//
// Claude Code's `maxTurns` sub-agent frontmatter does not enforce (upstream
// #41143: the hardcoded default always wins, and background spawns drop the
// config entirely), so sub-agents run unbounded. This hook owns the cap.
//
// Three hook events, all firing INSIDE the sub-agent and carrying a
// consistent `agent_id`. The main orchestrator's tool calls carry no
// `agent_id`, so the hook no-ops on them — only sub-agents are capped.
//   PreToolUse  — increment the per-agent turn counter, read live context
//                 bytes; deny the call if EITHER exceeds its hard ceiling.
//   PostToolUse — once per agent, inject a wrap-up nudge when either signal
//                 crosses its soft threshold (the graceful handoff window).
//   SubagentStop — delete the agent's counter dir. Every invocation also
//                 sweeps stale dirs so a missed Stop can't leak forever.
//
// Budgets are keyed by `agent_type` (table + default fallback). The byte
// ceiling is the sharper proxy for context rot: the sub-agent's own
// transcript (`agent-<agent_id>.jsonl`) is located live under the project
// dir and stat'd. If it can't be found the byte signal is 0 (fail-open to
// the turn ceiling alone).
//
// Fail-open everywhere: malformed/empty stdin, missing agent_id, unreadable
// state, or an unlocatable transcript → allow. The guard caps runaways; it
// must never become a denial-of-service. Matches the repo's
// sensitive-file-guard / git-guard convention.

const fs = require('fs');
const os = require('os');
const path = require('path');

// Prune counter dirs whose state file is older than this — backstop for a
// missed SubagentStop.
const STALE_HOURS = 6;

// Per-agent_type budgets. Turn ceilings are hand-set; byte ceilings are
// calibrated from the p50 (soft) / p90 (hard) of real agent-*.jsonl
// transcripts segmented by agent_type. Unknown types fall to `default`.
const BUDGETS = {
  coder: { turnSoft: 75, turnHard: 100, byteSoft: 368 * 1024, byteHard: 891 * 1024 },
  reviewer: { turnSoft: 40, turnHard: 50, byteSoft: 263 * 1024, byteHard: 408 * 1024 },
  explorer: { turnSoft: 40, turnHard: 50, byteSoft: 205 * 1024, byteHard: 396 * 1024 },
  researcher: { turnSoft: 40, turnHard: 50, byteSoft: 286 * 1024, byteHard: 512 * 1024 },
  default: { turnSoft: 40, turnHard: 50, byteSoft: 239 * 1024, byteHard: 517 * 1024 },
};

function budgetFor(agentType) {
  const key = String(agentType || '').trim().toLowerCase();
  return BUDGETS[key] || BUDGETS.default;
}

// State base dir. The env override lets tests sandbox away from the real dir.
function baseDir() {
  return process.env.CLAUDE_TURN_BUDGET_DIR || path.join(os.tmpdir(), 'claude-turn-budget');
}

// Keep externally-supplied ids from escaping the base dir.
function sanitize(id) {
  return String(id || '').replace(/[^A-Za-z0-9._-]/g, '_');
}

// The per-(session_id, agent_id) counter directory. Holds state.json.
function counterPath(sessionId, agentId) {
  return path.join(baseDir(), sanitize(sessionId), sanitize(agentId));
}

function stateFile(dir) {
  return path.join(dir, 'state.json');
}

// Read the counter state. Missing / malformed → fresh zeroed state.
function readState(dir) {
  try {
    const raw = fs.readFileSync(stateFile(dir), 'utf8');
    const s = JSON.parse(raw);
    return { turns: Number(s.turns) || 0, nudged: s.nudged === true };
  } catch {
    return { turns: 0, nudged: false };
  }
}

function writeState(dir, state) {
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(stateFile(dir), JSON.stringify(state));
}

// One increment per attempted tool call (PreToolUse only).
function incrementTurn(dir) {
  const s = readState(dir);
  const next = { turns: s.turns + 1, nudged: s.nudged };
  writeState(dir, next);
  return next;
}

function markNudged(dir) {
  const s = readState(dir);
  writeState(dir, { turns: s.turns, nudged: true });
}

function cleanup(dir) {
  try {
    fs.rmSync(dir, { recursive: true, force: true });
  } catch {
    /* fail-open */
  }
}

// Locate the sub-agent's own transcript (`agent-<agent_id>.jsonl`) under
// <dirname(transcript_path)>/<session_id>/ and return its byte size. The
// real path is .../<session_id>/subagents/agent-<agent_id>.jsonl, but the
// scheme is undocumented/internal, so walk for the file rather than hardcode
// the join — tolerant of layout drift across CC versions. Any miss / error
// → 0 (fail-open to the turn ceiling alone).
function contextBytes(transcriptPath, sessionId, agentId) {
  try {
    if (!transcriptPath || !sessionId || !agentId) return 0;
    const root = path.join(path.dirname(transcriptPath), sanitize(sessionId));
    const target = `agent-${agentId}.jsonl`;
    const hit = findFile(root, target, 4);
    if (!hit) return 0;
    return fs.statSync(hit).size;
  } catch {
    return 0;
  }
}

// Depth-capped recursive search for a file by exact name. No external glob
// lib; the depth cap survives symlink loops.
function findFile(dir, name, depth) {
  if (depth < 0) return null;
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return null;
  }
  for (const e of entries) {
    const full = path.join(dir, e.name);
    if (e.isFile() && e.name === name) return full;
  }
  for (const e of entries) {
    if (e.isDirectory()) {
      const found = findFile(path.join(dir, e.name), name, depth - 1);
      if (found) return found;
    }
  }
  return null;
}

// Prune agent counter dirs whose state.json mtime is older than the cutoff.
// Checks the STATE FILE's mtime, not the dir's — a dir's mtime freezes at
// mkdir on Linux and would falsely spare a leaked dir / falsely flag a live
// one. Best-effort; never throws to the caller.
function sweepStale(base, maxAgeHours) {
  const cutoff = Date.now() - maxAgeHours * 3600 * 1000;
  let sessions;
  try {
    sessions = fs.readdirSync(base, { withFileTypes: true });
  } catch {
    return;
  }
  for (const sess of sessions) {
    if (!sess.isDirectory()) continue;
    const sessDir = path.join(base, sess.name);
    let agents;
    try {
      agents = fs.readdirSync(sessDir, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const ag of agents) {
      if (!ag.isDirectory()) continue;
      const agDir = path.join(sessDir, ag.name);
      let mtime;
      try {
        mtime = fs.statSync(stateFile(agDir)).mtimeMs;
      } catch {
        continue; // no state file → leave it
      }
      if (mtime < cutoff) cleanup(agDir);
    }
    // Drop the session dir if it emptied out.
    try {
      if (fs.readdirSync(sessDir).length === 0) fs.rmdirSync(sessDir);
    } catch {
      /* fail-open */
    }
  }
}

function denyReason(agentType, turns, bytes, budget) {
  const kb = Math.round(bytes / 1024);
  const hardKb = Math.round(budget.byteHard / 1024);
  return `Sub-agent budget exceeded (type '${agentType || 'default'}': ` +
    `turns ${turns}/${budget.turnHard}, context ~${kb}KB/${hardKb}KB). ` +
    `Stop calling tools now — synthesize your findings and return your final ` +
    `text response. Every further tool call is denied until this sub-agent returns.`;
}

function nudgeContext(agentType, budget) {
  return `Approaching this sub-agent's budget (type '${agentType || 'default'}': ` +
    `soft ${budget.turnSoft} turns / ~${Math.round(budget.byteSoft / 1024)}KB context). ` +
    `Persist your handoff or partial results now and wrap up: tool calls are ` +
    `hard-blocked at the ceiling, so prefer returning a concise final answer ` +
    `over further exploration.`;
}

function emitDeny(reason) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: reason,
    },
  }));
}

function emitNudge(context) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PostToolUse',
      additionalContext: context,
    },
  }));
}

function handle(event) {
  const agentId = event.agent_id;
  if (!agentId) return; // orchestrator (no agent_id) is never capped → allow

  // Backstop cleanup: prune stale counter dirs. Runs below the orchestrator
  // no-op guard so main-session tool calls (the majority, and now also the
  // PostToolUse `.*` surface) don't pay a filesystem walk. Sub-agents run
  // constantly, so any orchestrator-only session's dirs still get swept later.
  try { sweepStale(baseDir(), STALE_HOURS); } catch { /* fail-open */ }

  const sessionId = event.session_id;
  const agentType = event.agent_type;
  const dir = counterPath(sessionId, agentId);
  const budget = budgetFor(agentType);
  const evt = event.hook_event_name;

  if (evt === 'SubagentStop') {
    cleanup(dir);
    return;
  }

  if (evt === 'PreToolUse') {
    const state = incrementTurn(dir);
    const bytes = contextBytes(event.transcript_path, sessionId, agentId);
    if (state.turns > budget.turnHard || bytes > budget.byteHard) {
      emitDeny(denyReason(agentType, state.turns, bytes, budget));
    }
    return;
  }

  if (evt === 'PostToolUse') {
    const state = readState(dir);
    if (state.nudged) return;
    const bytes = contextBytes(event.transcript_path, sessionId, agentId);
    if (state.turns >= budget.turnSoft || bytes >= budget.byteSoft) {
      markNudged(dir);
      emitNudge(nudgeContext(agentType, budget));
    }
  }
}

if (require.main === module) {
  let stdin = '';
  process.stdin.on('data', (chunk) => { stdin += chunk; });
  process.stdin.on('end', () => {
    try {
      const event = JSON.parse(stdin);
      handle(event);
    } catch {
      // fail-open on any error: malformed stdin or internal fault → allow
    }
  });
}

module.exports = {
  budgetFor,
  baseDir,
  counterPath,
  readState,
  incrementTurn,
  markNudged,
  cleanup,
  contextBytes,
  denyReason,
  nudgeContext,
  sweepStale,
};
