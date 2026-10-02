'use strict';
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
// a file read (`< file`) from stdin. Here-doc bodies (`<<EOF` … `EOF`) are
// skipped, so a body line never parses as a command. It is NOT a full POSIX
// parser: no `$(...)`/`${...}` expansion, no globbing. Unrecognized shapes fall
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
      heredocs.push({ delim: cur, stripTabs: expectTarget === 'heredoc-' });
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
    if (c === '\n') { // newline ends the segment, then skips any pending here-doc bodies
      endSeg(';'); i += 1;
      i = skipHeredocs(command, i, heredocs);
      heredocs = [];
      continue;
    }
    if (c === ';' || c === '(' || c === ')') { endSeg(';'); i += 1; continue; }
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

// Skip the here-doc bodies that start at `i`, in order. Each body runs to a
// line equal to its delimiter (leading tabs stripped for `<<-`); an unclosed
// body consumes the rest of the command. Returns the index after the bodies.
function skipHeredocs(command, i, heredocs) {
  for (const { delim, stripTabs } of heredocs) {
    while (i < command.length) {
      let j = command.indexOf('\n', i);
      if (j === -1) j = command.length;
      const line = command.slice(i, j);
      i = j + 1;
      if ((stripTabs ? line.replace(/^\t+/, '') : line) === delim) break;
    }
  }
  return i;
}

// The invoked command word of a segment, skipping `sudo`, `env VAR=val`, and
// bare leading `VAR=val` assignment prefixes so the REAL binary is found
// (`FOO=1 grep x` → grep). Returns the basename (`/usr/bin/grep` → `grep`)
// plus the args that follow it. `{ word: null }` when the segment has no
// command word (a lone assignment or empty).
function commandWord(argv) {
  let i = 0;
  while (i < argv.length && (argv[i] === 'sudo' || /(^|\/)env$/.test(argv[i]))) {
    const wasEnv = /(^|\/)env$/.test(argv[i]);
    i++;
    if (wasEnv) {
      while (i < argv.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(argv[i])) i++;
    }
  }
  while (i < argv.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(argv[i])) i++;
  const tok = argv[i];
  if (!tok) return { word: null, args: [] };
  return { word: tok.slice(tok.lastIndexOf('/') + 1), args: argv.slice(i + 1) };
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

module.exports = { parse, commandWord, shQuote, splitArgs, realFiles, pipedIn, inputFiles };
