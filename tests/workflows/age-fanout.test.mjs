import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow } from './harness.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/age-fanout.js')

const BASE_ARGS = { worktree_path: '/tmp/worktrees/parent', range: 'origin/main...HEAD', slug: 'parent' }
const DIMS = ['correctness', 'security', 'deslop']

function packetOk(dims = DIMS, slug = 'parent') {
  return { skill_files_ok: true, dimensions: dims, packet_path: `.cheese/age/${slug}-packet.md` }
}

function reviewOk(dim, findings = []) {
  return { status: 'ok', findings: findings.length ? findings : [{ dimension: dim, severity: 'medium', file: 'src/a.ts', line: 1, claim: 'x', why_it_matters: 'y', fix_direction: 'z', also_relevant_to: [] }] }
}

function reconcileOk({ hasMediumPlus = true, slug = 'parent', perCurd } = {}) {
  const out = { status: 'ok', has_medium_plus_findings: hasMediumPlus, has_cheap_lows: false, artifact: `.cheese/age/${slug}.md` }
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
  const reviewers = trace.agents.filter((c) => c.opts.agentType === 'reviewer')
  assert.equal(reviewers.length, DIMS.length + 1)
  for (const c of reviewers) assert.match(c.prompt, /^Review mode: severity-report\n/)
})

test('a worker that throws once is retried, and reconcile sees every dimension', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'packet') return packetOk()
      if (opts.label === 'review:correctness') throw new Error('worker crashed')
      if (opts.label === 'review:correctness:retry') return reviewOk('correctness', [{ dimension: 'correctness', severity: 'high', file: 'src/a.ts', line: 1, claim: 'bug', why_it_matters: 'y', fix_direction: 'z', also_relevant_to: [] }])
      if (opts.label === 'review:security') return reviewOk('security', [{ dimension: 'security', severity: 'high', file: 'src/b.ts', line: 2, claim: 'sec', why_it_matters: 'y', fix_direction: 'z', also_relevant_to: [] }])
      if (opts.label === 'review:deslop') return reviewOk('deslop', [{ dimension: 'deslop', severity: 'low', file: 'src/c.ts', line: 3, claim: 'slop', why_it_matters: 'y', fix_direction: 'z', also_relevant_to: [] }])
      if (opts.label === 'reconcile') return reconcileOk()
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: BASE_ARGS })

  const reviewCalls = trace.agents.filter((c) => c.opts.label.startsWith('review:'))
  assert.equal(reviewCalls.length, 4)

  const reconcileCall = trace.agents.find((c) => c.opts.label === 'reconcile')
  for (const file of ['src/a.ts', 'src/b.ts', 'src/c.ts']) assert.ok(reconcileCall.prompt.includes(file))
  assert.ok(trace.logs.some((l) => /review:correctness attempt 1 failed/.test(l)))
  assert.equal(result.status, 'ok')
})

test('a worker blocked by its contract twice blocks the run instead of passing clean', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'packet') return packetOk()
      if (opts.label.startsWith('review:security')) return { status: 'blocked', blocked_reason: 'missing-contract', findings: [] }
      if (opts.label.startsWith('review:')) return reviewOk(opts.label.slice('review:'.length))
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: BASE_ARGS })

  assert.equal(result.status, 'blocked')
  assert.match(result.error, /dimensions not reviewed: security/)
  assert.equal(trace.agents.filter((c) => c.opts.label.startsWith('review:security')).length, 2)
  assert.equal(trace.agents.some((c) => c.opts.label === 'reconcile'), false)
})

test('a blocked reconcile blocks the run', async () => {
  const workflow = await loadWorkflow(path)
  const { globals } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'packet') return packetOk()
      if (opts.label.startsWith('review:')) return reviewOk(opts.label.slice('review:'.length))
      if (opts.label === 'reconcile') return { status: 'blocked', blocked_reason: 'missing-contract', has_medium_plus_findings: true, has_cheap_lows: false, artifact: '' }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: BASE_ARGS })

  assert.equal(result.status, 'blocked')
  assert.match(result.error, /reconcile blocked: missing-contract/)
})

