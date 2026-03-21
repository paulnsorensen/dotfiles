// phantom-file-check.js
// Prevents reading non-existent files (anti-hallucination)

const fs = require('fs');
const path = require('path');

module.exports = {
  event: 'preToolUse',
  hooks: [{
    matcher: (toolName) => toolName === 'Read',
    handler: async (input) => {
      const rawPath = input.file_path || input.path;
      if (!rawPath) return null;
      const filePath = path.resolve(rawPath);
      if (!fs.existsSync(filePath)) {
        return {
          result: `Cheese Lord, that file doesn't exist: "${rawPath}"

Use \`ls\` or \`glob\` to find the correct path.
A true Gouda Explorer verifies the terrain before mapping it.`
        };
      }
      return null;
    }
  }]
};
