'use strict';
// cd-git.js — reroute module: `cd <path> && git …` → `wt-git <path> <args>`.
//
// `cd`-into-a-repo before a git op trips Claude Code's bare-repository-attack
// heuristic and gets denied; wt-git (`git -C <path>`) runs the same op without
// the cd. Only the CLEAN two-segment shape `cd <path> && git <args>` (nothing
// before, nothing after) REWRITES — trailing segments or a different chained
// command leave it for delegation. Only `git` is handled: wt-git is git-only,
// and session-analytics put cd+gh denials at 3 vs 21 for cd+git, so cd+gh falls
// through (rtk can't rewrite it either — the command just runs).

const { parse, commandWord, shQuote } = require('./shell');

const CHAIN = new Set(['&&', ';', '&']);

function detect(toolName, input) {
  if (toolName !== 'Bash') return null;
  const segs = parse((input && input.command) || '');
  if (segs.length !== 2) return null; // clean shape only: cd … && git …
  if (segs[0].redirects.length || segs[1].redirects.length) return null;
  const cd = commandWord(segs[0].argv);
  if (cd.word !== 'cd' || cd.args.length !== 1) return null;
  if (!CHAIN.has(segs[1].sep)) return null;
  const git = commandWord(segs[1].argv);
  if (git.word !== 'git') return null;
  const rewrite = `wt-git ${shQuote(cd.args[0])} ${git.args.map(shQuote).join(' ')}`.trimEnd();
  return { rewrite };
}

module.exports = { detect };
