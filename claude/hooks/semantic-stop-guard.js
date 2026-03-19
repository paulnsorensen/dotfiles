#!/usr/bin/env node

const fs = require('fs');

const MIN_MESSAGE_LENGTH = 200;
const FILE_MODIFYING_TOOLS = new Set(['Edit', 'Write', 'NotebookEdit']);

const CI_CHECK_PATTERNS = [
  /\bgh\s+(run|pr\s+checks|api\s+repos\/)/,
  /mcp__plugin_github_github__/,
];

const DISMISSAL_PATTERNS = [
  /\bpre-?existing\b/i,
  /\balready\s+(fail|broken|flak)/i,
  /\bnot\s+(related|caused)\s+(to|by)\b/i,
  /\bunrelated\s+to\b/i,
  /\bflaky\b/i,
  /\bintermittent\b/i,
  /\bknown\s+(issue|flake|failure)\b/i,
  /\bnothing\s+to\s+do\s+with\b/i,
  /\bnot\s+our\s+(fault|problem|change)\b/i,
  /\binfra\s+(issue|flake|problem)\b/i,
  /\brunner\s+(issue|flake|problem)\b/i,
];

const SELF_EVAL_PROMPT = `You modified files this turn. Invoke /self-eval using the Skill tool before stopping. Do not mentally check — actually call the skill.`;

const DISMISSAL_PROMPT = `You checked CI status and dismissed a failure as pre-existing or unrelated. Before stopping:
1. Did you verify this failure exists on the base branch? (git log, gh run list on main, or checking the PR's base)
2. Can you cite specific evidence (run ID, commit SHA, or log line) that this failure predates your changes?
If you cannot cite evidence, investigate the failure properly — don't dismiss it.`;

function scanCurrentTurn(transcriptPath) {
  let lines;
  try {
    lines = fs.readFileSync(transcriptPath, 'utf8').trim().split('\n');
  } catch {
    return { modifiedFiles: false, checkedCI: false };
  }

  let modifiedFiles = false;
  let checkedCI = false;

  for (let i = lines.length - 1; i >= 0; i--) {
    let entry;
    try { entry = JSON.parse(lines[i]); } catch { continue; }

    if (entry.type === 'user') break;

    if (entry.type === 'assistant') {
      const content = entry.message?.content;
      if (!Array.isArray(content)) continue;
      for (const block of content) {
        if (block.type !== 'tool_use') continue;

        if (FILE_MODIFYING_TOOLS.has(block.name)) {
          modifiedFiles = true;
        }

        if (block.name === 'Bash') {
          const cmd = block.input?.command || '';
          if (CI_CHECK_PATTERNS.some(p => p.test(cmd))) {
            checkedCI = true;
          }
        }

        if (CI_CHECK_PATTERNS.some(p => p.test(block.name))) {
          checkedCI = true;
        }
      }
    }
  }

  return { modifiedFiles, checkedCI };
}

function hasDismissalLanguage(message) {
  return DISMISSAL_PATTERNS.some(p => p.test(message));
}

let input = '';
process.stdin.on('data', (chunk) => { input += chunk; });
process.stdin.on('end', () => {
  try {
    const payload = JSON.parse(input);

    if (payload.stop_hook_active) {
      console.log('{}');
      process.exit(0);
    }

    const message = payload.last_assistant_message || '';

    if (message.length < MIN_MESSAGE_LENGTH) {
      console.log('{}');
      process.exit(0);
    }

    const { modifiedFiles, checkedCI } = scanCurrentTurn(payload.transcript_path);

    // Check for CI dismissal without evidence (higher priority)
    if (checkedCI && hasDismissalLanguage(message)) {
      console.log(JSON.stringify({
        decision: 'block',
        reason: 'CI failure dismissed without base-branch verification.',
        systemMessage: DISMISSAL_PROMPT
      }));
      process.exit(0);
    }

    // Standard self-eval for file modifications
    if (modifiedFiles) {
      console.log(JSON.stringify({
        decision: 'block',
        reason: 'Self-evaluation required before stopping.',
        systemMessage: SELF_EVAL_PROMPT
      }));
      process.exit(0);
    }

    console.log('{}');
  } catch {
    console.log('{}');
  }
  process.exit(0);
});
