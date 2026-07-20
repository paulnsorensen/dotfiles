#!/usr/bin/env node
// turn-budget-guard.js — per-sub-agent turn + context-token ceiling.
//
// Claude Code's `maxTurns` sub-agent frontmatter does not enforce (upstream
// #41143: the hardcoded default always wins, and background spawns drop the
// config entirely), so sub-agents run unbounded. This hook owns the cap.
//
// Three hook events, all firing INSIDE the sub-agent and carrying a
// consistent `agent_id`. The main orchestrator's tool calls carry no
// `agent_id`, so the hook no-ops on them — only sub-agents are capped.
//   PreToolUse  — increment the per-agent turn counter, read live context
//                 tokens; deny at the turn hard ceiling immediately. The
//                 context hard ceiling gets a short grace window
//                 (CTX_GRACE_CALLS), but ONLY when the agent's first
//                 observed reading is already above hard, or no prior real
//                 (non-zero) reading has been observed yet for this agent —
//                 the resume signature (SendMessage resume: SubagentStop
//                 wipes turn state but the transcript persists, so a
//                 continued agent can start above ctxHard on call 1, or on
//                 a later call if its early reading(s) hit a transient
//                 transcript-not-found miss). A fresh agent whose first
//                 real reading lands under hard, then crosses ctxHard
//                 mid-run, gets none of this window.
//   PostToolUse — once per agent, inject a wrap-up nudge when either signal
//                 crosses its soft threshold (the graceful handoff window);
//                 a sterner one-time hard nudge fires when context tokens
//                 cross the hard ceiling, even if the soft nudge already
//                 fired.
//   SubagentStop — delete the agent's counter dir, sweep stale dirs so a
//                 missed Stop can't leak forever, and rotate the decision
//                 log past a size cap.
//
// Budgets are keyed by `agent_type` (table + default fallback). The context
// ceiling is the sharper proxy for context rot: the sub-agent's own
// transcript (`agent-<agent_id>.jsonl`) is located live under the project
// dir and its last assistant `message.usage` tokens summed. If no usage
// line is found the byte size of the file stands in as a proxy; if the
// transcript can't be found at all the signal is 0 (fail-open to the turn
// ceiling alone).
//
// Per-agent counters live as append/marker files (turns, grace, nudged,
// hard-nudged) under one dir per (session_id, agent_id) — no read-modify-
// write of a single state.json, so concurrent tool calls can't race a lost
// increment or fail-open on a torn read.
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

// Prune counter dirs whose turns file is older than this — backstop for a
// missed SubagentStop.
const STALE_HOURS = 6;

// A continued sub-agent's transcript may already sit above ctxHard on its
// first call after resume (SubagentStop wipes turn state but the transcript
// persists) — allow this many over-hard calls before denying, so there's a
// window to persist a handoff instead of an instant wall. Granted only when
// the agent's FIRST observed reading is already above hard (see the
// graceEligible marker in handle()) — a fresh agent that crosses hard
// mid-run gets none of this window.
const CTX_GRACE_CALLS = 3;

// Byte-to-token conversion for the fallback signal below — restores the
// module's prior ~4-bytes/token calibration on the token scale so the
// fallback compares against ctxHard/ctxSoft correctly instead of a raw byte
// count against a token threshold.
const BYTES_PER_TOKEN_ESTIMATE = 4;

// Cap decisions.jsonl; rotated to one `.1` generation on SubagentStop once
// it crosses this (see rotateLogIfLarge).
const DECISION_LOG_MAX_BYTES = 5 * 1024 * 1024;

