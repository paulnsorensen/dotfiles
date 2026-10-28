import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { test } from 'node:test';
import { fakeGh, pathWith, runWfx, tempDir } from './fx-kit.mjs';

const SHA = 'a'.repeat(40);
const FIELDS = 'number,state,mergeable,headRefName,headRefOid,baseRefName';

function setup(fixtures, t) {
  const { binDir, logPath } = fakeGh(fixtures, t);
  const env = { ...process.env, PATH: pathWith(binDir) };
  const calls = () => (existsSync(logPath) ? readFileSync(logPath, 'utf8').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l)) : []);
  return { env, cwd: tempDir(t), calls };
}

const view = (n, head, base = 'main') =>
  JSON.stringify({ number: n, state: 'OPEN', mergeable: 'MERGEABLE', headRefName: head, headRefOid: SHA, baseRefName: base });

test('recon issues the recorded gh vectors and returns PRs plus base SHA', (t) => {
  const baseSha = 'b'.repeat(40);
  const { env, cwd, calls } = setup(
    {
      [`pr view 5 --json ${FIELDS}`]: { stdout: view(5, 'feat-a') },
      [`pr view 7 --json ${FIELDS}`]: { stdout: view(7, 'feat-b') },
      'api repos/{owner}/{repo}/commits/main --jq .sha': { stdout: `${baseSha}\n` },
    },
    t,
  );
  const { status, json } = runWfx(['recon', '--prs', '5,7'], { cwd, env });
  assert.equal(status, 0, JSON.stringify(json));
  assert.deepEqual(json.data, {
    prs: [
      { number: 5, head: { ref: 'feat-a', sha: SHA }, base: 'main', state: 'OPEN', mergeable: 'MERGEABLE' },
      { number: 7, head: { ref: 'feat-b', sha: SHA }, base: 'main', state: 'OPEN', mergeable: 'MERGEABLE' },
    ],
    base: { ref: 'main', sha: baseSha },
  });
  assert.deepEqual(calls(), [
    ['pr', 'view', '5', '--json', FIELDS],
    ['pr', 'view', '7', '--json', FIELDS],
    ['api', 'repos/{owner}/{repo}/commits/main', '--jq', '.sha'],
  ]);
});

test('recon passes --repo-slug to every gh call', (t) => {
  const { env, cwd, calls } = setup(
    {
      [`pr view 5 --repo o/r --json ${FIELDS}`]: { stdout: view(5, 'x', 'dev') },
      'api repos/o/r/commits/dev --jq .sha': { stdout: `${SHA}\n` },
    },
    t,
  );
  const { status, json } = runWfx(['recon', '--prs', '5', '--repo-slug', 'o/r'], { cwd, env });
  assert.equal(status, 0, JSON.stringify(json));
  assert.deepEqual(json.data.base, { ref: 'dev', sha: SHA });
  assert.deepEqual(calls()[0], ['pr', 'view', '5', '--repo', 'o/r', '--json', FIELDS]);
});

test('recon rejects bad input and gh failures', (t) => {
  const { env, cwd } = setup({ [`pr view 5 --json ${FIELDS}`]: { stderr: 'not found', status: 1 } }, t);
  assert.equal(runWfx(['recon', '--prs', '5;rm'], { cwd, env }).status, 2);
  assert.equal(runWfx(['recon'], { cwd, env }).status, 2);
  const fail = runWfx(['recon', '--prs', '5'], { cwd, env });
  assert.equal(fail.status, 1);
  assert.equal(fail.json.error.code, 'gh-failed');
});

test('recon fails on PRs with different bases', (t) => {
  const { env, cwd } = setup(
    {
      [`pr view 5 --json ${FIELDS}`]: { stdout: view(5, 'a', 'main') },
      [`pr view 6 --json ${FIELDS}`]: { stdout: view(6, 'b', 'dev') },
    },
    t,
  );
  const { status, json } = runWfx(['recon', '--prs', '5,6'], { cwd, env });
  assert.equal(status, 1);
  assert.equal(json.error.code, 'mixed-bases');
});

const POLL_FIELDS = 'state,isDraft,mergeStateStatus,reviewDecision,headRefOid,baseRefName';
const POLL_QUERY =
  'query($owner:String!,$repo:String!,$number:Int!,$endCursor:String){repository(owner:$owner,name:$repo){pullRequest(number:$number){reviewThreads(first:100,after:$endCursor){nodes{isResolved}pageInfo{hasNextPage endCursor}}}}}';