test('reviewer prompts read the age files directly and reconcile writes the report by absolute path', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'packet') return packetOk()
      if (opts.label.startsWith('review:')) return reviewOk(opts.label.slice('review:'.length))
      if (opts.label === 'reconcile') return { ...reconcileOk(), artifact: '/elsewhere/report.md' }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: BASE_ARGS })

  for (const c of trace.agents.filter((a) => a.opts.agentType === 'reviewer')) {
    assert.match(c.prompt, /Do not load the age skill or any other skill through the Skill tool/)
    assert.match(c.prompt, /Never return status ok for a review you did not run/)
  }
  const reconcileCall = trace.agents.find((c) => c.opts.label === 'reconcile')
  assert.ok(reconcileCall.prompt.includes('tilth_write to the absolute path `/tmp/worktrees/parent/.cheese/age/parent.md`'))
  assert.equal(result.artifact, '.cheese/age/parent.md')
})

test('packet returns no dimensions: blocked after exactly one agent call', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'packet') return { skill_files_ok: true, dimensions: [], packet_path: '.cheese/age/parent-packet.md' }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: BASE_ARGS })

  assert.equal(result.status, 'blocked')
  assert.equal(trace.agents.length, 1)
})

test('route_curds given: reconcile returns flat findings with severity and fix_cost_now, no per_curd, and the prompt drops git-log ownership', async () => {
  const workflow = await loadWorkflow(path)
  const routeCurds = [{ slug: 'alpha', branch: 'curd/alpha' }, { slug: 'beta', branch: 'curd/beta' }]
  const findingsFixture = [
    { dimension: 'correctness', severity: 'medium', fix_cost_now: 'contained', file: 'src/a.ts', line: 1, claim: 'finding-1', why_it_matters: 'y', fix_direction: 'z' },
    { dimension: 'deslop', severity: 'low', fix_cost_now: 'sprawling', file: 'src/b.ts', line: 2, claim: 'finding-2', why_it_matters: 'y', fix_direction: 'z' },
  ]
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'packet') return packetOk()
      if (opts.label.startsWith('review:')) return reviewOk(opts.label.slice('review:'.length))
      if (opts.label === 'reconcile') return { ...reconcileOk(), findings: findingsFixture }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { ...BASE_ARGS, route_curds: routeCurds } })

  assert.deepEqual(JSON.parse(JSON.stringify(result.findings)), findingsFixture)
  assert.ok(result.findings.every((f) => f.severity && f.fix_cost_now))
  assert.equal('per_curd' in result, false)
  assert.equal(result.artifact, '.cheese/age/parent.md')
  assert.equal(result.has_medium_plus_findings, true)
  assert.equal(result.has_cheap_lows, false)

  const reconcileCall = trace.agents.find((c) => c.opts.label === 'reconcile')
  assert.ok(!reconcileCall.prompt.includes('--name-only'))
  assert.ok(!reconcileCall.prompt.includes('per-finding ownership'))
  assert.ok(!reconcileCall.prompt.includes('per_curd'))
  assert.match(reconcileCall.prompt, /fix_cost_now/)
})

test('route_curds given but reconcile omits findings: the schema requires findings and no empty list is invented', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: respondHappy() })

  const result = await workflow.run({ ...globals, args: { ...BASE_ARGS, route_curds: [{ slug: 'alpha', branch: 'curd/alpha' }] } })

  assert.equal(result.findings, undefined)
  assert.ok(trace.agents.find((c) => c.opts.label === 'reconcile').opts.schema.required.includes('findings'))
})

test('route_curds absent: the reconcile schema does not require findings', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: respondHappy() })

  await workflow.run({ ...globals, args: BASE_ARGS })

  assert.equal(trace.agents.find((c) => c.opts.label === 'reconcile').opts.schema.required.includes('findings'), false)
})

test('route_curds given: finding items require severity, fix_cost_now, and file; absent: items have no required list', async () => {
  const workflow = await loadWorkflow(path)
  const route = createRuntime({ respond: respondHappy() })
  await workflow.run({ ...route.globals, args: { ...BASE_ARGS, route_curds: [{ slug: 'alpha', branch: 'curd/alpha' }] } })
  const items = route.trace.agents.find((c) => c.opts.label === 'reconcile').opts.schema.properties.findings.items
  for (const key of ['severity', 'fix_cost_now', 'file']) assert.ok(items.required.includes(key), key)

  const plain = createRuntime({ respond: respondHappy() })
  await workflow.run({ ...plain.globals, args: BASE_ARGS })
  const plainItems = plain.trace.agents.find((c) => c.opts.label === 'reconcile').opts.schema.properties.findings.items
  assert.equal(plainItems.required, undefined)
})

