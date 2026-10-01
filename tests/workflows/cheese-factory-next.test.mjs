import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow } from './harness.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/cheese-factory-next.js')

// ---- fixtures: each worker handback carries the ref the gate hook would return ----

let revCounter = 0
function nextRef(slug) {
  revCounter += 1
  return `wheypoint:acme/factory-parent--${slug}@rev-${revCounter.toString(16).padStart(12, '0')}`
}

function plan(curds) {
  return { mode: 'resolved', spec_path: '/specs/parent.md', slug: 'parent', landing_shape: 'stacked_linear', curds }
}

function curd(slug, depends_on = []) {
  return { slug, brief: `build ${slug}`, depends_on }
}

function graphFor(curds) {
  return { run_ref: 'wheypoint:acme/factory-parent@rev-000000000000', curds: curds.map((c) => ({ slug: c.slug, ref: nextRef(c.slug) })) }
}

// A scripted boss: per slug, a queue of actions; each turn pops one.
function respondWith({ curds, boss, coder = () => ({ status: 'ok', next: 'age' }), reviewer = () => ({ status: 'ok', next: 'done' }), keepRef = false, answers }) {
  const queues = Object.fromEntries(Object.entries(boss).map(([k, v]) => [k, [...v]]))
  return ({ opts }) => {
    const label = opts.label || ''
    const slug = label.split(':')[1]
    if (label === 'resolve') return plan(curds)
    if (label === 'graph') return graphFor(curds)
    if (label === 'answers') return answers || { curds: curds.map((c) => ({ slug: c.slug, ref: nextRef(c.slug) })) }
    if (label.startsWith('boss:')) {
      const action = queues[slug].shift()
      const ref = keepRef ? opts.__sent : nextRef(slug)
      if (action === 'raise_fork') {
        return { action, wheypoint_ref: ref, fork: { question: `Which base for ${slug}?`, options: [{ option: 'main', breaks: 'imports' }, { option: 'stack', breaks: 'bookkeeping' }] } }
      }
      return action === 'dispatch_coder' ? { action, wheypoint_ref: ref, brief: `implement ${slug}` } : { action, wheypoint_ref: ref }
    }
    if (label.startsWith('code:')) return { orientation: 'implemented', worktree_path: `/tmp/wt/${slug}`, wheypoint_ref: nextRef(slug), ...coder(slug) }
    if (label.startsWith('review:')) return { orientation: 'reviewed', wheypoint_ref: nextRef(slug), ...reviewer(slug) }
    if (label === 'integrate') return { worktree_path: '/tmp/wt/integration', merged: curds.map((c) => c.slug), conflicted: [] }
    if (label === 'review') return { status: 'ok', artifact: '.cheese/age/parent.md', orientation: 'clean' }
    if (label === 'plate') return { results: [{ slug: 'parent', status: 'ok', pr_url: 'https://example.com/pr/1' }] }
    throw new Error(`unexpected agent label ${label}`)
  }
}

const CLEAN = ['dispatch_coder', 'dispatch_review', 'finish']

async function run(respond, args) {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond })
  const result = await workflow.run({ ...globals, args })
  return { result, trace }
}

test('no spec returns usage without dispatching an agent', async () => {
  const { result, trace } = await run(() => { throw new Error('no agent expected') }, {})
  assert.match(result.error, /^Usage:/)
  assert.equal(trace.agents.length, 0)
})

test('a clean curd runs boss -> coder -> boss -> reviewer -> boss, then integrate, review, and plate', async () => {
  const curds = [curd('alpha')]
  const { result, trace } = await run(respondWith({ curds, boss: { alpha: CLEAN } }), { spec: 'parent' })
  assert.equal(result.status, 'done')
  assert.deepEqual(trace.agents.map((a) => a.opts.label), [
    'resolve', 'graph', 'boss:alpha:t1', 'code:alpha:t1', 'boss:alpha:t2', 'review:alpha:t2', 'boss:alpha:t3', 'integrate', 'review', 'plate',
  ])
  const types = Object.fromEntries(trace.agents.map((a) => [a.opts.label, a.opts.agentType]))
  assert.equal(types['boss:alpha:t1'], 'curd-boss')
  assert.equal(types['code:alpha:t1'], 'factory-coder')
  assert.equal(types['review:alpha:t2'], 'factory-reviewer')
})

test('a coder gets only the pinned ref and the boss brief, never prior JSON (AC-5)', async () => {
  const curds = [curd('alpha')]
  const { trace } = await run(respondWith({ curds, boss: { alpha: ['dispatch_coder', 'dispatch_coder', 'dispatch_review', 'finish'] } }), { spec: 'parent' })
  const coders = trace.agents.filter((a) => a.opts.agentType === 'factory-coder')
  assert.equal(coders.length, 2)
  for (const c of coders) {
    assert.match(c.prompt, /Ref: wheypoint:acme\/factory-parent--alpha@rev-[0-9a-f]{12}/)
    assert.match(c.prompt, /Brief: implement alpha/)
    assert.doesNotMatch(c.prompt, /"orientation"|Last worker result/)
  }
  assert.equal(coders[0].opts.isolation, 'worktree')
  assert.equal(coders[1].opts.isolation, undefined)
  assert.match(coders[1].prompt, /Worktree: \/tmp\/wt\/alpha/)
})

