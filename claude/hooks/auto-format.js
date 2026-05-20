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

function resolveEditedPath(event) {
  const rawPath = event.tool_input?.file_path || event.tool_input?.path || event.tool_response?.filePath || '';
  if (!rawPath) return '';
  return path.isAbsolute(rawPath) ? path.resolve(rawPath) : path.resolve(event.cwd || process.cwd(), rawPath);
}

async function main() {
  let event;
  try {
    event = JSON.parse(await readStdin() || '{}');
  } catch {
    process.exit(0);
  }

  if (event.hook_event_name && event.hook_event_name !== 'PostToolUse') process.exit(0);

  // Only format file-editing tools. settings.json matcher already filters,
  // but verify here so a future PostToolUse for Bash/Read can't accidentally
  // try to format `tool_input.file_path` and surface a confusing error.
  const FILE_EDITING_TOOLS = new Set(['Edit', 'Write', 'MultiEdit']);
  if (event.tool_name && !FILE_EDITING_TOOLS.has(event.tool_name)) process.exit(0);

  const filePath = resolveEditedPath(event);
  if (!filePath || !fs.existsSync(filePath)) process.exit(0);

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
  };

  const formatter = FORMATTERS[ext];
  if (!formatter) process.exit(0);

  const [bin, args] = formatter;

  try {
    execFileSync('which', [bin], { stdio: 'ignore' });
  } catch {
    process.exit(0);
  }

  try {
    execFileSync(bin, args, { stdio: 'pipe', timeout: 8000, cwd: event.cwd || process.cwd() });
  } catch (err) {
    const msg = err.stderr ? err.stderr.toString().trim() : err.message;
    process.stderr.write(`[auto-format] ${bin} failed on ${path.basename(filePath)}: ${msg}\n`);
  }
}

main();
