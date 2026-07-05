#!/usr/bin/env node
// tool-reroute.js — PreToolUse rewrite hook (harness-agnostic).
//
// Transparently REWRITES wrong-tool Bash/Grep/Glob calls to their tilth /
// wt-git shell equivalent, DENIES the two cross-tool cases that have no shell
// rewrite target (the Grep/Glob tools, shell write-redirects), and DELEGATES
// every other Bash command to the harness's rtk hook for token compaction.
//
// Three detection modules run in order; the FIRST hit wins:
//   search → grep/rg/ag/ack/find + the Grep/Glob tools
//   cd-git → `cd <path> && git …`
//   io     → write-redirect (deny) / bare `cat` (rewrite)
// Each module's detect() returns {rewrite} (allow + updatedInput), {reason}
// (deny + message), or null. A null from every module on a Bash call means
// "not ours" → delegate to `rtk hook <harness>` (argv[2]), piping the original
// event through and echoing rtk's output verbatim, so non-reroute commands keep
// rtk's compaction.
//
// Fail-open everywhere: malformed stdin, a thrown detection error, or an absent
// rtk all resolve to exit 0 with no rewrite — the command runs unchanged. A
// rewrite hook must never become a denial-of-service.

const { spawnSync } = require('child_process');
const search = require('./tool-reroute/search');
const cdGit = require('./tool-reroute/cd-git');
const io = require('./tool-reroute/io');

const MODULES = [search, cdGit, io];

// Pure over (toolName, input, cwd): the first module hit, or null. The unit-
// testable core the stdin adapter calls.
function classify(toolName, input, cwd) {
  for (const m of MODULES) {
    const hit = m.detect(toolName, input, cwd);
    if (hit) return hit;
  }
  return null;
}

// Hand the original event to the harness's rtk hook and echo its stdout. rtk
// absent (ENOENT) or killed → fail open (no output, command runs unchanged).
function delegate(harness, stdin) {
  const res = spawnSync('rtk', ['hook', harness], { input: stdin, encoding: 'utf8' });
  if (res.error || res.status === null) return; // fail open
  if (res.stdout) process.stdout.write(res.stdout);
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

    if (hit && hit.rewrite !== undefined) {
      const orig = input.command || '';
      process.stdout.write(JSON.stringify({
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          permissionDecision: 'allow',
          permissionDecisionReason: `tool-reroute: ${orig} → ${hit.rewrite}`,
          updatedInput: { command: hit.rewrite },
        },
      }));
      return;
    }
    if (hit && hit.reason !== undefined) {
      process.stdout.write(JSON.stringify({
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          permissionDecision: 'deny',
          permissionDecisionReason: hit.reason,
        },
      }));
      return;
    }
    // No module owns it. Delegate Bash to rtk; allow any other tool untouched.
    if (toolName === 'Bash') delegate(harness, stdin);
  });
}

if (require.main === module) main();

// Exported for unit tests; harmless when run as a hook.
module.exports = { classify };
