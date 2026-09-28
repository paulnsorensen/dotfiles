#!/usr/bin/env node
// PreToolUse dispatch guard for Claude Agent/Task and Codex spawn_agent calls.

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const CLAUDE_MODELS = new Set(['haiku', 'sonnet', 'opus']);
const CODEX_MODELS = new Set(['gpt-5.6-luna', 'gpt-5.6-sol', 'gpt-6-astra']);
const EFFORT_RANK = { low: 0, medium: 1, high: 2 };
const ROLE_RE = /^[A-Za-z0-9][A-Za-z0-9_-]*$/;

function outputDecision(reason) {
  return JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: `Agent routing guard: ${reason}`,
    },
  });
}

function deny(reason) {
  process.stdout.write(outputDecision(reason));
}

function isTargetTool(toolName) {
  return toolName === 'Agent' || toolName === 'Task' || toolName === 'spawn_agent';
}

function harnessFor(toolName) {
  const configured = (process.env.DOTFILES_HARNESS || '').trim().toLowerCase();
  if (configured === 'claude' || configured === 'codex') return configured;
  return toolName === 'spawn_agent' ? 'codex' : 'claude';
}

function roleFor(harness, input) {
  const key = harness === 'claude' ? 'subagent_type' : 'agent_type';
  if (!Object.prototype.hasOwnProperty.call(input, key)) return null;
  if (typeof input[key] !== 'string' || input[key].length === 0) return null;
  return input[key];
}

function requestedValue(input, ...keys) {
  const present = keys.filter((key) => Object.prototype.hasOwnProperty.call(input, key));
  if (present.some((key) => input[key] !== input[present[0]])) return { invalid: true };
  return present.length ? { present: true, value: input[present[0]] } : { present: false, value: undefined };
}

function validateModel(model, harness) {
  if (typeof model !== 'string') return false;
  if (/fable|terra/i.test(model)) return false;
  return (harness === 'claude' ? CLAUDE_MODELS : CODEX_MODELS).has(model);
}

function validateEffort(effort) {
  return typeof effort === 'string' && Object.prototype.hasOwnProperty.call(EFFORT_RANK, effort);
}

function rolePath(harness, role) {
  if (!ROLE_RE.test(role)) return null;
  const home = process.env.HOME || '';
  const root = harness === 'claude'
    ? path.join(home, '.claude', 'agents')
    : path.join(process.env.CODEX_HOME || path.join(home, '.codex'), 'agents');
  return path.join(root, harness === 'claude' ? `${role}.md` : `${role}.toml`);
}

function readRoleDefinition(harness, role) {
  const file = rolePath(harness, role);
  if (!file || !fs.existsSync(file)) {
    throw new Error(`missing deployed definition for named role '${role}'`);
  }
  const parserArgs = harness === 'claude'
    ? ['--front-matter=extract', '-r']
    : ['-p=toml', '-r'];
  const read = (field) => {
    try {
      return execFileSync('yq', [...parserArgs, `.${field} // \"\"`, file], {
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'pipe'],
      }).trim();
    } catch {
      throw new Error(`cannot parse deployed definition for named role '${role}'`);
    }
  };
  const effortField = harness === 'claude' ? 'effort' : 'model_reasoning_effort';
  return { model: read('model'), effort: read(effortField) };
}

function checkForkTurns(input) {
  const fork = input.fork_turns;
  if (typeof fork !== 'string' || (fork !== 'none' && !/^[1-9][0-9]*$/.test(fork))) {
    return 'Codex dispatches must set fork_turns to none or a positive integer string; do not inherit all or omit it';
  }
  return null;
}

