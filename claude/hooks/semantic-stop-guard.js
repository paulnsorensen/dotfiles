#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

const MIN_MESSAGE_LENGTH = 200;
const FILE_MODIFYING_TOOLS = new Set(['Edit', 'Write', 'NotebookEdit']);

function isSubstantiveUserMessage(entry) {
  if (entry.type !== 'user') return false;
  if (typeof entry.message === 'string') return entry.message.trim().length > 0;
  const content = entry.message?.content;
  if (typeof content === 'string') return content.trim().length > 0;
  if (Array.isArray(content)) {
    return content.some(b =>
      typeof b === 'string' ? b.trim().length > 0
        : b?.type === 'text' && typeof b.text === 'string' && b.text.trim().length > 0
    );
  }
  if (entry.message != null) {
    process.stderr.write(`[semantic-stop-guard] Warning: unexpected user message shape: ${JSON.stringify(entry.message).slice(0, 200)}\n`);
  }
  return false;
}

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

const UNRESOLVED_PROMPT = `Unresolved violations detected in this turn's output. Fix every violation before stopping. If a pipeline agent scored a finding >= 70, act on it now — do not defer to a follow-up.`;

const DISMISSAL_PROMPT = `You checked CI status and dismissed a failure as pre-existing or unrelated. Before stopping:
1. Did you verify this failure exists on the base branch? (git log, gh run list on main, or checking the PR's base)
2. Can you cite specific evidence (run ID, commit SHA, or log line) that this failure predates your changes?
If you cannot cite evidence, investigate the failure properly — don't dismiss it.`;

function loadClassifier() {
  try {
    const winkNLP = require('wink-nlp');
    const model = require('wink-eng-lite-web-model');
    const nbc = require('wink-naive-bayes-text-classifier');

    const nlp = winkNLP(model);
    const its = nlp.its;

    const classifier = nbc();
    classifier.definePrepTasks([
      (text) => {
        const doc = nlp.readDoc(text);
        return doc.tokens().filter(t => t.out(its.type) === 'word').out(its.normal);
      }
    ]);
    classifier.defineConfig({ considerOnlyPresence: true, smoothingFactor: 1 });

    const dataPath = path.join(__dirname, 'violation-training.json');
    const data = JSON.parse(fs.readFileSync(dataPath, 'utf8'));
    data.violation.forEach(v => classifier.learn(v, 'violation'));
    data.clean.forEach(c => classifier.learn(c, 'clean'));
    classifier.consolidate();

    return classifier;
  } catch (err) {
    process.stderr.write(`[semantic-stop-guard] Warning: failed to load violation classifier; running in pass-through mode. Error: ${err && err.message ? err.message : String(err)}\n`);
    return null;
  }
}

function parseTurnLines(transcriptPath) {
  try {
    return fs.readFileSync(transcriptPath, 'utf8').trim().split('\n');
  } catch {
    return [];
  }
}

