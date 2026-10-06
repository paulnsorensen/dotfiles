'use strict';
// native.js — reroute module: built-in file tools → tilth MCP tools.
//
//   Read (text file)                       → DENY → tilth_read
//   Read (image, PDF, or notebook)         → runs unchanged
//   Write / Edit / MultiEdit               → DENY → tilth_write
//   apply_patch (Codex)                    → DENY → tilth_write
//   Grep / Glob                            → DENY → tilth_search
//   tilth_write (Codex only)               → DENY outside the checkout roots
//
// Claude plan mode and auto-memory can only write through the built-in Write
// and Edit tools. Read, Write, Edit, and MultiEdit therefore pass when every
// target sits under ~/.claude/plans/ or ~/.claude/projects/*/memory/.
// Claude's session scratch directory (<tmp>/claude-<uid>/, see shell.js) is
// harness-owned too, so the same four tools pass there. A `..` segment or a
// shell expansion in the path never qualifies.
// Claude removes Grep/Glob through permissions.deny; this deny is the second
// layer. MultiEdit stays in the set for older Claude builds.
// Codex approves tilth_write without a prompt and tilth_write accepts absolute
// paths, so the Codex harness gets an out-of-tree block here. On Claude,
// worktree-guard owns that check.
// Read stays granted only because it is Claude's sole viewer for images,
// PDFs, and notebooks, which tilth_read does not render.

const path = require('path');
const fs = require('fs');
const { execFileSync } = require('child_process');
const { isScratchPath } = require('./shell');

const MEDIA_EXT = new Set(['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.pdf', '.ipynb']);
const WRITE_TOOLS = new Set(['Write', 'Edit', 'MultiEdit', 'apply_patch']);
const TILTH_WRITE = 'mcp__tilth__tilth_write';

function home() {
  return process.env.HOME || require('os').homedir();
}

function resolveFrom(cwd, p) {
  return path.isAbsolute(p) ? path.resolve(p) : path.resolve(cwd, p);
}

// Plan files and auto-memory: the only built-in writes that stay open.
function isHarnessOwnedPath(resolved) {
  const claude = path.join(home(), '.claude');
  if (resolved.startsWith(path.join(claude, 'plans') + '/')) return true;
  const projects = path.join(claude, 'projects') + '/';
  if (!resolved.startsWith(projects)) return false;
  const rest = resolved.slice(projects.length).split('/');
  return rest.length >= 3 && rest[0] !== '' && rest[1] === 'memory';
}

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

function searchReason(label, pattern) {
  const q = pattern || '<pattern>';
  return `Blocked: ${label} searches files — use tilth_search, not a raw search tool.

tilth_search is AST-aware and far cheaper in context. Run instead:
  mcp__tilth__tilth_search(queries:[{query:${JSON.stringify(q)}}], cwd:"<checkout>")

Add glob:"*.rs" to a query to narrow it. Filters on command output (\`git log | grep fix\`) still run.`;
}

function toolFilePath(input, cwd) {
  const file = input && typeof input.file_path === 'string' ? input.file_path : '';
  return file ? resolveFrom(cwd, file) : '';
}

// ── Codex tilth_write out-of-tree block ───────────────────────────────

function gitToplevel(cwd) {
  try {
    const out = execFileSync('git', ['-C', cwd, 'rev-parse', '--show-toplevel'], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 2000,
    }).trim();
    return out || cwd;
  } catch {
    return cwd;
  }
}

function writeTargets(input, eventCwd) {
  if (!input || !Array.isArray(input.edits)) return [];
  const base = typeof input.cwd === 'string' && input.cwd ? resolveFrom(eventCwd, input.cwd) : eventCwd;
  const targets = [];
  for (const edit of input.edits) {
    if (!edit || typeof edit.path !== 'string' || !edit.path) continue;
    targets.push(resolveFrom(base, edit.path));
    if (!Array.isArray(edit.ops)) continue;
    for (const op of edit.ops) {
      if (op && op.op === 'move_file' && typeof op.dest === 'string' && op.dest) {
        targets.push(resolveFrom(base, op.dest));
      }
    }
  }
  return targets;
}

function allowedRoots(eventCwd) {
  const roots = [gitToplevel(eventCwd), '/tmp', '/private/tmp'];
  if (process.env.TMPDIR) roots.push(process.env.TMPDIR.replace(/\/+$/, ''));
  const dataHome = process.env.XDG_DATA_HOME || path.join(home(), '.local', 'share');
  roots.push(path.join(dataHome, 'cheese'));
  for (const extra of (process.env.DOTFILES_WRITE_GUARD_ALLOW || '').split(',')) {
    if (extra.trim()) roots.push(extra.trim());
  }
  return roots.filter(Boolean);
}

// Resolve symlinks on the longest existing ancestor (macOS /var → /private/var).
function realish(p) {
  const tail = [];
  let cur = p;
  for (;;) {
    try {
      return path.join(fs.realpathSync(cur), ...tail);
    } catch {
      const parent = path.dirname(cur);
      if (parent === cur) return p;
      tail.unshift(path.basename(cur));
      cur = parent;
    }
  }
}

// Judge the real path only: a symlink inside the checkout that points outside
// it must not pass. Roots match in raw and real form (/tmp → /private/tmp).
function underRoot(resolved, roots) {
  const real = realish(resolved);
  if (/(^|\/)\.cheese(\/|$)/.test(real)) return true;
  const allRoots = roots.flatMap((r) => [r.replace(/\/+$/, ''), realish(r.replace(/\/+$/, ''))]);
  return allRoots.some((r) => real === r || real.startsWith(r + '/'));
}

function outOfTreeReason(blocked, roots) {
  return `Blocked: tilth_write targets outside the checkout: ${blocked.join(', ')}.

Allowed roots: ${roots.join(', ')}, any .cheese/ directory.
Ask the user for explicit approval before changing allowed roots. Do not retry through another tool.`;
}

function detectTilthWrite(input, eventCwd) {
  const targets = writeTargets(input, eventCwd);
  if (!targets.length) return null;
  const roots = allowedRoots(eventCwd);
  const blocked = targets.filter((t) => !underRoot(t, roots));
  if (!blocked.length) return null;
  return { reason: outOfTreeReason([...new Set(blocked)], roots), module: 'native' };
}

function detect(toolName, input, cwd, harness) {
  const eventCwd = cwd || process.cwd();
  if (toolName === 'Grep' || toolName === 'Glob') {
    const pattern = input && typeof input.pattern === 'string' ? input.pattern : null;
    return { reason: searchReason(`the ${toolName} tool`, pattern), pattern, module: 'native' };
  }
  if (toolName === TILTH_WRITE) {
    return harness === 'codex' ? detectTilthWrite(input, eventCwd) : null;
  }
  if (toolName === 'Read') {
    const file = input && typeof input.file_path === 'string' ? input.file_path : '';
    if (MEDIA_EXT.has(path.extname(file).toLowerCase())) return null;
    if (file && (isHarnessOwnedPath(toolFilePath(input, eventCwd)) || isScratchPath(file, eventCwd))) return null;
    return { reason: readReason(file), module: 'native' };
  }
  if (WRITE_TOOLS.has(toolName)) {
    if (toolName !== 'apply_patch') {
      const target = toolFilePath(input, eventCwd);
      if (target && (isHarnessOwnedPath(target) || isScratchPath(input.file_path, eventCwd))) return null;
    }
    return { reason: writeReason(toolName), module: 'native' };
  }
  return null;
}

module.exports = { detect };
