#!/usr/bin/env node
// permission-log.js — PermissionRequest / PermissionDenied observability hook.
//
// Appends one JSONL record per event to events.jsonl — never blocks, never
// prints, never denies. Purely a decision-trail so a permission prompt or a
// deny can be traced after the fact (which tool, which command, why).
//
// Fail-open everywhere: malformed stdin, a missing field, or a logging error
// all resolve to exit 0 with empty stdout — observability must never affect
// enforcement.

const os = require('os');
const path = require('path');
const { appendJsonl } = require('./jsonl-log');

const MAX_LOG_BYTES = 5 * 1024 * 1024;
const LOGGED_EVENTS = new Set(['PermissionRequest', 'PermissionDenied']);

function logDir() {
  return process.env.CLAUDE_PERMISSION_LOG_DIR
    || (process.env.XDG_STATE_HOME && path.join(process.env.XDG_STATE_HOME, 'claude-permission-log'))
    || path.join(os.homedir(), '.local', 'state', 'claude-permission-log');
}

function main() {
  let stdin = '';
  process.stdin.on('data', (chunk) => { stdin += chunk; });
  process.stdin.on('end', () => {
    let event;
    try {
      event = JSON.parse(stdin);
    } catch {
      return; // fail-open on malformed input
    }
    if (!LOGGED_EVENTS.has(event.hook_event_name)) return;
    const input = event.tool_input || {};
    const command = typeof input.command === 'string' ? input.command.slice(0, 500) : null;
    appendJsonl(logDir(), 'events.jsonl', {
      ts: new Date().toISOString(),
      event: event.hook_event_name || 'unknown',
      session_id: event.session_id || null,
      cwd: event.cwd || null,
      permission_mode: event.permission_mode || null,
      tool_name: event.tool_name || null,
      command,
      input_keys: Object.keys(input),
      reason: event.reason || null,
      suggestions: event.permission_suggestions || null,
    }, MAX_LOG_BYTES);
  });
}

if (require.main === module) main();