test('route mode asks for repo-relative finding paths in review and reconcile prompts; non-route review keeps the plain file hint', async () => {
  const workflow = await loadWorkflow(path)
  const PHRASE = 'repo-relative path, no leading ./, no absolute prefix'
  const route = createRuntime({ respond: respondHappy() })
  await workflow.run({ ...route.globals, args: { ...BASE_ARGS, route_curds: [{ slug: 'alpha', branch: 'curd/alpha' }] } })
  const review = route.trace.agents.find((c) => c.opts.label.startsWith('review:'))
  assert.ok(review.prompt.includes(PHRASE))
  assert.ok(route.trace.agents.find((c) => c.opts.label === 'reconcile').prompt.includes(PHRASE))

  const plain = createRuntime({ respond: respondHappy() })
  await workflow.run({ ...plain.globals, args: BASE_ARGS })
  const plainReview = plain.trace.agents.find((c) => c.opts.label.startsWith('review:'))
  assert.ok(plainReview.prompt.includes('"file":"<path>"'))
  assert.ok(!plainReview.prompt.includes(PHRASE))
})

test('route_curds absent: reconcile prompt has no findings request and the return keeps per_curd null', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: respondHappy() })

  const result = await workflow.run({ ...globals, args: BASE_ARGS })

  assert.equal(result.per_curd, null)
  assert.equal('findings' in result, false)
  const reconcileCall = trace.agents.find((c) => c.opts.label === 'reconcile')
  assert.ok(!reconcileCall.prompt.includes('fix_cost_now'))
  assert.ok(!reconcileCall.prompt.includes('--name-only'))
  assert.match(reconcileCall.prompt, /"has_cheap_lows":true\|false,"artifact":"\.cheese\/age\/parent\.md"\}\./)
})

test('a review prompt points at dimensions.md and does not copy its rubric text', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: respondHappy() })

  await workflow.run({ ...globals, args: BASE_ARGS })

  const securityReview = trace.agents.find((c) => c.opts.label === 'review:security')
  assert.ok(securityReview.prompt.includes('references/dimensions.md'))
  assert.ok(!securityReview.prompt.includes('caller-shadowed domain invariant'))
})

test('all review workers lost: each retries once, returns blocked, no reconcile call', async () => {
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
  assert.equal(trace.agents.filter((c) => c.opts.label.startsWith('review:')).length, DIMS.length * 2)
  assert.equal(trace.agents.some((c) => c.opts.label === 'reconcile'), false)
})

test('packet reports skill_files_ok:false: blocked, only the packet agent ran, zero review agents dispatched', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'packet') return { skill_files_ok: false, blocked_reason: 'dimensions.md missing', dimensions: [], packet_path: '' }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: BASE_ARGS })

  assert.equal(result.status, 'blocked')
  assert.match(result.error, /dimensions\.md missing/)
  assert.equal(trace.agents.length, 1)
  assert.equal(trace.agents[0].opts.label, 'packet')
  assert.equal(trace.agents.some((c) => c.opts.label.startsWith('review:')), false)
})

test('packet returns a non-slug dimension: ends blocked/failed with zero review agents dispatched', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'packet') return { skill_files_ok: true, dimensions: ['correctness', 'Not Invented Here'], packet_path: '.cheese/age/parent-packet.md' }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: BASE_ARGS })

  // The harness's schema `pattern` may reject the bad dimension at the agent() wrapper
  // (surfaced through the packet phase's try/catch) or the in-script invalidDimensions
  // guard may catch it first -- either outcome is acceptable; what matters is the
  // end-to-end property: blocked, with zero reviewer dispatches.
  assert.equal(result.status, 'blocked')
  assert.equal(trace.agents.some((c) => c.opts.label.startsWith('review:')), false)
})
