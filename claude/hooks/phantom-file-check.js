// phantom-file-check.js
// Prevents reading non-existent files (anti-hallucination)
// Part of the Cheddar Flow enforcement system

const fs = require('fs');
const path = require('path');

module.exports = {
  event: 'preToolUse',
  hooks: [{
    matcher: (toolName) => toolName === 'Read',
    handler: async (input) => {
      const filePath = path.resolve(input.path);
      if (!fs.existsSync(filePath)) {
        return {
          result: `Cheese Lord, that file doesn't exist: "${input.path}"

Use \`ls\` or \`glob\` to find the correct path.
A true Gouda Explorer verifies the terrain before mapping it.`
        };
      }
      return null; // Allow the read
    }
  }]
};
