'use strict';
// io.js — reroute module: file I/O via the shell.
//
//   write-redirect (`echo`/`printf`/`cat` … `>` / `>>`) into the tree → DENY → tilth_write
//   file read by cat/head/tail/less/more/nl/tac/bat/sed/awk          → DENY → tilth_read
//   in-place edit (`sed -i`)                                          → DENY → tilth_write
//
// A hook's updatedInput can't turn a Bash command into an MCP tool call, so
// every hit denies with the tilth MCP call to make instead. A reader that
// filters a pipe or a here-doc reads no file and runs unchanged, as does
// `tail -f` (a live stream tilth_read cannot follow) and a read of /dev,
// /proc, or /sys. A write-redirect to /dev/null or outside the cwd (e.g. /tmp
// scratch) delegates rather than hard-denying a legitimate non-repo write. A
// `>` inside a quoted string is not a redirect (the lexer resolves quotes).

const path = require('path');
const { parse, commandWord, splitArgs, realFiles, inputFiles } = require('./shell');

const WRITE_BINS = new Set(['echo', 'printf', 'cat']);

// Per-binary option grammar for file readers. `script` readers (sed, awk) take
// their program as the first operand unless a script flag supplies it.
const READERS = {
  cat: { valuedShort: '' },
  tac: { valuedShort: 's', valuedLong: ['--separator'] },
  head: { valuedShort: 'nc', valuedLong: ['--lines', '--bytes'] },
  tail: { valuedShort: 'ncs', valuedLong: ['--lines', '--bytes', '--sleep-interval', '--pid', '--max-unchanged-stats'], follow: ['-f', '-F', '--follow', '--retry'] },
  less: { valuedShort: 'bhjkoOpPtTxyz#' },
  more: { valuedShort: 'n' },
  nl: { valuedShort: 'bdfhilnsvw' },
  bat: { valuedShort: 'lHmr', valuedLong: ['--language', '--highlight-line', '--line-range', '--style', '--theme', '--tabs', '--wrap', '--map-syntax', '--file-name', '--color', '--paging', '--decorations', '--italic-text', '--terminal-width'] },
  sed: { valuedShort: 'efl', valuedLong: ['--expression', '--file', '--line-length'], script: ['-e', '-f', '--expression', '--file'], inPlace: ['-i', '--in-place'] },
  awk: { valuedShort: 'Fvfe', valuedLong: ['--field-separator', '--assign', '--file', '--source'], script: ['-f', '-e', '--file', '--source'] },
};
READERS.batcat = READERS.bat;
READERS.gawk = READERS.awk;
READERS.mawk = READERS.awk;

function writeReason(target) {
  const p = target || '<file>';
  return `Blocked: shell write-redirect to ${p} — use tilth_write, not echo/printf/cat with > / >>.

New file (seed — omit tag):
  mcp__tilth__tilth_write(edits:[{path:${JSON.stringify(p)}, ops:[{op:"create_file", content:"…"}]}], cwd:"<checkout>")

Existing file: tilth_read first to get the [path#TAG], then tag-anchored ops (replace/insert_before/insert_after) on the numbered lines.`;
}

function readReason(word, files) {
  const paths = files.map((f) => JSON.stringify(f)).join(', ');
  return `Blocked: \`${word}\` reads ${files.join(', ')} — use tilth_read, not a shell reader.

Run instead:
  mcp__tilth__tilth_read(paths:[${paths}], cwd:"<checkout>")

Append #start-end or #symbol to a path to read one section. Filters on command output (\`git log | head\`) still run.`;
}

function editReason(word, files) {
  return `Blocked: \`${word} -i\` edits ${files.join(', ')} in place — use tilth_write.

tilth_read the file first to get the [path#TAG], then:
  mcp__tilth__tilth_write(edits:[{path:${JSON.stringify(files[0])}, tag:"<TAG>", ops:[{op:"replace_text", old:"…", new:"…"}]}], cwd:"<checkout>")`;
}

// A write-redirect only needs tilth_write when it targets a file in the working
// tree. /dev/null and absolute paths outside cwd resolve elsewhere, so they
// delegate rather than hard-deny a legitimate non-repo write.
function isRepoWrite(target, cwd) {
  if (!target || target === '/dev/null') return false;
  const resolved = path.resolve(cwd, target);
  return resolved === cwd || resolved.startsWith(cwd + path.sep);
}

// The files a reader segment reads, plus whether it edits them in place.
function readTargets(seg, spec, args) {
  const { flags, operands } = splitArgs(args, new Set(spec.valuedShort), new Set(spec.valuedLong || []));
  if ((spec.follow || []).some((f) => flags.has(f))) return null;
  const scriptGiven = (spec.script || []).some((f) => flags.has(f));
  let files = spec.script && !scriptGiven ? operands.slice(1) : operands;
  if (spec.script) files = files.filter((f) => !/^[A-Za-z_][A-Za-z0-9_]*=/.test(f)); // awk var=value
  files = [...realFiles(files), ...inputFiles(seg)];
  if (!files.length) return null;
  return { files, inPlace: (spec.inPlace || []).some((f) => flags.has(f)) };
}

function detect(toolName, input, cwd) {
  if (toolName !== 'Bash') return null;
  cwd = cwd || process.cwd();
  const segs = parse((input && input.command) || '');

  // write-redirect: a stdout content write (`>`/`>>`, bare or `1>`) by a write
  // bin. An fd redirect (`2>`, `N>`, `2>&1`) writes no file content, so it must
  // NOT deny a command like `make 2>/dev/null`. `&>` splits on `&` and delegates.
  for (const seg of segs) {
    if (seg.redirects.length === 0) continue;
    const { word } = commandWord(seg.argv);
    if (!word || !WRITE_BINS.has(word)) continue;
    const i = seg.redirectFds.findIndex((fd) => fd === null || fd === '1');
    if (i !== -1 && isRepoWrite(seg.redirectTargets[i], cwd)) {
      return { reason: writeReason(seg.redirectTargets[i]), module: 'io' };
    }
  }

  for (const seg of segs) {
    const { word, args } = commandWord(seg.argv);
    const spec = word && READERS[word];
    if (!spec) continue;
    const hit = readTargets(seg, spec, args);
    if (!hit) continue;
    const reason = hit.inPlace ? editReason(word, hit.files) : readReason(word, hit.files);
    return { reason, module: 'io' };
  }
  return null;
}

module.exports = { detect };
