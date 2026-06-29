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
// write-redirect from a `>` inside a string. It is NOT a full POSIX parser: no
// `$(...)`/`${...}` expansion, no here-doc bodies, no globbing. Unrecognized
// shapes fall through and the hook fails open (a rewrite hook must never DoS).
//
// Each returned segment is:
//   { argv: string[],          // command + args, quotes/escapes stripped
//     redirects: string[],      // unquoted output redirects seen: '>' / '>>'
//     redirectFds: (string|null)[],// fd qualifier per redirect: '1'/'2'/… for
//                               //   `1>`/`2>`, null for a bare `>` (stdout)
//     redirectTargets: string[],// the filename token after each `>` / `>>`
//     sep: string|null }        // operator PRECEDING this segment ('|','&&',
//                               //   '||',';','&', or null for the first)

function parse(command) {
  const segments = [];
  let argv = [];
  let redirects = [];
  let redirectFds = [];
  let redirectTargets = [];
  let sep = null; // operator preceding the CURRENT segment
  let cur = '';
  let hasTok = false; // an in-progress token exists
  let expectTarget = false; // next completed token is a redirect target

  const endTok = () => {
    if (!hasTok) return;
    if (expectTarget) { redirectTargets.push(cur); expectTarget = false; }
    else argv.push(cur);
    cur = '';
    hasTok = false;
  };
  const endSeg = (nextSep) => {
    endTok();
    segments.push({ argv, redirects, redirectFds, redirectTargets, sep });
    argv = []; redirects = []; redirectFds = []; redirectTargets = []; sep = nextSep;
    expectTarget = false;
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
      i += 1;
      continue;
    }
    if (c === ' ' || c === '\t') { endTok(); i += 1; continue; }
    if (c === '\n' || c === ';' || c === '(' || c === ')') { endSeg(';'); i += 1; continue; }
    if (c === '|' || c === '&') { // a run of | / & is one operator boundary
      endTok();
      let op = c; i += 1;
      while (i < n && (command[i] === '|' || command[i] === '&')) { op += command[i]; i += 1; }
      endSeg(op);
      continue;
    }
    if (c === '>' || c === '<') { // redirection operator (collect a run: >>, <<)
      // an fd qualifier (`2>`, `1>`) is digits directly preceding `>` with no
      // space — capture it so io.js can tell a stdout write from an fd redirect.
      let fd = null;
      if (c === '>' && hasTok && /^[0-9]+$/.test(cur)) { fd = cur; cur = ''; hasTok = false; }
      endTok();
      let op = c; i += 1;
      while (i < n && command[i] === c) { op += command[i]; i += 1; }
      if (c === '>') { redirects.push(op); redirectFds.push(fd); expectTarget = true; } // only output redirects matter
      continue;
    }
    cur += c; hasTok = true; i += 1;
  }
  endTok();
  segments.push({ argv, redirects, redirectFds, redirectTargets, sep });
  return segments;
}

// The invoked command word of a segment, skipping `sudo`, `env VAR=val`, and
// bare leading `VAR=val` assignment prefixes so the REAL binary is found
// (`FOO=1 grep x` → grep). ADR-003: also strip a leading `rtk` / `rtk proxy`
// wrapper, so a model-issued `rtk grep foo` / `rtk proxy grep foo` still resolves
// to the wrapped command word (grep) and reroutes. Returns the basename
// (`/usr/bin/grep` → `grep`) plus the args that follow it. `{ word: null }` when
// the segment has no command word (a lone assignment, a bare `rtk`, or empty).
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
  if (i < argv.length && argv[i] === 'rtk') { // strip the rtk / rtk proxy wrapper
    i++;
    if (i < argv.length && argv[i] === 'proxy') i++;
  }
  const tok = argv[i];
  if (!tok) return { word: null, args: [] };
  return { word: tok.slice(tok.lastIndexOf('/') + 1), args: argv.slice(i + 1) };
}

// Shell-quote a token only when it carries a character outside the safe set, so
// a plain pattern/path stays bare in a rewrite (`tilth foo --scope .`) and an
// exotic one (`*.js`, spaces) is single-quoted into a runnable command.
function shQuote(tok) {
  if (tok === '') return "''";
  if (/^[A-Za-z0-9_./:@%+=,-]+$/.test(tok)) return tok;
  return `'${tok.replace(/'/g, "'\\''")}'`;
}

module.exports = { parse, commandWord, shQuote };
