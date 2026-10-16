// move-my-cheese review stages: cure triggers, reviewer contract, redo of cheap stages, and the done advisor.
import assert from 'node:assert/strict'
import test from 'node:test'

import {
  ageFull, aged, approve, builtConsolidation, detail, finalized, noTensions, openPr, planRoutes, ready, reconRoutes,
  run, sha, survey, wt,
} from './move-my-cheese.fixtures.mjs'

const cleanAge = (overrides = {}) => ageFull(1, { worktree_path: wt('age'), ...overrides })
const singleReview = (routes) => [...reconRoutes([openPr(1)], [detail(1)]), ['survey', survey], ['tensions', noTensions], ...routes]

test('cheap lows alone trigger the cure, and cure and affinage never ask what to cure', async () => {
  const { labels, call } = await run({ prs: [1], auto: true }, singleReview([
    ['age:1', ageFull(1, { artifact: 'a.md', has_cheap_lows: true })],
    ['cure:1', { status: 'ok', committed: false, pushed: false, head_sha: sha(1), worktree_path: '/tmp/wt-c', artifact: 'c.md', note: '' }],
    ['finalize:1', finalized],
    ['review:1:status', ready(1)],
  ]))
  assert.ok(labels.includes('cure:1'))
  const cure = call('cure:1').prompt
  assert.match(cure, /--auto --stake medium\+/)
  assert.match(cure, /every low with fix-cost-now: contained/)
  assert.match(cure, /Never ask which findings to cure/)
})

test('every reviewer dispatch opens with the severity-report contract line', async () => {
  const { trace } = await run({ prs: [1], auto: true }, singleReview([
    ['age:1', ageFull(1, { artifact: 'a.md', has_medium_plus_findings: true })],
    ['cure:1', { status: 'ok', committed: true, pushed: true, head_sha: sha(1, 5), worktree_path: '/tmp/wt-c', artifact: 'c.md', note: '' }],
    ['reage:1', ageFull(1, { mode: 'incremental', artifact: 'a2.md' })],
    ['finalize:1', finalized],
    ['review:1:status', ready(1)],
  ]))
  const reviewers = trace.agents.filter(({ opts }) => opts.agentType === 'reviewer')
  assert.deepEqual(reviewers.map(({ opts }) => opts.label), ['age:1', 'reage:1'])
  for (const { prompt } of reviewers) assert.match(prompt, /^Review mode: severity-report\n/)
})

test('a cure that stops with no commits fails the review instead of passing clean', async () => {
  const { result, labels } = await run({ prs: [1], auto: true }, singleReview([
    ['age:1', cleanAge({ has_cheap_lows: true })],
    ['cure:1', { status: 'blocked', committed: false, pushed: false, head_sha: sha(1), worktree_path: wt('cure'), artifact: '', note: 'the report copy failed' }],
  ]))
  assert.equal(result.status, 'partial')
  assert.equal(result.targets[0].review, 'failed')
  assert.match(result.targets[0].reason, /cure blocked with no commits: the report copy failed/)
  assert.equal(labels.some((l) => l.startsWith('finalize:') || l.startsWith('review:1:status')), false)
})

test('a cheap stage that returns nothing is redone once', async () => {
  let calls = 0
  const { result, labels } = await run({ prs: [1], auto: true }, [
    ...reconRoutes([openPr(1)], [aged(1)]),
    ['survey', survey],
    ['tensions', noTensions],
    ['review:1:status', () => (++calls === 1 ? null : ready(1))],
  ])
  assert.equal(result.status, 'ready')
  assert.deepEqual(labels.filter((l) => l.startsWith('review:1:status')), ['review:1:status:1', 'review:1:status:1:redo1'])
})

test('a marker the finalizer could not write is redone, then logged without failing the PR', async () => {
  const { result, labels, trace } = await run({ prs: [1], auto: true }, singleReview([
    ['age:1', cleanAge()],
    ['finalize:1', { marker_updated: false }],
    ['review:1:status', ready(1)],
  ]))
  assert.equal(result.status, 'ready')
  assert.deepEqual(labels.filter((l) => l.startsWith('finalize:')), ['finalize:1', 'finalize:1:redo1', 'finalize:1:redo2'])
  assert.ok(trace.logs.some((l) => /aged marker not written/.test(l)))
})

test('without land, the done advisor gates the draft conversions and the ready verdict', async () => {
  const { args } = await approve(planRoutes())
  const { result, labels } = await run(args, builtConsolidation([
    ['advise:done', { verdict: 'stop', concerns: ['wait for a human review'], guidance: '' }],
  ]))
  assert.equal(result.status, 'partial')
  assert.match(result.note, /advisor did not approve: wait for a human review/)
  assert.equal(labels.includes('mark'), false)
  assert.equal(labels.some((l) => l.startsWith('cleanup')), false)
})

test('an error during land still returns a report', async () => {
  const { result } = await run({ prs: [1], auto: true, land: true }, [
    ...reconRoutes([openPr(1)], [aged(1)]),
    ['survey', survey],
    ['tensions', noTensions],
    ['review:1:status', ready(1)],
    ['land:1:status', ready(1)],
    ['merge:1', () => { throw new Error('budget spent') }],
  ])
  assert.equal(result.status, 'partial')
  // The shared typed() call turns a throw into a failed stage, so the merge wfx call reports it as a refusal.
  assert.match(result.note, /merge refused: .*budget spent/)
})