function checkDispatch(event) {
  const toolName = event.tool_name;
  if (!isTargetTool(toolName)) return null;

  const harness = harnessFor(toolName);
  const input = event.tool_input;
  if (!input || typeof input !== 'object' || Array.isArray(input)) {
    return 'the dispatch tool_input must name an installed role';
  }

  const role = roleFor(harness, input);
  if (!role) {
    return `${harness} dispatches must select a named role (coder, explorer, reviewer, taste-tester, or generalist); do not inherit a default`;
  }

  if (harness === 'codex') {
    const forkError = checkForkTurns(input);
    if (forkError) return forkError;
  }

  const modelValue = requestedValue(input, 'model', 'agent_model');
  const effortValue = requestedValue(input, 'effort', 'reasoning_effort', 'model_reasoning_effort');
  if (modelValue.invalid || effortValue.invalid) return 'model and effort fields must not conflict';
  const explicitModel = modelValue.present;
  const explicitEffort = effortValue.present;
  if (explicitModel && !validateModel(modelValue.value, harness)) {
    return `unsupported model '${String(modelValue.value)}'; use the installed ${harness} model family`;
  }
  if (explicitEffort && !validateEffort(effortValue.value)) {
    return `unsupported effort '${String(effortValue.value)}'; use low, medium, or high`;
  }

  const lowerRole = role.toLowerCase();
  if (harness === 'claude' && (lowerRole === 'general-purpose' || lowerRole === 'claude')) {
    return 'generic Claude roles are denied; select a named coder, explorer, reviewer, taste-tester, or generalist';
  }
  if (harness === 'claude' && role === 'Plan') {
    if (!explicitModel || modelValue.value !== 'opus') {
      return 'the built-in Plan role requires an explicit model of opus';
    }
    return null;
  }

  const codexFallback = harness === 'codex' && (lowerRole === 'default' || lowerRole === 'worker');
  if (codexFallback && (!explicitModel || !explicitEffort)) {
    return 'Codex default/worker is only an unavailable-specialist fallback; provide explicit model and effort';
  }
  if (codexFallback && input.fork_turns !== 'none') {
    return 'Codex default/worker fallback must set fork_turns to none';
  }
  if (!codexFallback && !ROLE_RE.test(role)) {
    return 'role name must be a safe installed basename';
  }

  let definition;
  if (codexFallback) {
    definition = { model: modelValue.value, effort: effortValue.value };
  } else {
    try {
      definition = readRoleDefinition(harness, role);
    } catch (error) {
      return `${error.message}; repair the deployed role before dispatching it`;
    }
  }

  if (!validateModel(definition.model, harness)) {
    return `unsupported model in deployed definition for '${role}'; repair it to the installed ${harness} model family`;
  }
  if (!validateEffort(definition.effort)) {
    return `unsupported effort in deployed definition for '${role}'; repair it to low, medium, or high`;
  }
  if (explicitModel && modelValue.value !== definition.model) {
    if (harness === 'codex') {
      return `model '${modelValue.value}' differs from Codex role '${role}' model '${definition.model}'; use the configured role or an explicit default/worker fallback`;
    }
    if (process.env.DOTFILES_AGENT_MODEL_OVERRIDE !== modelValue.value) {
      return `model '${modelValue.value}' differs from role '${role}' model '${definition.model}'; set DOTFILES_AGENT_MODEL_OVERRIDE to approve an operator escalation`;
    }
  }
  if (explicitEffort && EFFORT_RANK[effortValue.value] > EFFORT_RANK[definition.effort]) {
    return `effort '${effortValue.value}' exceeds role '${role}' effort '${definition.effort}'; lower the effort`;
  }
  return null;
}

function main() {
  let input = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => { input += chunk; });
  process.stdin.on('end', () => {
    let event;
    try {
      event = JSON.parse(input);
      if (!event || typeof event !== 'object' || Array.isArray(event)) throw new Error('not an object');
    } catch {
      process.stderr.write('agent-routing-guard: input must be valid JSON object\n');
      process.exitCode = 2;
      return;
    }
    const reason = checkDispatch(event);
    if (reason) deny(reason);
  });
}

if (require.main === module) main();
