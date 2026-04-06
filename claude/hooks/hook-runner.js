#!/usr/bin/env node
// Bridge between Claude Code's stdin/stdout hook protocol and
// module.exports { hooks: [{ matcher, handler }] } format.
//
// Usage in settings.json:
//   "command": "node hook-runner.js bash-guard.js"
//
// Protocol: stdin = JSON { tool_name, tool_input, ... }
//           stdout = JSON { hookSpecificOutput: { permissionDecision, ... } }
//           exit 0 with no stdout = allow

const path = require('path');

const hookFile = process.argv[2];
if (!hookFile) {
  console.error('hook-runner: missing hook file argument');
  process.exit(1);
}

let mod;
try {
  mod = require(path.resolve(__dirname, hookFile));
} catch (err) {
  console.error(`hook-runner: failed to load ${hookFile}: ${err.message}`);
  process.exit(0); // fail-open: broken hook should not block all tool calls
}

function block(reason) {
  console.log(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'block',
      permissionDecisionReason: reason,
    },
  }));
}

async function runHook(hook, toolName, toolInput) {
  if (!hook.matcher(toolName, toolInput)) return false;
  const result = await hook.handler(toolName, toolInput);
  if (result && result.result) {
    block(result.result);
    return true;
  }
  return false;
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

  const toolName = event.tool_name || '';
  const toolInput = event.tool_input || {};

  for (const hook of mod.hooks || []) {
    if (await runHook(hook, toolName, toolInput)) break;
  }
});
