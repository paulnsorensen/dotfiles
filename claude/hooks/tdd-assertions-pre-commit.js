// tdd-assertions-pre-commit.js
// Fires before git commit, reminding Claude to check assertion strength in test files.
// Single reminder per commit — no per-file noise.

module.exports = {
  event: 'preToolUse',
  hooks: [{
    matcher: (toolName, input) => {
      if (toolName !== 'Bash') return false;
      const cmd = input.command || '';
      return /^\s*git\s+commit\b/.test(cmd);
    },
    handler: async () => {
      return {
        result: `TDD assertion reminder: Before committing test code, review assertions for weakness.
Use /tdd-assertions or check: existence checks instead of value equality, catch-all error types,
length-only checks, mock verification without arguments, no-crash-as-success, tautological assertions.`
      };
    }
  }]
};
