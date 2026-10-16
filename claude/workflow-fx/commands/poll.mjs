// wfx poll --pr N
// Reads CI checks through bin/gh-pr-checks-batch and counts unresolved review threads.
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { badInput } from '../lib/envelope.mjs';
import { assertPr, ghOrThrow } from '../lib/gh.mjs';
import { parseFlags } from '../lib/flags.mjs';

const CHECKS_BATCH = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..', 'bin', 'gh-pr-checks-batch');
const QUERY =
  'query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){reviewThreads(first:100){nodes{isResolved}}}}}';
const THREAD_JQ = '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not)] | length';

// `gh pr checks` prints tab-separated rows: name, state, duration, url.
function parseChecks(text) {
  const items = [];
  for (const line of text.split('\n')) {
    const cols = line.split('\t');
    if (cols.length < 2) continue;
    items.push({ name: cols[0], state: cols[1], url: cols[3] ?? '' });
  }
  return items;
}

export async function run(argv, ctx) {
  const { flags } = parseFlags(argv, { value: ['pr'] });
  if (!flags.pr) throw badInput('poll needs --pr');
  const pr = assertPr(flags.pr);

  const res = ctx.run(CHECKS_BATCH, [pr], { env: ctx.env, cwd: ctx.cwd });
  const items = parseChecks(res.stdout);
  const count = (...states) => items.filter((i) => states.includes(i.state)).length;

  const threads = ghOrThrow(ctx, [
    'api', 'graphql',
    '-F', 'owner={owner}',
    '-F', 'repo={repo}',
    '-F', `number=${pr}`,
    '-f', `query=${QUERY}`,
    '--jq', THREAD_JQ,
  ]);
  return {
    data: {
      pr: Number(pr),
      checks: { passing: count('pass'), failing: count('fail', 'cancel'), pending: count('pending'), items },
      unresolvedThreads: Number(threads.trim()),
    },
  };
}
