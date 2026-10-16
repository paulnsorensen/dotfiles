// wfx poll --pr N
// Reads CI checks through bin/gh-pr-checks-batch, counts unresolved review threads, and reads the PR fields
// state, isDraft, mergeStateStatus (CLEAN, BEHIND, BLOCKED, ...), reviewDecision (empty becomes NONE),
// headRefOid, and baseRefName from one gh pr view call.
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { FxError, badInput } from '../lib/envelope.mjs';
import { assertPr, ghOrThrow } from '../lib/gh.mjs';
import { parseFlags } from '../lib/flags.mjs';

const CHECKS_BATCH = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..', 'bin', 'gh-pr-checks-batch');
const QUERY =
  'query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){reviewThreads(first:100){nodes{isResolved}}}}}';
const THREAD_JQ = '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not)] | length';
const VIEW_FIELDS = 'state,isDraft,mergeStateStatus,reviewDecision,headRefOid,baseRefName';

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
  // One gh pr view call gives the fields that decide merge readiness.
  const raw = ghOrThrow(ctx, ['pr', 'view', pr, '--json', VIEW_FIELDS]);
  let view;
  try {
    view = JSON.parse(raw);
  } catch {
    throw new FxError('bad-gh-output', 'gh pr view returned text that is not JSON', { raw });
  }
  return {
    data: {
      pr: Number(pr),
      state: view.state,
      isDraft: view.isDraft === true,
      mergeStateStatus: view.mergeStateStatus,
      reviewDecision: view.reviewDecision || 'NONE',
      headRefOid: view.headRefOid,
      baseRefName: view.baseRefName,
      checks: { passing: count('pass'), failing: count('fail', 'cancel'), pending: count('pending'), items },
      unresolvedThreads: Number(threads.trim()),
    },
  };
}
