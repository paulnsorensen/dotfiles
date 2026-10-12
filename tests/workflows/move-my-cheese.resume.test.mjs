// move-my-cheese resume: a later run of the same approval continues from its own stamped state.
import assert from 'node:assert/strict'
import test from 'node:test'

import {
  ageFull, aged, approve, approveDone, builtConsolidation, detail, finalized, index, integrated, merged, minimalPlan, openPr, plain, planRoutes,
  published, ready, run, sha, stateMerged, verified,
} from './move-my-cheese.fixtures.mjs'

// After a non-land run: #1 and #2 are drafts with this approval's marker, and #10 is open on the
// new branch with a stamp of its head. Each field can be overridden to break the resume.
const resumeRoutes = (digest, { author10 = 'me', digest10 = digest, head10 = sha(50) } = {}) => planRoutes([
  ['recon:index', index([openPr(1, { is_draft: true }), openPr(2, { is_draft: true }), openPr(10, { branch: 'land/combined', author: author10 })], { base_sha: 'c'.repeat(40) })],
  ['recon:detail', { prs: [
    detail(1, { landing_digest: digest }),
    detail(2, { landing_digest: digest }),
    aged(10, { branch: 'land/combined', head_sha: sha(50), aged_sha: sha(50), landing_digest: digest10, landing_head: head10 }),
  ] }],
  ['integrate', integrated(['T-1'])],
  ['verify', verified],
  ['review:10:status', ready(10, { head_sha: sha(50) })],
  ['advise:done', approveDone],
  ['land:10:status', ready(10, { head_sha: sha(50) })],
  ['merge:10', merged],
  ['merged:10', stateMerged],
  ['close:T-1', { results: [{ pr: 1, action: 'closed', note: '' }, { pr: 2, action: 'closed', note: '' }] }],
])

test('a land run of the same approval resumes after a non-land run instead of starting over', async () => {
  const { first, args } = await approve(planRoutes(), { land: true })
  const { result, labels, call } = await run(args, resumeRoutes(first.result.digest))
  assert.equal(result.status, 'landed')
  assert.match(call('recon:detail').prompt, /PRs 1, 2, 10\./)
  assert.match(call('recon:detail').prompt, /never the PR body/)
  assert.equal(labels.some((l) => /^(target|age|finalize):/.test(l) || l === 'publish'), false)
  assert.ok(call('integrate:pre').prompt.includes('T-1=origin/land/combined'))
  assert.deepEqual(plain(result.inputs).map((i) => [i.number, i.mark]), [[1, 'closed'], [2, 'closed']])
})

for (const [name, override] of [
  ['carries no marker from this approval', { digest10: '' }],
  ['moved after its last stamp', { head10: sha(50, 4) }],
  ['was opened by someone else', { author10: 'someone' }],
]) {
  test(`an open PR on a new target branch that ${name} blocks the run`, async () => {
    const { first, args } = await approve(planRoutes(), { land: true })
    const { result, labels } = await run(args, resumeRoutes(first.result.digest, override))
    assert.equal(result.status, 'blocked')
    assert.match(result.error, /#10, which this approval did not open or which moved after its last run/)
    assert.deepEqual(labels, ['recon:index', 'recon:detail'])
  })
}

// #2 was modified and stamped by an earlier run of a minimal plan; its head moved to the stamp.
const modifiedRoutes = (digest, stampHead) => planRoutes([
  ['recon:detail', { prs: [aged(1), aged(2, { head_sha: sha(2, 6), landing_digest: digest, landing_head: stampHead })] }],
  ['plan:minimal', minimalPlan()],
  ['integrate', integrated(['T-1', 'T-2'])],
  ['verify', verified],
  ['age:2', ageFull(2)],
  ['finalize:2', finalized],
  ['review:1:status', ready(1)],
  ['review:2:status', ready(2, { head_sha: sha(2, 6) })],
])

test('a modified PR whose head matches this approval\'s stamp is not rebuilt again', async () => {
  const plan = planRoutes([['recon:detail', { prs: [aged(1), aged(2)] }], ['plan:minimal', minimalPlan()]])
  const { first, args } = await approve(plan)
  const { result, labels } = await run(args, modifiedRoutes(first.result.digest, sha(2, 6)))
  assert.equal(result.status, 'ready')
  assert.equal(labels.some((l) => l.startsWith('target:') || l === 'publish'), false)
})

test('a head that moved past this approval\'s stamp turns the plan into needs-replan', async () => {
  const plan = planRoutes([['recon:detail', { prs: [aged(1), aged(2)] }], ['plan:minimal', minimalPlan()]])
  const { first, args } = await approve(plan)
  const { result } = await run(args, modifiedRoutes(first.result.digest, sha(2, 5)))
  assert.equal(result.status, 'needs-replan')
  assert.match(result.reasons.join(' '), /#2 head moved/)
})

test('an executing run stamps the head it last saw on each open target', async () => {
  const plan = planRoutes([['recon:detail', { prs: [aged(1), aged(2)] }], ['plan:minimal', minimalPlan()]])
  const { first, args } = await approve(plan)
  const { call } = await run(args, modifiedRoutes(first.result.digest, sha(2, 6)))
  const stamp = call('stamp').prompt
  assert.ok(stamp.includes(`move-my-cheese:landing digest=${first.result.digest} head=${sha(2, 6)}`))
  assert.ok(stamp.includes(`move-my-cheese:landing digest=${first.result.digest} head=${sha(1)}`))
})

test('a revise on an approval that already started blocks before any planner runs', async () => {
  const { first, args } = await approve(planRoutes(), { revise: 'keep #2 apart' })
  const { result, labels } = await run(args, resumeRoutes(first.result.digest))
  assert.equal(result.status, 'blocked')
  assert.match(result.error, /this approval already started/)
  assert.deepEqual(labels, ['recon:index', 'recon:detail'])
})

test('a budget floor after publish still stamps the published head', async () => {
  const { first, args } = await approve(planRoutes())
  let spent = 0
  const budget = { total: 1e6, spent: () => spent, remaining: () => 1e6 - spent }
  const routes = builtConsolidation([['publish', () => { spent = 1e6 - 1000; return published('T-1', 10, sha(50)) }]])
  const { result, labels, call } = await run(args, routes, budget)
  assert.equal(result.status, 'partial')
  assert.equal(labels.some((l) => l.startsWith('age:')), false)
  assert.ok(call('stamp')?.prompt.includes(`move-my-cheese:landing digest=${first.result.digest} head=${sha(50)}`))
})

test('a poll that throws mid-loop still stamps the head its last status saw', async () => {
  const { first, args } = await approve(planRoutes())
  const routes = builtConsolidation([
    ['review:10:status', ready(10, { ci: 'fail', head_sha: sha(50, 3) })],
    ['review:10:affinage', () => { throw new Error('budget spent') }],
  ])
  const { call } = await run(args, routes)
  assert.ok(call('stamp')?.prompt.includes(`move-my-cheese:landing digest=${first.result.digest} head=${sha(50, 3)}`))
})
