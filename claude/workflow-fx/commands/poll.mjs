// wfx poll --pr N
// Reads CI checks through gh pr checks, counts unresolved review threads over every page, and reads the PR fields
// state, isDraft, mergeStateStatus (CLEAN, BEHIND, BLOCKED, ...), reviewDecision (empty becomes NONE),
// headRefOid, and baseRefName from one gh pr view call.
import { FxError, badInput } from '../lib/envelope.mjs';
import { assertPr, ghOrThrow } from '../lib/gh.mjs';
import { parseFlags } from '../lib/flags.mjs';

// gh pages the query with --paginate and fills $endCursor. The jq filter runs once per page.
const QUERY =
  'query($owner:String!,$repo:String!,$number:Int!,$endCursor:String){repository(owner:$owner,name:$repo){pullRequest(number:$number){reviewThreads(first:100,after:$endCursor){nodes{isResolved}pageInfo{hasNextPage endCursor}}}}}';
const THREAD_JQ = '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not)] | length';
const VIEW_FIELDS = 'state,isDraft,mergeStateStatus,reviewDecision,headRefOid,baseRefName';

// gh exits 1 when a check fails and 8 when one is pending, and still prints the rows.
// A real failure prints no rows and writes to stderr. gh says "no checks reported" when none exist.
function readChecks(ctx, pr) {
  const res = ctx.gh(['pr', 'checks', pr], { env: ctx.env, cwd: ctx.cwd });
  const items = parseChecks(res.stdout);
  if (items.length > 0 || res.status === 0) return items;
  if (/no checks reported/i.test(res.stderr)) return items;
  throw new FxError('checks-failed', `gh pr checks failed: ${res.stderr.trim()}`, {
    pr: Number(pr),
    status: res.status,
    stderr: res.stderr.trim(),
  });
}

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

  const items = readChecks(ctx, pr);
  const count = (...states) => items.filter((i) => states.includes(i.state)).length;

  const pages = ghOrThrow(ctx, [
    'api', 'graphql', '--paginate',
    '-F', 'owner={owner}',
    '-F', 'repo={repo}',
    '-F', `number=${pr}`,
    '-f', `query=${QUERY}`,
    '--jq', THREAD_JQ,
  ]);
  const unresolved = pages.split('\n').filter((l) => l.trim() !== '').reduce((sum, l) => sum + Number(l.trim()), 0);
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
      unresolvedThreads: unresolved,
    },
  };
}
