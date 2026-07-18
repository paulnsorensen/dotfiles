import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow } from './harness.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/curd-flock.js')

function implementation(slug, status = 'done', committed = true) {
  return {
    slug,
    branch: `curd/${slug}`,
    status,
    summary: 'implemented',
    files_changed: ['src/example.js'],
    verification: 'test: pass',
    committed,
    worktree_path: `/tmp/worktrees/${slug}`,
  }
}

function review(slug, verdict) {
  return {
    slug,
    verdict,
    lenses: [],
    issues: verdict === 'revise' ? ['fix this'] : [],
    recommendation: verdict,
  }
}

function correction(slug) {
  return {
    slug,
    branch: `curd/${slug}`,
    status: 'fixed',
    summary: 'fixed',
    committed: true,
  }
}

test('curd-flock caps revise corrections and re-reviews each correction', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'implement:task') return implementation('task')
      if (opts.label === 'review:task') return review('task', 'revise')
      if (opts.label === 'correct:task:r1' || opts.label === 'correct:task:r2') return correction('task')
      if (opts.label === 'review:task:r1') return review('task', 'revise')
      if (opts.label === 'review:task:r2') return review('task', 'pass')
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { tasks: [{ slug: 'task', brief: 'do it' }], correctiveRounds: 2 } })

  assert.equal(result.tasks[0].corrective_rounds_used, 2)
  assert.equal(result.tasks[0].status, 'revised-clean')
  assert.deepEqual(trace.agents.map(({ opts }) => opts.label), [
    'implement:task', 'review:task', 'correct:task:r1', 'review:task:r1', 'correct:task:r2', 'review:task:r2',
  ])

  for (const call of trace.agents.filter(({ opts }) => opts.label.startsWith('implement:'))) {
    assert.equal(call.opts.agentType, 'coder')
    assert.equal(call.opts.isolation, 'worktree')
  }
  for (const call of trace.agents.filter(({ opts }) => opts.label.startsWith('correct:'))) {
    assert.equal(call.opts.agentType, 'coder')
    assert.equal(call.opts.isolation, undefined)
  }
  for (const call of trace.agents.filter(({ opts }) => opts.label.startsWith('review:'))) {
    assert.equal(call.opts.agentType, 'reviewer')
  }
})

test('curd-flock skips corrections after a first-pass review', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => opts.label.startsWith('implement:') ? implementation('task') : review('task', 'pass'),
  })

  const result = await workflow.run({ ...globals, args: { tasks: [{ slug: 'task', brief: 'do it' }] } })

  assert.equal(result.tasks[0].status, 'clean')
  assert.equal(trace.agents.length, 2)
  assert.equal(trace.agents.some(({ opts }) => opts.label.startsWith('correct:')), false)
})

for (const [name, status, committed] of [
  ['non-done implementation', 'blocked', true],
  ['uncommitted implementation', 'done', false],
]) {
  test(`curd-flock reports failed work without reviewing a ${name}`, async () => {
    const workflow = await loadWorkflow(path)
    const { globals, trace } = createRuntime({
      respond: () => implementation('task', status, committed),
    })

    const result = await workflow.run({ ...globals, args: { tasks: [{ slug: 'task', brief: 'do it' }] } })

    assert.equal(result.tasks[0].status, 'failed')
    assert.equal(trace.agents.length, 1)
    assert.equal(trace.agents[0].opts.agentType, 'coder')
  })
}

test('curd-flock logs file overlap and gives coders/reviewers their required controls', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => opts.label.startsWith('implement:')
      ? implementation(opts.label.slice('implement:'.length))
      : review(opts.label.split(':')[1], 'pass'),
  })

  await workflow.run({
    ...globals,
    args: {
      tasks: [
        { slug: 'one', brief: 'one', files: ['shared.js'] },
        { slug: 'two', brief: 'two', files: ['shared.js'] },
      ],
    },
  })

  assert.match(trace.logs.join('\n'), /overlapping files/)
  for (const call of trace.agents.filter(({ opts }) => opts.label.startsWith('implement:'))) {
    assert.equal(call.opts.agentType, 'coder')
    assert.equal(call.opts.isolation, 'worktree')
  }
  for (const call of trace.agents.filter(({ opts }) => opts.label.startsWith('review:'))) {
    assert.equal(call.opts.agentType, 'reviewer')
  }
})

test('curd-flock fails fast on duplicate task slugs before spawning any agent', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: () => { throw new Error('no agent should be spawned') },
  })

  const result = await workflow.run({
    ...globals,
    args: { tasks: [{ slug: 'dup', brief: 'one' }, { slug: 'dup', brief: 'two' }] },
  })

  assert.match(result.error, /Duplicate task slug/)
  assert.equal(trace.agents.length, 0)
})

test('curd-flock keeps a task in the report when review crashes after a committed impl (finding 2)', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'implement:task') return implementation('task')
      if (opts.label === 'review:task') throw new Error('reviewer crashed')
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { tasks: [{ slug: 'task', brief: 'do it' }] } })

  // finding 2: a thrown agent() must not drop the task from the report — slug+branch and a failed status must survive.
  assert.equal(result.tasks.length, 1)
  assert.equal(result.tasks[0].slug, 'task')
  assert.equal(result.tasks[0].branch, 'curd/task')
  assert.equal(result.tasks[0].status, 'failed')
  assert.equal(result.tasks[0].failure.stage, 'review')
  assert.match(trace.logs.join('\n'), /review agent crashed/)
})

