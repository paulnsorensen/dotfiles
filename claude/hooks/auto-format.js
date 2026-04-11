const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const toolInput = JSON.parse(process.env.TOOL_INPUT || '{}');
const filePath = toolInput.file_path || toolInput.path || '';

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
  execFileSync(bin, args, { stdio: 'ignore', timeout: 8000 });
} catch {
  // formatting failure is non-blocking
}
