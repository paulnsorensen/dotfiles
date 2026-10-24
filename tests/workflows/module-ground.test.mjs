import strictAssert from 'node:assert/strict'
// The module runs in its own realm, so deepEqual compares through JSON.
const json = (v) => JSON.parse(JSON.stringify(v))
const assert = { ...strictAssert, deepEqual: (a, e) => strictAssert.deepEqual(json(a), json(e)) }
import test from 'node:test'
import { loadModule } from '../../claude/workflow-prelude/load.mjs'

const load = (child) => {
  const logs = []
  const m = loadModule('ground', { globals: { log: (s) => logs.push(s), workflow: async (name, q) => child(name, q) } })
  return { m, logs }
}
const plain = (v) => JSON.parse(JSON.stringify(v))

test('groundingSchema_requiresDecisionsAndPriorResearchWithKnownKinds', () => {
  const { m } = load(() => null)
  assert.deepEqual(m.GROUNDING_SCHEMA.required, ['decisions', 'prior_research'])
  assert.deepEqual(m.GROUNDING_SCHEMA.properties.decisions.items.properties.kind.enum, loadModule('mold').DECISION_KINDS)
  assert.deepEqual(m.GROUND_RESEARCH_SCHEMA.required, ['decisions', 'prior_research', 'research_questions'])
  assert.equal(m.GROUND_RESEARCH_SCHEMA.properties.decisions, m.GROUNDING_SCHEMA.properties.decisions)
})

test('researchRule_namesTheMaximumAtCallTime', () => {
  const { m } = load(() => null)
  assert.match(m.researchRule(3), /^research_questions: at most 3 questions/)
  assert.match(m.researchRule(1), /at most 1 questions/)
})

test('brieGround_found_carriesTheAnswerAndNoDroppedKey', async () => {
  const { m, logs } = load(() => ({ answer: 'yes', confidence: 'certain', report_path: '/r.md', evidence_table: [{ citation: 'c0' }] }))
  const r = await m.brieGround('q')
  assert.deepEqual(plain(r), { found: { question: 'q', answer: 'yes', confidence: 'certain', report_path: '/r.md', citations: ['c0'] } })
  assert.deepEqual(logs, [])
})

test('brieGround_dontKnow_isUnsettledWithAtMostTwoFollowUps', async () => {
  const { m } = load(() => ({ answer: '', confidence: 'dont_know', open_questions: ['a', ' ', 'b'] }))
  assert.deepEqual(plain(await m.brieGround('q')), { unsettled: ['q', 'a', 'b'] })
})

test('brieGround_failures_returnFailedForThrowNullErrorAndBadConfidence', async () => {
  const thrown = load(() => { throw new Error('boom') })
  assert.deepEqual(plain(await thrown.m.brieGround('q')), { failed: 'research failed: q' })
  assert.match(thrown.logs[0], /boom/)
  for (const bad of [null, { error: 'x' }, { answer: 'a', confidence: 'sure' }, { answer: '', confidence: 'certain' }]) {
    assert.deepEqual(plain(await load(() => bad).m.brieGround('q')), { failed: 'research failed: q' }, JSON.stringify(bad))
  }
})

test('brieGround_cappedResult_returnsAndLogsTheDroppedCount', async () => {
  const cited = load(() => ({ answer: 'a', confidence: 'speculating', evidence_table: Array.from({ length: 9 }, (_, i) => ({ citation: `c${i}` })) }))
  const r = await cited.m.brieGround('q')
  assert.equal(r.dropped, 4)
  assert.equal(r.found.citations.length, 5)
  assert.match(cited.logs[0], /dropped 4 citation row\(s\) past the cap of 5/)
  const open = load(() => ({ answer: 'x', confidence: 'dont_know', open_questions: ['a', 'b', 'c', 'd'] }))
  const u = await open.m.brieGround('q')
  assert.equal(u.dropped, 2)
  assert.deepEqual(plain(u.unsettled), ['q', 'a', 'b'])
})
