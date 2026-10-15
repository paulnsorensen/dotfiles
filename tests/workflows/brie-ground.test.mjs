import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow } from './harness.mjs'
import { cached, claim, dataItems, evidence, plan, prototype, recall, respondWith, sub, synth, verdicts, warranted } from './brie-ground.fixtures.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/brie-ground.js')

const labeled = (trace, re) => trace.agents.filter(({ opts }) => re.test(opts.label))
const promptOf = (trace, label) => trace.agents.find(({ opts }) => opts.label === label).prompt
// A default parameter would turn an explicit undefined args into the default question, so read the rest list.
const run = async (respond, extra = {}, ...rest) => {
  const args = rest.length ? rest[0] : 'question?'
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond, ...extra })
  const result = await workflow.run({ ...globals, args })
  return { result, trace }
}

test('Verify sends each distinct decision-critical claim, up to the cap, to one batched explorer agent on sonnet', async () => {
  const claims = [
    claim('A is true'), claim('a  is TRUE'), claim('B is true'), claim('C is true', { confidence: 'dont_know' }),
    claim('D is true'), claim('E is true'), claim('F is true'),
    claim('G is certain', { confidence: 'certain' }), claim('H is minor', { decision_critical: false }),
  ]
  const { result, trace } = await run(respondWith({ claims, verdict: 'refuted' }))

  const checks = labeled(trace, /^verify:/)
  assert.deepEqual(checks.map(({ opts }) => [opts.label, opts.agentType, opts.model]), [['verify:q1', 'explorer', 'sonnet']])
  // A speculating claim outranks a dont_know claim, and a duplicate never gets its own item.
  assert.deepEqual(dataItems(checks[0].prompt, 'C-').map(({ id, claim: c }) => [id, c]), [['C-1', 'A is true'], ['C-2', 'B is true'], ['C-3', 'D is true'], ['C-4', 'E is true']])
  // C and F are past the cap, so the result reports them as unchecked.
  assert.equal(result.unchecked_claims, 2)
  assert.ok(trace.logs.some((l) => /checking 4 of 6 distinct decision-critical claims/.test(l)))
  // Both copies of a checked claim carry its verdict into Synthesize.
  assert.equal(promptOf(trace, 'synthesize').match(/"refuted": ?true/g).length, 5)
})

test('the same claim with a different citation gets its own item', async () => {
  const claims = [claim('A is true'), claim('A is true', { citation: 'https://other.example.com' })]
  const { trace } = await run(respondWith({ claims }))

  const [check] = labeled(trace, /^verify:/)
  assert.deepEqual(dataItems(check.prompt, 'C-').map(({ citation }) => citation), ['https://example.com', 'https://other.example.com'])
})

test('an unknown or repeated verdict id is ignored and a claim with no verdict stays unchecked', async () => {
  const claims = [claim('A is true'), claim('B is true')]
  const base = respondWith({ claims })
  const v = (id) => ({ id, verdict: 'supported', note: '', corrected_claim: '' })
  const respond = (call) => (call.opts.label === 'verify:q1' ? { verdicts: [v('C-1'), v('C-9'), v('C-1')] } : base(call))
  const { result, trace } = await run(respond)

  assert.equal(result.unchecked_claims, 1)
  assert.ok(trace.logs.some((l) => /ignored 2 verdict/.test(l)))
  assert.ok(trace.logs.some((l) => /1 of 2 claim\(s\) got no verdict/.test(l)))
})

test('the plan caps at five sub-questions, code assigns the ids, and the rest are open', async () => {
  const subs = Array.from({ length: 9 }, (_, i) => sub(i + 1, { id: 'dup' }))
  const { result, trace } = await run(respondWith({ subs, synthOut: synth({ confidence: 'certain', open_questions: ['sub q6'] }) }))

  const dropped = ['sub q6', 'sub q7', 'sub q8', 'sub q9']
  assert.equal(result.sub_questions, 5)
  assert.deepEqual([...result.dropped_sub_questions], dropped)
  assert.deepEqual(labeled(trace, /^web:/).map(({ opts }) => opts.label), ['web:q1', 'web:q2', 'web:q3', 'web:q4', 'web:q5'])
  assert.deepEqual([...result.open_questions], dropped)
  assert.equal(result.confidence, 'speculating')
  assert.match(promptOf(trace, 'synthesize'), /NOT GROUNDED .*sub q6 \| sub q7 \| sub q8 \| sub q9/)
})

