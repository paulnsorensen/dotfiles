#!/usr/bin/env node
// PreToolUse doom-loop detector shared by Claude, Codex, and OMP.

const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const OBSERVE_AT = 2;
const BLOCK_AT = 3;
const STOP_AT = 6;
const STATE_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000;
const MAX_STATE_FILES = 256;
const MAX_TOOLS_PER_SESSION = 128;
const EXEMPT_TOOLS = new Set([
  'agent',
  'spawn_agent',
  'task',
  'wait',
  'wait_agent',
  'write_stdin',
]);

function stableStringify(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(',')}]`;

  return `{${Object.keys(value)
    .sort()
    .map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`)
    .join(',')}}`;
}

function normalizedToolName(toolName) {
  return String(toolName).split(/__|\./).pop().toLowerCase();
}

function isExempt(toolName) {
  return EXEMPT_TOOLS.has(normalizedToolName(toolName));
}

function digest(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function stateDirectory() {
  return process.env.DOOM_LOOP_STATE_DIR
    || path.join(process.env.XDG_CACHE_HOME || path.join(os.homedir(), '.cache'), 'dotfiles', 'doom-loop');
}

function harnessName(event) {
  if (event.harness) return String(event.harness);
  return event.turn_id === undefined ? 'claude' : 'codex';
}

function sessionIdentity(event) {
  const identity = event.agent_id || event.transcript_path || event.session_id;
  if (!identity) return null;
  return `${harnessName(event)}:${identity}`;
}

function scopeIdentity(event) {
  const identity = event.scope_id ?? event.prompt_id ?? event.turn_id;
  return identity === undefined || identity === null ? null : String(identity);
}

function invocationIdentity(event) {
  const identity = event.invocation_id ?? event.tool_use_id;
  return identity === undefined || identity === null ? null : String(identity);
}

function readState(statePath) {
  try {
    const state = JSON.parse(fs.readFileSync(statePath, 'utf8'));
    if (!state || typeof state !== 'object' || !state.tools || typeof state.tools !== 'object') {
      return { tools: {} };
    }
    return state;
  } catch (error) {
    if (error.code === 'ENOENT') return { tools: {} };
    throw error;
  }
}

function pruneDirectory(directory, now) {
  const files = fs.readdirSync(directory)
    .filter((name) => name.endsWith('.json'))
    .map((name) => {
      const filePath = path.join(directory, name);
      return { filePath, mtimeMs: fs.statSync(filePath).mtimeMs };
    })
    .sort((a, b) => b.mtimeMs - a.mtimeMs);

  for (const file of files) {
    if (file.mtimeMs < now - STATE_MAX_AGE_MS) fs.rmSync(file.filePath, { force: true });
  }
  for (const file of files.slice(MAX_STATE_FILES)) {
    fs.rmSync(file.filePath, { force: true });
  }
}

function pruneTools(state, now) {
  const entries = Object.entries(state.tools)
    .filter(([, entry]) => entry && entry.updatedAt >= now - STATE_MAX_AGE_MS)
    .sort(([, a], [, b]) => b.updatedAt - a.updatedAt)
    .slice(0, MAX_TOOLS_PER_SESSION);
  state.tools = Object.fromEntries(entries);
}

function acquireLock(lockPath) {
  try {
    fs.mkdirSync(lockPath, { mode: 0o700 });
    return true;
  } catch (error) {
    if (error.code !== 'EEXIST') throw error;
    try {
      if (fs.statSync(lockPath).mtimeMs < Date.now() - 5_000) {
        fs.rmSync(lockPath, { recursive: true, force: true });
        fs.mkdirSync(lockPath, { mode: 0o700 });
        return true;
      }
    } catch {
      return false;
    }
    return false;
  }
}

function actionForCount(count) {
  if (count >= STOP_AT) return 'stop';
  if (count >= BLOCK_AT) return 'block';
  if (count >= OBSERVE_AT) return 'observe';
  return 'allow';
}

function messageFor(action, toolName, count) {
  const next = 'Inspect the last result and change the input or approach; ask the user if blocked.';
  if (action === 'stop') {
    return `Doom-loop stop threshold reached: ${toolName} repeated identical input ${count} times. ${next}`;
  }
  if (action === 'block') {
    return `Blocked ${toolName}: identical input repeated ${count} times. ${next}`;
  }
  return `Doom-loop warning: ${toolName} repeated identical input ${count} times. ${next}`;
}

function evaluate(event) {
  try {
    if (!event || typeof event !== 'object') return { action: 'allow' };

    const toolName = event.tool_name;
    const identity = sessionIdentity(event);
    const scope = scopeIdentity(event);
    if (!toolName || !identity || !scope || isExempt(toolName)) return { action: 'allow' };

    const directory = stateDirectory();
    fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
    fs.chmodSync(directory, 0o700);

    const statePath = path.join(directory, `${digest(identity)}.json`);
    const lockPath = `${statePath}.lock`;
    if (!acquireLock(lockPath)) return { action: 'allow' };

    try {
      const now = Date.now();
      const state = readState(statePath);
      pruneTools(state, now);

      const toolKey = digest(String(toolName));
      const signature = digest(`${toolName}\0${stableStringify(event.tool_input)}`);
      const invocation = invocationIdentity(event);
      const previous = state.tools[toolKey];
      const sameInvocation = invocation
        && previous
        && previous.scope === scope
        && previous.lastInvocation === invocation
        && previous.signature === signature;
      const count = sameInvocation
        ? previous.count
        : previous && previous.scope === scope && previous.signature === signature
          ? previous.count + 1
          : 1;

      state.tools[toolKey] = {
        signature,
        count,
        scope,
        lastInvocation: invocation,
        updatedAt: now,
      };

      const temporaryPath = `${statePath}.${process.pid}.${crypto.randomUUID()}.tmp`;
      fs.writeFileSync(temporaryPath, JSON.stringify(state), { mode: 0o600 });
      fs.renameSync(temporaryPath, statePath);
      pruneDirectory(directory, now);

      const action = actionForCount(count);
      return action === 'allow'
        ? { action }
        : { action, message: messageFor(action, toolName, count) };
    } finally {
      fs.rmSync(lockPath, { recursive: true, force: true });
    }
  } catch {
    return { action: 'allow' };
  }
}

function hookResponse(event, verdict) {
  if (verdict.action === 'allow') return null;

  if (verdict.action === 'stop' && event.harness !== 'codex' && event.turn_id === undefined) {
    return { continue: false, stopReason: verdict.message };
  }

  const hookSpecificOutput = {
    hookEventName: 'PreToolUse',
    permissionDecision: verdict.action === 'observe' ? undefined : 'deny',
    permissionDecisionReason: verdict.action === 'observe' ? undefined : verdict.message,
    additionalContext: verdict.action === 'observe' ? verdict.message : undefined,
  };
  for (const key of Object.keys(hookSpecificOutput)) {
    if (hookSpecificOutput[key] === undefined) delete hookSpecificOutput[key];
  }
  return { hookSpecificOutput };
}

function runCli() {
  let input = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => { input += chunk; });
  process.stdin.on('end', () => {
    try {
      const event = JSON.parse(input);
      const response = hookResponse(event, evaluate(event));
      if (response) process.stdout.write(`${JSON.stringify(response)}\n`);
    } catch {
      // Fail open: malformed hook input must not block a tool call.
    }
  });
  process.stdin.on('error', () => {});
}

module.exports = { evaluate, isExempt, stableStringify };

if (require.main === module) runCli();