const POLL_JQ = '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not)] | length';
const pollThreadsArgv = (n) => [
  'api', 'graphql', '--paginate', '-F', 'owner={owner}', '-F', 'repo={repo}', '-F', `number=${n}`,
  '-f', `query=${POLL_QUERY}`, '--jq', POLL_JQ,
];
const pollView = JSON.stringify({ state: 'OPEN', isDraft: false, mergeStateStatus: 'BEHIND', reviewDecision: '', headRefOid: SHA, baseRefName: 'main' });

test('poll counts checks and unresolved review threads', (t) => {
  const argv = pollThreadsArgv(9);
  const checks = 'build\tpass\t1m\thttp://x/1\nlint\tfail\t2m\thttp://x/2\ndeploy\tpending\t0\thttp://x/3\ndocs\tskipping\t0\thttp://x/4\n';
  const { env, cwd, calls } = setup(
    {
      'pr checks 9': { stdout: checks, status: 1 },
      [argv.join(' ')]: { stdout: '3\n' },
      [`pr view 9 --json ${POLL_FIELDS}`]: { stdout: pollView },
    },
    t,
  );
  const { status, json } = runWfx(['poll', '--pr', '9'], { cwd, env });
  assert.equal(status, 0, JSON.stringify(json));
  assert.equal(json.data.pr, 9);
  assert.equal(json.data.unresolvedThreads, 3);
  assert.deepEqual({ ...json.data.checks, items: undefined }, { passing: 1, failing: 1, pending: 1, items: undefined });
  assert.deepEqual(json.data.checks.items.map((i) => [i.name, i.state, i.url]), [
    ['build', 'pass', 'http://x/1'],
    ['lint', 'fail', 'http://x/2'],
    ['deploy', 'pending', 'http://x/3'],
    ['docs', 'skipping', 'http://x/4'],
  ]);
  assert.deepEqual(calls(), [['pr', 'checks', '9'], argv, ['pr', 'view', '9', '--json', POLL_FIELDS]]);
  assert.deepEqual(
    { ...json.data, checks: undefined },
    { pr: 9, state: 'OPEN', isDraft: false, mergeStateStatus: 'BEHIND', reviewDecision: 'NONE', headRefOid: SHA, baseRefName: 'main', checks: undefined, unresolvedThreads: 3 },
  );
});

test('poll sums unresolved threads over every page', (t) => {
  const { env, cwd } = setup(
    {
      'pr checks 9': { stdout: 'build\tpass\t1m\thttp://x/1\n' },
      [pollThreadsArgv(9).join(' ')]: { stdout: '4\n2\n1\n' },
      [`pr view 9 --json ${POLL_FIELDS}`]: { stdout: pollView },
    },
    t,
  );
  const { status, json } = runWfx(['poll', '--pr', '9'], { cwd, env });
  assert.equal(status, 0, JSON.stringify(json));
  assert.equal(json.data.unresolvedThreads, 7);
});

test('poll reports checks-failed when gh pr checks fails, not an empty check list', (t) => {
  const { env, cwd, calls } = setup(
    { 'pr checks 9': { stderr: 'gh: To use GitHub CLI, run: gh auth login', status: 4 } },
    t,
  );
  const { status, json } = runWfx(['poll', '--pr', '9'], { cwd, env });
  assert.equal(status, 1);
  assert.equal(json.error.code, 'checks-failed');
  assert.match(json.error.details.stderr, /auth login/);
  assert.deepEqual(calls(), [['pr', 'checks', '9']]);
});

test('poll keeps an empty check list when gh reports no checks', (t) => {
  const { env, cwd } = setup(
    {
      'pr checks 9': { stderr: "no checks reported on the 'feat' branch\n", status: 1 },
      [pollThreadsArgv(9).join(' ')]: { stdout: '0\n' },
      [`pr view 9 --json ${POLL_FIELDS}`]: { stdout: pollView },
    },
    t,
  );
  const { status, json } = runWfx(['poll', '--pr', '9'], { cwd, env });
  assert.equal(status, 0, JSON.stringify(json));
  assert.deepEqual(json.data.checks, { passing: 0, failing: 0, pending: 0, items: [] });
});

test('poll fails with gh-failed when the thread query fails', (t) => {
  const { env, cwd, calls } = setup({ 'pr checks 9': { stdout: 'build\tpass\t1m\thttp://x/1\n' } }, t);
  const { status, json } = runWfx(['poll', '--pr', '9'], { cwd, env });
  assert.equal(status, 1);
  assert.equal(json.error.code, 'gh-failed');
  assert.deepEqual(calls()[0], ['pr', 'checks', '9']);
});

