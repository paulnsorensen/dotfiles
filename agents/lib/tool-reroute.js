#!/usr/bin/env node
// tool-reroute.js — PreToolUse rewrite hook (harness-agnostic).
//
// Routes file reads, writes, and searches to the tilth MCP tools. It denies
// the built-in file tools (Read on text, Write/Edit/MultiEdit, Codex
// apply_patch, Grep/Glob) and shell commands that read, search, or write files
// in the tree. Each deny names the tilth call to make instead. On Codex it
// also denies tilth_write outside the checkout. The hook rewrites worktree
// command shapes to wt-git. Every other command runs unchanged.
// Kill switch: DOTFILES_TOOL_REROUTE=0|false|off|no disables the hook.
//
// Five detection modules run in order; the FIRST hit wins:
//   native   → Read (text) / Write / Edit / MultiEdit / apply_patch /
//              Grep / Glob / Codex tilth_write
//   search   → grep/egrep/fgrep/rg/ag/ack on files
//   cd-strip → `cd <cwd> && …` — strip a no-op cd to the event's own cwd,
//              then re-classify the remainder against search/cd-git/io
//   cd-git   → `cd <path> && git …` (including a git-only chain)
//   io       → write-redirect / file read by cat, head, sed, … (deny)
// Each module's detect() returns {rewrite} (allow + updatedInput), {reason}
// (deny + message), or null. A null from every module leaves the command
// untouched — it runs exactly as the model wrote it.
//
// Fail-open everywhere: malformed stdin or a thrown detection error resolve
// to exit 0 with no decision — the call runs unchanged. A routing hook must
// never become a denial-of-service.

const os = require('os');
const path = require('path');
const { appendJsonl, scrubSecrets } = require('./jsonl-log');
const native = require('./tool-reroute/native');
const search = require('./tool-reroute/search');
const cdStrip = require('./tool-reroute/cd-strip');
const cdGit = require('./tool-reroute/cd-git');
const io = require('./tool-reroute/io');

const MODULES = [native, search, cdStrip, cdGit, io];
// Modules re-run against the cd-strip remainder — the Bash modules except
// cd-strip itself, so a stripped command can still hit search/cd-git/io.
const AFTER_STRIP = [search, cdGit, io];

// Pure over (toolName, input, cwd, harness): the first module hit, or null.
// The stdin adapter calls this unit-testable core. The dispatcher re-classifies
// a cd-strip hit against the remaining modules on the stripped command. A hit
// there wins. Otherwise the strip stands alone, tagged action: 'strip', so
// main() emits its own updatedInput for the stripped command.
function classify(toolName, input, cwd, harness = 'claude') {
  for (const m of MODULES) {
    const hit = m.detect(toolName, input, cwd, harness);
    if (!hit) continue;
    if (m !== cdStrip) return hit;
    const rehit = classifyWith(AFTER_STRIP, toolName, { ...input, command: hit.rewrite }, cwd, harness);
    return rehit || { ...hit, action: 'strip' };
  }
  return null;
}

function classifyWith(modules, toolName, input, cwd, harness) {
  for (const m of modules) {
    const hit = m.detect(toolName, input, cwd, harness);
    if (hit) return hit;
  }
  return null;
}

const MAX_LOG_BYTES = 5 * 1024 * 1024;
const MAX_TEXT_LENGTH = 2000;
const KILL_HINT = '\n(tilth down? export DOTFILES_TOOL_REROUTE=0)';

// Slice before scrubbing so the regex work stays bounded on huge input.
function safeText(value) {
  return scrubSecrets(String(value).slice(0, MAX_TEXT_LENGTH)).slice(0, MAX_TEXT_LENGTH);
}

function denyText(reason) {
  const text = safeText(reason);
  return text.length + KILL_HINT.length <= MAX_TEXT_LENGTH ? text + KILL_HINT : text;
}

function killSwitchOn() {
  return /^(0|false|off|no)$/i.test((process.env.DOTFILES_TOOL_REROUTE || '').trim());
}

function logDir() {
  return process.env.CLAUDE_TOOL_REROUTE_LOG_DIR
    || (process.env.XDG_STATE_HOME && path.join(process.env.XDG_STATE_HOME, 'claude-tool-reroute'))
    || path.join(os.homedir(), '.local', 'state', 'claude-tool-reroute');
}

// Log a rewrite/deny/strip decision to decisions.jsonl. The caller skips this
// when no module matches, because that path has no module or action to record.
function logDecision(harness, event, toolName, cwd, hit, action) {
  const input = event.tool_input || {};
  // The log keeps only a shell command verbatim, never an apply_patch body.
  const command = toolName === 'Bash' ? (input.command || '') : '';
  appendJsonl(logDir(), 'decisions.jsonl', {
    ts: new Date().toISOString(),
    harness,
    session_id: event.session_id || null,
    cwd,
    tool_name: toolName,
    module: hit.module || null,
    action,
    command,
    ...(typeof input.file_path === 'string' ? { file_path: input.file_path } : {}),
    ...(hit.pattern !== undefined ? { pattern: hit.pattern } : {}),
    ...(action === 'rewrite' || action === 'strip'
      ? { rewrite: hit.rewrite }
      : { reason: hit.reason }),
  }, MAX_LOG_BYTES);
}

function main() {
  if (killSwitchOn()) return;
  const harness = process.argv[2] || 'claude';
  let stdin = '';
  process.stdin.on('data', (chunk) => { stdin += chunk; });
  process.stdin.on('end', () => {
    let event;
    try {
      event = JSON.parse(stdin);
    } catch {
      return; // fail-open on malformed input
    }
    if (!event || typeof event !== 'object') return;
    const toolName = event.tool_name || '';
    const input = event.tool_input || {};
    const cwd = event.cwd || process.cwd();

    let hit;
    try {
      hit = classify(toolName, input, cwd, harness);
    } catch {
      return; // fail-open on a detection bug
    }

    if (hit && hit.action === 'strip') {
      // A no-op cd-strip with no rehit. On Claude, updatedInput without
      // permissionDecision runs normal permission evaluation on the rewritten
      // input (no auto-allow). Codex reports that shape as a failed hook, so
      // Codex gets no output and runs the command unchanged.
      if (harness !== 'codex') {
        process.stdout.write(JSON.stringify({
          hookSpecificOutput: {
            hookEventName: 'PreToolUse',
            updatedInput: { ...input, command: hit.rewrite },
          },
        }));
      }
      logDecision(harness, event, toolName, cwd, hit, 'strip');
      return;
    }
    if (hit && hit.rewrite !== undefined) {
      const orig = input.command || '';
      process.stdout.write(JSON.stringify({
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          permissionDecision: 'allow',
          permissionDecisionReason: safeText('tool-reroute: ' + orig + ' → ' + hit.rewrite),
          updatedInput: { ...input, command: hit.rewrite },
        },
      }));
      logDecision(harness, event, toolName, cwd, hit, 'rewrite');
      return;
    }
    if (hit && hit.reason !== undefined) {
      process.stdout.write(JSON.stringify({
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          permissionDecision: 'deny',
          permissionDecisionReason: denyText(hit.reason),
        },
      }));
      logDecision(harness, event, toolName, cwd, hit, 'deny');
      return;
    }
    // No module owns it — allow, untouched.
  });
}

if (require.main === module) main();

// Exported for unit tests; harmless when run as a hook.
module.exports = { classify };
