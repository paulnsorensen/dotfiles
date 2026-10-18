// worktree-guard.js
// When running in a git worktree, blocks writes to files outside the worktree
// root. Prevents agents from accidentally modifying the main repo or sibling
// worktrees. Covers Edit, Write, MultiEdit, and the tilth_write MCP writer.
//
// Enforced by default in a worktree (opt-out):
//   CLAUDE_WORKTREE_GUARD=0|false|off|no   → disable entirely
// Allowed-path escape hatch (writable even outside the worktree):
//   built-in: worktree root, $TMPDIR, /tmp, ~/.claude/, any .cheese/ dir,
//             ${XDG_DATA_HOME:-~/.local/share}/cheese/ (durable corpus)
//   request:  the root of a tool request's `cwd` (tilth_write) when that cwd is
//             a linked worktree of the same repository. A parent can dispatch
//             a coder into a sibling worktree it created; the main checkout
//             stays blocked (issue #1396).
//   extra:    CLAUDE_WORKTREE_GUARD_ALLOW=/abs/prefix,/another  (comma-separated)

const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const EDIT_TOOLS = new Set(['Write', 'Edit', 'MultiEdit', 'mcp__tilth__tilth_write']);

function isDisabled() {
  const v = (process.env.CLAUDE_WORKTREE_GUARD || '').trim().toLowerCase();
  return v === '0' || v === 'false' || v === 'off' || v === 'no';
}

const cache = new Map(); // cwd -> { isWorktree, worktreeRoot, commonDir }

// A linked worktree has its own git dir, distinct from the shared common dir.
function detectWorktree(cwd) {
  if (cache.has(cwd)) return cache.get(cwd);
  let info = { isWorktree: false, worktreeRoot: null, commonDir: null };
  try {
    const opts = { encoding: 'utf8', timeout: 3000, cwd, stdio: ['ignore', 'pipe', 'ignore'] };
    const [gitDir, commonDir, top] = execSync(
      'git rev-parse --path-format=absolute --git-dir --git-common-dir --show-toplevel',
      opts,
    ).trim().split('\n');
    if (gitDir && commonDir && top && gitDir !== commonDir) {
      info = { isWorktree: true, worktreeRoot: top, commonDir: fs.realpathSync(commonDir) };
    }
  } catch {
    // Not a git checkout, or git is unavailable: not a worktree.
  }
  cache.set(cwd, info);
  return info;
}

// The request's own worktree root, when the request cwd is a linked worktree
// that shares the session's common git dir. Otherwise null.
function requestRoot(input, session, eventCwd) {
  if (typeof input.cwd !== 'string' || !input.cwd) return null;
  const reqCwd = path.resolve(eventCwd, input.cwd);
  if (!fs.existsSync(reqCwd)) return null;
  const req = detectWorktree(reqCwd);
  return req.isWorktree && req.commonDir === session.commonDir ? req.worktreeRoot : null;
}

function allowedPrefixes(roots) {
  const prefixes = [...roots];
  const home = process.env.HOME || '';
  if (home) prefixes.push(path.join(home, '.claude'));
  // Cheese durable corpus (specs, rfds, reports, research) — the /mold and
  // /cheese artifact resolvers write here (see issue #270).
  const dataHome = process.env.XDG_DATA_HOME || (home && path.join(home, '.local', 'share'));
  if (dataHome) prefixes.push(path.join(dataHome, 'cheese'));
  const tmp = process.env.TMPDIR;
  if (tmp) prefixes.push(tmp.replace(/\/$/, ''));
  const extra = (process.env.CLAUDE_WORKTREE_GUARD_ALLOW || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
  return prefixes.concat(extra);
}

function isAllowedPath(filePath, roots, cwd) {
  const resolved = path.isAbsolute(filePath) ? path.resolve(filePath) : path.resolve(cwd, filePath);
  // /tmp and /private/tmp (macOS) are always writable scratch.
  if (/^(\/private)?\/tmp(\/|$)/.test(resolved)) return true;
  // Any .cheese/ artifact dir (specs, rfds, reports) is always writable.
  if (/(^|\/)\.cheese(\/|$)/.test(resolved)) return true;
  for (const prefix of allowedPrefixes(roots)) {
    if (!prefix) continue;
    if (resolved === prefix || resolved.startsWith(prefix + '/')) return true;
  }
  return false;
}

function resolveEditPath(rawPath, inputCwd, eventCwd) {
  if (typeof rawPath !== 'string' || !rawPath) return rawPath;
  const cwd = typeof inputCwd === 'string' && inputCwd ? path.resolve(eventCwd, inputCwd) : eventCwd;
  return path.isAbsolute(rawPath) ? path.resolve(rawPath) : path.resolve(cwd, rawPath);
}

function editTargets(input, eventCwd) {
  if (!Array.isArray(input.edits)) return [];
  const targets = [];
  for (const edit of input.edits) {
    if (!edit || typeof edit.path !== 'string' || !edit.path) continue;
    targets.push(resolveEditPath(edit.path, input.cwd, eventCwd));
    if (!Array.isArray(edit.ops)) continue;
    for (const op of edit.ops) {
      if (op && op.op === 'move_file' && typeof op.dest === 'string' && op.dest) {
        targets.push(resolveEditPath(op.dest, input.cwd, eventCwd));
      }
    }
  }
  return targets;
}

function targetPaths(toolName, input, eventCwd) {
  if (!EDIT_TOOLS.has(toolName)) return [];
  const targets = editTargets(input, eventCwd);
  if (Array.isArray(input.files)) {
    targets.push(...input.files.filter((f) => f && f.path).map((f) => f.path));
  }
  const single = input.file_path || input.path;
  if (single) targets.push(single);
  return targets;
}

function blockedTargets(toolName, input, event) {
  const cwd = (event && event.cwd) || process.cwd();
  const session = detectWorktree(cwd);
  if (!session.isWorktree) return { session, blocked: [] };
  const roots = [session.worktreeRoot, requestRoot(input, session, cwd)].filter(Boolean);
  const blocked = targetPaths(toolName, input, cwd).filter((p) => !isAllowedPath(p, roots, cwd));
  return { session, blocked };
}

module.exports = {
  hooks: [{
    matcher: (toolName, input, event) => {
      if (isDisabled()) return false;
      if (!EDIT_TOOLS.has(toolName)) return false;
      return blockedTargets(toolName, input, event).blocked.length > 0;
    },
    handler: async (toolName, input, event) => {
      const { session, blocked } = blockedTargets(toolName, input, event);
      const worktreeRoot = session.worktreeRoot;
      return {
        result: `Blocked: write to ${blocked.join(', ')} — outside worktree root (${worktreeRoot}).

In a worktree, writes are scoped to:
- ${worktreeRoot}/ (worktree files)
- the tilth_write \`cwd\` worktree, when it is a linked worktree of the same repository
- $TMPDIR, /tmp (scratch)
- ~/.claude/ (memories, specs)
- any .cheese/ dir (specs, rfds, reports)
- \${XDG_DATA_HOME:-~/.local/share}/cheese/ (durable corpus)
- CLAUDE_WORKTREE_GUARD_ALLOW prefixes

Disable this guard: export CLAUDE_WORKTREE_GUARD=0
Allow more paths:   export CLAUDE_WORKTREE_GUARD_ALLOW=/abs/prefix,...`,
      };
    },
  }],
};
