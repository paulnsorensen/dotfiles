'use strict';
// io.js — reroute module: file I/O via the shell.
//
//   write-redirect (`echo`/`printf`/`cat` … `>` / `>>`) to a file    → DENY → tilth_write
//   `tee FILE` fed by echo/printf/cat or a here-doc/here-string      → DENY → tilth_write
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
// `cmd | tee log` captures command output, like `cmd > log`, and runs.
//
// Two exemptions let a command run unchanged. First, Claude's session scratch
// directory (<tmp>/claude-<uid>/, see exempt.js): every write, tee, read, and
// in-place edit there runs, because the harness owns it and it is not part of
// the tree. A `..` segment or a shell expansion never counts as scratch.
// Second, a plain read runs when every target is an existing regular file of
// at most 16 KiB and the segment writes no file (no file redirect, no sed
// `w`/`W`/`e` command, no `-i`). A directory, a missing file, an xargs feed,
// or a shell expansion keeps the deny.

const os = require('os');
const path = require('path');
const { commandsWithCwd, commandWord, splitArgs, realFiles, pipedIn, inputFiles } = require('./shell');
const { allScratch, allSmallFiles, isFileWrite, segWritesFile } = require('./exempt');

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

// On Codex, native.js denies tilth_write outside the allowed roots.
function writeReason(target, cwd, harness, kind = 'write-redirect') {
  const p = suggestPath(target, cwd);
  const codex = harness === 'codex'
    ? ' On Codex, a path outside the allowed roots remains blocked. Ask the user before changing allowed roots.'
    : '';
  // The lexer ends a `$(mktemp)` target at `(`, so it records a bare `$`.
  const shown = target === '$' ? '$(…)' : target;
  return `Blocked: shell ${kind} to ${shown} — write files with mcp__tilth__tilth_write, not echo/printf/cat with > / >> or tee.

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
  if (!path.isAbsolute(f) && !cwd) return '<absolute path>';
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

// The first file a `tee` segment writes when it copies authored content: a
// pipe from echo/printf/cat, or a here-doc/here-string on its stdin. `tee`
// takes no valued short flags; `--output-error=MODE` is fused.
function teeTarget(segs, k, cwd) {
  const seg = segs[k];
  const { word, args } = commandWord(seg.argv);
  if (word !== 'tee') return null;
  const fromHeredoc = seg.inputRedirects.some((r) => r !== '<');
  const fromWriter = pipedIn(seg) && k > 0 && WRITE_BINS.has(commandWord(segs[k - 1].argv).word);
  if (!fromHeredoc && !fromWriter) return null;
  return splitArgs(args).operands.find((f) => f !== '-' && isFileWrite(f, cwd)) || null;
}

// `awk -i inplace` loads gawk's in-place library; `-i` takes the library name.
function awkInPlace(args) {
  return args.some((a, k) => (a === '-i' && args[k + 1] === 'inplace') || a === '-iinplace');
}

// Decode inline and valued scripts before granting a small-file exemption.
// A script file hides its effects, so it cannot qualify.
function readerScripts(word, args) {
  if (!/^(g?sed|[gm]?awk)$/.test(word)) return [];
  const scripts = [];
  const operands = [];
  const sed = /^(g?sed)$/.test(word);
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '--') { operands.push(...args.slice(i + 1)); break; }
    if (a === '-f' || a === '--file' || a.startsWith('--file=') || /^-[a-zA-Z]*f(?:.|$)/.test(a)) return null;
    const long = sed ? '--expression' : '--source';
    if (a === '-e' || a === long) { if (args[++i] === undefined) return null; scripts.push(args[i]); continue; }
    if (a.startsWith(long + '=')) { scripts.push(a.slice(long.length + 1)); continue; }
    const fused = sed ? /^-[nErus]*e(.*)$/.exec(a) : /^-e(.*)$/.exec(a);
    if (fused) {
      if (fused[1]) scripts.push(fused[1]);
      else if (args[++i] !== undefined) scripts.push(args[i]);
      else return null;
      continue;
    }
    if (!sed && a === '-i') return null;
    if (!sed && (a === '-v' || a === '-F' || a === '--assign' || a === '--field-separator')) { i++; continue; }
    if (sed && (/^-[nErus]+$/.test(a) || ['--quiet', '--silent', '--regexp-extended', '--unbuffered', '--separate'].includes(a))) continue;
    if (!sed && (/^-[Fv].+/.test(a) || a.startsWith('--assign=') || a.startsWith('--field-separator='))) continue;
    if (a.startsWith('-')) return null;
    operands.push(a);
  }
  if (!scripts.length) scripts.push(operands[0] || '');
  return scripts;
}

// A small-file script must fit a known read-only form. Other script effects
// can write files or run commands, so they keep the deny.
function sedScriptSafe(script) {
  const text = script.trim();
  if (/^(?:\d+(?:,\d+)?)?\s*[pPdDqQnN]$/.test(text)) return true;
  const start = /^(?:\d+(?:,\d+)?)?\s*s/.exec(text);
  if (!start) return false;
  const delimiter = text[start[0].length];
  if (!delimiter || /[\w\s]/.test(delimiter)) return false;
  let end = start[0].length + 1;
  for (let part = 0; part < 2; part++) {
    while (end < text.length && text[end] !== delimiter) {
      if (text[end] === '\\') end++;
      end++;
    }
    if (end >= text.length) return false;
    end++;
  }
  return /^[0-9gpiImM]*$/.test(text.slice(end));
}

function scriptUnsafe(word, args) {
  const scripts = readerScripts(word, args);
  if (scripts === null) return true;
  if (/^g?sed$/.test(word)) return !scripts.every(sedScriptSafe);
  if (/^[gm]?awk$/.test(word)) {
    return !scripts.every((script) => /^\s*\{\s*(?:print|printf)(?:\s+\$[0-9]+)?\s*\}\s*$/.test(script));
  }
  return false;
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
  const segs = commandsWithCwd((input && input.command) || '', cwd);

  // write-redirect: a stdout content write (`>`/`>>`, bare or `1>`) by a write
  // bin. An fd redirect (`2>`, `N>`, `2>&1`) writes no file content, so it must
  // NOT deny a command like `make 2>/dev/null`. `&>` and `>|` write stdout.
  for (const seg of segs) {
    if (seg.redirects.length === 0) continue;
    const { word } = commandWord(seg.argv);
    if (!word || !WRITE_BINS.has(word)) continue;
    for (let j = 0; j < seg.redirectFds.length; j++) {
      const fd = seg.redirectFds[j];
      if ((fd === null || fd === '1') && isFileWrite(seg.redirectTargets[j], seg.cwd)) {
        return { reason: writeReason(seg.redirectTargets[j], seg.cwd, harness), module: 'io' };
      }
    }
  }

  for (let k = 0; k < segs.length; k++) {
    const target = teeTarget(segs, k, segs[k].cwd);
    if (target) return { reason: writeReason(target, segs[k].cwd, harness, 'tee write'), module: 'io' };
  }

  for (const seg of segs) {
    const { word, args, xargs } = commandWord(seg.argv);
    const spec = word && Object.hasOwn(READERS, word) && READERS[word];
    if (!spec) continue;
    const hit = readTargets(seg, spec, args, xargs);
    if (!hit) continue;
    if (allScratch(hit.files, seg.cwd)) continue;
    // The small-file exemption covers a plain read only.
    if (!hit.inPlace && !segWritesFile(seg, seg.cwd) && !scriptUnsafe(word, args)
        && allSmallFiles(hit.files, seg.cwd)) continue;
    const hintCwd = seg.cwd;
    const reason = hit.inPlace ? editReason(word, hit.files, hintCwd) : readReason(word, hit.files, hintCwd);
    return { reason, module: 'io' };
  }
  return null;
}

module.exports = { detect };
