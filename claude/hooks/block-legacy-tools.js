// block-legacy-tools.js
// Blocks grep/sed/awk/find in Bash — agents should use dedicated tools
// Part of the Cheddar Flow enforcement system
//
// grep  → built-in Grep tool (ripgrep)
// sed   → sd (chisel skill) or Edit tool
// awk   → sd (chisel skill) or Edit tool
// find  → Glob tool or fd (scout skill)

const BLOCKED_TOOLS = [
  {
    // Piped grep (e.g. `git branch | grep foo`) is allowed — Grep tool can't filter stdout
    pattern: /^\s*(grep|egrep|fgrep)\b/,
    message: `Blocked: grep via Bash. Use the built-in Grep tool instead (ripgrep under the hood).
Example: Grep with pattern="your_pattern" path="target/dir"`
  },
  {
    pattern: /^\s*sed\b/,
    message: `Blocked: sed via Bash. Use sd for regex replacements or the Edit tool for precise edits.
sd syntax: sd 'pattern' 'replacement' file`
  },
  {
    // Also catch `sed -i` mid-pipeline
    pattern: /\bsed\s+-[^|]*i/,
    message: `Blocked: sed via Bash. Use sd for regex replacements or the Edit tool for precise edits.
sd syntax: sd 'pattern' 'replacement' file`
  },
  {
    pattern: /^\s*awk\b/,
    message: `Blocked: awk via Bash. Use sd for text transformations or the Edit tool for file edits.`
  },
  {
    pattern: /^\s*find\b/,
    message: `Blocked: find via Bash. Use the Glob tool for file patterns or fd (scout skill) for name/metadata searches.
Example: Glob with pattern="**/*.ts" or Bash fd -e ts`
  }
];

module.exports = {
  event: 'preToolUse',
  hooks: [{
    matcher: (toolName, input) => {
      if (toolName !== 'Bash') return false;
      const cmd = input.command || '';
      return BLOCKED_TOOLS.some(t => t.pattern.test(cmd));
    },
    handler: async (_toolName, input) => {
      const cmd = input.command || '';
      const match = BLOCKED_TOOLS.find(t => t.pattern.test(cmd));
      return { result: match ? match.message : 'Use the dedicated tool instead of shell commands.' };
    }
  }]
};
