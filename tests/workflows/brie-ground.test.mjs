import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow } from './harness.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/brie-ground.js')

const claim = (text, extra = {}) => ({ claim: text, citation: 'https://example.com', confidence: 'speculating', decision_critical: true, ...extra })
const synth = { answer: 'a', confidence: 'speculating', evidence_table: [], prototype_decision: { warranted: false } }
const plan = (subs) => ({ restated_question: 'q', sub_questions: subs, stop_criteria: 's' })
const sub = (id) => ({ id, question: `sub ${id}`, route: 'web', depth: 'shallow' })

function respondWith({ recall = { reusable_claims: [], docs: [], fully_answers: false }, subs = [sub('q1')], claims = [], verdict = 'supported' }) {
  return ({ opts, prompt }) => {
    if (opts.label === 'recall') return recall
    if (opts.label === 'plan') return plan(subs)
    if (opts.label.startsWith('web:')) return { sub_question_id: opts.label.slice(4), route: 'web', claims }
    if (opts.label.startsWith('verify:')) return { claim: prompt.match(/^Claim: (.*)$/m)[1], verdict }
    if (opts.label === 'synthesize') return synth
    throw new Error(`unexpected agent ${opts.label}`)
  }
}

const verifies = (trace) => trace.agents.filter(({ opts }) => opts.label.startsWith('verify:'))

test('brie-ground checks each distinct decision-critical claim once, up to the cap, on sonnet', async () => {
  const workflow = await loadWorkflow(path)
  const claims = [
    claim('A is true'), claim('a  is TRUE'), claim('B is true'), claim('C is true', { confidence: 'dont_know' }),
    claim('D is true'), claim('E is true'), claim('F is true'),
    claim('G is certain', { confidence: 'certain' }), claim('H is minor', { decision_critical: false }),
  ]
  const { globals, trace } = createRuntime({ respond: respondWith({ claims, verdict: 'refuted' }) })

  await workflow.run({ ...globals, args: 'question?' })

  const checked = verifies(trace)
  assert.equal(checked.length, 4)
  assert.ok(checked.every(({ opts }) => opts.model === 'sonnet'))
  // A speculating claim outranks a dont_know claim, and a duplicate never gets its own check.
  assert.deepEqual(checked.map(({ prompt }) => prompt.match(/^Claim: (.*)$/m)[1]), ['A is true', 'B is true', 'D is true', 'E is true'])
  assert.ok(trace.logs.some((l) => /checking 4 of 6 distinct decision-critical claims/.test(l)))
  // Both copies of a checked claim carry its verdict into Synthesize.
  const synthPrompt = trace.agents.find(({ opts }) => opts.label === 'synthesize').prompt
  assert.equal(synthPrompt.match(/"refuted": true/g).length, 5)
})

test('brie-ground caps the plan at six sub-questions', async () => {
  const workflow = await loadWorkflow(path)
  const subs = Array.from({ length: 9 }, (_, i) => sub(`q${i + 1}`))
  const { globals, trace } = createRuntime({ respond: respondWith({ subs }) })

  const result = await workflow.run({ ...globals, args: 'question?' })

  assert.equal(result.sub_questions, 6)
  assert.equal(trace.agents.filter(({ opts }) => opts.label.startsWith('web:')).length, 6)
})

test('brie-ground does not trust a recall answer whose decision-critical claims went unchecked', async () => {
  const workflow = await loadWorkflow(path)
  const recall = {
    reusable_claims: Array.from({ length: 6 }, (_, i) => ({ claim: `cached ${i}`, citation: 'notes.md:1', confidence: 'speculating', decision_critical: true })),
    docs: ['notes.md'],
    fully_answers: true,
  }
  const { globals, trace } = createRuntime({ respond: respondWith({ recall }) })

  await workflow.run({ ...globals, args: 'question?' })

  assert.equal(verifies(trace).length, 4)
  assert.ok(trace.agents.some(({ opts }) => opts.label === 'plan'), 'unchecked cached claims must fall through to fresh research')
})

test('brie-ground trusts a recall answer whose decision-critical claims all survive the check', async () => {
  const workflow = await loadWorkflow(path)
  const recall = {
    reusable_claims: [{ claim: 'cached', citation: 'notes.md:1', confidence: 'speculating', decision_critical: true }],
    docs: ['notes.md'],
    fully_answers: true,
  }
  const { globals, trace } = createRuntime({ respond: respondWith({ recall }) })

  await workflow.run({ ...globals, args: 'question?' })

  assert.equal(trace.agents.some(({ opts }) => opts.label === 'plan'), false)
})
