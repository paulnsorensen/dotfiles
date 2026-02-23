// block-install.js
// Blocks automatic package installation - requires human approval
// Part of the Cheddar Flow enforcement system

module.exports = {
  event: 'preToolUse',
  hooks: [{
    matcher: (toolName, input) => {
      if (toolName !== 'Bash') return false;
      const cmd = input.command?.toLowerCase() || '';
      return /\bnpm\s+install\b/.test(cmd) ||
             /\byarn\s+add\b/.test(cmd) ||
             /\bpnpm\s+(add|install)\b/.test(cmd) ||
             /\bpip3?\s+install\b/.test(cmd) ||
             /\bgo\s+get\b/.test(cmd) ||
             /\bcargo\s+add\b/.test(cmd);
    },
    handler: async () => ({
      result: `Whoa there, Cheese Lord! Package installation requires your royal approval.

Before I can install this dependency:
1. Confirm why stdlib cannot solve this problem
2. Review the dependency weight (including transitives)
3. Explicitly approve the installation

If you approve, please run the install command yourself or say "approved".`
    })
  }]
};
