// move-my-cheese Ground and Research: wiki decisions and brie-ground answers reach the planners, the advisors, and the landing.
import assert from 'node:assert/strict'
import test from 'node:test'

import {
  approveP1, builtConsolidation, consolidatePlan, grounded, noTensions, openPr, plain, planRoutes, reconRoutes, detail, run, survey,
} from './move-my-cheese.fixtures.mjs'

const DECISION = { statement: 'Workflows never merge without --match-head-commit.', kind: 'locked', citation: 'architecture/move-my-cheese-workflow.md:40', items: ['#1'] }
const call = (trace, label) => trace.agents.find(({ opts }) => opts.label === label)
const dataOf = (text, name) => {
  const m = new RegExp(`<data name="${name}">\\n([\\s\\S]*?)\\n</data>`).exec(text)
  return m ? JSON.parse(m[1]) : null
}
const answer = (q, over = {}) => ({ answer: `answer to ${q}`, confidence: 'certain', report_path: '/research/r.md', evidence_table: [{ citation: 'https://example.test' }], ...over })
const found = (q) => ({ question: q, answer: `answer to ${q}`, confidence: 'certain', report_path: '/research/r.md', citations: ['https://example.test'] })
// Zero tensions and complete PRs: without grounding, this run takes the keep-all plan.
const quietRoutes = (overrides = []) => [...overrides, ...reconRoutes([openPr(1), openPr(2)], [detail(1), detail(2)]), ['survey', survey], ['tensions', noTensions]]
// A consolidation plan that resolves no tension, for a run where Tensions found none.
const untensed = () => {
  const p = consolidatePlan()
  return { ...p, targets: p.targets.map((t) => ({ ...t, resolves: [] })) }
}
const researching = (questions) => ['ground', grounded({ research_questions: questions })]
const childFor = (fn) => {
  const calls = []
  const child = async (name, q) => {
    calls.push({ name, q })
    return fn(q)
  }
  return { calls, child }
}

test('ground runs beside tensions over the PR digests, cited as #<number>', async () => {
  const { trace, labels } = await run({ prs: [1, 2] }, planRoutes())
  const g = call(trace, 'ground')
  assert.equal(g.opts.agentType, 'explorer')
  assert.equal(g.opts.phase, 'Ground')
  assert.deepEqual(dataOf(g.prompt, 'items').map((i) => i.id), ['#1', '#2'])
  assert.ok(labels.indexOf('ground') > labels.indexOf('survey:2') && labels.indexOf('ground') < labels.indexOf('plan:minimal'))
})

test('with no grounding, a quiet run keeps the keep-all plan and the landing has no grounding field', async () => {
  const { result, labels } = await run({ prs: [1, 2] }, quietRoutes())
  assert.equal(result.status, 'needs-approval')
  assert.equal(result.plan_source, 'default')
  assert.equal(labels.some((l) => l.startsWith('plan:')), false)
  assert.equal(Object.hasOwn(result.landing, 'grounding'), false)
  assert.equal(Object.hasOwn(result, 'gaps'), false)
})

test('a decision on a PR skips the keep-all plan and reaches the planner, the advisor, and the landing', async () => {
  const { result, trace } = await run({ prs: [1, 2] }, quietRoutes([['ground', grounded({ decisions: [DECISION] })], ['plan:minimal', untensed()], ['advise:plan:0', approveP1]]))
  const expected = [{ id: 'D-1', ...DECISION }]
  assert.deepEqual(dataOf(call(trace, 'plan:minimal').prompt, 'context').decisions, expected)
  assert.deepEqual(dataOf(call(trace, 'advise:plan:0').prompt, 'context').decisions, expected)
  assert.equal(result.plan_source, 'minimal')
  assert.deepEqual(plain(result.landing.grounding), { decisions: expected, research: [] })
})

test('a repo-wide decision alone keeps the keep-all plan but still rides in the landing', async () => {
  const { result } = await run({ prs: [1, 2] }, quietRoutes([['ground', grounded({ decisions: [{ ...DECISION, items: [] }] })]]))
  assert.equal(result.plan_source, 'default')
  assert.equal(plain(result.landing.grounding).decisions[0].id, 'D-1')
})

test('a bare PR number in a decision is repaired to #<number>', async () => {
  let n = 0
  const { result, labels } = await run({ prs: [1, 2] }, planRoutes([['ground', () => (n++ ? grounded({ decisions: [DECISION] }) : grounded({ decisions: [{ ...DECISION, items: ['1'] }] }))]]))
  assert.ok(labels.includes('ground:repair1'))
  assert.deepEqual(plain(result.landing.grounding).decisions[0].items, ['#1'])
})

test('a ground failure is a gap: the plan still runs, and the result names the gap', async () => {
  const { result } = await run({ prs: [1, 2] }, planRoutes([['ground', null]]))
  assert.equal(result.status, 'needs-approval')
  assert.deepEqual(plain(result.gaps), ['wiki grounding failed; the plan ran without recorded decisions'])
})