function scanCurrentTurn(lines) {
  let modifiedFiles = false;
  let checkedCI = false;

  for (let i = lines.length - 1; i >= 0; i--) {
    let entry;
    try { entry = JSON.parse(lines[i]); } catch { continue; }

    if (isSubstantiveUserMessage(entry)) break;

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

function extractTurnText(lines) {
  const chunks = [];

  for (let i = lines.length - 1; i >= 0; i--) {
    let entry;
    try { entry = JSON.parse(lines[i]); } catch { continue; }

    if (isSubstantiveUserMessage(entry)) break;

    if (entry.type === 'assistant') {
      const content = entry.message?.content;
      if (!Array.isArray(content)) continue;
      for (const block of content) {
        if (block.type === 'text' && typeof block.text === 'string') {
          chunks.push(block.text);
        }
        if (block.type === 'tool_result' && typeof block.content === 'string') {
          chunks.push(block.content);
        }
      }
    }
  }

  return chunks;
}

function hasUnresolvedFindings(lines, classifier) {
  if (!classifier) return false;

  const chunks = extractTurnText(lines);
  if (chunks.length === 0) return false;

  for (const chunk of chunks) {
    const sentences = chunk.split(/\n+/).filter(s => s.trim().length > 10);
    for (const sentence of sentences) {
      if (classifier.predict(sentence) === 'violation') {
        return true;
      }
    }
  }

  return false;
}

function hasFixesAfterFindings(lines, classifier) {
  if (!classifier) return false;

  let start = 0;
  for (let i = lines.length - 1; i >= 0; i--) {
    let entry;
    try { entry = JSON.parse(lines[i]); } catch { continue; }
    if (isSubstantiveUserMessage(entry)) { start = i + 1; break; }
  }

  let foundViolation = false;

  for (let i = start; i < lines.length; i++) {
    let entry;
    try { entry = JSON.parse(lines[i]); } catch { continue; }

    if (isSubstantiveUserMessage(entry)) {
      foundViolation = false;
      continue;
    }

    if (entry.type !== 'assistant') continue;

    const content = entry.message?.content;
    if (!Array.isArray(content)) continue;

    for (const block of content) {
      if (!foundViolation) {
        const text = block.type === 'text' ? block.text
          : block.type === 'tool_result' ? block.content : null;
        if (typeof text === 'string') {
          const sentences = text.split(/\n+/).filter(s => s.trim().length > 10);
          for (const sentence of sentences) {
            if (classifier.predict(sentence) === 'violation') {
              foundViolation = true;
              break;
            }
          }
        }
      } else if (block.type === 'tool_use' && FILE_MODIFYING_TOOLS.has(block.name)) {
        return true;
      }
    }
  }

  return false;
}

function hasDismissalLanguage(message) {
  return DISMISSAL_PATTERNS.some(p => p.test(message));
}

let input = '';
process.stdin.on('data', (chunk) => { input += chunk; });
process.stdin.on('end', () => {
  try {
    const payload = JSON.parse(input);
    const lines = parseTurnLines(payload.transcript_path);

    if (payload.stop_hook_active) {
      const { modifiedFiles: editedFiles } = scanCurrentTurn(lines);
      if (!editedFiles) {
        console.log('{}');
        process.exit(0);
      }

      if (extractTurnText(lines).length === 0) {
        console.log('{}');
        process.exit(0);
      }

      const classifier = loadClassifier();
      const hasViolations = hasUnresolvedFindings(lines, classifier);
      const hasFixed = hasViolations && hasFixesAfterFindings(lines, classifier);

      if (hasViolations && !hasFixed) {
        console.log(JSON.stringify({
          decision: 'block',
          reason: 'Unresolved violations detected.',
          systemMessage: UNRESOLVED_PROMPT
        }));
      } else {
        console.log('{}');
      }
      process.exit(0);
    }

    const message = payload.last_assistant_message || '';

    if (message.length < MIN_MESSAGE_LENGTH) {
      console.log('{}');
      process.exit(0);
    }

    const { modifiedFiles, checkedCI } = scanCurrentTurn(lines);

    if (checkedCI && hasDismissalLanguage(message)) {
      console.log(JSON.stringify({
        decision: 'block',
        reason: 'CI failure dismissed without base-branch verification.',
        systemMessage: DISMISSAL_PROMPT
      }));
      process.exit(0);
    }

    if (modifiedFiles) {
      if (extractTurnText(lines).length === 0) {
        console.log('{}');
        process.exit(0);
      }

      const classifier = loadClassifier();
      if (hasUnresolvedFindings(lines, classifier)) {
        console.log(JSON.stringify({
          decision: 'block',
          reason: 'Self-evaluation required — violation language detected.',
          systemMessage: SELF_EVAL_PROMPT
        }));
        process.exit(0);
      }
    }

    console.log('{}');
  } catch (err) {
    console.error('semantic-stop-guard error:', err.message || err);
    console.log('{}');
  }
  process.exit(0);
});
