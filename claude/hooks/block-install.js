// block-install.js
// Blocks automatic package installation - requires human approval
// Part of the Cheddar Flow enforcement system

module.exports = {
  event: 'preToolUse',
  hooks: [{
    matcher: (toolName, input) => {
      if (toolName !== 'Bash') return false;
      const cmd = input.command?.toLowerCase() || '';
      return cmd.includes('npm install') ||
             cmd.includes('yarn add') ||
             cmd.includes('pnpm add') ||
             cmd.includes('pip install') ||
             cmd.includes('pip3 install') ||
             cmd.includes('go get') ||
             cmd.includes('cargo add');
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