test('merge passes --match-head-commit with the checked head SHA', (t) => {
  const { env, cwd, calls } = setup({ [`pr merge 12 --squash --match-head-commit ${SHA}`]: { stdout: 'merged\n' } }, t);
  const { status, json } = runWfx(['merge', '--pr', '12', '--head', SHA], { cwd, env });
  assert.equal(status, 0, JSON.stringify(json));
  assert.deepEqual(json.data, { pr: 12, method: 'squash', head: SHA, queued: false });
  assert.deepEqual(calls(), [['pr', 'merge', '12', '--squash', '--match-head-commit', SHA]]);
});

test('merge honors --method and never passes --admin or --auto', (t) => {
  const { env, cwd, calls } = setup({ [`pr merge 12 --rebase --match-head-commit ${SHA}`]: {} }, t);
  const { status } = runWfx(['merge', '--pr', '12', '--head', SHA, '--method', 'rebase'], { cwd, env });
  assert.equal(status, 0);
  const argv = calls()[0];
  assert.ok(argv.includes('--rebase'));
  assert.ok(!argv.includes('--admin') && !argv.includes('--auto'));
});

test('merge --queue passes --auto with the pinned head and never --admin', (t) => {
  const { env, cwd, calls } = setup({ [`pr merge 12 --squash --auto --match-head-commit ${SHA}`]: {} }, t);
  const { status, json } = runWfx(['merge', '--pr', '12', '--head', SHA, '--queue'], { cwd, env });
  assert.equal(status, 0, JSON.stringify(json));
  assert.deepEqual(json.data, { pr: 12, method: 'squash', head: SHA, queued: true });
  assert.deepEqual(calls(), [['pr', 'merge', '12', '--squash', '--auto', '--match-head-commit', SHA]]);
});

test('merge maps gh failure to merge-failed with stderr', (t) => {
  const { env, cwd } = setup({ [`pr merge 12 --squash --match-head-commit ${SHA}`]: { stderr: 'head moved', status: 1 } }, t);
  const { status, json } = runWfx(['merge', '--pr', '12', '--head', SHA], { cwd, env });
  assert.equal(status, 1);
  assert.equal(json.error.code, 'merge-failed');
  assert.equal(json.error.details.stderr, 'head moved');
});

test('merge rejects a short head, a bad method, and a missing head', (t) => {
  const { env, cwd, calls } = setup({}, t);
  assert.equal(runWfx(['merge', '--pr', '12', '--head', 'abc123'], { cwd, env }).status, 2);
  assert.equal(runWfx(['merge', '--pr', '12', '--head', SHA, '--method', 'octopus'], { cwd, env }).status, 2);
  assert.equal(runWfx(['merge', '--pr', '12'], { cwd, env }).status, 2);
  assert.deepEqual(calls(), []);
});

const DIGEST = '0123456789abcdef';
const MARKER = `<!-- move-my-cheese:landing digest=${DIGEST} head=${SHA} -->`;
const VIEW = 'pr view 4 --json comments --jq [.comments[].body]';

test('stamp posts the landing marker in the move-my-cheese format', (t) => {
  const { env, cwd, calls } = setup({ [VIEW]: { stdout: '["hello"]\n' }, [`pr comment 4 --body ${MARKER}`]: {} }, t);
  const { status, json } = runWfx(['stamp', '--pr', '4', '--marker', DIGEST, '--sha', SHA], { cwd, env });
  assert.equal(status, 0, JSON.stringify(json));
  assert.deepEqual(json.data, { stamped: true });
  assert.deepEqual(calls()[1], ['pr', 'comment', '4', '--body', MARKER]);
});

test('stamp is a no-op when the marker comment exists', (t) => {
  const { env, cwd, calls } = setup({ [VIEW]: { stdout: JSON.stringify(['x', `note\n${MARKER}`]) } }, t);
  const { status, json } = runWfx(['stamp', '--pr', '4', '--marker', DIGEST, '--sha', SHA], { cwd, env });
  assert.equal(status, 0, JSON.stringify(json));
  assert.deepEqual(json.data, { stamped: false, existing: true });
  assert.equal(calls().length, 1);
});

test('stamp posts again when the existing marker records a different head', (t) => {
  const old = `<!-- move-my-cheese:landing digest=${DIGEST} head=${'c'.repeat(40)} -->`;
  const { env, cwd } = setup({ [VIEW]: { stdout: JSON.stringify([old]) }, [`pr comment 4 --body ${MARKER}`]: {} }, t);
  const { json } = runWfx(['stamp', '--pr', '4', '--marker', DIGEST, '--sha', SHA], { cwd, env });
  assert.deepEqual(json.data, { stamped: true });
});

test('stamp rejects a marker that is not a 16-hex digest', (t) => {
  const { env, cwd } = setup({}, t);
  assert.equal(runWfx(['stamp', '--pr', '4', '--marker', 'nope', '--sha', SHA], { cwd, env }).status, 2);
});
