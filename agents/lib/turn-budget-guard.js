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
//   SubagentStop — delete the agent's counter dir, and sweep stale dirs so a
//                 missed Stop can't leak forever.
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

// Opt-in observability: with CLAUDE_TURN_BUDGET_DEBUG set, emit one stderr line
// per budget decision so enforcement is distinguishable from a silent fail-open
// (e.g. a byte probe that resolved to 0). Off by default; stderr never reaches
// the model, only the hook log.
function debug(msg) {
  if (process.env.CLAUDE_TURN_BUDGET_DEBUG) process.stderr.write(`[turn-budget-guard] ${msg}\n`);
}

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

// The budget key actually applied for `agentType` — the matched table key, or
// 'default' when the type is unknown/empty. Kept separate from the raw
// `agent_type` so operator-facing messages name the budget in force, not a
// phantom type-specific budget that was never selected.
function resolvedType(agentType) {
  const key = String(agentType || '').trim().toLowerCase();
  return BUDGETS[key] ? key : 'default';
}

// State base dir. An explicit CLAUDE_TURN_BUDGET_DIR is trusted as-is (the test
// sandbox). The default path is namespaced by uid so it is not a single
// world-known location shared across every user of the host.
function baseDir() {
  if (process.env.CLAUDE_TURN_BUDGET_DIR) return process.env.CLAUDE_TURN_BUDGET_DIR;
  const uid = (process.getuid && process.getuid()) ?? 'nouid';
  return path.join(os.tmpdir(), `claude-turn-budget-${uid}`);
}

// Reject a pre-seeded / hijacked default base dir before writing into it: a
// symlink, a dir we don't own, or one group/other-accessible could let a local
// attacker on a shared host redirect our writes via the predictable temp path.
// Skipped for an explicit CLAUDE_TURN_BUDGET_DIR (trusted). Throwing here
// fail-opens (the caller's outer try/catch → allow).
function assertSafeBase() {
  if (process.env.CLAUDE_TURN_BUDGET_DIR) return;
  let st;
  try {
    st = fs.lstatSync(baseDir());
  } catch {
    return; // absent — writeState's mkdir with mode 0o700 creates it safely
  }
  const uid = process.getuid && process.getuid();
  if (st.isSymbolicLink() || !st.isDirectory() ||
      (uid !== undefined && st.uid !== uid) || (st.mode & 0o077) !== 0) {
    throw new Error('unsafe turn-budget base dir');
  }
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
  assertSafeBase();
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
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

  const sessionId = event.session_id;
  const agentType = event.agent_type;
  const dir = counterPath(sessionId, agentId);
  const budget = budgetFor(agentType);
  const evt = event.hook_event_name;

  if (evt === 'SubagentStop') {
    cleanup(dir);
    // Backstop: sweep stale counter dirs left by a missed SubagentStop. Runs
    // only here (not on every Pre/PostToolUse) — SubagentStop fires once per
    // sub-agent and the sweep walks all sessions, so leaked dirs are still
    // reclaimed by the next agent that stops cleanly.
    try { sweepStale(baseDir(), STALE_HOURS); } catch { /* fail-open */ }
    return;
  }

  if (evt === 'PreToolUse') {
    const state = incrementTurn(dir);
    const bytes = contextBytes(event.transcript_path, sessionId, agentId);
    debug(`pre type=${resolvedType(agentType)} turns=${state.turns}/${budget.turnHard} ` +
      `bytes=${bytes}/${budget.byteHard}`);
    if (state.turns > budget.turnHard || bytes > budget.byteHard) {
      emitDeny(denyReason(resolvedType(agentType), state.turns, bytes, budget));
    }
    return;
  }

  if (evt === 'PostToolUse') {
    const state = readState(dir);
    if (state.nudged) return;
    const bytes = contextBytes(event.transcript_path, sessionId, agentId);
    if (state.turns >= budget.turnSoft || bytes >= budget.byteSoft) {
      markNudged(dir);
      debug(`nudge type=${resolvedType(agentType)} turns=${state.turns} bytes=${bytes}`);
      emitNudge(nudgeContext(resolvedType(agentType), budget));
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
  resolvedType,
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
