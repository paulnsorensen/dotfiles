'use strict';
// search.js — reroute module: code/text search → tilth_search.
//
// The native Grep/Glob TOOLS deny (a hook's updatedInput cannot change the tool
// name, so there is no rewrite target). Shell grep/egrep/fgrep/rg/ag/ack DENY
// when they read files: a path operand, a `< file` input redirect, or a
// recursive search with no path (rg/ag/ack default to the cwd; grep with -r).
// A search that filters a pipe or a here-string (`git log | grep fix`) reads
// no file and runs unchanged, as do file-listing modes (`rg --files`, `ag -g`,
// `ack -f`). The deny names the tilth_search MCP tool; it does not depend on a
// tilth CLI.

const { commands, commandWord, splitArgs, realFiles, pipedIn, inputFiles } = require('./shell');

// Per-binary option grammar: which flags take a value, which flags make the
// search recursive, which supply the pattern (so every operand is a path), and
// which list files instead of searching them.
const BINS = {
  grep: {
    valuedShort: 'efmABCdD',
    valuedLong: ['--regexp', '--file', '--max-count', '--context', '--after-context',
      '--before-context', '--directories', '--devices', '--label', '--include',
      '--exclude', '--exclude-dir', '--binary-files'],
    recursive: ['-r', '-R', '--recursive', '--dereference-recursive'],
  },
  rg: {
    valuedShort: 'efgtTmABCjMrdE',
    valuedLong: ['--regexp', '--file', '--glob', '--iglob', '--type', '--type-not',
      '--type-add', '--type-clear', '--max-count', '--context', '--after-context',
      '--before-context', '--threads', '--max-columns', '--replace', '--max-depth',
      '--encoding', '--sort', '--sortr', '--colors', '--color', '--pre', '--pre-glob',
      '--max-filesize', '--engine'],
    recursive: 'always',
    listing: ['--files', '--type-list'],
  },
  ag: {
    valuedShort: 'ABCGgm',
    valuedLong: ['--file-search-regex', '--ignore', '--ignore-dir', '--context',
      '--after', '--before', '--max-count', '--depth', '--pager'],
    recursive: 'always',
    listing: ['-g', '--list-file-types'],
  },
  ack: {
    valuedShort: 'ABCm',
    valuedLong: ['--type', '--ignore-dir', '--ignore-file', '--match', '--context',
      '--after-context', '--before-context', '--max-count', '--output'],
    recursive: 'always',
    listing: ['-f', '-g', '--help-types'],
  },
};
BINS.egrep = BINS.grep;
BINS.fgrep = BINS.grep;
const PATTERN_FLAGS = ['-e', '-f', '--regexp', '--file'];

function reason(label, pattern, targets) {
  const q = pattern || '<pattern>';
  const where = targets && targets.length ? ` (${targets.join(', ')})` : '';
  return `Blocked: ${label} searches files${where} — use tilth_search, not a raw search tool.

tilth_search is AST-aware and far cheaper in context. Run instead:
  mcp__tilth__tilth_search(queries:[{query:${JSON.stringify(q)}}], cwd:"<checkout>")

Add glob:"*.rs" to a query to narrow it. Filters on command output (\`git log | grep fix\`) still run.`;
}

// The files a shell search reads, or null when it reads none.
function searchTargets(seg, spec, args, xargs) {
  const { flags, operands } = splitArgs(args, new Set(spec.valuedShort), new Set(spec.valuedLong));
  if ((spec.listing || []).some((f) => flags.has(f))) return null;
  const patternGiven = PATTERN_FLAGS.some((f) => flags.has(f));
  const pattern = patternGiven ? null : operands[0];
  const paths = realFiles(patternGiven ? operands : operands.slice(1));
  const targets = [...paths, ...inputFiles(seg)];
  if (targets.length) return { targets, pattern };
  const recursive = spec.recursive === 'always' || spec.recursive.some((f) => flags.has(f));
  const stdinFed = pipedIn(seg) || seg.inputRedirects.length > 0;
  if (recursive && !stdinFed) return { targets: ['.'], pattern };
  if (xargs) return { targets: ['(files from xargs)'], pattern }; // xargs feeds file names on stdin
  return null;
}

function detect(toolName, input) {
  if (toolName !== 'Bash') return null;
  for (const seg of commands((input && input.command) || '')) {
    const { word, args, xargs } = commandWord(seg.argv);
    const spec = word && Object.hasOwn(BINS, word) && BINS[word];
    if (!spec) continue;
    const hit = searchTargets(seg, spec, args, xargs);
    if (hit) return { reason: reason(`\`${word}\``, hit.pattern, hit.targets), pattern: hit.pattern, module: 'search' };
  }
  return null;
}

module.exports = { detect };