test('curd-flock reports failed when corrective rounds are exhausted with review still revise', async () => {
  const workflow = await loadWorkflow(path)
  const { globals } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'implement:task') return implementation('task')
      if (opts.label === 'review:task') return review('task', 'revise')
      if (opts.label === 'correct:task:r1') return correction('task')
      if (opts.label === 'review:task:r1') return review('task', 'revise')
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  // finding 6b: exhausting correctiveRounds without a clean review must land on status 'failed', not silently pass.
  const result = await workflow.run({ ...globals, args: { tasks: [{ slug: 'task', brief: 'do it' }], correctiveRounds: 1 } })

  assert.equal(result.tasks[0].status, 'failed')
  assert.equal(result.tasks[0].corrective_rounds_used, 1)
})

test('curd-flock stops the corrective loop on an uncommitted correction', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'implement:task') return implementation('task')
      if (opts.label === 'review:task') return review('task', 'revise')
      if (opts.label === 'correct:task:r1') return { ...correction('task'), committed: false }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  // finding 6c: an uncommitted correction must break the loop immediately rather than re-reviewing nothing.
  const result = await workflow.run({ ...globals, args: { tasks: [{ slug: 'task', brief: 'do it' }], correctiveRounds: 2 } })

  assert.equal(result.tasks[0].status, 'failed')
  assert.equal(result.tasks[0].corrective_rounds_used, 1)
  assert.equal(trace.agents.filter(({ opts }) => opts.label.startsWith('correct:')).length, 1)
  assert.match(trace.logs.join('\n'), /uncommitted correction/)
})

test('curd-flock accepts args as a JSON string', async () => {
  const workflow = await loadWorkflow(path)
  const { globals } = createRuntime({
    respond: ({ opts }) => opts.label.startsWith('implement:') ? implementation('task') : review('task', 'pass'),
  })

  // finding 6d: args may arrive as a JSON string (some Workflow-tool invocations serialize it) rather than an object.
  const result = await workflow.run({ ...globals, args: JSON.stringify({ tasks: [{ slug: 'task', brief: 'do it' }] }) })

  assert.equal(result.tasks[0].status, 'clean')
})

for (const bad of [-1, 1.5, 'two', null]) {
  test(`curd-flock falls back to correctiveRounds=1 for invalid value ${JSON.stringify(bad)}`, async () => {
    const workflow = await loadWorkflow(path)
    const { globals } = createRuntime({
      respond: ({ opts }) => {
        if (opts.label === 'implement:task') return implementation('task')
        if (opts.label === 'review:task') return review('task', 'revise')
        if (opts.label === 'correct:task:r1') return correction('task')
        if (opts.label === 'review:task:r1') return review('task', 'pass')
        throw new Error(`unexpected agent ${opts.label}`)
      },
    })

    // finding 6e: a negative/non-integer correctiveRounds must fall back to the default of 1, not 0 or NaN rounds.
    const result = await workflow.run({ ...globals, args: { tasks: [{ slug: 'task', brief: 'do it' }], correctiveRounds: bad } })

    assert.equal(result.tasks[0].corrective_rounds_used, 1)
    assert.equal(result.tasks[0].status, 'revised-clean')
  })
}

for (const [name, tasks] of [
  ['metachar slug', [{ slug: 'task; rm -rf', brief: 'do it' }]],
  ['missing slug', [{ brief: 'do it' }]],
  ['missing brief', [{ slug: 'task' }]],
  ['empty brief', [{ slug: 'task', brief: '' }]],
]) {
  test(`curd-flock fails fast on ${name} before spawning any agent (finding 1)`, async () => {
    const workflow = await loadWorkflow(path)
    const { globals, trace } = createRuntime({
      respond: () => { throw new Error('no agent should be spawned') },
    })

    // finding 1: curd/<slug> is interpolated into a literal `git checkout -B` command — an invalid slug must reject before any agent spawns.
    const result = await workflow.run({ ...globals, args: { tasks } })

    assert.match(result.error, /Invalid task slug\/brief/)
    assert.equal(trace.agents.length, 0)
  })
}

test('curd-flock clamps correctiveRounds above the max of 3 (finding 4)', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label.startsWith('implement:')) return implementation('task')
      if (opts.label.startsWith('correct:')) return correction('task')
      return review('task', 'revise')
    },
  })

  // finding 4: correctiveRounds must clamp to MAX_CORRECTIVE_ROUNDS (3), mirroring triage-sweep's MAX_LIMIT pattern.
  const result = await workflow.run({ ...globals, args: { tasks: [{ slug: 'task', brief: 'do it' }], correctiveRounds: 10 } })

  assert.equal(result.tasks[0].corrective_rounds_used, 3)
  assert.match(trace.logs.join('\n'), /clamping to 3/)
})
