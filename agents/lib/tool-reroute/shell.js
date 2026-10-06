'use strict';
const fs = require('fs');
const path = require('path');
const { isLiteralPath } = require('./exempt');
// shell.js — a minimal shell-ish lexer shared by the tool-reroute modules.
//
// `parse(command)` splits a Bash command line into pipeline/command segments on
// UNQUOTED control operators (`|`, `||`, `&&`, `;`, `&`, newline, `(`, `)`) and,
// within each segment, separates redirection operators (`>`, `>>`, `<`, `<<`)
// from words. Single/double quotes and backslash escapes are resolved so a
// binary name, redirect, or operator that lives INSIDE a quoted string is never
// mistaken for the structural thing (`echo "a > b"` has no redirect; `echo
// "x && y"` is one segment; `echo grep` is not a grep invocation).
//
// This is the same conservative lexer shape as git-guard.js's tokenizeSegments,
// extended to surface redirects — the io module needs to tell a real
// write-redirect from a `>` inside a string, and the read modules need to tell
// a file read (`< file`) from stdin. The lexer skips here-doc bodies (`<<EOF` …
// `EOF`), so a body line never parses as a command. It parses the body of a
// here-doc fed to an interpreter (bash, sh, …) as commands. An unquoted `#` at
// token start begins a comment. Backticks and `$((…))` are handled; `$(…)`
// bounds a segment. It is NOT a full POSIX parser: no `${...}` expansion, no
// globbing. Unrecognized shapes fall
// through and the hook fails open (a rewrite hook must never DoS).
//
// Each returned segment is:
//   { argv: string[],          // command + args, quotes/escapes stripped
//     redirects: string[],      // unquoted output redirects seen: '>' / '>>'
//     redirectFds: (string|null)[],// fd qualifier per redirect: '1'/'2'/… for
//                               //   `1>`/`2>`, null for a bare `>` (stdout)
//     redirectTargets: string[],// the filename token after each `>` / `>>`
//     inputRedirects: string[], // unquoted input redirects: '<', '<<', '<<-', '<<<'
//     inputTargets: string[],   // the token after each input redirect (a file
//                               //   for '<', a here-doc delimiter or string otherwise)
//     sep: string|null }        // operator PRECEDING this segment ('|','&&',
//                               //   '||',';','&', or null for the first)

