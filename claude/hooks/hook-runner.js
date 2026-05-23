#!/usr/bin/env node
// Bridge between Claude Code's stdin/stdout hook protocol and
// module.exports { hooks: [{ matcher, handler }] } format.
//
// Usage in settings.json (one or more hook files, run in order):
//   "command": "node hook-runner.js write-guard.js worktree-guard.js"
//
// Protocol: stdin = JSON { tool_name, tool_input, ... }
//           stdout = JSON { hookSpecificOutput: { permissionDecision, ... } }
//           exit 0 with no stdout = allow

const path = require('path');

const hookFiles = process.argv.slice(2);
if (hookFiles.length === 0) {
  console.error('hook-runner: missing hook file argument');
  process.exit(1);
}

// Load every requested hook module, fail-open per file: a broken hook should
// not block all tool calls, nor stop sibling hooks from loading.
const hooks = [];
for (const hookFile of hookFiles) {
  try {
    const mod = require(path.resolve(__dirname, hookFile));
    if (mod && Array.isArray(mod.hooks)) hooks.push(...mod.hooks);
  } catch (err) {
    console.error(`hook-runner: failed to load ${hookFile}: ${err.message}`);
  }
}

function block(reason) {
  console.log(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: reason,
    },
  }));
}

function writeOutput(result, eventName) {
  if (!result) return false;
  if (result.hookSpecificOutput || Object.prototype.hasOwnProperty.call(result, 'decision')) {
    console.log(JSON.stringify(result));
    return true;
  }
  if (result && result.result) {
    if (eventName === 'PreToolUse') {
      block(result.result);
    } else {
      console.log(JSON.stringify({ decision: 'block', reason: result.result }));
    }
    return true;
  }
  return false;
}

async function runHook(hook, event) {
  const toolName = event.tool_name || '';
  const toolInput = event.tool_input || {};
  if (!hook.matcher(toolName, toolInput, event)) return false;
  const result = await hook.handler(toolName, toolInput, event);
  return writeOutput(result, event.hook_event_name || 'PreToolUse');
}

let stdin = '';
process.stdin.on('data', (chunk) => { stdin += chunk; });
process.stdin.on('end', async () => {
  let event;
  try {
    event = JSON.parse(stdin);
  } catch {
    console.error('hook-runner: invalid JSON on stdin');
    process.exit(0); // fail-open on malformed input
  }

  for (const hook of hooks) {
    if (await runHook(hook, event)) break;
  }
});
