// de-slop-pre-commit.js
// Fires before git commit, reminding Claude to de-slop staged changes.
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
        result: `De-slop reminder: Before committing, review staged changes for AI anti-patterns.
Use /de-slop or check: comment pollution, silent error swallowing, over-abstraction,
partial strict mode (set -e without -uo pipefail), unnecessary type annotations, dead code.`
      };
    }
  }]
};