function parse(command) {
  const segments = [];
  let argv = [];
  let redirects = [];
  let redirectFds = [];
  let redirectTargets = [];
  let inputRedirects = [];
  let inputTargets = [];
  let heredocs = []; // pending { delim, stripTabs } bodies to skip at the next newline
  let sep = null; // operator preceding the CURRENT segment
  let cur = '';
  let hasTok = false; // an in-progress token exists
  let expectTarget = null; // 'out' | 'in' | 'heredoc' | 'heredoc-' — next token is a target

  const endTok = () => {
    if (!hasTok) return;
    if (expectTarget === 'out') redirectTargets.push(cur);
    else if (expectTarget === 'in') inputTargets.push(cur);
    else if (expectTarget) {
      inputTargets.push(cur);
      heredocs.push({ delim: cur, stripTabs: expectTarget === 'heredoc-', segIdx: segments.length });
    } else argv.push(cur);
    expectTarget = null;
    cur = '';
    hasTok = false;
  };
  const endSeg = (nextSep) => {
    endTok();
    segments.push({ argv, redirects, redirectFds, redirectTargets, inputRedirects, inputTargets, sep });
    argv = []; redirects = []; redirectFds = []; redirectTargets = [];
    inputRedirects = []; inputTargets = []; sep = nextSep;
    expectTarget = null;
  };

  let i = 0;
  const n = command.length;
  while (i < n) {
    const c = command[i];
    if (c === '\\') { // backslash escape outside quotes → next char literal
      if (i + 1 < n) { cur += command[i + 1]; hasTok = true; i += 2; } else i += 1;
      continue;
    }
    if (c === "'") { // single quotes: everything literal up to the next '
      hasTok = true; i += 1;
      while (i < n && command[i] !== "'") { cur += command[i]; i += 1; }
      if (i >= n) return [];
      i += 1;
      continue;
    }
    if (c === '"') { // double quotes: backslash escapes " \ $ `
      hasTok = true; i += 1;
      while (i < n && command[i] !== '"') {
        if (command[i] === '\\' && i + 1 < n && /["\\$`]/.test(command[i + 1])) {
          cur += command[i + 1]; i += 2;
        } else { cur += command[i]; i += 1; }
      }
      if (i >= n) return [];
      i += 1;
      continue;
    }
    if (c === ' ' || c === '\t') { endTok(); i += 1; continue; }
    if (c === '#' && !hasTok) { // comment: runs to end of line (a `#` inside a word is literal)
      while (i < n && command[i] !== '\n') i += 1;
      continue;
    }
    if (c === '\n') { // newline ends the segment, then reads any pending here-doc bodies
      endSeg(';'); i += 1;
      i = readHeredocs(command, i, heredocs, segments);
      heredocs = [];
      continue;
    }
    if (c === '(' && command[i + 1] === '(') { // arithmetic `((…))` / `$((…))` is one word
      let depth = 0;
      let j = i;
      for (; j < n; j += 1) {
        if (command[j] === '(') depth += 1;
        else if (command[j] === ')' && (depth -= 1) === 0) break;
      }
      if (j < n && command[j - 1] === ')') { cur += command.slice(i, j + 1); hasTok = true; i = j + 1; continue; }
    }
    if (c === '`') { cur += '`'; hasTok = true; endSeg(';'); i += 1; continue; }
    if (c === ';' || c === '(' || c === ')') { endSeg(';'); i += 1; continue; }
    if (c === '&' && command[i + 1] === '>') { endTok(); i += 1; continue; } // `&>` / `&>>` write stdout
    if (c === '|' || c === '&') { // a run of | / & is one operator boundary
      endTok();
      let op = c; i += 1;
      while (i < n && (command[i] === '|' || command[i] === '&')) { op += command[i]; i += 1; }
      endSeg(op);
      continue;
    }
    if (c === '>' || c === '<') { // redirection operator (collect a run: >>, <<, <<<)
      // an fd qualifier (`2>`, `1>`) is digits directly preceding `>` with no
      // space — capture it so io.js can tell a stdout write from an fd redirect.
      let fd = null;
      if (c === '>' && hasTok && /^[0-9]+$/.test(cur)) { fd = cur; cur = ''; hasTok = false; }
      endTok();
      let op = c; i += 1;
      while (i < n && command[i] === c) { op += command[i]; i += 1; }
      if (op === '>' && command[i] === '|') i += 1; // `>|` is one clobber-write operator
      if (c === '>') { redirects.push(op); redirectFds.push(fd); expectTarget = 'out'; continue; }
      if (op === '<<' && command[i] === '-') { op = '<<-'; i += 1; }
      inputRedirects.push(op);
      expectTarget = op === '<<' ? 'heredoc' : op === '<<-' ? 'heredoc-' : 'in';
      continue;
    }
    cur += c; hasTok = true; i += 1;
  }
  endTok();
  segments.push({ argv, redirects, redirectFds, redirectTargets, inputRedirects, inputTargets, sep });
  return segments;
}

const INTERPRETERS = new Set(['bash', 'sh', 'zsh', 'dash', 'ksh']);

// Read the here-doc bodies that start at `i`, in order. Each body runs to a
// line equal to its delimiter (leading tabs stripped for `<<-`); an unclosed
// body consumes the rest of the command. A body fed to an interpreter is
// parsed and its segments are appended to `segments`; any other body is
// dropped. Returns the index after the bodies.
function readHeredocs(command, i, heredocs, segments) {
  for (const { delim, stripTabs, segIdx } of heredocs) {
    const body = [];
    while (i < command.length) {
      let j = command.indexOf('\n', i);
      if (j === -1) j = command.length;
      const line = command.slice(i, j);
      i = j + 1;
      if ((stripTabs ? line.replace(/^\t+/, '') : line) === delim) break;
      body.push(line);
    }
    const owner = segments[segIdx];
    if (owner && INTERPRETERS.has(commandWord(owner.argv).word)) {
      const inner = parse(body.join('\n'));
      if (inner.length) inner[0].sep = ';';
      segments.push(...inner);
    }
  }
  return i;
}

const ASSIGN = /^[A-Za-z_][A-Za-z0-9_]*=/;

// Skip option tokens from `j`. A token in `valued` also consumes its value.
function skipOpts(argv, j, valued) {
  while (j < argv.length && argv[j].startsWith('-') && argv[j].length > 1) {
    if (argv[j] === '--') return j + 1;
    j += valued.has(argv[j]) ? 2 : 1;
  }
  return j;
}

const NO_VALUES = new Set();
const XARGS_VALUED = new Set(['-n', '-P', '-I', '-L', '-s', '-d', '-E', '-a', '-J',
  '--max-args', '--max-procs', '--max-lines', '--max-chars', '--delimiter', '--eof', '--arg-file']);
// Wrapper commands that run their operand as the real command. Each entry
// returns the index of the wrapped command, or -1 when the call only looks
// a command up (`command -v cat`).
const WRAPPERS = {
  sudo: (a, j) => skipOpts(a, j, new Set(['-u', '-g', '-h', '-p', '-C', '-D', '-R', '-T', '-U'])),
  env: (a, j) => skipOpts(a, j, new Set(['-u', '-C', '-S'])),
  command: (a, j) => (a.slice(j).some((t) => t === '-v' || t === '-V') ? -1 : skipOpts(a, j, NO_VALUES)),
  exec: (a, j) => skipOpts(a, j, new Set(['-a'])),
  builtin: (a, j) => j,
  nohup: (a, j) => j,
  time: (a, j) => skipOpts(a, j, NO_VALUES),
  nice: (a, j) => skipOpts(a, j, new Set(['-n'])),
  timeout: (a, j) => {
    const k = skipOpts(a, j, new Set(['-s', '-k']));
    return k < a.length ? k + 1 : k; // skip the DURATION operand
  },
  xargs: (a, j) => skipOpts(a, j, XARGS_VALUED),
};

// The invoked command word of a segment, skipping wrappers (`sudo`, `env`,
// `command`, `exec`, `time`, `nice`, `timeout`, `xargs`, …) and bare leading
// `VAR=val` assignments so the REAL binary is found (`FOO=1 grep x` → grep).
// Returns the basename (`/usr/bin/grep` → `grep`), the args that follow it,
// and `xargs: true` when xargs supplies extra file operands on stdin.
// `{ word: null }` when the segment has no command word.
function commandWord(argv) {
  let i = 0;
  let xargs = false;
  for (;;) {
    while (i < argv.length && ASSIGN.test(argv[i])) i++;
    const tok = argv[i];
    if (!tok) return { word: null, args: [], xargs };
    const base = tok.slice(tok.lastIndexOf('/') + 1);
    if (!Object.hasOwn(WRAPPERS, base)) return { word: base, args: argv.slice(i + 1), xargs };
    const next = WRAPPERS[base](argv, i + 1);
    if (next === -1) return { word: null, args: [], xargs };
    if (base === 'xargs') xargs = true;
    i = next;
  }
}

function syntheticSeg(argv, sep) {
  return { argv, redirects: [], redirectFds: [], redirectTargets: [], inputRedirects: [], inputTargets: [], sep };
}

// Like `parse`, plus the commands a segment hides: the string after `bash -c`
// and the command after `find -exec`/`-execdir`/`-ok`/`-okdir`. Derived
// segments follow their parent so the readers see every command that runs.
function commands(command, depth = 0) {
  return parse(command).flatMap((seg) => expand(seg, depth));
}

// Words that change the shell's cwd or run commands somewhere else. A command
// run through a wrapper (`env -C dir`, `xargs`) or an interpreter (`bash -c`)
// is unknown too.
const CWD_CHANGERS = new Set(['pushd', 'popd', 'chdir', 'source', '.', 'eval', 'find', ...INTERPRETERS]);
const FUNCTION_DEF = /\bfunction\b|\w\s*\(\s*\)/;
const COMPOUND_WORDS = new Set(['if', 'then', 'elif', 'else', 'fi', 'for', 'while', 'until', 'case', 'esac', 'do', 'done', 'select', '!', '{', '}']);

// Attach the cwd each segment runs in, or null when it is unknown. Only a
// relative path needs a known cwd; exempt.js judges an absolute path without it.
// Only `cd <abs-or-./ literal> &&` keeps a known cwd. The lexer loses scope, so
// a group, a subshell, or a function definition makes every `cd` unknown.
function commandsWithCwd(command, cwd) {
  const segs = commands(command);
  let current = FUNCTION_DEF.test(command) ? null : (cwd || process.cwd());
  const grouped = /[(){}`]/.test(command);
  let changed = false;
  return segs.map((seg, k) => {
    if (changed && seg.sep !== '&&') current = null;
    const { word, args } = commandWord(seg.argv);
    const first = seg.argv.find((t) => !ASSIGN.test(t));
    const wrapped = first !== undefined && Object.hasOwn(WRAPPERS, first.slice(first.lastIndexOf('/') + 1));
    if (COMPOUND_WORDS.has(first)) current = null;
    const result = { ...seg, cwd: wrapped ? null : current };
    if (word === 'cd') {
      // Only && guarantees that the next command sees a successful cd.
      // Bare relative names depend on CDPATH; options and expansions are unknown.
      const target = args[0];
      const next = segs[k + 1];
      if (current && !wrapped && !grouped && args.length === 1 && isLiteralPath(target)
          && (path.isAbsolute(target) || target.startsWith('./'))
          && (seg.sep === null || seg.sep === ';' || seg.sep === '&&')
          && next && next.sep === '&&') {
        try {
          const resolved = fs.realpathSync(path.resolve(current, target));
          current = fs.statSync(resolved).isDirectory() ? resolved : null;
        } catch { current = null; }
      } else current = null;
      changed = true;
    } else if (wrapped || CWD_CHANGERS.has(word)) {
      current = null;
    }
    return result;
  });
}

function expand(seg, depth) {
  const out = [seg];
  if (depth > 4) return out;
  const { word, args } = commandWord(seg.argv);
  if (INTERPRETERS.has(word)) {
    const k = args.findIndex((a) => /^-[A-Za-z]*c[A-Za-z]*$/.test(a));
    if (k === -1 || args[k + 1] === undefined) return out;
    const inner = commands(args[k + 1], depth + 1);
    if (inner.length) inner[0] = { ...inner[0], sep: seg.sep };
    out.push(...inner);
  } else if (word === 'find') {
    for (let k = 0; k < args.length; k++) {
      if (!/^-(exec|execdir|ok|okdir)$/.test(args[k])) continue;
      let e = k + 1;
      while (e < args.length && args[e] !== ';' && args[e] !== '+') e++;
      out.push(...expand(syntheticSeg(args.slice(k + 1, e), ';'), depth + 1));
      k = e;
    }
  }
  return out;
}

// Shell-quote a token only when it carries a character outside the safe set, so
// a plain path stays bare in a rewrite (`wt-git ../wt status`) and an exotic one
// (`*.js`, spaces) is single-quoted into a runnable command.
function shQuote(tok) {
  if (tok === '') return "''";
  if (/^[A-Za-z0-9_./:@%+=,-]+$/.test(tok)) return tok;
  return `'${tok.replace(/'/g, "'\\''")}'`;
}

