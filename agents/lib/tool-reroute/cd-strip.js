'use strict';
// cd-strip.js — reroute module: strip a leading `cd <path> &&`/`;`/newline
// prefix that targets the event's own cwd, leaving the remainder for the
// other modules to classify. This is the case none of search/cd-git/io
// handle: a plain `cd $CWD && <anything>` compound where the cd is a no-op
// (the shell already starts in cwd) but still trips Claude Code's
// bare-repository-attack heuristic on `cd`.
//
// Only the clean two-part shape on the RAW command string matches: `||`,
// `|`, `&` are refused only as the SEPARATOR immediately after `cd` — no
// bare `cd X` with nothing after, no bare `cd` with no argument. The
// remainder itself may freely contain `||`/`|`/`&`. The target must resolve
// (by literal path or realpath) to cwd; anything else (a subdirectory, an
// unrelated path, an unexpandable target carrying `$`/backticks or
// `~user`) is left alone. Strips in a loop (max 3) so a chain of no-op cds
// (`cd $cwd && cd $cwd && ls`) collapses fully; a remainder that trims to
// empty (e.g. a trailing separator with nothing after) is not a strip.

const os = require('os');
const path = require('path');
const fs = require('fs');

const CD_PREFIX = /^\s*cd\s+(?:"([^"]*)"|'([^']*)'|([^\s;&|"']+))\s*(?:&&|;|\n)\s*([\s\S]+)$/;

// Resolve `~` / `~/rest` via the real home dir; reject `$`/backtick
// expansion targets and `~user` forms this module cannot safely resolve.
function resolveTarget(raw) {
  if (raw.includes('$') || raw.includes('`')) return null;
  let target = raw;
  if (target === '~') target = os.homedir();
  else if (target.startsWith('~/')) target = path.join(os.homedir(), target.slice(2));
  else if (target.startsWith('~')) return null; // ~user — not resolvable here
  while (target.length > 1 && target.endsWith('/')) target = target.slice(0, -1);
  return target;
}

function samePlace(target, cwd) {
  if (path.resolve(cwd, target) === path.resolve(cwd)) return true;
  try {
    return fs.realpathSync(path.resolve(cwd, target)) === fs.realpathSync(cwd);
  } catch {
    return false;
  }
}

const MAX_ITERATIONS = 3;

function detect(toolName, input, cwd) {
  if (toolName !== 'Bash') return null;
  cwd = cwd || process.cwd();
  let command = (input && input.command) || '';
  let stripped = false;
  for (let i = 0; i < MAX_ITERATIONS; i++) {
    const m = CD_PREFIX.exec(command);
    if (!m) break;
    const raw = m[1] !== undefined ? m[1] : m[2] !== undefined ? m[2] : m[3];
    const remainder = m[4];
    const target = resolveTarget(raw);
    if (target === null || !samePlace(target, cwd)) break;
    if (!remainder.trim()) return null; // strips down to nothing — not a strip
    command = remainder;
    stripped = true;
  }
  return stripped ? { rewrite: command, module: 'cd-strip' } : null;
}

module.exports = { detect };
