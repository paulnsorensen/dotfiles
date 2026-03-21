// worktree-guard.js
// When running in a git worktree, blocks Write/Edit to files outside the worktree root.
// Prevents agents from accidentally modifying main repo or other worktrees.

const { execSync } = require('child_process');
const path = require('path');

let worktreeRoot = null;
let isWorktree = null;

function detectWorktree() {
  if (isWorktree !== null) return isWorktree;
  try {
    const gitDir = execSync('git rev-parse --git-dir', {
      encoding: 'utf8',
      timeout: 3000
    }).trim();
    isWorktree = gitDir.includes('/worktrees/');
    if (isWorktree) {
      worktreeRoot = execSync('git rev-parse --show-toplevel', {
        encoding: 'utf8',
        timeout: 3000
      }).trim();
    }
  } catch {
    isWorktree = false;
  }
  return isWorktree;
}

function isAllowedPath(filePath) {
  const resolved = path.isAbsolute(filePath) ? path.resolve(filePath) : path.resolve(process.cwd(), filePath);
  if (resolved.startsWith(worktreeRoot + '/')) return true;
  if (resolved === worktreeRoot) return true;
  if (/^(\/private)?\/tmp\//.test(resolved)) return true;
  const home = process.env.HOME || '';
  if (resolved.startsWith(home + '/.claude/')) return true;
  return false;
}

module.exports = {
  event: 'preToolUse',
  hooks: [{
    matcher: (toolName, input) => {
      if (toolName !== 'Write' && toolName !== 'Edit') return false;
      if (!detectWorktree()) return false;
      const filePath = input.file_path || '';
      return !isAllowedPath(filePath);
    },
    handler: async (_toolName, input) => {
      const filePath = input.file_path || '';
      return {
        result: `Blocked: write to ${filePath} — outside worktree root (${worktreeRoot}).

In a worktree, writes are scoped to:
- ${worktreeRoot}/ (worktree files)
- $TMPDIR (temp reports)
- ~/.claude/ (memories, specs)

If you need to modify files outside the worktree, ask the Cheese Lord.`
      };
    }
  }]
};
