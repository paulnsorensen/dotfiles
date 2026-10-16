// move-my-cheese land: bottom-up merges, re-checks of moved heads, and superseded PRs.
import assert from 'node:assert/strict'
import test from 'node:test'

import {
  ageFull, aged, approve, approveDone, built, finalized, merged, noTensions, openPr, plain, planRoutes, published,
  ready, reconRoutes, replaceOnePlan, run, sha, stateMerged, survey,
} from './move-my-cheese.fixtures.mjs'

// A two-PR stack (#2 on #1), both aged and clean; #2 moves when it is restacked onto main.
const stackRoutes = (overrides = []) => [
  ...overrides,
  ...reconRoutes([openPr(1), openPr(2, { base: 'feat/pr-1' })], [aged(1), aged(2, { base: 'feat/pr-1' })]),
  ['survey', survey],
  ['tensions', noTensions],
  ['review:1:status', ready(1)],
  ['review:2:status', ready(2)],
  ['advise:done', approveDone],
  ['land:1:status', ready(1)],
  ['merge:1', merged],
  ['merged:1', stateMerged],
  ['restack:2', { status: 'ok', pushed: true, worktree_path: '/tmp/wt-2', note: '' }],
  ['recheck-age:2', ageFull(2)],
  ['land:2:status', ready(2, { head_sha: sha(2, 3) })],
  ['merge:2', merged],
  ['merged:2', stateMerged],
]

test('land merges a stack bottom-up, restacks the child, and fully re-reviews its moved head on main', async () => {
  const { result, labels, wfxLabels, call } = await run({ prs: [1, 2], auto: true, land: true }, stackRoutes())
  assert.equal(result.status, 'landed')
  assert.deepEqual(labels.filter((l) => /^(merge|merged|restack|recheck-age):/.test(l)), ['merge:1', 'merged:1:1', 'restack:2', 'recheck-age:2', 'merge:2', 'merged:2:1'])
  assert.equal(labels.some((l) => l.startsWith('integrate:') || l.startsWith('verify:')), false)
  assert.equal(wfxLabels.some((l) => l.startsWith('integrate') || l.startsWith('worktree:')), false)
  assert.match(call('merge:2').prompt, new RegExp(`Run gh pr merge 2 --squash --match-head-commit ${sha(2, 3)}\\.`))
  assert.equal(call('restack:2').opts.isolation, 'worktree')
  const restack = call('restack:2').prompt
  assert.ok(restack.includes('git checkout --detach origin/feat/pr-2'))
  assert.ok(restack.includes('git rebase --onto origin/main origin/feat/pr-1'))
  assert.ok(!restack.includes('git checkout -B feat/pr-2 '))
  const recheck = call('recheck-age:2').prompt
  assert.ok(recheck.includes('/age origin/main...HEAD --auto'))
  assert.ok(!recheck.includes('origin/feat/pr-1...HEAD'))
  assert.doesNotMatch(recheck, /Mode incremental/)
})

test('a moved head with new findings stops landing before it merges', async () => {
  const { result, labels } = await run({ prs: [1, 2], auto: true, land: true }, stackRoutes([
    ['recheck-age:2', ageFull(2, { has_medium_plus_findings: true })],
  ]))
  assert.equal(result.status, 'partial')
  assert.equal(labels.includes('merge:2'), false)
  const child = plain(result.targets).find((t) => t.pr === 2)
  assert.equal(child.land, 'failed')
  assert.match(child.reason, /changed-after-verify: new medium\+ findings/)
})

test('land is skipped when the advisor does not approve', async () => {
  const { result, labels } = await run({ prs: [1], auto: true, land: true }, [
    ...reconRoutes([openPr(1)], [aged(1)]),
    ['survey', survey],
    ['tensions', noTensions],
    ['review:1:status', ready(1)],
    ['advise:done', { verdict: 'stop', concerns: ['unsafe'], guidance: '' }],
  ])
  assert.equal(result.status, 'partial')
  assert.match(result.note, /advisor did not approve: unsafe/)
  assert.equal(labels.some((l) => l.startsWith('merge:')), false)
})

