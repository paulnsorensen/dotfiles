// write-guard.js
// Blocks placeholder/lazy code and inline test snippets in file writes.
// Covers Edit, Write, MultiEdit, and the tilth_write MCP batch writer.

const EDIT_TOOLS = new Set(['Edit', 'Write', 'MultiEdit', 'mcp__tilth__tilth_write']);

const RULES = [
  {
    pattern: /(\/\/\s*\.\.\.|#\s*\.\.\.|\/\*\s*\.\.\.\s*\*\/|\.{3}\s*(rest|remaining|similar|same))/,
    msg: `Ellipsis/lazy code detected. Write the actual code — every line. No shortcuts.
If the pattern truly repeats, use a loop or function.`,
  },
  {
    pattern: /\b(TODO|FIXME|HACK|XXX|PLACEHOLDER)\b|unimplemented!\(\)|todo!\(\)/,
    msg: `Placeholder detected. Implement it now or state the specific blocker.
Do not leave TODO/FIXME markers or unimplemented!() stubs.`,
  },
  {
    pattern: /(?:python3?\s+-c\s+['"][^'"]*(?:import|assert|print\s*\()|cat\s+<<)/,
    skipFiles: /\.(md|sh|bash|yml|yaml|toml|Makefile|justfile)$/,
    msg: `Inline test code detected. Use /test-sandbox or /wreck to write a proper test file.`,
  },
];

// Flatten any supported edit tool into { filePath, text } pairs.
function extractWrites(toolName, input) {
  if (!EDIT_TOOLS.has(toolName)) return [];
  const writes = [];
  // tilth_write: batch of files; overwrite/append carry content, hash carries edits[].content.
  if (Array.isArray(input.files)) {
    for (const f of input.files) {
      if (!f || !f.path) continue;
      if (typeof f.content === 'string') writes.push({ filePath: f.path, text: f.content });
      if (Array.isArray(f.edits)) {
        for (const e of f.edits) {
          if (e && typeof e.content === 'string') writes.push({ filePath: f.path, text: e.content });
        }
      }
    }
    return writes;
  }
  const filePath = input.file_path || input.path || '';
  // MultiEdit: edits[].new_string against one file.
  if (Array.isArray(input.edits)) {
    for (const e of input.edits) {
      if (e && typeof e.new_string === 'string') writes.push({ filePath, text: e.new_string });
    }
    return writes;
  }
  // Edit / Write.
  const text = input.new_string || input.content || '';
  if (text) writes.push({ filePath, text });
  return writes;
}

function firstViolation(writes) {
  for (const w of writes) {
    for (const r of RULES) {
      if (r.skipFiles && r.skipFiles.test(w.filePath)) continue;
      if (r.pattern.test(w.text)) return r.msg;
    }
  }
  return null;
}

module.exports = {
  hooks: [{
    matcher: (toolName, input) => firstViolation(extractWrites(toolName, input)) !== null,
    handler: async (toolName, input) => {
      const msg = firstViolation(extractWrites(toolName, input));
      return { result: msg || 'Code quality issue detected.' };
    },
  }],
};
