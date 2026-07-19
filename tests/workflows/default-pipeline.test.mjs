import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow } from './harness.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/default-pipeline.js')

// Acceptance (spec: orchestration-model-tiering): the plan and judge stages run
// on the deep-thinker brain (agentType, no call-site model — it inherits its
// fable/xhigh frontmatter pin), and the work stage runs on sonnet.

test('default-pipeline: plan+judge dispatch the deep-thinker brain, work fans out on sonnet', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'plan') {
        return { approach: 'split it', subtasks: [
          { label: 'a', brief: 'do a' },
          { label: 'b', brief: 'do b' },
        ] }
      }
      if (opts.label === 'a') return 'result a'
      if (opts.label === 'b') return 'result b'
      if (opts.label === 'judge') return 'final answer'
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: 'solve X' })

  assert.equal(result, 'final answer')

  const byLabel = Object.fromEntries(trace.agents.map((c) => [c.opts.label, c.opts]))

  // Plan: deep-thinker, no call-site model override (so it inherits fable/xhigh).
  assert.equal(byLabel.plan.agentType, 'deep-thinker')
  assert.equal(byLabel.plan.model, undefined)
  assert.ok(byLabel.plan.schema, 'plan stage requests structured output')

  // Work: one sonnet agent per subtask.
  assert.equal(byLabel.a.model, 'sonnet')
  assert.equal(byLabel.b.model, 'sonnet')
  assert.equal(byLabel.a.agentType, undefined)

  // Judge: deep-thinker, no call-site model override.
  assert.equal(byLabel.judge.agentType, 'deep-thinker')
  assert.equal(byLabel.judge.model, undefined)

  // Dispatch order: plan -> work fan-out -> judge.
  assert.deepEqual(trace.agents.map((c) => c.opts.label), ['plan', 'a', 'b', 'judge'])
})

test('default-pipeline: empty args returns an error and dispatches no agents', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: () => { throw new Error('should not dispatch') } })

  const result = await workflow.run({ ...globals, args: '   ' })

  assert.ok(result.error, 'returns an error object')
  assert.equal(trace.agents.length, 0)
})

test('default-pipeline: when every worker fails, it skips the judge and returns the plan + outputs', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'plan') return { approach: 'split it', subtasks: [{ label: 'a', brief: 'do a' }] }
      if (opts.label === 'a') throw new Error('worker crashed') // harness pipeline maps a throw to null
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: 'solve X' })

  // No judge dispatched — plan + work only.
  assert.deepEqual(trace.agents.map((c) => c.opts.label), ['plan', 'a'])
  assert.ok(result.plan, 'returns the plan')
  assert.ok(Array.isArray(result.outputs), 'returns the raw outputs')
})

test('default-pipeline: a plan with no subtasks returns the plan without a work/judge fan-out', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'plan') return { approach: 'nothing to split', subtasks: [] }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { problem: 'trivial' } })

  // result is built in the workflow's vm realm — assert on properties, not a
  // cross-realm deepEqual (prototype identity differs).
  assert.equal(result.plan.approach, 'nothing to split')
  assert.equal(result.plan.subtasks.length, 0)
  assert.deepEqual(trace.agents.map((c) => c.opts.label), ['plan'])
})
