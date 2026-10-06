import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow } from './harness.mjs'

const path = resolve(import.meta.dirname, '../../skills/claude-workflows/assets/workflow-template.js')

const criterion = (id, check) => ({ id, statement: `${id} holds`, check_kind: 'command', check })
const task = (id, satisfies, depends_on = []) => ({ id, brief: `do ${id}`, satisfies, depends_on })
const plan = (over = {}) => ({
  criteria: [criterion('AC-1', 'tool --version'), criterion('AC-2', 'just docs')],
  tasks: [task('T-1', ['AC-1']), task('T-2', ['AC-2'], ['T-1'])],
  open_questions: [],
  ...over,
})
const approve = { verdict: 'approve', concerns: [], guidance: 'sound' }
const done = (checkpoint = 'sha-done') => ({ status: 'done', completed: ['all'], remaining: [], checkpoint, note: '' })
const partial = (checkpoint) => ({ status: 'partial', completed: ['half'], remaining: ['rest'], checkpoint, note: 'low context' })
const pass = (id) => ({ criterion: id, passes: true, evidence: 'ran check: exit 0' })

// Route fixtures by label; an unknown label fails the test loudly. A null
// route models a subagent that died: the runtime returns null without schema
// validation, so the shared harness agent() is bypassed for that call.
function runtime(routes) {
  const rt = createRuntime({
    respond: ({ opts }) => {
      if (!Object.hasOwn(routes, opts.label)) throw new Error(`unexpected agent ${opts.label}`)
      return routes[opts.label]
    },
  })
  const validated = rt.globals.agent
  rt.globals.agent = async (prompt, opts = {}) => {
    if (routes[opts.label] !== null) return validated(prompt, opts)
    rt.trace.agents.push({ prompt, opts, index: rt.trace.agents.length })
    return null
  }
  return rt
}

const happy = {
  plan: plan(),
  'advise:plan:0': approve,
  'task:T-1': done(),
  'task:T-2': done(),
  'verify:AC-1': pass('AC-1'),
  'verify:AC-2': pass('AC-2'),
  'advise:done': approve,
}
const labels = (trace) => trace.agents.map(({ opts }) => opts.label)

test('happy path plans, advises, runs dependency waves, verifies each criterion, and advises before done', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = runtime(happy)

  const result = await workflow.run({ ...globals, args: 'add a version flag' })

  assert.equal(result.status, 'pass')
  assert.deepEqual(labels(trace), ['plan', 'advise:plan:0', 'task:T-1', 'task:T-2', 'verify:AC-1', 'verify:AC-2', 'advise:done'])
  const t1 = trace.agents.find(({ opts }) => opts.label === 'task:T-1')
  assert.match(t1.prompt, /tool --version/)
  assert.doesNotMatch(t1.prompt, /just docs/, 'a task sees only the criteria it satisfies')
  assert.equal(t1.opts.isolation, 'worktree')
  const advisor = trace.agents.find(({ opts }) => opts.label === 'advise:plan:0')
  assert.equal(advisor.opts.agentType, 'reviewer')
  assert.equal(advisor.opts.model, 'opus')
})

test('a form error goes to a haiku repair, not a rerun of the producer', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = runtime({
    ...happy,
    'verify:AC-1': { ...pass('AC-1'), criterion: 'ac-1' },
    'verify:AC-1:repair1': pass('AC-1'),
  })

  const result = await workflow.run({ ...globals, args: { goal: 'g' } })

  assert.equal(result.status, 'pass')
  const repair = trace.agents.find(({ opts }) => opts.label === 'verify:AC-1:repair1')
  assert.equal(repair.opts.model, 'haiku')
  assert.equal(repair.opts.effort, 'low')
  assert.match(repair.prompt, /'ac-1' should be 'AC-1'/)
})

test('a substance error reruns the producer with the failed checks', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = runtime({
    ...happy,
    plan: plan({ tasks: [task('T-1', ['AC-1']), task('T-2', ['AC-1'], ['T-1'])] }),
    'plan:redo1': plan(),
  })

  const result = await workflow.run({ ...globals, args: { goal: 'g' } })

  assert.equal(result.status, 'pass')
  const redo = trace.agents.find(({ opts }) => opts.label === 'plan:redo1')
  assert.equal(redo.opts.model, undefined, 'substance goes back to the producer tier')
  assert.match(redo.prompt, /AC-2 has no task/)
})

