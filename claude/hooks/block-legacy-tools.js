// block-legacy-tools.js
// Blocks grep/sed/awk/find in Bash — agents should use dedicated tools
// Part of the Cheddar Flow enforcement system
//
// grep  → built-in Grep tool (ripgrep)
// sed   → sd (chisel skill) or Edit tool
// awk   → sd (chisel skill) or Edit tool
// find  → Glob tool or fd (scout skill)

module.exports = {
  event: 'preToolUse',
  hooks: [{
    matcher: (toolName, input) => {
      if (toolName !== 'Bash') return false;
      const cmd = input.command || '';

      // Block grep/egrep/fgrep as the primary command (not after a pipe).
      // Piped grep (e.g. `git branch | grep foo`) is allowed — Grep tool can't filter stdout.
      if (/^\s*(grep|egrep|fgrep)\b/.test(cmd)) return true;

      // Block sed as the primary command or with -i flag anywhere (in-place editing).
      if (/^\s*sed\b/.test(cmd)) return true;
      if (/\bsed\s+-[^|]*i/.test(cmd)) return true;

      // Block awk as the primary command.
      if (/^\s*awk\b/.test(cmd)) return true;

      // Block find as the primary command — use Glob or fd.
      if (/^\s*find\b/.test(cmd)) return true;

      return false;
    },
    handler: async (_toolName, input) => {
      const cmd = input.command || '';
      if (/^\s*(grep|egrep|fgrep)\b/.test(cmd)) {
        return {
          result: `Blocked: grep via Bash. Use the built-in Grep tool instead (ripgrep under the hood).
Example: Grep with pattern="your_pattern" path="target/dir"`
        };
      }
      if (/\bsed\b/.test(cmd)) {
        return {
          result: `Blocked: sed via Bash. Use sd for regex replacements or the Edit tool for precise edits.
sd syntax: sd 'pattern' 'replacement' file`
        };
      }
      if (/^\s*awk\b/.test(cmd)) {
        return {
          result: `Blocked: awk via Bash. Use sd for text transformations or the Edit tool for file edits.`
        };
      }
      if (/^\s*find\b/.test(cmd)) {
        return {
          result: `Blocked: find via Bash. Use the Glob tool for file patterns or fd (scout skill) for name/metadata searches.
Example: Glob with pattern="**/*.ts" or Bash fd -e ts`
        };
      }
      return { result: 'Use the dedicated tool instead of shell commands.' };
    }
  }]
};
