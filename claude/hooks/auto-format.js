const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

function readStdin() {
  return new Promise((resolve) => {
    let input = '';
    process.stdin.on('data', (chunk) => { input += chunk; });
    process.stdin.on('end', () => resolve(input));
  });
}

// Tools whose written files we format. tilth_write is the tilth MCP batch
// writer; its PostToolUse name is the fully-qualified mcp__<server>__<tool>.
const FILE_EDITING_TOOLS = new Set([
  'Edit', 'Write', 'MultiEdit', 'mcp__tilth__tilth_write',
]);

// Linters that exit non-zero when residual (non-auto-fixable) findings remain
// after --fix. That exit is expected, not a failure — stay silent so we don't
// nag on every markdown write (silent fix-only).
const SILENT_NONZERO_EXIT = new Set(['markdownlint-cli2']);

// Collect every file an edit touched, resolved to absolute paths.
// Edit/Write/MultiEdit carry a single file_path; tilth_write is a batch and
// carries tool_input.files[].path.
function collectEditedPaths(event) {
  const input = event.tool_input || {};
  const raw = [];
  if (Array.isArray(input.files)) {
    for (const f of input.files) {
      if (f && f.path) raw.push(f.path);
    }
  }
  const single = input.file_path || input.path || (event.tool_response && event.tool_response.filePath);
  if (single) raw.push(single);
  const base = event.cwd || process.cwd();
  return raw.map((p) => (path.isAbsolute(p) ? path.resolve(p) : path.resolve(base, p)));
}

function formatterFor(filePath) {
  const ext = path.extname(filePath).toLowerCase();
  const FORMATTERS = {
    '.rs': ['rustfmt', [filePath]],
    '.py': ['ruff', ['format', filePath]],
    '.js': ['prettier', ['--write', filePath]],
    '.ts': ['prettier', ['--write', filePath]],
    '.jsx': ['prettier', ['--write', filePath]],
    '.tsx': ['prettier', ['--write', filePath]],
    '.sh': ['shfmt', ['-w', filePath]],
    '.zsh': ['shfmt', ['-w', filePath]],
    '.bash': ['shfmt', ['-w', filePath]],
    '.md': ['markdownlint-cli2', ['--fix', filePath]],
    '.markdown': ['markdownlint-cli2', ['--fix', filePath]],
  };
  return FORMATTERS[ext] || null;
}

function formatFile(filePath, cwd) {
  if (!fs.existsSync(filePath)) return;
  const formatter = formatterFor(filePath);
  if (!formatter) return;
  const [bin, args] = formatter;
  try {
    execFileSync('which', [bin], { stdio: 'ignore' });
  } catch {
    return;
  }
  try {
    execFileSync(bin, args, { stdio: 'pipe', timeout: 8000, cwd });
  } catch (err) {
    if (SILENT_NONZERO_EXIT.has(bin)) return;
    const msg = err.stderr ? err.stderr.toString().trim() : err.message;
    process.stderr.write(`[auto-format] ${bin} failed on ${path.basename(filePath)}: ${msg}\n`);
  }
}

async function main() {
  let event;
  try {
    event = JSON.parse(await readStdin() || '{}');
  } catch {
    process.exit(0);
  }

  if (event.hook_event_name && event.hook_event_name !== 'PostToolUse') process.exit(0);
  if (event.tool_name && !FILE_EDITING_TOOLS.has(event.tool_name)) process.exit(0);

  const cwd = event.cwd || process.cwd();
  for (const filePath of collectEditedPaths(event)) {
    formatFile(filePath, cwd);
  }
}

main();
