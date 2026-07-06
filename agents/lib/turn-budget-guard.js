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

// Per-agent_type budgets. Turn ceilings are hand-set; byte ceilings use a
// uniform byte proxy for ~110K-token soft and ~130K-token hard context caps
// (4 bytes/token estimate against JSONL transcript size). Unknown types fall
// to `default`.
const CONTEXT_SOFT_BYTES = 110 * 1024 * 4;
const CONTEXT_HARD_BYTES = 130 * 1024 * 4;
const BUDGETS = {
  coder: { turnSoft: 75, turnHard: 100, byteSoft: CONTEXT_SOFT_BYTES, byteHard: CONTEXT_HARD_BYTES },
  reviewer: { turnSoft: 40, turnHard: 50, byteSoft: CONTEXT_SOFT_BYTES, byteHard: CONTEXT_HARD_BYTES },
  explorer: { turnSoft: 40, turnHard: 50, byteSoft: CONTEXT_SOFT_BYTES, byteHard: CONTEXT_HARD_BYTES },
  researcher: { turnSoft: 40, turnHard: 50, byteSoft: CONTEXT_SOFT_BYTES, byteHard: CONTEXT_HARD_BYTES },
  default: { turnSoft: 40, turnHard: 50, byteSoft: CONTEXT_SOFT_BYTES, byteHard: CONTEXT_HARD_BYTES },
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
// sandbox). The default path lives under the user's state directory, not the
// system temp dir, so CodeQL and local attackers do not see a predictable
// shared-temp write target.
function baseDir() {
  if (process.env.CLAUDE_TURN_BUDGET_DIR) return process.env.CLAUDE_TURN_BUDGET_DIR;
  const stateHome = process.env.XDG_STATE_HOME || path.join(os.homedir(), '.local', 'state');
  return path.join(stateHome, 'claude-turn-budget');
}

function logPath() {
  if (process.env.CLAUDE_TURN_BUDGET_LOG) return process.env.CLAUDE_TURN_BUDGET_LOG;
  return path.join(baseDir(), 'decisions.jsonl');
}

function harnessName(event) {
  if (event.harness) return event.harness;
  if (process.env.CLAUDE_TURN_BUDGET_HARNESS) return process.env.CLAUDE_TURN_BUDGET_HARNESS;
  const script = process.argv[1] || '';
  if (script.includes(`${path.sep}.codex${path.sep}`)) return 'codex';
  if (script.includes(`${path.sep}.claude${path.sep}`)) return 'claude';
  return 'unknown';
}

function writeDecision(event, fields) {
  try {
    const file = logPath();
    fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
    const record = {
      ts: new Date().toISOString(),
      harness: harnessName(event),
      event: event.hook_event_name || 'unknown',
      session_id: event.session_id || null,
      agent_id: event.agent_id || null,
      agent_type: event.agent_type || null,
      ...fields,
    };
    fs.appendFileSync(file, `${JSON.stringify(record)}\n`, { mode: 0o600 });
  } catch {
    /* fail-open: observability must not affect enforcement */
  }
}

function thresholdFields(budget) {
  return {
    turnSoft: budget.turnSoft,
    turnHard: budget.turnHard,
    byteSoft: budget.byteSoft,
    byteHard: budget.byteHard,
  };
}

// Reject a pre-seeded / hijacked default base dir before writing into it: a
// symlink, a dir we don't own, or one group/other-accessible could let a local
// attacker redirect our writes. Skipped for an explicit CLAUDE_TURN_BUDGET_DIR
// (trusted). Throwing here fail-opens (the caller's outer try/catch → allow).
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

function contextBytesFromEvent(event) {
  try {
    if (event.agent_transcript_path) return fs.statSync(event.agent_transcript_path).size;
  } catch {
    return 0;
  }
  return contextBytes(event.transcript_path, event.session_id, event.agent_id);
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

function handle(event, emit = { deny: emitDeny, nudge: emitNudge }) {
  const agentId = event.agent_id;
  if (!agentId) {
    writeDecision(event, { action: 'allow', reason: 'no-agent-id' });
    return { action: 'allow', reason: 'no-agent-id' };
  }

  const sessionId = event.session_id;
  const agentType = event.agent_type;
  const dir = counterPath(sessionId, agentId);
  const budget = budgetFor(agentType);
  const type = resolvedType(agentType);
  const evt = event.hook_event_name;

  if (evt === 'SubagentStop') {
    cleanup(dir);
    // Backstop: sweep stale counter dirs left by a missed SubagentStop. Runs
    // only here (not on every Pre/PostToolUse) — SubagentStop fires once per
    // sub-agent and the sweep walks all sessions, so leaked dirs are still
    // reclaimed by the next agent that stops cleanly.
    try { sweepStale(baseDir(), STALE_HOURS); } catch { /* fail-open */ }
    writeDecision(event, {
      action: 'cleanup',
      reason: 'subagent-stop',
      budget_type: type,
      ...thresholdFields(budget),
    });
    return { action: 'cleanup', reason: 'subagent-stop' };
  }

  if (evt === 'PreToolUse') {
    const state = incrementTurn(dir);
    const bytes = contextBytesFromEvent(event);
    debug(`pre type=${type} turns=${state.turns}/${budget.turnHard} ` +
      `bytes=${bytes}/${budget.byteHard}`);
    const fields = {
      budget_type: type,
      turns: state.turns,
      bytes,
      ...thresholdFields(budget),
    };
    if (state.turns > budget.turnHard || bytes > budget.byteHard) {
      const reason = denyReason(type, state.turns, bytes, budget);
      writeDecision(event, { ...fields, action: 'deny', reason: 'hard-ceiling' });
      emit.deny(reason);
      return { action: 'deny', reason };
    }
    writeDecision(event, { ...fields, action: 'allow', reason: 'within-budget' });
    return { action: 'allow', reason: 'within-budget' };
  }

  if (evt === 'PostToolUse') {
    const state = readState(dir);
    const bytes = contextBytesFromEvent(event);
    const fields = {
      budget_type: type,
      turns: state.turns,
      bytes,
      ...thresholdFields(budget),
    };
    if (state.nudged) {
      writeDecision(event, { ...fields, action: 'allow', reason: 'already-nudged' });
      return { action: 'allow', reason: 'already-nudged' };
    }
    if (state.turns >= budget.turnSoft || bytes >= budget.byteSoft) {
      markNudged(dir);
      debug(`nudge type=${type} turns=${state.turns} bytes=${bytes}`);
      const context = nudgeContext(type, budget);
      writeDecision(event, { ...fields, action: 'nudge', reason: 'soft-threshold' });
      emit.nudge(context);
      return { action: 'nudge', reason: context };
    }
    writeDecision(event, { ...fields, action: 'allow', reason: 'below-soft-threshold' });
    return { action: 'allow', reason: 'below-soft-threshold' };
  }

  writeDecision(event, { action: 'allow', reason: 'unsupported-event' });
  return { action: 'allow', reason: 'unsupported-event' };
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
  logPath,
  writeDecision,
  contextBytesFromEvent,
  handle,
  denyReason,
  nudgeContext,
  sweepStale,
};
