// move-my-cheese per-target integration (AC-20) and verification through verify-criteria (AC-25).
import assert from 'node:assert/strict'
import test from 'node:test'

import {
  INT_WORKTREE, approve, built, failure, keepPlan, keepPlanRoutes, passingVerdict, plain, planRoutes, run, sha,
} from './move-my-cheese.fixtures.mjs'

const AC = (id) => ({ id, statement: `criterion ${id}`, check_kind: 'command', check: 'test -e src/1.js' })

// Four new targets; T-4 waits for T-2.
const fourTargetPlan = () => {
  const target = (n, depends_on = []) => ({ id: `T-${n}`, kind: 'new', pr: 0, branch: `land/t${n}`, base: depends_on.length ? 'T-2' : 'main', title: `feat: t${n}`, sources: n <= 2 ? [n] : [], brief: `build ${n}`, resolves: n === 1 ? ['TN-1'] : [], satisfies: ['AC-1'], depends_on })
  return {
    summary: 'four targets',
    dispositions: [
      { pr: 1, action: 'supersede', target: 'T-1', reason: 'rebuilt' },
      { pr: 2, action: 'supersede', target: 'T-2', reason: 'rebuilt' },
    ],
    targets: [target(1), target(2), target(3), target(4, ['T-2'])],
    criteria: [AC('AC-1')],
    open_questions: [],
  }
}
const buildRoutes = [1, 2, 3, 4].map((n) => [`target:T-${n}`, built(sha(50 + n), `/tmp/wt-t${n}`)])
const conflictRoute = ['integrate:T-2', failure('integrate', 'conflict', 'merge conflict', { integrated: [], conflict: { target: 'x', files: ['src/a.js'] }, sha: sha(1) })]

test('a target that conflicts fails alone, its dependent skips, and independent targets still integrate', async () => {
  const routes = planRoutes([['plan:minimal', fourTargetPlan()], ...buildRoutes, conflictRoute])
  const { args } = await approve(routes)
  const { result, raw, labels, wfxLabels, allLabels } = await run(args, routes)
  assert.equal(result.status, 'fail')
  assert.match(result.note, /T-2/)
  assert.match(result.note, /src\/a\.js/)
  assert.match(result.note, /T-4 \(skipped\)/)
  assert.ok(wfxLabels.includes('integrate:T-3'))
  assert.equal(allLabels.includes('target:T-4'), false)
  assert.equal(wfxLabels.includes('integrate:pre'), false)
  const order = raw.agents.map(({ opts }) => opts.label)
  for (const n of [1, 2, 3]) assert.ok(order.indexOf(`target:T-${n}`) < order.indexOf(`integrate:T-${n}`), `integrate:T-${n} follows its build`)
})

const twoCriteria = () => {
  const plan = keepPlan()
  return { ...plan, targets: plan.targets.map((t) => ({ ...t, satisfies: ['AC-1', 'AC-2'] })), criteria: [AC('AC-1'), AC('AC-2')] }
}
const twoRoutes = () => keepPlanRoutes([['plan:minimal', twoCriteria()]])

test('verification runs through verify-criteria on the integration worktree with fixed arguments', async () => {
  const { result, workflowCalls, wfxLabels } = await run({ prs: [1, 2], auto: true }, twoRoutes())
  assert.equal(result.status, 'ready')
  assert.equal(workflowCalls.length, 1)
  assert.deepEqual(workflowCalls[0], {
    name: 'verify-criteria',
    input: { worktree_path: INT_WORKTREE, head: sha(98), criteria: plain(twoCriteria().criteria), batch_size: 8, preflight: false },
  })
  assert.deepEqual(wfxLabels.filter((l) => l.startsWith('worktree:')), ['worktree:add:pre', 'worktree:remove:pre'])
})

test('a child that throws leaves every criterion not verified, and the worktree is still removed', async () => {
  const { result, wfxLabels } = await run({ prs: [1, 2], auto: true }, twoRoutes(), null, null, () => { throw new Error('boom') })
  assert.equal(result.status, 'fail')
  assert.deepEqual(plain(result.verification.verdicts).map((v) => v.result), ['fail', 'fail'])
  assert.match(result.verification.verdicts[0].evidence, /not verified: verify-criteria failed: boom/)
  assert.deepEqual(wfxLabels.filter((l) => l.startsWith('worktree:')), ['worktree:add:pre', 'worktree:remove:pre'])
})

test('a blocked child reports its reason in every verdict', async () => {
  const { result, wfxLabels } = await run({ prs: [1, 2], auto: true }, twoRoutes(), null, null, () => ({ status: 'blocked', reason: 'no shell' }))
  assert.equal(result.status, 'fail')
  for (const v of plain(result.verification.verdicts)) assert.match(v.evidence, /not verified: verify-criteria blocked: no shell/)
  assert.ok(wfxLabels.includes('worktree:remove:pre'))
})

test('a criterion the child lists as missing fails, and the others keep their verdicts', async () => {
  const verify = (input) => ({ status: 'partial', verdicts: [passingVerdict(input.criteria[0])], missing: ['AC-2'] })
  const { result, wfxLabels } = await run({ prs: [1, 2], auto: true }, twoRoutes(), null, null, verify)
  assert.equal(result.status, 'fail')
  assert.deepEqual(plain(result.verification.verdicts).map((v) => [v.criterion, v.result]), [['AC-1', 'pass'], ['AC-2', 'fail']])
  assert.match(result.verification.verdicts[1].evidence, /^not verified: /)
  assert.ok(wfxLabels.includes('worktree:remove:pre'))
})
