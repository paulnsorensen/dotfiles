const RULES = [
  {
    pattern: /(\/\/\s*\.\.\.|#\s*\.\.\.|\/\*\s*\.\.\.\s*\*\/|\.{3}\s*(rest|remaining|similar|same))/,
    msg: `Ellipsis/lazy code detected. Write the actual code — every line. No shortcuts.
If the pattern truly repeats, use a loop or function.`
  },
  {
    pattern: /\b(TODO|FIXME|HACK|XXX|PLACEHOLDER)\b|unimplemented!\(\)|todo!\(\)/,
    msg: `Placeholder detected. Implement it now or state the specific blocker.
Do not leave TODO/FIXME markers or unimplemented!() stubs.`
  },
  {
    pattern: /(?:python3?\s+-c\s+['"][^'"]*(?:import|assert|print\s*\()|cat\s+<<)/,
    skipFiles: /\.(md|sh|bash|yml|yaml|toml|Makefile|justfile)$/,
    msg: `Inline test code detected. Use /test-sandbox or /wreck to write a proper test file.`
  },
];

module.exports = {
  event: 'preToolUse',
  hooks: [{
    matcher: (toolName, input) => {
      if (toolName !== 'Edit' && toolName !== 'Write') return false;
      const text = input.new_string || input.content || '';
      const filePath = input.file_path || '';
      return RULES.some(r => {
        if (r.skipFiles && r.skipFiles.test(filePath)) return false;
        return r.pattern.test(text);
      });
    },
    handler: async (_toolName, input) => {
      const text = input.new_string || input.content || '';
      const filePath = input.file_path || '';
      for (const r of RULES) {
        if (r.skipFiles && r.skipFiles.test(filePath)) continue;
        if (r.pattern.test(text)) return { result: r.msg };
      }
      return { result: 'Code quality issue detected.' };
    }
  }]
};
