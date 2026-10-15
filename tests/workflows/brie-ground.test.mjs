import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow } from './harness.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/brie-ground.js')

const claim = (text, extra = {}) => ({ claim: text, citation: 'https://example.com', confidence: 'speculating', decision_critical: true, ...extra })
const synth = { answer: 'a', confidence: 'speculating', evidence_table: [], prototype_decision: { warranted: false } }
const plan = (subs) => ({ restated_question: 'q', sub_questions: subs, stop_criteria: 's' })
const sub = (id) => ({ id, question: `sub ${id}`, route: 'web', depth: 'shallow' })

function respondWith({ recall = { reusable_claims: [], docs: [], fully_answers: false }, subs = [sub('q1')], claims = [], verdict = 'supported', synthOut = synth }) {
  return ({ opts, prompt }) => {
    if (opts.label === 'recall') return recall
    if (opts.label === 'plan') return plan(subs)
    if (opts.label.startsWith('web:')) return { sub_question_id: opts.label.slice(4), route: 'web', claims }
    if (opts.label.startsWith('verify:')) return { claim: prompt.match(/^Claim: (.*)$/m)[1], verdict }
    if (opts.label === 'synthesize') return synthOut
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

  const result = await workflow.run({ ...globals, args: 'question?' })
  // C and F are past the cap, so the result reports them as unchecked.
  assert.equal(result.unchecked_claims, 2)

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

test('brie-ground caps the plan at five sub-questions and reports the rest as open', async () => {
  const workflow = await loadWorkflow(path)
  const subs = Array.from({ length: 9 }, (_, i) => sub(`q${i + 1}`))
  const { globals, trace } = createRuntime({ respond: respondWith({ subs, synthOut: { ...synth, confidence: 'certain', open_questions: ['sub q6'] } }) })

  const result = await workflow.run({ ...globals, args: 'question?' })

  const dropped = ['sub q6', 'sub q7', 'sub q8', 'sub q9']
  assert.equal(result.sub_questions, 5)
  assert.deepEqual([...result.dropped_sub_questions], dropped)
  assert.equal(trace.agents.filter(({ opts }) => opts.label.startsWith('web:')).length, 5)
  // Parents read open_questions and confidence, so the dropped questions reach them without repeats.
  assert.deepEqual([...result.open_questions], dropped)
  assert.equal(result.confidence, 'speculating')
  assert.match(trace.agents.find(({ opts }) => opts.label === 'synthesize').prompt, /NOT GROUNDED .*sub q6 \| sub q7 \| sub q8 \| sub q9/)
  assert.match(trace.agents.find(({ opts }) => opts.label === 'plan').prompt, /2-5 focused sub-questions/)
})

test('the same claim with a different citation gets its own check', async () => {
  const workflow = await loadWorkflow(path)
  const claims = [claim('A is true'), claim('A is true', { citation: 'https://other.example.com' })]
  const { globals, trace } = createRuntime({ respond: respondWith({ claims }) })

  await workflow.run({ ...globals, args: 'question?' })

  assert.deepEqual(verifies(trace).map(({ prompt }) => prompt.match(/^Stated citation: (.*)$/m)[1]), ['https://example.com', 'https://other.example.com'])
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

test('a refute agent that returns nothing leaves its claim unchecked, so recall falls through', async () => {
  const workflow = await loadWorkflow(path)
  const recall = {
    reusable_claims: [{ claim: 'cached', citation: 'notes.md:1', confidence: 'speculating', decision_critical: true }],
    docs: ['notes.md'],
    fully_answers: true,
  }
  const respond = respondWith({ recall })
  const { globals, trace } = createRuntime({ respond: (call) => (call.opts.label.startsWith('verify:') ? null : respond(call)) })

  await workflow.run({ ...globals, args: 'question?' })

  assert.ok(trace.agents.some(({ opts }) => opts.label === 'plan'))
})

test('the worst-case run stays within the 100 agents each caller budgets for one brie-ground child', async () => {
  const workflow = await loadWorkflow(path)
  const many = (prefix, n) => Array.from({ length: n }, (_, i) => claim(`${prefix} claim ${i}`))
  const evidence = (label, route) => ({ sub_question_id: label, route, claims: many(label, 10) })
  const { globals, trace } = createRuntime({
    respond: ({ opts, prompt }) => {
      const l = opts.label
      if (l === 'recall') return { reusable_claims: many('cached', 10), docs: ['notes.md'], fully_answers: false }
      if (l === 'plan') return plan(Array.from({ length: 9 }, (_, i) => ({ id: `q${i + 1}`, question: `sub ${i + 1}`, route: 'mixed', depth: 'deep' })))
      if (l.startsWith('deep-scope:')) return { angles: Array.from({ length: 6 }, (_, i) => ({ label: `a${i}`, query: 'q' })) }
      if (l.startsWith('deep-search:')) return { results: Array.from({ length: 6 }, (_, i) => ({ url: `https://${l}/${i}`, title: 't', relevance: 'high' })) }
      if (l.startsWith('deep-extract:')) return { sourceQuality: 'primary', claims: Array.from({ length: 4 }, (_, i) => ({ claim: `${prompt.match(/^URL: (.*)$/m)[1]} ${i}`, quote: 'q', importance: 'central' })) }
      if (/^(wiki|web|code):/.test(l)) return evidence(l, l.split(':')[0])
      if (l.startsWith('verify:')) return { claim: prompt.match(/^Claim: (.*)$/m)[1], verdict: 'supported' }
      if (l === 'synthesize') return { ...synth, prototype_decision: { warranted: true, spec: { goal: 'g' } } }
      if (l === 'prototype') return { built: true, conclusion: 'c', confirms_grounded_answer: 'confirms' }
      if (l === 'prototype-verify') return { claim: 'c', verdict: 'supported' }
      throw new Error(`unexpected agent ${l}`)
    },
  })

  await workflow.run({ ...globals, args: 'question?' })

  const count = (re) => trace.agents.filter(({ opts }) => re.test(opts.label)).length
  assert.equal(count(/^deep-scope:/), 3)
  assert.equal(count(/^deep-search:/), 18)
  assert.equal(count(/^deep-extract:/), 36)
  assert.equal(count(/^verify:/), 24)
  assert.equal(trace.agents.length, 96)
  assert.ok(trace.agents.length <= 100)
  assert.deepEqual(trace.agents.filter(({ opts }) => /^(deep-|verify:|wiki:)/.test(opts.label) && opts.model !== 'sonnet').map(({ opts }) => opts.label), [])
})
