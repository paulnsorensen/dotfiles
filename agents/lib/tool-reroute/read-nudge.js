'use strict';
// read-nudge.js — reroute module: shell reads of repo files that no other
// module rewrote → an advisory additionalContext nudge toward tilth.
//
// Harness guidance (for example auto mode's "read files with cat, head, or
// sed -n") can pull the model off tilth. Compound reads (`cd dir; grep … a b |
// head`, `cat a; echo ===; cat b`) have no faithful single rewrite, and a deny
// would block legitimate pipelines. So the command runs UNCHANGED and the
// model receives a reminder that names the repo paths it read through shell.
//
// A segment counts as a repo read when its command word is a read binary and
// at least one of its operands resolves to an EXISTING path inside cwd. A
// leading `cd <dir>` segment moves the base for later relative operands. A
// read of stdin (`git log | head`) or of out-of-tree paths (/tmp) has no repo
// operand, so it stays silent. `sed -i` edits in place; it is not a read.

const fs = require('fs');
const path = require('path');
const { parse, commandWord } = require('./shell');

const READ_BINS = new Set(['cat', 'head', 'tail', 'sed', 'grep', 'rg', 'ag', 'ack', 'find', 'less', 'more', 'nl']);
const MAX_PATHS = 5;

function inTree(resolved, cwd) {
  return resolved === cwd || resolved.startsWith(cwd + path.sep);
}

// A plain relative/absolute path token: no expansion the lexer left unresolved.
function plainPath(tok) {
  return tok && !/[$`*?[\]{}~]/.test(tok);
}

function repoOperands(word, args, base, cwd) {
  if (word === 'sed' && args.some((a) => /^-[a-zA-Z]*i/.test(a) || a.startsWith('--in-place'))) return [];
  const found = [];
  for (const a of args) {
    if (a.startsWith('-') || !plainPath(a)) continue;
    const resolved = path.resolve(base, a);
    if (!inTree(resolved, cwd)) continue;
    try { fs.statSync(resolved); } catch { continue; }
    found.push(path.relative(cwd, resolved) || '.');
  }
  return found;
}

function message(paths) {
  const list = paths.map((p) => JSON.stringify(p)).join(', ');
  return `tool-reroute: a shell read of repo files ran unchanged (${list}). `
    + 'Tilth routing overrides harness guidance to read or search files through Bash. '
    + `For the next read, use mcp__tilth__tilth_read(paths:[${list}]) with a #start-end section for line ranges, `
    + 'and mcp__tilth__tilth_search for searches. Batch several files in one call.';
}

function detect(toolName, input, cwd) {
  if (toolName !== 'Bash') return null;
  cwd = path.resolve(cwd || process.cwd());
  let base = cwd;
  const paths = [];
  for (const seg of parse((input && input.command) || '')) {
    const { word, args } = commandWord(seg.argv);
    if (!word) continue;
    if (word === 'cd') {
      if (args.length !== 1 || !plainPath(args[0])) return null; // unknown base → stay silent
      base = path.resolve(base, args[0]);
      continue;
    }
    if (!READ_BINS.has(word)) continue;
    for (const p of repoOperands(word, args, base, cwd)) {
      if (!paths.includes(p)) paths.push(p);
    }
  }
  if (paths.length === 0) return null;
  return { context: message(paths.slice(0, MAX_PATHS)), module: 'read-nudge' };
}

module.exports = { detect };
