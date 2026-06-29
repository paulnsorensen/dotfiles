'use strict';
// search.js — reroute module: wrong-tool code/text/file search → tilth.
//
// Bash grep/rg/ag/ack with a CLEAN shape — a single standalone invocation (no
// pipe, no redirect), a pattern, an optional single path, and only
// non-semantic flags — REWRITE to `tilth <pattern> [--scope <path>]`. Bash find
// filtering solely by -name/-path REWRITES to `tilth <glob> [--scope <path>]`
// (QUERY is positional — tilth has no --glob flag). The native Grep/Glob TOOLS
// have no Bash rewrite target (updatedInput
// cannot change the tool name — ADR-004) so they DENY with a cheez-search
// message.
//
// "Exotic" shapes — semantic flags tilth cannot reproduce faithfully (-l, -c,
// -o, -v, -w, -x, -E/-P, context -A/-B/-C, any long flag, multiple path
// operands, a piped/redirected search) or a non-name find — return null and
// fall through to rtk delegation (ADR-002): never ship a rewrite that silently
// changes search semantics, never hard-block a search.

const { parse, commandWord, shQuote } = require('./shell');

const GREP_BINS = new Set(['grep', 'rg', 'ag', 'ack']);
const GLOB_FLAGS = new Set(['-name', '-iname', '-path', '-ipath']);
// Short option letters whose semantics tilth cannot reproduce; their presence
// (alone or fused, e.g. `-rl`) forces delegation. Letters that take a value
// (-A/-B/-C context, -e pattern, -f file, -m max-count) are exotic too, so we
// never have to consume a following value to find the operands.
const EXOTIC_SHORT = new Set('lLcovwxEPABCefm'.split(''));

function reason(label, pattern, cwd) {
  const q = pattern || '<pattern>';
  const example = `mcp__tilth__tilth_search(queries:[{query:${JSON.stringify(q)}}], root:${JSON.stringify(cwd)})`;
  return `Blocked: ${label} — use the cheez-search skill (tilth_search), not the raw search tool.

tilth_search is AST-aware and far cheaper in context than grep/find. Run instead:
  ${example}

For "where is X defined" / "what calls Y" pass kind:"symbol" or kind:"callers".`;
}

// grep-family clean-shape → `tilth <pattern> [--scope <path>]`, or null when exotic.
function grepRewrite(args) {
  const operands = [];
  for (const a of args) {
    if (a === '--') continue; // a lone separator; the rest are operands
    if (a.startsWith('--')) return null; // any long flag: conservatively exotic
    if (a.startsWith('-') && a.length > 1) {
      for (const ch of a.slice(1)) if (EXOTIC_SHORT.has(ch)) return null;
      continue; // clean short flags (-r/-n/-i/-H/…): ignore
    }
    operands.push(a);
  }
  if (operands.length === 0 || operands.length > 2) return null;
  const [pattern, path] = operands;
  return `tilth ${shQuote(pattern)}${path !== undefined ? ` --scope ${shQuote(path)}` : ''}`;
}

// find filtering ONLY by -name/-path → `tilth <glob> [--scope <path>]` (QUERY
// positional), or null when any other predicate is present (a real filesystem op).
function findRewrite(args) {
  const paths = [];
  let i = 0;
  while (i < args.length && !args[i].startsWith('-')) { paths.push(args[i]); i++; }
  let glob = null;
  for (; i < args.length; i++) {
    if (GLOB_FLAGS.has(args[i])) {
      if (glob !== null) return null; // a second name/path predicate → exotic
      glob = args[i + 1];
      i++; // skip the predicate value
      continue;
    }
    return null; // -type/-size/-mtime/-o/-exec/… → delegate, tilth can't express it
  }
  if (glob == null || paths.length > 1) return null;
  return `tilth ${shQuote(glob)}${paths.length ? ` --scope ${shQuote(paths[0])}` : ''}`;
}

function detect(toolName, input, cwd) {
  cwd = cwd || process.cwd();
  if (toolName === 'Grep' || toolName === 'Glob') {
    return { reason: reason(`the ${toolName} tool`, (input && input.pattern) || null, cwd) };
  }
  if (toolName !== 'Bash') return null;
  const segs = parse((input && input.command) || '');
  // A clean search reroute is a STANDALONE invocation: one segment, no
  // redirect. A pipe/`&&`/redirect adds structure tilth can't carry, so leave
  // it for delegation.
  if (segs.length !== 1 || segs[0].redirects.length) return null;
  const { word, args } = commandWord(segs[0].argv);
  if (!word) return null;
  if (GREP_BINS.has(word)) {
    const rw = grepRewrite(args);
    return rw ? { rewrite: rw } : null;
  }
  if (word === 'find') {
    const rw = findRewrite(args);
    return rw ? { rewrite: rw } : null;
  }
  return null;
}

module.exports = { detect };
