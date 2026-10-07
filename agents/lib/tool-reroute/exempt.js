'use strict';
// exempt.js — the exemptions shared by the tool-reroute modules (the registry
// deploys this file next to shell.js):
//   isScratchPath       a path inside Claude's per-session scratch root
//                       <root>/claude-<uid>/, where root is /tmp, /private/tmp,
//                       or $TMPDIR. The harness owns that directory.
//   isHarnessOwnedPath  a plan file or auto-memory file under ~/.claude.
//   allSmallFiles       every target is a plain path to an existing regular file
//                       of at most 16 KiB.
//   segWritesFile       a segment redirects output into a real file.
// All checks fail closed (false) on any doubt. A stat error never throws.
// A relative path needs a known cwd (`cwd === null` means unknown); an
// absolute path does not.
const fs = require('fs');
const path = require('path');

const SMALL_FILE_BYTES = 16 * 1024;
const EXPANSION = /[$`*?\[\]{}~]/;

// A path with no shell expansion (no `$`, backtick, glob, brace, or `~`).
function isPlainPath(p) {
  return typeof p === 'string' && p !== '' && !EXPANSION.test(p);
}

// A plain path whose `..` cannot climb out of a root.
function isLiteralPath(p) {
  return isPlainPath(p) && !p.split('/').includes('..');
}

// Absolute form of `p`, or null when a relative path has no known cwd.
function absolutize(p, cwd) {
  if (path.isAbsolute(p)) return p;
  if (cwd === null) return null;
  return path.resolve(cwd || process.cwd(), p);
}

// Resolve symlinks on the longest existing ancestor (macOS /var → /private/var).
// Strict mode also fails closed (null) on a dangling symlink or any component
// that cannot resolve. Loose mode returns `p` unchanged at the filesystem root.
function canonicalize(p, strict) {
  const tail = [];
  let cur = p;
  for (;;) {
    try {
      return path.join(fs.realpathSync(cur), ...tail);
    } catch (err) {
      if (strict) {
        if (err.code !== 'ENOENT') return null;
        try { fs.lstatSync(cur); return null; } catch (missing) {
          if (missing.code !== 'ENOENT') return null;
        }
      }
      const parent = path.dirname(cur);
      if (parent === cur) return strict ? null : p;
      tail.unshift(path.basename(cur));
      cur = parent;
    }
  }
}

function scratchRoots() {
  const uid = typeof process.getuid === 'function' ? process.getuid() : null;
  if (uid === null) return [];
  const roots = ['/tmp', '/private/tmp'];
  const tmpdir = (process.env.TMPDIR || '').replace(/\/+$/, '');
  if (tmpdir && path.isAbsolute(tmpdir)) roots.push(tmpdir);
  return roots.map((r) => `${r}/claude-${uid}/`);
}

function isScratchPath(p, cwd) {
  if (!isLiteralPath(p)) return false;
  const abs = absolutize(p, cwd);
  if (!abs) return false;
  const resolved = canonicalize(path.resolve(abs), true);
  if (!resolved) return false;
  const inRoot = scratchRoots().some((root) => {
    try {
      const canonicalRoot = fs.realpathSync(root) + path.sep;
      return resolved.startsWith(canonicalRoot) && resolved.length > canonicalRoot.length;
    } catch { return false; }
  });
  if (!inRoot) return false;
  try {
    // A hard link to a file outside the root shares its inode.
    const st = fs.lstatSync(resolved);
    if (st.isFile() && st.nlink !== 1) return false;
  } catch { /* a new file has no inode yet */ }
  return true;
}

// Plan files and auto-memory: the built-in writes that stay open on Claude.
// Both the path and the roots resolve through symlinks.
function isHarnessOwnedPath(resolved, home) {
  const real = canonicalize(resolved, true);
  if (!real) return false;
  const claude = canonicalize(path.join(home, '.claude'), false);
  if (real.startsWith(path.join(claude, 'plans') + '/')) return true;
  const projects = path.join(claude, 'projects') + '/';
  if (!real.startsWith(projects)) return false;
  const rest = real.slice(projects.length).split('/');
  return rest.length >= 3 && rest[0] !== '' && rest[1] === 'memory';
}

function isSmallFile(p, cwd) {
  if (!isPlainPath(p) || (cwd === null && !path.isAbsolute(p))) return false;
  try {
    // Preserve symlink/.. traversal as the filesystem sees it.
    const target = path.isAbsolute(p) ? p : `${cwd || process.cwd()}/${p}`;
    const st = fs.statSync(target);
    return st.isFile() && st.size <= SMALL_FILE_BYTES;
  } catch {
    return false;
  }
}

function allScratch(files, cwd) {
  return files.length > 0 && files.every((f) => isScratchPath(f, cwd));
}

function allSmallFiles(files, cwd) {
  return files.length > 0 && files.every((f) => isSmallFile(f, cwd));
}

// A write-redirect writes a file unless its target is a stream device or a
// kernel interface. The device match is exact, so `/dev/shm/x` (a regular
// file) is a write. /proc and /sys writes (`echo 1 > /proc/sys/...`) pass,
// because tilth cannot write them. A `..` segment makes it a write, so
// `/dev/../tmp/x` and `/proc/../tmp/x` cannot escape. An fd duplication such
// as `>&2` has no target and never reaches this check.
const STREAM_DEVICES = new Set(['/dev/null', '/dev/stdout', '/dev/stderr', '/dev/tty']);
function isFileWrite(target, cwd) {
  if (!target) return false;
  if (isScratchPath(target, cwd)) return false;
  if (STREAM_DEVICES.has(target) || /^\/dev\/fd\/\d+$/.test(target)) return false;
  return !(/^\/(proc|sys)\//.test(target) && !target.split('/').includes('..'));
}

// True when any redirect of the segment (any fd) targets a real file.
function segWritesFile(seg, cwd) {
  return seg.redirectTargets.some((t) => isFileWrite(t, cwd));
}

module.exports = {
  isLiteralPath, canonicalize, isScratchPath, isHarnessOwnedPath,
  allScratch, allSmallFiles, isFileWrite, segWritesFile,
};
