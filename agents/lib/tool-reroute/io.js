'use strict';
// io.js — reroute module: file I/O via the shell.
//
//   write-redirect (`echo`/`printf`/`cat` … `>` / `>>`) to a file    → DENY → tilth_write
//   file read by cat/head/tail/less/more/nl/tac/bat/sed/awk          → DENY → tilth_read
//   in-place edit (`sed -i`)                                          → DENY → tilth_write
//
// A hook's updatedInput can't turn a Bash command into an MCP tool call, so
// every hit denies with the tilth MCP call to make instead. The deny applies
// to every file, in the tree or outside it (for example /tmp), because tilth
// takes absolute paths. A reader that filters a pipe or a here-doc reads no
// file and runs unchanged, as does `tail -f` (a live stream tilth_read cannot
// follow) and a read of /dev, /proc, or /sys. A write-redirect to a stream
// device (/dev/null, /dev/stderr, /dev/fd/N) or to /proc or /sys runs. A `>`
// inside a quoted string is not a redirect (the lexer resolves quotes).

const os = require('os');
const path = require('path');
const { commands, commandWord, splitArgs, realFiles, inputFiles } = require('./shell');

const WRITE_BINS = new Set(['echo', 'printf', 'cat']);

// Per-binary option grammar for file readers. `script` readers (sed, awk) take
// their program as the first operand unless a script flag supplies it.
const READERS = {
  cat: { valuedShort: '' },
  tac: { valuedShort: 's', valuedLong: ['--separator'] },
  head: { valuedShort: 'nc', valuedLong: ['--lines', '--bytes'] },
  tail: { valuedShort: 'ncs', valuedLong: ['--lines', '--bytes', '--sleep-interval', '--pid', '--max-unchanged-stats'], follow: ['-f', '-F', '--follow', '--retry'], plusOperands: true },
  less: { valuedShort: 'bhjkoOpPtTxyz#', plusOperands: true },
  more: { valuedShort: 'n', plusOperands: true },
  nl: { valuedShort: 'bdfhilnsvw' },
  bat: { valuedShort: 'lHmr', valuedLong: ['--language', '--highlight-line', '--line-range', '--style', '--theme', '--tabs', '--wrap', '--map-syntax', '--file-name', '--color', '--paging', '--decorations', '--italic-text', '--terminal-width'] },
  sed: { valuedShort: 'efl', valuedLong: ['--expression', '--file', '--line-length'], script: ['-e', '-f', '--expression', '--file'], inPlace: ['-i', '--in-place'] },
  awk: { valuedShort: 'Fvfei', libInPlace: true, valuedLong: ['--field-separator', '--assign', '--file', '--source'], script: ['-f', '-e', '--file', '--source'] },
};
READERS.batcat = READERS.bat;
READERS.gawk = READERS.awk;
READERS.mawk = READERS.awk;
READERS.gsed = READERS.sed;

// On Codex, native.js denies a tilth_write outside the allowed roots, so the
// hint names the variable that adds a root.
function writeReason(target, cwd, harness) {
  const p = suggestPath(target, cwd);
  const codex = harness === 'codex'
    ? ' On Codex, a path outside the checkout, /tmp, and .cheese/ also needs its root in DOTFILES_WRITE_GUARD_ALLOW.'
    : '';
  // The lexer ends a `$(mktemp)` target at `(`, so it records a bare `$`.
  const shown = target === '$' ? '$(…)' : target;
  return `Blocked: shell write-redirect to ${shown} — write files with mcp__tilth__tilth_write, not echo/printf/cat with > / >>.

New file (omit tag):
  mcp__tilth__tilth_write(edits:[{path:${JSON.stringify(p)}, ops:[{op:"create_file", content:"…"}]}], cwd:"<checkout>")

Existing file: tilth_read the section first to get the [path#TAG], then edit the displayed lines with that TAG (replace_text, replace, insert_after). create_file fails on an existing path.

This applies outside the checkout too (for example /tmp): use an absolute path.${codex}`;
}