test('a recall answer whose decision-critical claims went unchecked falls through to Plan', async () => {
  const recallOut = recall(Array.from({ length: 6 }, (_, i) => cached(`cached ${i}`)), true)
  const { trace } = await run(respondWith({ recallOut }))

  const checks = labeled(trace, /^verify:recall$/)
  assert.equal(checks.length, 1)
  assert.equal(dataItems(checks[0].prompt, 'C-').length, 4)
  assert.ok(labeled(trace, /^plan$/).length, 'unchecked cached claims must fall through to fresh research')
})

test('a recall answer whose claims survive the check skips Plan; a null check falls through', async () => {
  const recallOut = recall([cached('cached')], true)
  const kept = await run(respondWith({ recallOut }))
  assert.equal(labeled(kept.trace, /^plan$/).length, 0)

  const base = respondWith({ recallOut })
  const nullCheck = await run((call) => (call.opts.label.startsWith('verify:') ? null : base(call)))
  assert.equal(labeled(nullCheck.trace, /^plan$/).length, 1)
})

test('recall reads the mold research store and Synthesize writes there with source_kind research', async () => {
  const { trace } = await run(respondWith({ recallOut: recall([cached('cached')], false) }))

  assert.match(promptOf(trace, 'recall'), /mold\.pyz artifact-path research probe/)
  const synthPrompt = promptOf(trace, 'synthesize')
  assert.match(synthPrompt, /artifact-path research <slug>/)
  assert.match(synthPrompt, /"source_kind": ?"research"/)
})

test('the recall check does not block Plan when recall cannot answer alone', async () => {
  let planSeen
  const planned = new Promise((r) => { planSeen = r })
  let blocked = null
  const base = respondWith({ recallOut: recall([cached('cached')], false) })
  const respond = async (call) => {
    if (call.opts.label === 'plan') planSeen()
    if (call.opts.label === 'verify:recall') {
      blocked = !(await Promise.race([planned.then(() => true), new Promise((r) => setTimeout(() => r(false), 200))]))
    }
    return base(call)
  }
  await run(respond)

  assert.equal(blocked, false)
})