// Per-agent_type budgets. Turn ceilings are hand-set. Context ceilings are
// real token counts read from the transcript's last assistant
// `message.usage` line (input_tokens + cache_creation_input_tokens +
// cache_read_input_tokens — the summed live context the model last
// ingested), not a byte proxy: ~110K-token soft / ~130K-token hard. When no
// usage line can be read, `statSync(...).size / BYTES_PER_TOKEN_ESTIMATE`
// (a ~4-bytes/token estimate on the token scale) stands in as a fail-open
// fallback proxy for the same thresholds — strictly monotonic, which is all
// a ceiling needs. Per Claude Code's documented async transcript writes, the
// reading can trail the model's live context by up to one turn; acceptable
// for a monotonic ceiling. Unknown agent_types fall to `default`.
const CONTEXT_SOFT_TOKENS = 110_000;
const CONTEXT_HARD_TOKENS = 130_000;
const BUDGETS = {
  coder: { turnSoft: 75, turnHard: 100, ctxSoft: CONTEXT_SOFT_TOKENS, ctxHard: CONTEXT_HARD_TOKENS },
  // general-purpose sub-agents run the same coder-shaped workloads.
  'general-purpose': { turnSoft: 75, turnHard: 100, ctxSoft: CONTEXT_SOFT_TOKENS, ctxHard: CONTEXT_HARD_TOKENS },
  // milknado worker's exact reported agent_type is unobserved — key both
  // plausible spellings at coder tier so whichever the plugin emits resolves
  // correctly instead of silently falling to `default`.
  'milknado-worker': { turnSoft: 75, turnHard: 100, ctxSoft: CONTEXT_SOFT_TOKENS, ctxHard: CONTEXT_HARD_TOKENS },
  'milknado:milknado-worker': { turnSoft: 75, turnHard: 100, ctxSoft: CONTEXT_SOFT_TOKENS, ctxHard: CONTEXT_HARD_TOKENS },
  reviewer: { turnSoft: 40, turnHard: 50, ctxSoft: CONTEXT_SOFT_TOKENS, ctxHard: CONTEXT_HARD_TOKENS },
  explorer: { turnSoft: 40, turnHard: 50, ctxSoft: CONTEXT_SOFT_TOKENS, ctxHard: CONTEXT_HARD_TOKENS },
  researcher: { turnSoft: 40, turnHard: 50, ctxSoft: CONTEXT_SOFT_TOKENS, ctxHard: CONTEXT_HARD_TOKENS },
  default: { turnSoft: 40, turnHard: 50, ctxSoft: CONTEXT_SOFT_TOKENS, ctxHard: CONTEXT_HARD_TOKENS },
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
    ctxSoft: budget.ctxSoft,
    ctxHard: budget.ctxHard,
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
    return; // absent — ensureCounterDir's mkdir with mode 0o700 creates it safely
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

// The per-(session_id, agent_id) counter directory. Holds append/marker
// files: turns, grace, nudged, hard-nudged (plus a legacy state.json from a
// pre-rewrite agent, tolerated only by sweepStale's fallback).
function counterPath(sessionId, agentId) {
  return path.join(baseDir(), sanitize(sessionId), sanitize(agentId));
}

function stateFile(dir) {
  return path.join(dir, 'state.json');
}

function turnsFile(dir) {
  return path.join(dir, 'turns');
}

function graceFile(dir) {
  return path.join(dir, 'grace');
}

function graceEligibleFile(dir) {
  return path.join(dir, 'grace-eligible');
}

// One-shot marker: set the first time a call for this agent produces a real
// (non-zero) context reading, regardless of turn. Lets grace eligibility
// (#9) latch on a resume whose early call(s) hit a transient transcript-
// not-found miss (tokens=0 on turns===1) without opening the window for a
// fresh agent whose first real reading is under hard and later crosses it.
function realReadingSeenFile(dir) {
  return path.join(dir, 'real-reading-seen');
}

function nudgedFile(dir) {
  return path.join(dir, 'nudged');
}

function hardNudgedFile(dir) {
  return path.join(dir, 'hard-nudged');
}

function fileSize(file) {
  try {
    return fs.statSync(file).size;
  } catch {
    return 0;
  }
}

function fileExists(file) {
  try {
    fs.statSync(file);
    return true;
  } catch {
    return false;
  }
}

// Read the counter state from the append/marker files. Missing → zero/false.
// Counts derive from file size (one byte per append), not a JSON field, so a
// torn read can't zero out a live counter.
function readState(dir) {
  return {
    turns: fileSize(turnsFile(dir)),
    graceUsed: fileSize(graceFile(dir)),
    nudged: fileExists(nudgedFile(dir)),
    hardNudged: fileExists(hardNudgedFile(dir)),
  };
}

function ensureCounterDir(dir) {
  assertSafeBase();
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
}

// Append one byte to `file` and return the new size — O_APPEND appends are
// atomic, so concurrent batched tool calls can't race a read-modify-write
// and lose an increment the way a shared state.json could.
function appendCounter(dir, file) {
  ensureCounterDir(dir);
  fs.appendFileSync(file, 'x');
  return fileSize(file);
}

// One increment per attempted tool call (PreToolUse only).
function incrementTurn(dir) {
  appendCounter(dir, turnsFile(dir));
  return readState(dir);
}

// One increment per grace-consumed over-hard byte call (PreToolUse only).
function incrementGrace(dir) {
  return appendCounter(dir, graceFile(dir));
}

// Create `file` iff absent — atomic create-if-absent via the 'wx' flag.
// Returns true if THIS call created it, false if another process already won
// the race (EEXIST) — the caller must not emit a duplicate nudge.
function markOnce(dir, file) {
  ensureCounterDir(dir);
  try {
    fs.writeFileSync(file, '', { flag: 'wx' });
    return true;
  } catch (err) {
    if (err && err.code === 'EEXIST') return false;
    throw err;
  }
}

function markNudged(dir) {
  return markOnce(dir, nudgedFile(dir));
}

function markHardNudged(dir) {
  return markOnce(dir, hardNudgedFile(dir));
}

function cleanup(dir) {
  try {
    fs.rmSync(dir, { recursive: true, force: true });
  } catch {
    /* fail-open */
  }
}

// Byte window read from the tail of a transcript before falling back to a
// full-file read below — keeps the common case bounded instead of O(file
// size) on every Pre/PostToolUse call. One turn's transcript bytes
// comfortably fit inside this window, so the full-read fallback is rare.
const TAIL_READ_BYTES = 256 * 1024;

// Scan transcript content for the LAST assistant `message.usage` tokens
// (input_tokens + cache_creation_input_tokens + cache_read_input_tokens).
// A per-line try/catch means one torn/malformed line (e.g. an in-progress
// async write, or a partial first line from a tail-window read) is skipped
// rather than treated as a fatal parse failure that discards every good
// reading already accumulated. Shared by both the tail-window and
// full-file read paths below.
function lastUsageTokens(content) {
  let lastTokens = null;
  for (const line of content.split('\n')) {
    if (!line.trim()) continue;
    try {
      const record = JSON.parse(line);
      const usage = record && record.type === 'assistant' && record.message && record.message.usage;
      if (usage && typeof usage.input_tokens === 'number') {
        lastTokens = usage.input_tokens +
          (usage.cache_creation_input_tokens || 0) +
          (usage.cache_read_input_tokens || 0);
      }
    } catch {
      /* torn/malformed line — skip it, keep any reading already seen */
    }
  }
  return lastTokens;
}

// Read the LAST assistant transcript line's `message.usage` tokens — the
// real live context the model last ingested. Reads only the tail window
// first (the common case); falls back to a full-file read only when the
// tail yields no usage line, so correctness is never sacrificed for speed.
// Returns null when the file can't be read at all or no usage line is found
// anywhere in it — the caller falls back to the byte-size proxy.
function tokensFromTranscript(file) {
  let size;
  try {
    size = fs.statSync(file).size;
  } catch {
    return null;
  }
  if (size > TAIL_READ_BYTES) {
    try {
      const fd = fs.openSync(file, 'r');
      const buf = Buffer.alloc(TAIL_READ_BYTES);
      fs.readSync(fd, buf, 0, TAIL_READ_BYTES, size - TAIL_READ_BYTES);
      fs.closeSync(fd);
      const tail = lastUsageTokens(buf.toString('utf8'));
      if (tail !== null) return tail;
    } catch {
      /* fall through to the full-file read below */
    }
  }
  let content;
  try {
    content = fs.readFileSync(file, 'utf8');
  } catch {
    return null;
  }
  return lastUsageTokens(content);
}

// Locate the sub-agent's own transcript (`agent-<agent_id>.jsonl`) under
// <dirname(transcript_path)>/<session_id>/ and return its context signal.
// The real path is .../<session_id>/subagents/agent-<agent_id>.jsonl, but
// the scheme is undocumented/internal, so walk for the file rather than
// hardcode the join — tolerant of layout drift across CC versions. Any
// miss / error → 0 (fail-open to the turn ceiling alone).
function contextTokens(transcriptPath, sessionId, agentId) {
  try {
    if (!transcriptPath || !sessionId || !agentId) return { tokens: 0, source: 'none' };
    const root = path.join(path.dirname(transcriptPath), sanitize(sessionId));
    const target = `agent-${agentId}.jsonl`;
    const hit = findFile(root, target, 4);
    if (!hit) return { tokens: 0, source: 'none' };
    const tokens = tokensFromTranscript(hit);
    if (tokens !== null) return { tokens, source: 'tokens' };
    // fail-open: byte-size proxy fallback, converted to the token scale
    return { tokens: Math.round(fs.statSync(hit).size / BYTES_PER_TOKEN_ESTIMATE), source: 'bytes-fallback' };
  } catch {
    return { tokens: 0, source: 'none' };
  }
}

// A failed read of the primary (Codex) path must fall through to the
// walk-based fallback, not short-circuit to 0 — the fallback is exactly for
// when the primary path doesn't resolve.
function contextTokensFromEvent(event) {
  if (event.agent_transcript_path) {
    try {
      const tokens = tokensFromTranscript(event.agent_transcript_path);
      if (tokens !== null) return { tokens, source: 'tokens' };
      // fail-open: byte-size proxy fallback, converted to the token scale
      return {
        tokens: Math.round(fs.statSync(event.agent_transcript_path).size / BYTES_PER_TOKEN_ESTIMATE),
        source: 'bytes-fallback',
      };
    } catch {
      /* fall through to the walk-based fallback below */
    }
  }
  return contextTokens(event.transcript_path, event.session_id, event.agent_id);
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

// Prune agent counter dirs whose turns file mtime is older than the cutoff,
// falling back to a legacy state.json mtime for a dir left by a pre-rewrite
// agent (no migration shim — those just reset to zero, which is fail-open
// and acceptable). A dir with neither file is mid-creation; leave it.
// Checks a FILE's mtime, not the dir's — a dir's mtime freezes at mkdir on
// Linux and would falsely spare a leaked dir / falsely flag a live one.
// Best-effort; never throws to the caller.
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
        mtime = fs.statSync(turnsFile(agDir)).mtimeMs;
      } catch {
        try {
          mtime = fs.statSync(stateFile(agDir)).mtimeMs; // legacy leftover dir
        } catch {
          continue; // neither file → mid-creation or already-swept; leave it
        }
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

// Rotate decisions.jsonl to one `.1` generation once it crosses maxBytes.
// Best-effort: a missing log file or a failed rename both fail-open (the
// log just keeps growing rather than blocking enforcement).
function rotateLogIfLarge(maxBytes) {
  try {
    const file = logPath();
    if (fs.statSync(file).size > maxBytes) {
      fs.renameSync(file, `${file}.1`);
    }
  } catch {
    /* fail-open */
  }
}

function denyReason(agentType, turns, tokens, budget) {
  return `Sub-agent budget exceeded (type '${agentType || 'default'}': ` +
    `turns ${turns}/${budget.turnHard}, context ${tokens}/${budget.ctxHard} tokens). ` +
    `Stop calling tools now — synthesize your findings and return your final ` +
    `text response. Every further tool call is denied until this sub-agent returns. ` +
    `If your task is incomplete, open your final reply with ` +
    `"status: blocked: out of context" so the orchestrator re-dispatches a fresh agent.`;
}

function nudgeContext(agentType, budget) {
  return `Approaching this sub-agent's budget (type '${agentType || 'default'}': ` +
    `soft ${budget.turnSoft} turns / ${budget.ctxSoft} context tokens). ` +
    `Persist your handoff or partial results now and wrap up: tool calls are ` +
    `hard-blocked at the ceiling, so prefer returning a concise final answer ` +
    `over further exploration.`;
}

// Sterner one-time nudge for crossing the context HARD ceiling (as opposed
// to the soft-threshold nudgeContext above) — the grace window is short, so
// this must land before it runs out.
function hardNudgeContext(agentType, budget, remainingCalls) {
  return `Context hard ceiling exceeded (type '${agentType || 'default'}': ` +
    `${budget.ctxHard} tokens). At most ${remainingCalls} further ` +
    `tool call(s) will be allowed before this sub-agent is denied outright. ` +
    `Persist your handoff NOW — do not keep exploring. If your task is ` +
    `incomplete, open your final reply with "status: blocked: out of context" ` +
    `so the orchestrator re-dispatches a fresh agent.`;
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
    // These used to be 64% of all records — the orchestrator's own tool
    // calls, written on every call of every session. Gate behind the debug
    // env var so the always-on log only carries actual sub-agent decisions.
    if (process.env.CLAUDE_TURN_BUDGET_DEBUG) {
      writeDecision(event, { action: 'allow', reason: 'no-agent-id' });
    }
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
    try { rotateLogIfLarge(DECISION_LOG_MAX_BYTES); } catch { /* fail-open */ }
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
    const { tokens, source: ctxSource } = contextTokensFromEvent(event);
    // Resume-only grace: eligibility is decided once, on the agent's first
    // observed reading over ctxHard. The over-hard-on-turn-1 signature is
    // almost always a resume (SubagentStop wiped turn state but the
    // transcript persists) — a fresh agent's own transcript grows one turn
    // at a time, so it can only cross ctxHard mid-run, not on call 1; the
    // rare exception (a fresh agent spawned with an already-large inline
    // context) also earns the short window, which is acceptable. A resume
    // whose first call(s) hit a transient transcript-not-found miss
    // (tokens===0) can still latch on its first over-hard reading, tracked
    // via realReadingSeenFile — but only if no earlier real reading was
    // already seen (that would mean a fresh agent crossing mid-run).
    const seenBefore = fileExists(realReadingSeenFile(dir));
    if (tokens > budget.ctxHard && (state.turns === 1 || !seenBefore)) {
      try { markOnce(dir, graceEligibleFile(dir)); } catch { /* fail-open: eligibility best-effort */ }
    }
    if (tokens > 0) {
      try { markOnce(dir, realReadingSeenFile(dir)); } catch { /* best-effort */ }
    }
    const graceEligible = fileExists(graceEligibleFile(dir));
    debug(`pre type=${type} turns=${state.turns}/${budget.turnHard} ` +
      `tokens=${tokens}/${budget.ctxHard} grace=${state.graceUsed}/${CTX_GRACE_CALLS} eligible=${graceEligible}`);
    const fields = {
      budget_type: type,
      turns: state.turns,
      tokens,
      ctx_source: ctxSource,
      graceUsed: state.graceUsed,
      ...thresholdFields(budget),
    };
    if (state.turns > budget.turnHard) {
      const reason = denyReason(type, state.turns, tokens, budget);
      writeDecision(event, { ...fields, action: 'deny', reason: 'hard-ceiling' });
      emit.deny(reason);
      return { action: 'deny', reason };
    }
    if (tokens > budget.ctxHard) {
      if (graceEligible && state.graceUsed < CTX_GRACE_CALLS) {
        const graceUsed = incrementGrace(dir);
        writeDecision(event, { ...fields, graceUsed, action: 'allow', reason: 'ctx-grace' });
        return { action: 'allow', reason: 'ctx-grace' };
      }
      const reason = denyReason(type, state.turns, tokens, budget);
      writeDecision(event, { ...fields, action: 'deny', reason: 'hard-ceiling' });
      emit.deny(reason);
      return { action: 'deny', reason };
    }
    writeDecision(event, { ...fields, action: 'allow', reason: 'within-budget' });
    return { action: 'allow', reason: 'within-budget' };
  }

  if (evt === 'PostToolUse') {
    let state = readState(dir);
    const { tokens, source: ctxSource } = contextTokensFromEvent(event);
    const fields = {
      budget_type: type,
      turns: state.turns,
      tokens,
      ctx_source: ctxSource,
      graceUsed: state.graceUsed,
      ...thresholdFields(budget),
    };

    if (tokens > budget.ctxHard && !state.hardNudged) {
      const created = markHardNudged(dir);
      if (created) {
        markNudged(dir); // suppress the soft nudge too — one nudge per agent max
        const graceEligible = fileExists(graceEligibleFile(dir));
        const remaining = graceEligible ? Math.max(0, CTX_GRACE_CALLS - state.graceUsed) : 0;
        debug(`hard-nudge type=${type} turns=${state.turns} tokens=${tokens} remaining=${remaining}`);
        const context = hardNudgeContext(type, budget, remaining);
        writeDecision(event, { ...fields, action: 'nudge', reason: 'hard-threshold' });
        emit.nudge(context);
        return { action: 'nudge', reason: context };
      }
      // Lost the create-if-absent race — another process is already emitting
      // the hard nudge; fall through as if already nudged.
      state = { ...state, hardNudged: true, nudged: true };
    }

    if (state.nudged) {
      writeDecision(event, { ...fields, action: 'allow', reason: 'already-nudged' });
      return { action: 'allow', reason: 'already-nudged' };
    }
    if (state.turns >= budget.turnSoft || tokens >= budget.ctxSoft) {
      markNudged(dir);
      debug(`nudge type=${type} turns=${state.turns} tokens=${tokens}`);
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
  incrementGrace,
  markNudged,
  markHardNudged,
  cleanup,
  contextTokens,
  logPath,
  writeDecision,
  contextTokensFromEvent,
  handle,
  denyReason,
  nudgeContext,
  hardNudgeContext,
  sweepStale,
  rotateLogIfLarge,
  CTX_GRACE_CALLS,
  DECISION_LOG_MAX_BYTES,
};
