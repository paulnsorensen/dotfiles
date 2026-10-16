import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow, validate } from './harness.mjs'

// Review follows the age-route plan, and Reconcile writes through the age skill gated writer.
const path = resolve(import.meta.dirname, '../../claude/workflows/age-fanout.js')
const BASE_ARGS = { worktree_path: '/tmp/worktrees/parent', range: 'origin/main...HEAD', slug: 'parent' }

const assignment = (id, subjects = [id]) => ({ id, subjects, targets: ['src/a.ts'], effort: 'medium' })
const PLAN_3 = [assignment('general', ['changed-behavior', 'reuse', 'simplification']), assignment('conventions'), assignment('altitude')]
const PLAN_7 = [...PLAN_3, assignment('security'), assignment('caller-impact'), assignment('removed-behavior'), assignment('spec-tests')]
const finding = { dimension: 'correctness', severity: 'medium', file: 'src/a.ts', line: 1, claim: 'x', why_it_matters: 'y', fix_direction: 'z', also_relevant_to: [] }

async function run(assignments) {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'packet') return { skill_files_ok: true, blocked_reason: '', assignments }
      if (opts.label.startsWith('review:')) return { status: 'ok', blocked_reason: '', findings: [finding] }
      if (opts.label === 'reconcile') return { status: 'ok', blocked_reason: '', has_medium_plus_findings: true, has_cheap_lows: false, artifact: '.cheese/age/parent.md' }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })
  const result = await workflow.run({ ...globals, args: BASE_ARGS })
  return { result, trace, reviews: trace.agents.filter((c) => c.opts.label.startsWith('review:')) }
}

test('a route plan of 3 assignments starts exactly 3 reviewers, one per assignment', async () => {
  const { result, reviews } = await run(PLAN_3)

  assert.equal(result.status, 'ok')
  assert.deepEqual(reviews.map((c) => c.opts.label), ['review:general', 'review:conventions', 'review:altitude'])
  assert.match(reviews[0].prompt, /changed-behavior/)
  assert.match(reviews[0].prompt, /simplification/)
  assert.deepEqual([...result.assignments], ['general', 'conventions', 'altitude'])
})

test('the packet prompt plans assignments through age-route and locks the tree', async () => {
  const { trace } = await run(PLAN_3)
  const packet = trace.agents.find((c) => c.opts.label === 'packet').prompt

  assert.match(packet, /age\.pyz age-route/)
  assert.match(packet, /age\.pyz review-lock --slug parent/)
})

test('code caps the review wave at 5 reviewers and logs the dropped assignments', async () => {
  const { result, trace, reviews } = await run(PLAN_7)

  assert.equal(result.status, 'ok')
  assert.equal(reviews.length, 5)
  assert.deepEqual([...result.dropped_assignments], ['removed-behavior', 'spec-tests'])
  assert.ok(trace.logs.some((l) => /removed-behavior, spec-tests/.test(l)))
  assert.match(trace.agents.find((c) => c.opts.label === 'reconcile').prompt, /removed-behavior/)
})

test('a result without blocked_reason fails validation in all three schemas', async () => {
  const { trace } = await run(PLAN_3)
  const schemaOf = (label) => trace.agents.find((c) => c.opts.label === label).opts.schema
  const cases = [
    ['packet', { skill_files_ok: true, assignments: PLAN_3 }],
    ['review:general', { status: 'ok', findings: [finding] }],
    ['reconcile', { status: 'ok', has_medium_plus_findings: true, has_cheap_lows: false, artifact: 'a' }],
  ]

  for (const [label, value] of cases) {
    validate({ ...value, blocked_reason: '' }, schemaOf(label))
    assert.throws(() => validate(value, schemaOf(label)), { name: 'SchemaError' }, label)
  }
})

test('the Reconcile prompt writes the report through the age skill gated writer', async () => {
  const { trace } = await run(PLAN_3)
  const prompt = trace.agents.find((c) => c.opts.label === 'reconcile').prompt

  assert.match(prompt, /age\.pyz write-handoff-artifact --phase age --slug parent/)
  assert.ok(prompt.includes('tilth_write to the absolute path `/tmp/worktrees/parent/.cheese/age/parent-body.md`'))
  assert.doesNotMatch(prompt, /tilth_write to the absolute path `\/tmp\/worktrees\/parent\/\.cheese\/age\/parent\.md`/)
})
