'use strict';
// io.js — reroute module: file I/O via the shell.
//
//   bare `cat <file>` (no redirect, no pipe, one file operand)  → REWRITE `tilth <file>`
//   write-redirect (`echo`/`printf`/`cat` … `>` / `>>`)         → DENY → cheez-write
//
// The bare-cat read has a faithful tilth equivalent, so it rewrites. A
// write-redirect to a working-tree file has no shell write CLI to rewrite to (a
// hook's updatedInput can't turn a Bash command into the tilth_write MCP tool),
// so it denies with a cheez-write message; /dev/null and out-of-tree targets
// (e.g. /tmp scratch) have no tilth_write equivalent, so they delegate rather
// than hard-deny a legitimate non-repo write. It must NOT fire on `echo foo`
// (no redirect) or claim a
// read on `cat file | grep …` (a pipe — that is search's territory, and the
// bare-read path requires a single segment). A `>` inside a quoted string is
// not a redirect (the lexer resolves quotes), so `echo "a > b"` passes through.

const path = require('path');
const { parse, commandWord, shQuote } = require('./shell');

const WRITE_BINS = new Set(['echo', 'printf', 'cat']);

function writeReason(target) {
  const path = target || '<file>';
  return `Blocked: shell write-redirect to ${path} — use the cheez-write skill (tilth_write), not echo/printf/cat with > / >>.

New file (seed — omit tag):
  mcp__tilth__tilth_write(edits:[{path:${JSON.stringify(path)}, ops:[{op:"prepend", content:"…"}]}], cwd:"…")

Existing file: tilth_read first to get the [path#TAG], then tag-anchored ops (replace/insert_before/insert_after) on the numbered lines.`;
}

// A write-redirect only needs cheez-write when it targets a file in the working
// tree. /dev/null and absolute paths outside cwd resolve elsewhere, so they
// delegate rather than hard-deny a legitimate non-repo write.
function isRepoWrite(target, cwd) {
  if (!target || target === '/dev/null') return false;
  const resolved = path.resolve(cwd, target);
  return resolved === cwd || resolved.startsWith(cwd + path.sep);
}

function detect(toolName, input, cwd) {
  if (toolName !== 'Bash') return null;
  cwd = cwd || process.cwd();
  const segs = parse((input && input.command) || '');

  // write-redirect: a stdout content write (`>`/`>>`, bare or `1>`) by a write
  // bin. An fd redirect (`2>`, `N>`, `2>&1`) writes no file content, so it must
  // NOT hard-deny a legitimate read like `cat f 2>/dev/null` — let it delegate
  // rather than block. `&>` splits on `&` and delegates too.
  for (const seg of segs) {
    if (seg.redirects.length === 0) continue;
    const { word } = commandWord(seg.argv);
    if (!word || !WRITE_BINS.has(word)) continue;
    const i = seg.redirectFds.findIndex((fd) => fd === null || fd === '1');
    if (i !== -1 && isRepoWrite(seg.redirectTargets[i], cwd)) {
      return { reason: writeReason(seg.redirectTargets[i]) };
    }
  }

  // bare `cat <file>`: exactly one segment (no pipe), no redirect, one operand.
  if (segs.length === 1 && segs[0].redirects.length === 0) {
    const { word, args } = commandWord(segs[0].argv);
    if (word === 'cat' && args.length === 1 && !args[0].startsWith('-')) {
      return { rewrite: `tilth ${shQuote(args[0])}` };
    }
  }
  return null;
}

module.exports = { detect };
