// wfx merge --pr N --head <sha> [--method squash|merge|rebase]
// The head SHA pins the merge: gh refuses when the PR head moved.
import { badInput } from '../lib/envelope.mjs';
import { assertPr, ghOrThrow } from '../lib/gh.mjs';
import { parseFlags } from '../lib/flags.mjs';
import { assertSha } from '../lib/push.mjs';

const METHODS = new Set(['squash', 'merge', 'rebase']);

export async function run(argv, ctx) {
  const { flags } = parseFlags(argv, { value: ['pr', 'head', 'method'] });
  if (!flags.pr) throw badInput('merge needs --pr');
  if (!flags.head) throw badInput('merge needs --head');
  const pr = assertPr(flags.pr);
  const head = assertSha(flags.head, 'head');
  const method = flags.method ?? 'squash';
  if (!METHODS.has(method)) throw badInput(`--method must be one of ${[...METHODS].join(', ')}`);
  ghOrThrow(ctx, ['pr', 'merge', pr, `--${method}`, '--match-head-commit', head], 'merge-failed');
  return { data: { pr: Number(pr), method, head } };
}
