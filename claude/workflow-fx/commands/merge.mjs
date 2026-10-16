// wfx merge --pr N --head <sha> [--method squash|merge|rebase] [--queue]
// The head SHA pins the merge: gh refuses when the PR head moved.
// --queue adds --auto for a repo with a merge queue. gh then queues the merge; data.queued is true.
// The command never passes --admin.
import { badInput } from '../lib/envelope.mjs';
import { assertPr, ghOrThrow } from '../lib/gh.mjs';
import { parseFlags } from '../lib/flags.mjs';
import { assertSha } from '../lib/push.mjs';

const METHODS = new Set(['squash', 'merge', 'rebase']);

export async function run(argv, ctx) {
  const { flags } = parseFlags(argv, { value: ['pr', 'head', 'method'], bool: ['queue'] });
  if (!flags.pr) throw badInput('merge needs --pr');
  if (!flags.head) throw badInput('merge needs --head');
  const pr = assertPr(flags.pr);
  const head = assertSha(flags.head, 'head');
  const method = flags.method ?? 'squash';
  if (!METHODS.has(method)) throw badInput(`--method must be one of ${[...METHODS].join(', ')}`);
  const queue = flags.queue === true;
  const args = ['pr', 'merge', pr, `--${method}`, ...(queue ? ['--auto'] : []), '--match-head-commit', head];
  ghOrThrow(ctx, args, 'merge-failed');
  return { data: { pr: Number(pr), method, head, queued: queue } };
}
