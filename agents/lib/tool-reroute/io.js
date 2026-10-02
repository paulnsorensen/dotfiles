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
// scratch) delegates rather than hard-denying a legitimate non-repo write.
// A `$VAR` target resolves from the command's own assignments; an unknown
// expansion delegates. A `>` inside a quoted string is not a redirect (the
// lexer resolves quotes).

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

function writeReason(target) {
  const p = target || '<file>';
  return `Blocked: shell write-redirect to ${p} — write workspace files with mcp__tilth__tilth_write, not echo/printf/cat with > / >>.

New file (omit tag):
  mcp__tilth__tilth_write(edits:[{path:${JSON.stringify(p)}, ops:[{op:"create_file", content:"…"}]}], cwd:"<checkout>")

Existing file: tilth_read the section first to get the [path#TAG], then edit the displayed lines with that TAG (replace_text, replace, insert_after). create_file fails on an existing path.

Out-of-tree scratch (for example /tmp) may still use a shell redirect.`;
}

// tilth refuses `..` in a relative path, so a parent-relative file becomes absolute.
function suggestPath(f, cwd) {
  return f.split('/').includes('..') ? path.resolve(cwd, f) : f;
}

function readReason(word, files, cwd) {
  const paths = files.map((f) => JSON.stringify(suggestPath(f, cwd))).join(', ');
  return `Blocked: \`${word}\` reads ${files.join(', ')} — use tilth_read, not a shell reader.

Run instead:
  mcp__tilth__tilth_read(paths:[${paths}], cwd:"<checkout>")

Append #start-end or #symbol to a path to read one section. Filters on command output (\`git log | head\`) still run.`;
}

function editReason(word, files, cwd) {
  return `Blocked: \`${word} -i\` edits ${files.join(', ')} in place — use tilth_write.

tilth_read the file first to get the [path#TAG], then:
  mcp__tilth__tilth_write(edits:[{path:${JSON.stringify(suggestPath(files[0], cwd))}, tag:"<TAG>", ops:[{op:"replace_text", old:"…", new:"…"}]}], cwd:"<checkout>")`;
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

function detect(toolName, input, cwd) {
  if (toolName !== 'Bash') return null;
  cwd = cwd || process.cwd();
  const segs = commands((input && input.command) || '');
  const vars = new Map([
    ['PWD', cwd],
    ['CLAUDE_PROJECT_DIR', process.env.CLAUDE_PROJECT_DIR || cwd],
    ['HOME', os.homedir()],
  ]);

  // write-redirect: a stdout content write (`>`/`>>`, bare or `1>`) by a write
  // bin. An fd redirect (`2>`, `N>`, `2>&1`) writes no file content, so it must
  // NOT deny a command like `make 2>/dev/null`. `&>` and `>|` write stdout.
  // Each redirect resolves against the variables set BEFORE its own segment.
  for (let i = 0; i < segs.length; i++) {
    const seg = segs[i];
    if (seg.redirects.length > 0) {
      const { word } = commandWord(seg.argv);
      if (word && WRITE_BINS.has(word)) {
        for (let j = 0; j < seg.redirectFds.length; j++) {
          const fd = seg.redirectFds[j];
          if ((fd === null || fd === '1') && isRepoWrite(seg.redirectTargets[j], cwd, vars)) {
            return { reason: writeReason(seg.redirectTargets[j]), module: 'io' };
          }
        }
      }
    }
    applyAssignments(vars, segs, i);
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
