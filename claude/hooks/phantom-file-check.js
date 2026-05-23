// phantom-file-check.js
// Prevents reading non-existent files (anti-hallucination)

const fs = require('fs');
const path = require('path');

module.exports = {
  hooks: [{
    matcher: (toolName) => toolName === 'Read',
    handler: async (_toolName, input, event) => {
      const rawPath = input.file_path || input.path;
      if (!rawPath) return null;
      // Resolve relative paths against the event's cwd (the project root the
      // user is working in), not the hook process's cwd. process.cwd() would
      // give false negatives for any relative path read.
      const base = (event && event.cwd) || process.cwd();
      const filePath = path.isAbsolute(rawPath) ? path.resolve(rawPath) : path.resolve(base, rawPath);
      if (!fs.existsSync(filePath)) {
        return {
          result: `Cheese Lord, that file doesn't exist: "${rawPath}"

Use \`tilth_list\` or \`tilth_search\` to find the correct path.
A true Gouda Explorer verifies the terrain before mapping it.`
        };
      }
      return null;
    }
  }]
};
