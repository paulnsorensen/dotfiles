'use strict';
// io.js — reroute module: file I/O via the shell.
//
//   bare `cat <file>` (no redirect, no pipe, one file operand)  → REWRITE `tilth <file>`
//   write-redirect (`echo`/`printf`/`cat` … `>` / `>>`)         → DENY → tilth_write
//
// The bare-cat read has a faithful tilth equivalent, so it rewrites. A
// write-redirect to a working-tree file has no shell write CLI to rewrite to (a
// hook's updatedInput can't turn a Bash command into the tilth_write MCP tool),
// so it denies with a tilth_write message; /dev/null and out-of-tree targets
// (e.g. /tmp scratch) have no tilth_write equivalent, so they delegate rather
// than hard-deny a legitimate non-repo write. It must NOT fire on `echo foo`
// (no redirect) or claim a
// read on `cat file | grep …` (a pipe — that is search's territory, and the
// bare-read path requires a single segment). A `>` inside a quoted string is
// not a redirect (the lexer resolves quotes), so `echo "a > b"` passes through.

const os = require('os');
const path = require('path');
const { parse, commandWord, shQuote } = require('./shell');

const WRITE_BINS = new Set(['echo', 'printf', 'cat']);

function writeReason(target) {
  const path = target || '<file>';
  return `Blocked: shell write-redirect to ${path} — write workspace files with mcp__tilth__tilth_write, not echo/printf/cat with > / >>.

New file (omit tag):
  mcp__tilth__tilth_write(edits:[{path:${JSON.stringify(path)}, ops:[{op:"create_file", content:"…"}]}], cwd:"…")

Existing file: tilth_read the section first to get the [path#TAG], then edit the displayed lines with that TAG (replace_text, replace, insert_after). create_file fails on an existing path.

Out-of-tree scratch (for example /tmp) may still use a shell redirect.`;
}

const ASSIGNMENT = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/;
const LEADING_VAR = /^\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))/;

// Resolve a leading `$NAME` / `${NAME}` from the tracked variables, or a leading
// `$(pwd)` as cwd. Return null when the target starts with an expansion the hook
// cannot know (an unknown variable, another `$(...)`, or a backtick): its real
// path may sit outside the tree, so the hook delegates instead of a false deny.
function expandTarget(target, vars, cwd) {
  if (!target.startsWith('$') && !target.startsWith('`')) return target;
  if (target.startsWith('$(pwd)')) return cwd + target.slice('$(pwd)'.length);
  const m = LEADING_VAR.exec(target);
  if (!m) return null;
  const value = vars.get(m[1] || m[2]);
  if (value === undefined || value.includes('$') || value.includes('`')) return null;
  return value + target.slice(m[0].length);
}

function expandTilde(value) {
  if (value === '~' || value.startsWith('~/')) return os.homedir() + value.slice(1);
  return value;
}

// Leading `NAME=value` words of a segment, as [name, value] pairs.
function leadingAssignments(argv) {
  const out = [];
  for (const word of argv) {
    const m = ASSIGNMENT.exec(word);
    if (!m) break;
    out.push([m[1], m[2]]);
  }
  return out;
}

// Track variables in execution order. Only an assignment-only segment persists
// its names; `D=x cmd` is command-local. Where the effect is uncertain (a
// pipeline, background, or &&/|| segment) the names are dropped, not set.
function applyAssignments(vars, segs, i) {
  const seg = segs[i];
  if (commandWord(seg.argv).word !== null) return;
  const next = segs[i + 1];
  const uncertain =
    ['|', '&', '&&', '||'].includes(seg.sep) || (next && (next.sep === '|' || next.sep === '&'));
  for (const [name, value] of leadingAssignments(seg.argv)) {
    if (uncertain) vars.delete(name);
    else vars.set(name, expandTilde(value));
  }
}

// A write-redirect only needs tilth_write when it targets a file in the working
// tree. /dev/null and absolute paths outside cwd resolve elsewhere, so they
// delegate rather than hard-deny a legitimate non-repo write.
function isRepoWrite(target, cwd, vars) {
  if (!target) return false;
  const expanded = expandTarget(target, vars, cwd);
  if (!expanded || expanded === '/dev/null') return false;
  const resolved = path.resolve(cwd, expanded);
  return resolved === cwd || resolved.startsWith(cwd + path.sep);
}

function detect(toolName, input, cwd) {
  if (toolName !== 'Bash') return null;
  cwd = cwd || process.cwd();
  const segs = parse((input && input.command) || '');
  const vars = new Map([
    ['PWD', cwd],
    ['CLAUDE_PROJECT_DIR', process.env.CLAUDE_PROJECT_DIR || cwd],
    ['HOME', os.homedir()],
  ]);

  // write-redirect: a stdout content write (`>`/`>>`, bare or `1>`) by a write
  // bin. An fd redirect (`2>`, `N>`, `2>&1`) writes no file content, so it must
  // NOT hard-deny a legitimate read like `cat f 2>/dev/null` — let it delegate
  // rather than block. `&>` splits on `&` and delegates too.
  // Each redirect resolves against the variables set BEFORE its own segment.
  for (let i = 0; i < segs.length; i++) {
    const seg = segs[i];
    if (seg.redirects.length > 0) {
      const { word } = commandWord(seg.argv);
      if (word && WRITE_BINS.has(word)) {
        const j = seg.redirectFds.findIndex((fd) => fd === null || fd === '1');
        if (j !== -1 && isRepoWrite(seg.redirectTargets[j], cwd, vars)) {
          return { reason: writeReason(seg.redirectTargets[j]), module: 'io' };
        }
      }
    }
    applyAssignments(vars, segs, i);
  }

  // bare `cat <file>`: exactly one segment (no pipe), no redirect, one operand.
  if (segs.length === 1 && segs[0].redirects.length === 0) {
    const { word, args } = commandWord(segs[0].argv);
    if (word === 'cat' && args.length === 1 && !args[0].startsWith('-')) {
      return { rewrite: `tilth ${shQuote(args[0])}`, module: 'io' };
    }
  }
  return null;
}

module.exports = { detect };
