// worktree-guard.js
// When running in a git worktree, blocks writes to files outside the worktree
// root. Prevents agents from accidentally modifying the main repo or sibling
// worktrees. Covers Edit, Write, MultiEdit, and the tilth_write MCP writer.
//
// Enforced by default in a worktree (opt-out):
//   CLAUDE_WORKTREE_GUARD=0|false|off|no   → disable entirely
// Allowed-path escape hatch (writable even outside the worktree):
//   built-in: worktree root, $TMPDIR, /tmp, ~/.claude/, any .cheese/ dir
//   extra:    CLAUDE_WORKTREE_GUARD_ALLOW=/abs/prefix,/another  (comma-separated)

const { execSync } = require('child_process');
const path = require('path');

const EDIT_TOOLS = new Set(['Write', 'Edit', 'MultiEdit', 'mcp__tilth__tilth_write']);

function isDisabled() {
  const v = (process.env.CLAUDE_WORKTREE_GUARD || '').trim().toLowerCase();
  return v === '0' || v === 'false' || v === 'off' || v === 'no';
}

let cache = null; // { isWorktree, worktreeRoot } — one event per process, so safe.

function detectWorktree(cwd) {
  if (cache) return cache;
  let isWorktree = false;
  let worktreeRoot = null;
  try {
    const opts = { encoding: 'utf8', timeout: 3000, cwd };
    const gitDir = execSync('git rev-parse --git-dir', opts).trim();
    isWorktree = gitDir.includes('/worktrees/');
    if (isWorktree) {
      worktreeRoot = execSync('git rev-parse --show-toplevel', opts).trim();
    }
  } catch {
    isWorktree = false;
  }
  cache = { isWorktree, worktreeRoot };
  return cache;
}

function allowedPrefixes(worktreeRoot) {
  const prefixes = [worktreeRoot];
  const home = process.env.HOME || '';
  if (home) prefixes.push(path.join(home, '.claude'));
  const tmp = process.env.TMPDIR;
  if (tmp) prefixes.push(tmp.replace(/\/$/, ''));
  const extra = (process.env.CLAUDE_WORKTREE_GUARD_ALLOW || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
  return prefixes.concat(extra);
}

function isAllowedPath(filePath, worktreeRoot, cwd) {
  const resolved = path.isAbsolute(filePath) ? path.resolve(filePath) : path.resolve(cwd, filePath);
  // /tmp and /private/tmp (macOS) are always writable scratch.
  if (/^(\/private)?\/tmp(\/|$)/.test(resolved)) return true;
  // Any .cheese/ artifact dir (specs, rfds, reports) is always writable.
  if (/(^|\/)\.cheese(\/|$)/.test(resolved)) return true;
  for (const prefix of allowedPrefixes(worktreeRoot)) {
    if (!prefix) continue;
    if (resolved === prefix || resolved.startsWith(prefix + '/')) return true;
  }
  return false;
}

function targetPaths(toolName, input) {
  if (!EDIT_TOOLS.has(toolName)) return [];
  if (Array.isArray(input.files)) {
    return input.files.filter((f) => f && f.path).map((f) => f.path);
  }
  const single = input.file_path || input.path;
  return single ? [single] : [];
}

module.exports = {
  hooks: [{
    matcher: (toolName, input, event) => {
      if (isDisabled()) return false;
      if (!EDIT_TOOLS.has(toolName)) return false;
      const cwd = (event && event.cwd) || process.cwd();
      const { isWorktree, worktreeRoot } = detectWorktree(cwd);
      if (!isWorktree) return false;
      return targetPaths(toolName, input).some((p) => !isAllowedPath(p, worktreeRoot, cwd));
    },
    handler: async (toolName, input, event) => {
      const cwd = (event && event.cwd) || process.cwd();
      const { worktreeRoot } = detectWorktree(cwd);
      const blocked = targetPaths(toolName, input).filter((p) => !isAllowedPath(p, worktreeRoot, cwd));
      return {
        result: `Blocked: write to ${blocked.join(', ')} — outside worktree root (${worktreeRoot}).

In a worktree, writes are scoped to:
- ${worktreeRoot}/ (worktree files)
- $TMPDIR, /tmp (scratch)
- ~/.claude/ (memories, specs)
- any .cheese/ dir (specs, rfds, reports)
- CLAUDE_WORKTREE_GUARD_ALLOW prefixes

Disable this guard: export CLAUDE_WORKTREE_GUARD=0
Allow more paths:   export CLAUDE_WORKTREE_GUARD_ALLOW=/abs/prefix,...`,
      };
    },
  }],
};