test('a settled research answer reaches the planner and the landing', async () => {
  const { calls, child } = childFor((q) => answer(q))
  const { result, trace } = await run({ prs: [1, 2] }, planRoutes([researching(['Is gh 2.60 current?'])]), null, child)
  assert.deepEqual(calls, [{ name: 'brie-ground', q: 'Is gh 2.60 current?' }])
  assert.deepEqual(dataOf(call(trace, 'plan:minimal').prompt, 'context').research, [found('Is gh 2.60 current?')])
  assert.deepEqual(plain(result.landing.grounding.research), [found('Is gh 2.60 current?')])
  assert.equal(result.status, 'needs-approval')
})

test('an unsettled answer becomes an open question even when the planner drops it', async () => {
  const { child } = childFor(() => answer('x', { confidence: 'dont_know', open_questions: ['Which gh?'] }))
  const { result, trace } = await run({ prs: [1, 2] }, planRoutes([researching(['Is gh 2.60 current?'])]), null, child)
  assert.deepEqual(dataOf(call(trace, 'plan:minimal').prompt, 'context').unsettled_research, ['Is gh 2.60 current?', 'Which gh?'])
  assert.equal(result.status, 'needs-input')
  assert.deepEqual(plain(result.questions), ['Is gh 2.60 current?', 'Which gh?'])
  assert.deepEqual(plain(result.landing.plan.open_questions), ['Is gh 2.60 current?', 'Which gh?'])
})

test('questions over the cap run no child and become open questions; repeats run once', async () => {
  const { calls, child } = childFor((q) => answer(q))
  const { result } = await run({ prs: [1, 2] }, planRoutes([researching(['q1', ' q1 ', 'q2', 'q3'])]), null, child)
  assert.deepEqual(calls.map((c) => c.q), ['q1', 'q2'])
  assert.equal(result.status, 'needs-input')
  assert.deepEqual(plain(result.questions), ['q3'])
})

test('a failed research child blocks the run before any planner', async () => {
  const { child } = childFor(() => { throw new Error('tavily down') })
  const { result, labels } = await run({ prs: [1, 2] }, planRoutes([researching(['Is gh 2.60 current?'])]), null, child)
  assert.equal(result.status, 'blocked')
  assert.equal(result.error, 'research failed: Is gh 2.60 current?')
  assert.equal(labels.some((l) => l.startsWith('plan:')), false)
})

test('the approve run reads grounding from the landing: no new Ground, and the done advisor sees it', async () => {
  const first = await run({ prs: [1, 2] }, builtConsolidation([['ground', grounded({ decisions: [DECISION] })]]))
  assert.equal(first.result.status, 'needs-approval')
  const second = await run({ prs: [1, 2], plan: plain(first.result.landing), approve: first.result.digest }, builtConsolidation())
  assert.equal(second.result.status, 'ready')
  assert.equal(second.labels.includes('ground'), false)
  assert.deepEqual(dataOf(call(second.trace, 'advise:done').prompt, 'payload').grounding.decisions[0].id, 'D-1')
})

test('an approval made before Ground has no grounding field and still executes with its digest', async () => {
  const first = await run({ prs: [1, 2] }, builtConsolidation())
  assert.equal(Object.hasOwn(first.result.landing, 'grounding'), false)
  const second = await run({ prs: [1, 2], plan: plain(first.result.landing), approve: first.result.digest }, builtConsolidation())
  assert.equal(second.result.status, 'ready')
  assert.equal(Object.hasOwn(dataOf(call(second.trace, 'advise:done').prompt, 'payload'), 'grounding'), false)
})

test('a fold planner gets the landing grounding in its context', async () => {
  const first = await run({ prs: [1, 2] }, planRoutes([['ground', grounded({ decisions: [DECISION] })]]))
  const second = await run({ prs: [1, 2], plan: plain(first.result.landing), approve: first.result.digest, revise: 'rename T-1' }, [
    ...reconRoutes([openPr(1), openPr(2)], [detail(1), detail(2)]),
    ['plan:revise', consolidatePlan({ summary: 'renamed' })],
    ['advise:plan:revise', approveP1],
  ])
  assert.equal(second.result.status, 'needs-approval')
  assert.equal(second.labels.includes('ground'), false)
  assert.equal(dataOf(call(second.trace, 'plan:revise').prompt, 'context').decisions[0].id, 'D-1')
  assert.deepEqual(plain(second.result.landing.grounding), plain(first.result.landing.grounding))
})

test('when the advisor cannot settle, each candidate landing still carries the unsettled question', async () => {
  const { child } = childFor(() => answer('x', { confidence: 'dont_know', open_questions: [] }))
  const { result } = await run({ prs: [1, 2] }, planRoutes([researching(['Is gh 2.60 current?']), ['advise:plan:0', null]]), null, child)
  assert.equal(result.status, 'needs-input')
  assert.ok(result.candidates.length >= 1)
  for (const c of plain(result.candidates)) assert.deepEqual(c.landing.plan.open_questions, ['Is gh 2.60 current?'])
})

test('a planner copy that differs only in case or spacing is not added twice', async () => {
  const { child } = childFor(() => answer('x', { confidence: 'dont_know', open_questions: [] }))
  const { result } = await run({ prs: [1, 2] }, planRoutes([researching(['Is gh 2.60 current?']), ['plan:minimal', consolidatePlan({ open_questions: ['  is GH 2.60   current? '] })]]), null, child)
  assert.equal(result.status, 'needs-input')
  assert.deepEqual(plain(result.questions), ['  is GH 2.60   current? '])
})