// #1 is replaced by new PR #10 (T-1); #2 is kept (T-2).
const replaceRoutes = (overrides = []) => planRoutes([
  ...overrides,
  ['recon:detail', { prs: [aged(1), aged(2)] }],
  ['plan:minimal', replaceOnePlan()],
  ['target:T-1', built(sha(50), '/tmp/wt-t1')],
  ['publish', published('T-1', 10, sha(50))],
  ['age:10', ageFull(10, { worktree_path: '/tmp/wt-t1' })],
  ['finalize:10', finalized],
  ['review:10:status', ready(10, { head_sha: sha(50) })],
  ['review:2:status', ready(2)],
  ['advise:done', approveDone],
  ['land:10:status', ready(10, { head_sha: sha(50) })],
  ['merge:10', merged],
  ['merged:10', stateMerged],
  ['close:T-1', { results: [{ pr: 1, action: 'closed', note: '' }] }],
  ['land:2:status', ready(2)],
  ['merge:2', { result: 'refused', note: 'base branch policy' }],
])

test('a superseded PR closes as soon as its replacement merges, even when landing stops later', async () => {
  const { args } = await approve(replaceRoutes(), { land: true })
  const { result, labels, call } = await run(args, replaceRoutes())
  assert.equal(result.status, 'partial')
  assert.ok(labels.indexOf('close:T-1') > labels.indexOf('merged:10:1'))
  assert.ok(labels.indexOf('close:T-1') < labels.indexOf('merge:2'))
  assert.equal(labels.includes('mark'), false)
  assert.match(call('close:T-1').prompt, /gh pr close <pr>/)
  assert.deepEqual(plain(result.inputs).map((i) => [i.number, i.mark]), [[1, 'closed'], [2, '']])
})

test('a stop before a replacement merges drafts the PR it supersedes instead of closing it', async () => {
  const { args } = await approve(replaceRoutes(), { land: true })
  const { result, labels, call } = await run(args, replaceRoutes([
    ['merge:10', { result: 'refused', note: 'checks changed' }],
    ['mark', { results: [{ pr: 1, action: 'drafted', note: '' }] }],
  ]))
  assert.equal(result.status, 'partial')
  assert.equal(labels.some((l) => l.startsWith('close:')), false)
  assert.match(call('mark').prompt, /gh pr ready <pr> --undo/)
  assert.match(call('mark').prompt, /"pr": 1/)
  assert.deepEqual(plain(result.inputs).map((i) => [i.number, i.mark]), [[1, 'drafted'], [2, '']])
})

test('a moved head on a reshaping plan re-checks its criteria on main, including landed outcomes', async () => {
  const { args } = await approve(replaceRoutes(), { land: true })
  const { result, raw, wfxLabels, workflowCalls } = await run(args, replaceRoutes([
    ['land:2:status', ready(2, { head_sha: sha(2, 5) })],
    ['recheck-age:2', ageFull(2)],
    ['merge:2', merged],
    ['merged:2', stateMerged],
  ]))
  assert.equal(result.status, 'landed')
  assert.ok(wfxLabels.includes('integrate:land-T-2:T-2'))
  assert.deepEqual(wfxLabels.filter((l) => l.endsWith(':land-T-2')), ['worktree:add:land-T-2', 'worktree:remove:land-T-2'])
  const verify = workflowCalls.find((c) => c.name === 'verify-criteria')
  assert.deepEqual(verify.input.criteria.map((c) => c.id), ['AC-1'])
  const order = raw.agents.map(({ opts }) => opts.label)
  assert.ok(order.indexOf('integrate:land-T-2:T-2') < order.indexOf('worktree:add:land-T-2'))
  assert.ok(order.indexOf('worktree:remove:land-T-2') < order.indexOf('merge:2'))
})