// Split a command's args into the flags it sets and its operands. A short flag
// letter in `valuedShort` or a long flag in `valuedLong` consumes the next token
// as its value unless the value is fused (`-n5`, `--lines=5`). Bare numeric
// flags (`head -5`) carry no operand. `--` makes every later token an operand.
function splitArgs(args, valuedShort = new Set(), valuedLong = new Set()) {
  const flags = new Set();
  const operands = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '--') { operands.push(...args.slice(i + 1)); break; }
    if (a.startsWith('--')) {
      const eq = a.indexOf('=');
      const name = eq === -1 ? a : a.slice(0, eq);
      flags.add(name);
      if (eq === -1 && valuedLong.has(name)) i++;
      continue;
    }
    if (/^-\d+$/.test(a)) continue;
    if (a.startsWith('-') && a.length > 1) {
      for (let k = 1; k < a.length; k++) {
        flags.add('-' + a[k]);
        if (valuedShort.has(a[k])) { if (k === a.length - 1) i++; break; }
      }
      continue;
    }
    operands.push(a);
  }
  return { flags, operands };
}

// Paths that name a stream or kernel interface, not a file in a tree:
// stdin (`-`), /dev, /proc, and /sys. Reading them is not a file read.
const PSEUDO_PATH = /^(-|\/dev\/.*|\/proc\/.*|\/sys\/.*)$/;
function realFiles(paths) {
  return paths.filter((p) => p !== '' && !PSEUDO_PATH.test(p));
}

// True when a pipe feeds the segment's stdin (`git log | grep x`).
function pipedIn(seg) {
  return seg.sep === '|' || seg.sep === '|&';
}

// The real files a segment reads through `< file` input redirects.
function inputFiles(seg) {
  return realFiles(seg.inputTargets.filter((_, k) => seg.inputRedirects[k] === '<'));
}

module.exports = { parse, commands, commandsWithCwd, commandWord, shQuote, splitArgs, realFiles, pipedIn, inputFiles };
