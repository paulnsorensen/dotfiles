import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow } from './harness.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/age-fanout.js')

const BASE_ARGS = { worktree_path: '/tmp/worktrees/parent', range: 'origin/main...HEAD', slug: 'parent' }
const DIMS = ['correctness', 'security', 'deslop']

function packetOk(dims = DIMS, slug = 'parent') {
  return { dimensions: dims, packet_path: `.cheese/age/${slug}-packet.md` }
}

function reviewOk(dim, findings = []) {
  return { findings: findings.length ? findings : [{ dimension: dim, severity: 'medium', file: 'src/a.ts', line: 1, claim: 'x', why_it_matters: 'y', fix_direction: 'z', also_relevant_to: [] }] }
}

function reconcileOk({ hasMediumPlus = true, slug = 'parent', perCurd } = {}) {
  const out = { has_medium_plus_findings: hasMediumPlus, artifact: `.cheese/age/${slug}.md` }
  if (perCurd) out.per_curd = perCurd
  return out
}

function respondHappy({ slug = 'parent', dims = DIMS } = {}) {
  return ({ opts }) => {
    if (opts.label === 'packet') return packetOk(dims, slug)
    if (opts.label.startsWith('review:')) return reviewOk(opts.label.slice('review:'.length))
    if (opts.label === 'reconcile') return reconcileOk({ slug })
    throw new Error(`unexpected agent ${opts.label}`)
  }
}

test('missing worktree_path returns blocked with zero agents dispatched', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: () => { throw new Error('should not dispatch') } })

  const result = await workflow.run({ ...globals, args: { range: BASE_ARGS.range, slug: BASE_ARGS.slug } })

  assert.equal(result.status, 'blocked')
  assert.match(result.error, /worktree_path/)
  assert.equal(trace.agents.length, 0)
})

test('worktree_path with a space is rejected', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: () => { throw new Error('should not dispatch') } })

  const result = await workflow.run({ ...globals, args: { ...BASE_ARGS, worktree_path: '/tmp/bad path' } })

  assert.equal(result.status, 'blocked')
  assert.match(result.error, /worktree_path/)
  assert.equal(trace.agents.length, 0)
})

test('worktree_path with a semicolon is rejected', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: () => { throw new Error('should not dispatch') } })

  const result = await workflow.run({ ...globals, args: { ...BASE_ARGS, worktree_path: '/tmp/bad;rm' } })

  assert.equal(result.status, 'blocked')
  assert.match(result.error, /worktree_path/)
  assert.equal(trace.agents.length, 0)
})

test('missing range returns blocked', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: () => { throw new Error('should not dispatch') } })

  const result = await workflow.run({ ...globals, args: { worktree_path: BASE_ARGS.worktree_path, slug: BASE_ARGS.slug } })

  assert.equal(result.status, 'blocked')
  assert.match(result.error, /range/)
  assert.equal(trace.agents.length, 0)
})

test('bad slug returns blocked', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: () => { throw new Error('should not dispatch') } })

  const result = await workflow.run({ ...globals, args: { ...BASE_ARGS, slug: 'Not A Slug!' } })

  assert.equal(result.status, 'blocked')
  assert.match(result.error, /slug/)
  assert.equal(trace.agents.length, 0)
})

test('malformed route_curds entry returns blocked', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: () => { throw new Error('should not dispatch') } })

  const result = await workflow.run({ ...globals, args: { ...BASE_ARGS, route_curds: [{ slug: 'ok', branch: 'curd/ok' }, { slug: 'Bad Slug', branch: 'curd/bad' }] } })

  assert.equal(result.status, 'blocked')
  assert.match(result.error, /route_curds/)
  assert.equal(trace.agents.length, 0)
})

test('happy path fans out one review agent per dimension and reconciles', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: respondHappy() })

  const result = await workflow.run({ ...globals, args: BASE_ARGS })

  const reviewCalls = trace.agents.filter((c) => c.opts.label.startsWith('review:'))
  assert.equal(reviewCalls.length, 3)
  for (const dim of DIMS) {
    const call = reviewCalls.find((c) => c.opts.label === `review:${dim}`)
    assert.ok(call, `expected a review:${dim} agent`)
    assert.equal(call.opts.phase, 'Review')
  }

  assert.equal(result.status, 'ok')
  assert.equal(result.artifact, '.cheese/age/parent.md')
  assert.equal(result.has_medium_plus_findings, true)
  assert.deepEqual(JSON.parse(JSON.stringify(result.dimensions)), DIMS)
  assert.equal(result.per_curd, null)
})

