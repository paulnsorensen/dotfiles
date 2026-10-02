#!/usr/bin/env node
// tool-reroute.js — PreToolUse rewrite hook (harness-agnostic).
//
// Routes file reads, writes, and searches to the tilth MCP tools. It DENIES
// the built-in file tools (Read on text, Write/Edit/MultiEdit, Codex
// apply_patch, Grep/Glob) and shell commands that read, search, or write files
// in the tree, naming the tilth call to make instead. It REWRITES worktree
// command shapes to wt-git. Every other command runs unchanged.
//
// Five detection modules run in order; the FIRST hit wins:
//   native   → Read (text) / Write / Edit / MultiEdit / apply_patch
//   search   → grep/egrep/fgrep/rg/ag/ack on files + the Grep/Glob tools
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

// Pure over (toolName, input, cwd): the first module hit, or null. The unit-
// testable core the stdin adapter calls. A cd-strip hit is re-classified
// against the remaining modules on the stripped command; a hit there wins
// (its own module/rewrite/reason), otherwise the strip stands alone, tagged
// action: 'strip' so main() emits its own updatedInput for the stripped
// command instead of an unconditional allow.
function classify(toolName, input, cwd) {
  for (const m of MODULES) {
    const hit = m.detect(toolName, input, cwd);
    if (!hit) continue;
    if (m !== cdStrip) return hit;
    const rehit = classifyWith(AFTER_STRIP, toolName, { ...input, command: hit.rewrite }, cwd);
    return rehit || { ...hit, action: 'strip' };
  }
  return null;
}

function classifyWith(modules, toolName, input, cwd) {
  for (const m of modules) {
    const hit = m.detect(toolName, input, cwd);
    if (hit) return hit;
  }
  return null;
}

const MAX_LOG_BYTES = 5 * 1024 * 1024;
const MAX_TEXT_LENGTH = 500;

function safeText(value) {
  return scrubSecrets(String(value)).slice(0, MAX_TEXT_LENGTH);
}

function logDir() {
  return process.env.CLAUDE_TOOL_REROUTE_LOG_DIR
    || (process.env.XDG_STATE_HOME && path.join(process.env.XDG_STATE_HOME, 'claude-tool-reroute'))
    || path.join(os.homedir(), '.local', 'state', 'claude-tool-reroute');
}

// Log a rewrite/deny/strip decision to decisions.jsonl. Never called when no
// module matches — that path carries no module/action to record.
function logDecision(harness, event, toolName, cwd, hit, action) {
  const input = event.tool_input || {};
  // Only a shell command is logged verbatim; an apply_patch body is not.
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
    const toolName = event.tool_name || '';
    const input = event.tool_input || {};
    const cwd = event.cwd || process.cwd();

    let hit;
    try {
      hit = classify(toolName, input, cwd);
    } catch {
      return; // fail-open on a detection bug
    }

    if (hit && hit.action === 'strip') {
      // A no-op cd-strip with no rehit: emit updatedInput for the stripped
      // command. Per Claude Code's PreToolUse contract, updatedInput WITHOUT
      // permissionDecision runs normal permission evaluation on the rewritten
      // input — the desired behaviour for a strip-only hit (no auto-allow).
      logDecision(harness, event, toolName, cwd, hit, 'strip');
      process.stdout.write(JSON.stringify({
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          updatedInput: { ...input, command: hit.rewrite },
        },
      }));
      return;
    }
    if (hit && hit.rewrite !== undefined) {
      const orig = input.command || '';
      logDecision(harness, event, toolName, cwd, hit, 'rewrite');
      process.stdout.write(JSON.stringify({
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          permissionDecision: 'allow',
          permissionDecisionReason: safeText('tool-reroute: ' + orig + ' → ' + hit.rewrite),
          updatedInput: { ...input, command: hit.rewrite },
        },
      }));
      return;
    }
    if (hit && hit.reason !== undefined) {
      logDecision(harness, event, toolName, cwd, hit, 'deny');
      process.stdout.write(JSON.stringify({
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          permissionDecision: 'deny',
          permissionDecisionReason: safeText(hit.reason),
        },
      }));
      return;
    }
    // No module owns it — allow, untouched.
  });
}

if (require.main === module) main();

// Exported for unit tests; harmless when run as a hook.
module.exports = { classify };
