'use strict';
// native.js — reroute module: built-in file tools → tilth MCP tools.
//
//   Read (text file)                       → DENY → tilth_read
//   Read (image, PDF, or notebook)         → runs unchanged
//   Write / Edit / MultiEdit (Claude)      → DENY → tilth_write
//   apply_patch (Codex)                    → DENY → tilth_write
//
// Claude also removes Write/Edit through permissions.deny; this deny is the
// second layer for profiles and launches that do not carry that rule. MultiEdit
// stays in the set for older Claude builds that still ship it.
// Read stays granted only because it is Claude's sole viewer for images,
// PDFs, and notebooks, which tilth_read does not render.

const path = require('path');

const MEDIA_EXT = new Set(['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.pdf', '.ipynb']);
const WRITE_TOOLS = new Set(['Write', 'Edit', 'MultiEdit', 'apply_patch']);

function readReason(file) {
  const p = file || '<file>';
  return `Blocked: the Read tool on ${p} — use tilth_read for text files.

Run instead:
  mcp__tilth__tilth_read(paths:[${JSON.stringify(p)}], cwd:"<checkout>")

Append #start-end or #symbol to read one section. Read remains for images, PDFs, and notebooks.`;
}

function writeReason(toolName) {
  return `Blocked: the ${toolName} tool — use tilth_write for every file change.

tilth_read the file first to get the [path#TAG], then:
  mcp__tilth__tilth_write(edits:[{path:"<file>", tag:"<TAG>", ops:[{op:"replace_text", old:"…", new:"…"}]}], cwd:"<checkout>")

New file: omit tag and use ops:[{op:"create_file", content:"…"}].`;
}

function detect(toolName, input) {
  if (toolName === 'Read') {
    const file = input && typeof input.file_path === 'string' ? input.file_path : '';
    if (MEDIA_EXT.has(path.extname(file).toLowerCase())) return null;
    return { reason: readReason(file), module: 'native' };
  }
  if (WRITE_TOOLS.has(toolName)) return { reason: writeReason(toolName), module: 'native' };
  return null;
}

module.exports = { detect };