// tilth refuses `..` in a relative path, so a parent-relative file becomes
// absolute. A leading `~` expands to HOME, because the hint asks for an
// absolute path. A path with a shell expansion anywhere (`$f`, `logs/$name`,
// `$(…)`, a backtick) has no literal value, so the hint shows a placeholder.
function suggestPath(f, cwd) {
  if (/[$`]/.test(f)) return '<absolute path>';
  if (f === '~' || f.startsWith('~/')) return os.homedir() + f.slice(1);
  return cwd && f.split('/').includes('..') ? path.resolve(cwd, f) : f;
}

function readReason(word, files, cwd) {
  const paths = files.map((f) => JSON.stringify(suggestPath(f, cwd))).join(', ');
  return `Blocked: \`${word}\` reads ${files.join(', ')} — use tilth_read, not a shell reader.

Run instead:
  mcp__tilth__tilth_read(paths:[${paths}], cwd:"<checkout>")

Append #start-end or #symbol to a path to read one section. Use an absolute path for a file outside the checkout. Filters on command output (\`git log | head\`) still run.`;
}

function editReason(word, files, cwd) {
  return `Blocked: \`${word} -i\` edits ${files.join(', ')} in place — use tilth_write.

tilth_read the file first to get the [path#TAG], then:
  mcp__tilth__tilth_write(edits:[{path:${JSON.stringify(suggestPath(files[0], cwd))}, tag:"<TAG>", ops:[{op:"replace_text", old:"…", new:"…"}]}], cwd:"<checkout>")`;
}

// A write-redirect writes a file unless its target is a stream device or a
// kernel interface. The device match is exact, so `/dev/shm/x` (a regular
// file) denies. /proc and /sys writes (`echo 1 > /proc/sys/...`) pass,
// because tilth cannot write them; the reader side exempts them too. A `..`
// segment denies, so `/dev/../tmp/x` and `/proc/../tmp/x` cannot escape.
// An fd duplication such as `>&2` has no target and never reaches this check.
const STREAM_DEVICES = new Set(['/dev/null', '/dev/stdout', '/dev/stderr', '/dev/tty']);
function isFileWrite(target) {
  if (!target) return false;
  if (STREAM_DEVICES.has(target) || /^\/dev\/fd\/\d+$/.test(target)) return false;
  return !(/^\/(proc|sys)\//.test(target) && !target.split('/').includes('..'));
}

// `awk -i inplace` loads gawk's in-place library; `-i` takes the library name.
function awkInPlace(args) {
  return args.some((a, k) => (a === '-i' && args[k + 1] === 'inplace') || a === '-iinplace');
}

// The files a reader segment reads, plus whether it edits them in place. With
// `xargs`, stdin supplies more file operands than the command line shows.
function readTargets(seg, spec, args, xargs) {
  const { flags, operands: allOperands } = splitArgs(args, new Set(spec.valuedShort), new Set(spec.valuedLong || []));
  if ((spec.follow || []).some((f) => flags.has(f))) return null;
  const inPlace = (spec.inPlace || []).some((f) => flags.has(f)) || (spec.libInPlace && awkInPlace(args));
  let operands = spec.plusOperands ? allOperands.filter((f) => !f.startsWith('+')) : allOperands; // `tail +5`, `less +F`
  const scriptGiven = (spec.script || []).some((f) => flags.has(f));
  if (spec.inPlace && inPlace && !scriptGiven && operands[0] === '') operands = operands.slice(1); // macOS `sed -i ''`
  let files = spec.script && !scriptGiven ? operands.slice(1) : operands;
  if (spec.script) files = files.filter((f) => !/^[A-Za-z_][A-Za-z0-9_]*=/.test(f)); // awk var=value
  files = [...realFiles(files), ...inputFiles(seg)];
  if (!files.length) {
    if (!xargs) return null;
    files = ['(files from xargs)'];
  }
  return { files, inPlace };
}

function detect(toolName, input, cwd, harness) {
  if (toolName !== 'Bash') return null;
  cwd = cwd || process.cwd();
  const segs = commands((input && input.command) || '');

  // write-redirect: a stdout content write (`>`/`>>`, bare or `1>`) by a write
  // bin. An fd redirect (`2>`, `N>`, `2>&1`) writes no file content, so it must
  // NOT deny a command like `make 2>/dev/null`. `&>` and `>|` write stdout.
  for (const seg of segs) {
    if (seg.redirects.length === 0) continue;
    const { word } = commandWord(seg.argv);
    if (!word || !WRITE_BINS.has(word)) continue;
    for (let j = 0; j < seg.redirectFds.length; j++) {
      const fd = seg.redirectFds[j];
      if ((fd === null || fd === '1') && isFileWrite(seg.redirectTargets[j])) {
        return { reason: writeReason(seg.redirectTargets[j], cwd, harness), module: 'io' };
      }
    }
  }

  for (const seg of segs) {
    const { word, args, xargs } = commandWord(seg.argv);
    const spec = word && Object.hasOwn(READERS, word) && READERS[word];
    if (!spec) continue;
    const hit = readTargets(seg, spec, args, xargs);
    if (!hit) continue;
    const reason = hit.inPlace ? editReason(word, hit.files, cwd) : readReason(word, hit.files, cwd);
    return { reason, module: 'io' };
  }
  return null;
}

module.exports = { detect };