test('a dependency cycle that survives every fix round blocks before any write', async () => {
  const workflow = await loadWorkflow(path)
  const cyclic = plan({ tasks: [task('T-1', ['AC-1'], ['T-2']), task('T-2', ['AC-2'], ['T-1'])] })
  const { globals, trace } = runtime({ plan: cyclic, 'plan:redo1': cyclic, 'plan:redo2': cyclic })

  const result = await workflow.run({ ...globals, args: { goal: 'g' } })

  assert.equal(result.status, 'blocked')
  assert.match(result.errors[0], /dependency cycle among T-1, T-2/)
  assert.deepEqual(labels(trace), ['plan', 'plan:redo1', 'plan:redo2'])
})

test('partial work resumes from its checkpoint, and a dead agent is salvaged from durable state', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = runtime({
    ...happy,
    'task:T-1': partial('sha-1'),
    'task:T-1:c1': done(),
    'task:T-2': null,
    'salvage:T-2': { found: true, checkpoint: 'sha-9', completed: ['a'], remaining: ['b'] },
    'task:T-2:c1': done(),
  })

  const result = await workflow.run({ ...globals, args: { goal: 'g' } })

  assert.equal(result.status, 'pass')
  assert.match(trace.agents.find(({ opts }) => opts.label === 'task:T-1:c1').prompt, /sha-1/)
  assert.match(trace.agents.find(({ opts }) => opts.label === 'task:T-2:c1').prompt, /sha-9/)
  assert.equal(trace.agents.find(({ opts }) => opts.label === 'salvage:T-2').opts.model, 'haiku')
})

test('a continuation with no new checkpoint stalls, skips dependents, and fails without a verifier', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = runtime({ ...happy, 'task:T-1': partial('sha-1'), 'task:T-1:c1': partial('sha-1') })

  const result = await workflow.run({ ...globals, args: { goal: 'g' } })

  assert.equal(result.status, 'fail')
  assert.equal(result.tasks.map((t) => `${t.id}:${t.status}`).join(' '), 'T-1:stalled T-2:skipped')
  assert.deepEqual(labels(trace), ['plan', 'advise:plan:0', 'task:T-1', 'task:T-1:c1'])
  assert.ok(trace.logs.some((line) => /Skipped 1 task\(s\): T-2/.test(line)), 'dropped coverage is logged')
  assert.match(result.verdicts[0].evidence, /not verified: T-1 not done/)
})

test('an advisor stop ends the run before any implementer starts', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = runtime({
    plan: plan(),
    'advise:plan:0': { verdict: 'stop', concerns: ['wrong layer'], guidance: 'use the existing adapter' },
  })

  const result = await workflow.run({ ...globals, args: { goal: 'g' } })

  assert.equal(result.status, 'stopped')
  assert.equal(trace.agents.some(({ opts }) => opts.label.startsWith('task:')), false)
})

test('an advisor revise replans once with its concerns, then proceeds on approve', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = runtime({
    ...happy,
    'advise:plan:0': { verdict: 'revise', concerns: ['split T-1'], guidance: 'smaller tasks' },
    'plan:r1': plan(),
    'advise:plan:1': approve,
  })

  const result = await workflow.run({ ...globals, args: { goal: 'g' } })

  assert.equal(result.status, 'pass')
  assert.match(trace.agents.find(({ opts }) => opts.label === 'plan:r1').prompt, /split T-1/)
})

test('open questions return to the user before the advisor runs', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = runtime({ plan: plan({ open_questions: ['which flag name?'] }) })

  const result = await workflow.run({ ...globals, args: { goal: 'g' } })

  assert.equal(result.status, 'needs-input')
  assert.deepEqual(result.questions, ['which flag name?'])
  assert.deepEqual(labels(trace), ['plan'])
})

test('a missing goal blocks before the first agent call', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = runtime({})

  const result = await workflow.run({ ...globals, args: undefined })

  assert.equal(result.status, 'blocked')
  assert.equal(trace.agents.length, 0)
})