test('each agent receives the ref the previous handback returned', async () => {
  const curds = [curd('alpha')]
  const { trace } = await run(respondWith({ curds, boss: { alpha: CLEAN } }), { spec: 'parent' })
  const refs = trace.agents.filter((a) => /^(boss|code|review):/.test(a.opts.label)).map((a) => a.prompt.match(/Ref: (\S+)\./)[1])
  assert.equal(new Set(refs).size, refs.length, 'every dispatch carries a fresh pinned revision')
})

test('a fork parks its curd, siblings finish, and the run returns before integrate (AC-6)', async () => {
  const curds = [curd('alpha'), curd('beta')]
  const { result, trace } = await run(respondWith({ curds, boss: { alpha: ['raise_fork'], beta: CLEAN } }), { spec: 'parent' })
  assert.equal(result.status, 'gated')
  assert.deepEqual(result.forks.map((f) => f.slug), ['alpha'])
  assert.equal(result.forks[0].fork.question, 'Which base for alpha?')
  assert.equal(result.curds.find((c) => c.slug === 'beta').state, 'clean')
  assert.ok(!trace.agents.some((a) => ['integrate', 'review', 'plate'].includes(a.opts.label)))
})

test('a dependent of a parked curd is blocked and never dispatched', async () => {
  const curds = [curd('alpha'), curd('beta', ['alpha'])]
  const { result, trace } = await run(respondWith({ curds, boss: { alpha: ['raise_fork'], beta: CLEAN } }), { spec: 'parent' })
  assert.equal(result.curds.find((c) => c.slug === 'beta').state, 'blocked')
  assert.ok(!trace.agents.some((a) => a.opts.label.includes(':beta:')))
})

test('an unchanged ref means the gate hook did not run, so the curd fails closed (U-2)', async () => {
  const curds = [curd('alpha')]
  const respond = respondWith({ curds, boss: { alpha: CLEAN }, keepRef: true })
  const wrapped = (call) => {
    if (call.opts.label.startsWith('boss:')) call.opts.__sent = call.prompt.match(/Ref: (\S+)\./)[1]
    return respond(call)
  }
  const { result } = await run(wrapped, { spec: 'parent' })
  assert.equal(result.status, 'blocked')
  assert.match(result.curds[0].reason, /handback gate did not write the boss decision \(U-2\)/)
})

test('a coder halt marks the curd halted and keeps it out of plate (AC-8)', async () => {
  const curds = [curd('alpha'), curd('beta')]
  const { result, trace } = await run(respondWith({
    curds,
    boss: { alpha: CLEAN, beta: CLEAN },
    coder: (slug) => (slug === 'beta' ? { status: 'halt: gate failed', next: 'hold' } : { status: 'ok', next: 'age' }),
  }), { spec: 'parent' })
  assert.equal(result.curds.find((c) => c.slug === 'beta').state, 'halted')
  const integrate = trace.agents.find((a) => a.opts.label === 'integrate')
  assert.match(integrate.prompt, /curd\/alpha/)
  assert.doesNotMatch(integrate.prompt, /curd\/beta/)
})

test('resume with answers applies them before any boss turn and shows them to the boss (AC-7)', async () => {
  const curds = [curd('alpha')]
  const answers = { alpha: [{ entry_id: 'q-0123456789ab', decision: 'stack on alpha', quote: 'use the stack' }] }
  const { trace } = await run(respondWith({ curds, boss: { alpha: CLEAN } }), { spec: 'parent', answers })
  const labels = trace.agents.map((a) => a.opts.label)
  assert.ok(labels.indexOf('answers') < labels.indexOf('boss:alpha:t1'))
  assert.match(trace.agents.find((a) => a.opts.label === 'answers').prompt, /use the stack/)
  assert.match(trace.agents.find((a) => a.opts.label === 'boss:alpha:t1').prompt, /Fork answers from the user: .*use the stack/)
})

test('a depends_on cycle or unknown dependency stops before the graph', async () => {
  for (const curds of [[curd('alpha', ['beta']), curd('beta', ['alpha'])], [curd('alpha', ['ghost'])]]) {
    const { result, trace } = await run(respondWith({ curds, boss: {} }), { spec: 'parent' })
    assert.match(result.error, /^invalid curd plan/)
    assert.deepEqual(trace.agents.map((a) => a.opts.label), ['resolve'])
  }
})
