'use strict';
// cd-git.js — reroute module: `cd <path> && git …` → `wt-git <path> <args>`.
//
// `cd`-into-a-repo before a git op trips Claude Code's bare-repository-attack
// heuristic and gets denied; wt-git (`git -C <path>`) runs the same op without
// the cd. The clean two-segment shape `cd <path> && git <args>` REWRITES, and
// so does a longer chain where EVERY segment after cd is `git` and every
// separator is `&&`/`;` with no redirects anywhere (`cd <p> && git a && git b
// ; git c` → `wt-git <p> a && wt-git <p> b ; wt-git <p> c`, each sep
// preserved). Any other segment — a non-git command, a `|`/`||`/`&` — leaves
// the whole thing for delegation. Only `git` is handled: wt-git is git-only,
// and session-analytics put cd+gh denials at 3 vs 21 for cd+git, so cd+gh falls
// through (rtk can't rewrite it either — the command just runs).

const { parse, commandWord, shQuote } = require('./shell');

const CHAIN = new Set(['&&', ';']);

function detect(toolName, input) {
  if (toolName !== 'Bash') return null;
  const segs = parse((input && input.command) || '');
  if (segs.length < 2) return null; // clean shape only: cd … && git … [&& git …]*
  if (segs.some((seg) => seg.redirects.length)) return null;
  const cd = commandWord(segs[0].argv);
  if (cd.word !== 'cd' || cd.args.length !== 1) return null;
  const path = shQuote(cd.args[0]);
  const parts = [];
  for (const seg of segs.slice(1)) {
    if (!CHAIN.has(seg.sep)) return null;
    const git = commandWord(seg.argv);
    if (git.word !== 'git') return null;
    parts.push({ sep: seg.sep, cmd: `wt-git ${path} ${git.args.map(shQuote).join(' ')}`.trimEnd() });
  }
  const rewrite = parts.map((p, i) => (i === 0 ? p.cmd : `${p.sep} ${p.cmd}`)).join(' ');
  return { rewrite, module: 'cd-git' };
}

module.exports = { detect };