test('one worker throws: the other two still dispatch, reconcile sees only survivors, a lost-worker message is logged', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'packet') return packetOk()
      if (opts.label === 'review:correctness') throw new Error('worker crashed')
      if (opts.label === 'review:security') return reviewOk('security', [{ dimension: 'security', severity: 'high', file: 'src/b.ts', line: 2, claim: 'sec', why_it_matters: 'y', fix_direction: 'z', also_relevant_to: [] }])
      if (opts.label === 'review:deslop') return reviewOk('deslop', [{ dimension: 'deslop', severity: 'low', file: 'src/c.ts', line: 3, claim: 'slop', why_it_matters: 'y', fix_direction: 'z', also_relevant_to: [] }])
      if (opts.label === 'reconcile') return reconcileOk()
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: BASE_ARGS })

  const reviewCalls = trace.agents.filter((c) => c.opts.label.startsWith('review:'))
  assert.equal(reviewCalls.length, 3)

  const reconcileCall = trace.agents.find((c) => c.opts.label === 'reconcile')
  assert.ok(reconcileCall)
  assert.ok(reconcileCall.prompt.includes('src/b.ts'))
  assert.ok(reconcileCall.prompt.includes('src/c.ts'))
  assert.ok(!reconcileCall.prompt.includes('correctness'))

  assert.ok(trace.logs.some((l) => /lost/.test(l)))
  assert.equal(result.status, 'ok')
})

test('packet returns no dimensions: blocked after exactly one agent call', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'packet') return { dimensions: [], packet_path: '.cheese/age/parent-packet.md' }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: BASE_ARGS })

  assert.equal(result.status, 'blocked')
  assert.equal(trace.agents.length, 1)
})

test('route_curds given: per_curd echoes the reconcile fixture and the reconcile prompt carries route_curds info', async () => {
  const workflow = await loadWorkflow(path)
  const routeCurds = [{ slug: 'alpha', branch: 'curd/alpha' }, { slug: 'beta', branch: 'curd/beta' }]
  const perCurdFixture = [
    { slug: 'alpha', has_medium_plus_findings: true, findings: [{ dimension: 'correctness', severity: 'medium', file: 'src/a.ts', line: 1, claim: 'finding-1', why_it_matters: 'y', fix_direction: 'z' }] },
    { slug: 'beta', has_medium_plus_findings: false, findings: [] },
  ]
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'packet') return packetOk()
      if (opts.label.startsWith('review:')) return reviewOk(opts.label.slice('review:'.length))
      if (opts.label === 'reconcile') return reconcileOk({ perCurd: perCurdFixture })
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { ...BASE_ARGS, route_curds: routeCurds } })

  assert.deepEqual(JSON.parse(JSON.stringify(result.per_curd)), perCurdFixture)

  const reconcileCall = trace.agents.find((c) => c.opts.label === 'reconcile')
  assert.ok(reconcileCall.prompt.includes('curd/alpha'))
  assert.ok(reconcileCall.prompt.includes('curd/beta'))
})

test('a review prompt points at dimensions.md and does not copy its rubric text', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: respondHappy() })

  await workflow.run({ ...globals, args: BASE_ARGS })

  const securityReview = trace.agents.find((c) => c.opts.label === 'review:security')
  assert.ok(securityReview.prompt.includes('references/dimensions.md'))
  assert.ok(!securityReview.prompt.includes('caller-shadowed domain invariant'))
})

test('all review workers lost: returns blocked, no reconcile call', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'packet') return packetOk()
      if (opts.label.startsWith('review:')) throw new Error('worker crashed')
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: BASE_ARGS })

  assert.equal(result.status, 'blocked')
  assert.equal(trace.agents.some((c) => c.opts.label === 'reconcile'), false)
})