test('deep search is one agent; code caps, dedups, and batches the extract fetches', async () => {
  const url = (a, r) => (r < 3 ? `https://www.shared.example/${r}/` : `https://a${a}.example/${r}?x=1`)
  const respond = ({ opts, prompt }) => {
    const l = opts.label
    if (l === 'recall') return recall()
    if (l === 'plan') return plan([sub(1, { depth: 'deep' })])
    if (l === 'wiki:q1') return evidence('q1', 'wiki', [])
    if (l === 'deep-search:q1') {
      return { angles: Array.from({ length: 8 }, (_, a) => ({ label: `a${a}`, query: 'q', results: Array.from({ length: 8 }, (_, r) => ({ url: url(a, r), title: 't', snippet: 's', relevance: 'high' })) })) }
    }
    if (l.startsWith('deep-extract:q1:')) {
      const ids = dataItems(prompt, 'S-').map(({ id }) => id).filter((id) => id !== 'S-12')
      return { sources: [...ids, 'S-99'].map((id) => ({ id, sourceQuality: 'primary', claims: Array.from({ length: 6 }, (_, i) => ({ claim: `${id} ${i}`, quote: 'q', importance: 'central' })) })) }
    }
    if (l.startsWith('verify:')) return verdicts(prompt, 'supported')
    if (l === 'synthesize') return synth()
    throw new Error(`unexpected agent ${l}`)
  }
  const { trace } = await run(respond)

  assert.deepEqual(labeled(trace, /^deep-/).map(({ opts }) => opts.label), ['deep-search:q1', 'deep-extract:q1:1', 'deep-extract:q1:2', 'deep-extract:q1:3'])
  const logged = (re) => assert.ok(trace.logs.some((l) => re.test(l)), String(re))
  logged(/kept 6 of 8 angles/)
  logged(/dropped 12 search result/)
  logged(/21 novel sources → fetching 12 \(9 past/)
  logged(/1 source\(s\) returned no extract/)
  logged(/dropped 22 claim\(s\)/)
  assert.equal(promptOf(trace, 'synthesize').match(/"source_kind": ?"web"/g).length, 44)
})

test('args with no question string return a usage error and start no agents', async () => {
  for (const args of [{ topic: 'x' }, ['q?'], { question: '  ' }, undefined]) {
    const { result, trace } = await run(respondWith(), {}, args)
    assert.match(result.error, /\{ question: "<question>" \}/, JSON.stringify(args))
    assert.equal(trace.agents.length, 0)
  }
  const { result } = await run(respondWith(), {}, { question: 'q?' })
  assert.equal(result.question, 'q?')
})

test('a sub-question with no evidence is reported, not dropped, and caps confidence', async () => {
  const base = respondWith({ subs: [sub(1), sub(2)], synthOut: synth({ confidence: 'certain' }) })
  const { result, trace } = await run((call) => (call.opts.label === 'web:q2' ? null : base(call)))

  assert.deepEqual([...result.failed_sub_questions], ['sub q2'])
  assert.ok(result.open_questions.includes('sub q2'))
  assert.equal(result.confidence, 'speculating')
  assert.match(promptOf(trace, 'synthesize'), /NOT GROUNDED .*sub q2/)
})

test('code caps a certain answer when a decision-critical claim is not verified', async () => {
  const synthOut = synth({ confidence: 'certain' })
  const uncertain = await run(respondWith({ claims: [claim('A')], verdict: 'uncertain', synthOut }))
  assert.equal(uncertain.result.confidence, 'speculating')
  const supported = await run(respondWith({ claims: [claim('A')], verdict: 'supported', synthOut }))
  assert.equal(supported.result.confidence, 'certain')
})

test('a null plan or synthesis gets one bounded redo', async () => {
  const base = respondWith()
  const { trace } = await run((call) => (call.opts.label.startsWith('plan') ? null : base(call)))
  assert.deepEqual(labeled(trace, /^plan/).map(({ opts }) => opts.label), ['plan', 'plan:redo1'])

  const nullSynth = await run((call) => (call.opts.label.startsWith('synthesize') ? null : base(call)))
  assert.equal(nullSynth.result.error, 'Synthesis failed.')
  assert.deepEqual(labeled(nullSynth.trace, /^synthesize/).map(({ opts }) => opts.label), ['synthesize', 'synthesize:redo1'])
})

test('under the budget floor the run skips deep escalation and the prototype', async () => {
  const base = respondWith({ subs: [sub(1, { depth: 'deep' })], synthOut: synth({ prototype_decision: warranted }) })
  const { trace } = await run(base, { budgetTotal: 100000, budgetSpent: 90000 })

  assert.deepEqual(labeled(trace, /^(deep-|prototype)/).map(({ opts }) => opts.label), [])
  assert.ok(trace.logs.some((l) => /Budget floor: q1 downgraded/.test(l)))
  assert.ok(trace.logs.some((l) => /Prototype warranted but skipped/.test(l)))
})

test('the worst-case run starts 33 agents, with explorer and sonnet on every mechanical stage', async () => {
  const many = (prefix, n) => Array.from({ length: n }, (_, i) => claim(`${prefix} claim ${i}`))
  const respond = ({ opts, prompt }) => {
    const l = opts.label
    if (l === 'recall') return recall(Array.from({ length: 10 }, (_, i) => cached(`cached ${i}`)), false)
    if (l === 'plan') return plan(Array.from({ length: 9 }, (_, i) => sub(i + 1, { route: 'mixed', depth: 'deep' })))
    if (l.startsWith('deep-search:')) {
      return { angles: Array.from({ length: 6 }, (_, a) => ({ label: `a${a}`, query: 'q', results: Array.from({ length: 6 }, (_, r) => ({ url: `https://${l}/${a}/${r}`, title: 't', snippet: 's', relevance: 'high' })) })) }
    }
    if (l.startsWith('deep-extract:')) {
      return { sources: dataItems(prompt, 'S-').map(({ id, url }) => ({ id, sourceQuality: 'primary', claims: Array.from({ length: 4 }, (_, i) => ({ claim: `${url} ${i}`, quote: 'q', importance: 'central' })) })) }
    }
    if (/^(wiki|web|code):/.test(l)) return evidence(l, l.split(':')[0], many(l, 10))
    if (l.startsWith('verify:')) return verdicts(prompt, 'supported')
    if (l === 'synthesize') return synth({ prototype_decision: warranted })
    if (l === 'prototype') return prototype
    if (l === 'prototype-verify') return { verdict: 'supported', note: '' }
    throw new Error(`unexpected agent ${l}`)
  }
  const { trace } = await run(respond)

  const count = (re) => labeled(trace, re).length
  assert.equal(count(/^deep-search:/), 3)
  assert.equal(count(/^deep-extract:/), 9)
  assert.equal(count(/^verify:/), 6)
  assert.equal(trace.agents.length, 33)
  const workers = trace.agents.filter(({ opts }) => /^(recall|deep-|verify:|wiki:|code:|prototype-verify)/.test(opts.label))
  assert.deepEqual(workers.filter(({ opts }) => opts.agentType !== 'explorer').map(({ opts }) => opts.label), [])
  assert.deepEqual(labeled(trace, /^(deep-|verify:|wiki:)/).filter(({ opts }) => opts.model !== 'sonnet').map(({ opts }) => opts.label), [])
})
