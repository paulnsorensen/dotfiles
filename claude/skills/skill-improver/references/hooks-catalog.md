# Hooks Catalog for Skill Enforcement

Rules in SKILL.md and CLAUDE.md are *requests*. Hooks are *laws*. If a behavior
must happen 100% of the time, implement it as a hook.

## The Skill + Hook + Command Trinity

The most robust skill architecture uses all three:

- **Skill** — Progressive-disclosure knowledge that loads on demand
- **Hook** — Runtime enforcement that cannot be overridden by the model
- **Command** — User-invoked workflow (slash command) for explicit activation

## Hook Categories

### 1. Forced Skill Evaluation (Activation)

**Problem:** Skills trigger at ~20% baseline. Claude skips evaluation for tasks
it thinks it can handle directly.

**Fix:** `UserPromptSubmit` hook forces Claude to evaluate available skills.
Community testing: ~20% → ~84% activation.

```javascript
// .claude/hooks/force-skill-eval.js
const message = `MANDATORY: Before responding, evaluate whether any installed skill
is relevant to this request. Check all skill descriptions against the user's intent.
If a skill matches, read its SKILL.md BEFORE proceeding.`;
console.log(message);
```

**Tuned version** (keyword-filtered to avoid overhead on simple prompts):
```javascript
const prompt = process.env.USER_PROMPT || '';
const skillKeywords = ['review', 'test', 'deploy', 'migrate', 'refactor', 'analyze'];
const shouldEval = skillKeywords.some(kw => prompt.toLowerCase().includes(kw));
if (shouldEval) {
  console.log('MANDATORY: Evaluate installed skills before proceeding.');
}
```

Cost: ~$0.007/prompt, ~7s overhead.

### 2. Output Validation (Quality)

**Problem:** Skill says "always include tests" but Claude skips them.

**Fix:** `PostToolUse` hook validates requirements after file writes.

```javascript
// .claude/hooks/validate-output.js
const fs = require('fs');
const path = require('path');
const toolInput = JSON.parse(process.env.TOOL_INPUT || '{}');
const filePath = toolInput.path || toolInput.file_path || '';
if (!filePath) process.exit(0);

const ext = path.extname(filePath);
const dir = path.dirname(filePath);
const base = path.basename(filePath, ext);

// Rule: source files should have corresponding test files
const isSourceFile = ['.ts', '.tsx'].includes(ext)
  && !filePath.includes('.test.') && !filePath.includes('.spec.');

if (isSourceFile) {
  const testPatterns = [
    path.join(dir, `${base}.test${ext}`),
    path.join(dir, '__tests__', `${base}.test${ext}`),
  ];
  if (!testPatterns.some(p => fs.existsSync(p))) {
    console.log(`WARNING: ${filePath} written without a test file.`);
  }
}
```

### 3. Context Preprocessing (Efficiency)

**Problem:** Skill reads 10,000-line log, burning context on irrelevant lines.

**Fix:** `PreToolUse` hook preprocesses data before Claude sees it.

```javascript
// .claude/hooks/preprocess-context.js
const fs = require('fs');
const path = require('path');
const toolInput = JSON.parse(process.env.TOOL_INPUT || '{}');
const filePath = toolInput.path || '';
if (!filePath) process.exit(0);

if (filePath.endsWith('.log')) {
  const content = fs.readFileSync(filePath, 'utf-8');
  const lines = content.split('\n');
  const filtered = lines.filter(l => /\b(ERROR|WARN|FATAL)\b/i.test(l));
  if (filtered.length < lines.length * 0.5) {
    const preprocessed = path.join('/tmp', `preprocessed-${path.basename(filePath)}`);
    fs.writeFileSync(preprocessed, `[${lines.length} lines → ${filtered.length}]\n\n${filtered.join('\n')}`);
    console.log(`Filtered ${filePath}: ${lines.length} → ${filtered.length} lines. See ${preprocessed}`);
  }
}
```

### 4. Banned Pattern Detection (Guardrails)

**Problem:** Skill says "never use console.log" but Claude does it anyway.

**Fix:** `PostToolUse` hook scans written files for banned patterns.

```javascript
// .claude/hooks/banned-patterns.js
const fs = require('fs');
const toolInput = JSON.parse(process.env.TOOL_INPUT || '{}');
const filePath = toolInput.path || toolInput.file_path || '';
if (!filePath || !fs.existsSync(filePath)) process.exit(0);

const content = fs.readFileSync(filePath, 'utf-8');
const rules = [
  { pattern: /console\.log\(/g, message: 'Use project logger instead of console.log',
    exclude: ['.test.', '.spec.', 'scripts/'] },
  { pattern: /TODO|FIXME|HACK/g, message: 'Resolve TODO/FIXME before committing' },
];

const violations = [];
for (const rule of rules) {
  if (rule.exclude && rule.exclude.some(ex => filePath.includes(ex))) continue;
  const matches = content.match(rule.pattern);
  if (matches) violations.push(`  ${rule.message} (${matches.length}x)`);
}
if (violations.length > 0) {
  console.log(`Pattern violations in ${filePath}:\n${violations.join('\n')}`);
}
```

### 5. Token Budget Warning (Cost Control)

**Problem:** Long sessions degrade silently. The interval between 50% and
auto-compaction is the "dumb zone."

**Fix:** `UserPromptSubmit` hook tracks prompt count and suggests compaction.

```javascript
// .claude/hooks/token-budget-check.js
const fs = require('fs');
const file = '/tmp/claude-prompt-counter.json';
let counter = { count: 0, lastCompact: Date.now() };
try { counter = JSON.parse(fs.readFileSync(file, 'utf-8')); } catch {}
counter.count++;
fs.writeFileSync(file, JSON.stringify(counter));

if (counter.count % 20 === 0) {
  console.log(`Context check: ${counter.count} prompts. Consider /compact if responses feel imprecise.`);
}
```

## Hook Installation

All hooks go in settings.json or `.claude/settings.json`:

```json
{
  "hooks": {
    "EventName": [
      { "type": "command", "command": "node .claude/hooks/your-hook.js" }
    ]
  }
}
```

Valid events: `UserPromptSubmit`, `PreToolUse`, `PostToolUse`.

Exit 0 = allow, non-zero = block. Stdout is injected into Claude's context.
Keep hooks fast (<5 seconds for prompt-level hooks).
