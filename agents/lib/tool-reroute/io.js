'use strict';
// io.js — reroute module: file I/O via the shell.
//
//   bare `cat <file>` (no redirect, no pipe, one file operand)  → REWRITE `tilth <file>`
//   write-redirect (`echo`/`printf`/`cat`/`tee` … `>` / `>>`)   → DENY → cheez-write
//
// The bare-cat read has a faithful tilth equivalent, so it rewrites. A
// write-redirect has no tilth write CLI (ADR-004), so it denies with a
// cheez-write message. It must NOT fire on `echo foo` (no redirect) or claim a
// read on `cat file | grep …` (a pipe — that is search's territory, and the
// bare-read path requires a single segment). A `>` inside a quoted string is
// not a redirect (the lexer resolves quotes), so `echo "a > b"` passes through.

const { parse, commandWord, shQuote } = require('./shell');

const WRITE_BINS = new Set(['echo', 'printf', 'cat', 'tee']);

function writeReason(target) {
  const path = target || '<file>';
  return `Blocked: shell write-redirect to ${path} — use the cheez-write skill (tilth_write), not echo/printf/cat/tee with > / >>.

Run instead (whole-file create/overwrite):
  mcp__tilth__tilth_write(files:[{path:${JSON.stringify(path)}, mode:"overwrite", overwrite:true, content:"…"}])

For a surgical change, tilth_read first for hash anchors, then a hash-mode edit.`;
}

function detect(toolName, input) {
  if (toolName !== 'Bash') return null;
  const segs = parse((input && input.command) || '');

  // write-redirect: a stdout content write (`>`/`>>`, bare or `1>`) by a write
  // bin. An fd redirect (`2>`, `N>`, `2>&1`) writes no file content, so it must
  // NOT hard-deny a legitimate read like `cat f 2>/dev/null` — let it delegate
  // (ADR-002 never-hard-block). `&>` splits on `&` and delegates too.
  for (const seg of segs) {
    if (seg.redirects.length === 0) continue;
    const { word } = commandWord(seg.argv);
    if (!word || !WRITE_BINS.has(word)) continue;
    const i = seg.redirectFds.findIndex((fd) => fd === null || fd === '1');
    if (i !== -1) return { reason: writeReason(seg.redirectTargets[i]) };
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
