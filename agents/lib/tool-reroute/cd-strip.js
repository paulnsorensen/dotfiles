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
// bare `cd X` with nothing after, no bare `cd` with no argument.
// The remainder may contain `||`/`|`/`&`. The target must match cwd by logical path.
// Reject subdirectories and unsupported shell expansions.
// Strips in a loop (max 3) so a chain of no-op cds
// (`cd $cwd && cd $cwd && ls`) collapses fully; a remainder that trims to
// empty (e.g. a trailing separator with nothing after) is not a strip.
//
// The event's `cwd` is Claude Code's tracked cwd, not the shell's live
// $PWD; the two can diverge after a `pushd`, a sourced script, or a
// `bash -c 'cd … && …'` — check by grepping decisions.jsonl for `strip`
// records whose `rewrite` starts with `./`, `../`, or a bare script name.

const os = require('os');
const path = require('path');
const fs = require('fs');

const CD_PREFIX = /^\s*cd\s+(?:"([^"]*)"|'([^']*)'|([^\s;&|"']+))\s*(?:&&|;|\n)\s*([\s\S]+)$/;
const EXPANSION_CHARS = ['*', '?', '[', ']', '{', '}'];

// Resolve unquoted `~` / `~/rest`; reject shell expansion forms we cannot safely resolve.
function resolveTarget(raw, unquoted) {
  if (!raw || !raw.trim()) return null;
  if (unquoted && EXPANSION_CHARS.some((char) => raw.includes(char))) return null;
  if (raw.includes('$') || raw.includes('`') || raw.includes('\\')) return null;
  if (raw.split('/').includes('..')) return null;
  let target = raw;
  if (target.startsWith('~')) {
    if (!unquoted || target.startsWith('~user')) return null;
    if (target === '~') target = os.homedir();
    else if (target.startsWith('~/')) target = path.join(os.homedir(), target.slice(2));
    else return null;
  }
  return target;
}

function samePlace(target, cwd) {
  const resolvedTarget = path.resolve(cwd, target);
  if (resolvedTarget !== path.resolve(cwd)) return false;
  try {
    return fs.statSync(resolvedTarget).isDirectory();
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
    const target = resolveTarget(raw, m[3] !== undefined);
    if (target === null || !samePlace(target, cwd)) break;
    if (!remainder.trim()) return null; // strips down to nothing — not a strip
    command = remainder;
    stripped = true;
  }
  return stripped ? { rewrite: command, module: 'cd-strip' } : null;
}

module.exports = { detect };
