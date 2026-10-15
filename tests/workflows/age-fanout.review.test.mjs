import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow, validate } from './harness.mjs'

// Fixes from the claude-workflows review of age-fanout.js. Each test fails on the pre-fix script.
const path = resolve(import.meta.dirname, '../../claude/workflows/age-fanout.js')
const BASE_ARGS = { worktree_path: '/tmp/worktrees/parent', range: 'origin/main...HEAD', slug: 'parent' }
const ROUTE_ARGS = { ...BASE_ARGS, route_curds: [{ slug: 'alpha', branch: 'curd/alpha' }] }
const DIMS = ['correctness', 'security']

const finding = (over = {}) => ({ dimension: 'correctness', severity: 'medium', fix_cost_now: 'contained', file: 'src/a.ts', line: 1, claim: 'x', why_it_matters: 'y', fix_direction: 'z', also_relevant_to: [], ...over })
const reconcileOk = (over = {}) => ({ status: 'ok', has_medium_plus_findings: true, has_cheap_lows: false, artifact: '.cheese/age/parent.md', ...over })

function respond(overrides = {}) {
  return (call) => {
    const { label } = call.opts
    if (overrides[label]) return overrides[label](call)
    if (label === 'packet') return { skill_files_ok: true, dimensions: DIMS }
    if (label.startsWith('review:')) return { status: 'ok', findings: [finding({ dimension: label.split(':')[1] })] }
    if (label === 'reconcile') return reconcileOk()
    throw new Error(`unexpected agent ${label}`)
  }
}

async function run(args, overrides, runtime = {}) {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: respond(overrides), ...runtime })
  const result = await workflow.run({ ...globals, args })
  return { result, trace, labels: trace.agents.map((c) => c.opts.label) }
}

test('a null packet answer is redone once, then blocks instead of throwing', async () => {
  const { result, labels } = await run(BASE_ARGS, { packet: () => null, 'packet:retry': () => null })

  assert.equal(result.status, 'blocked')
  assert.match(result.error, /packet/)
  assert.deepEqual(labels, ['packet', 'packet:retry'])
})

for (const args of ['null', '5', null]) {
  test(`args ${JSON.stringify(args)} block with the call shape instead of throwing`, async () => {
    const { result, labels } = await run(args)

    assert.equal(result.status, 'blocked')
    assert.match(result.usage, /worktree_path/)
    assert.deepEqual(labels, [])
  })
}

test('a null first packet answer recovers on the redo', async () => {
  const { result, labels } = await run(BASE_ARGS, { packet: () => null, 'packet:retry': () => ({ skill_files_ok: true, dimensions: DIMS }) })

  assert.equal(result.status, 'ok')
  assert.deepEqual(labels.slice(0, 2), ['packet', 'packet:retry'])
})

test('packet and review prompts route file reads and writes through tilth, not shell redirection', async () => {
  const { trace } = await run(BASE_ARGS)

  const packet = trace.agents.find((c) => c.opts.label === 'packet').prompt
  assert.doesNotMatch(packet, /redirection/)
  assert.doesNotMatch(packet, /Use Bash\./)
  assert.ok(packet.includes('tilth_write to the absolute path `/tmp/worktrees/parent/.cheese/age/parent-packet.md`'))
  assert.match(packet, /tilth_read/)
  for (const c of trace.agents.filter((a) => a.opts.label.startsWith('review:'))) {
    assert.match(c.prompt, /tilth_read/)
    assert.doesNotMatch(c.prompt, /Use Bash for read-only inspection/)
  }
})

test('no prompt tells a schema-returning agent to write a handoff slug', async () => {
  const { trace } = await run(BASE_ARGS)

  for (const { prompt } of trace.agents) assert.doesNotMatch(prompt, /Write your handoff slug/)
})

test('code sorts findings, drops exact repeats with a log, and passes shared locations as data', async () => {
  const { result, trace } = await run(BASE_ARGS, {
    'review:correctness': () => ({ status: 'ok', findings: [finding({ file: 'src/b.ts', line: 9 }), finding({ file: 'src/a.ts', line: 4 }), finding({ file: 'src/a.ts', line: 4 })] }),
    'review:security': () => ({ status: 'ok', findings: [finding({ dimension: 'security', file: 'src/a.ts', line: 4, claim: 'sec' })] }),
  })

  assert.equal(result.status, 'ok')
  const prompt = trace.agents.find((c) => c.opts.label === 'reconcile').prompt
  const findings = JSON.parse(prompt.match(/<data name="findings">\n([\s\S]*?)\n<\/data>/)[1])
  assert.deepEqual(findings.map((f) => `${f.file}:${f.line}:${f.dimension}`), ['src/a.ts:4:correctness', 'src/a.ts:4:security', 'src/b.ts:9:correctness'])
  const overlaps = JSON.parse(prompt.match(/<data name="overlaps">\n([\s\S]*?)\n<\/data>/)[1])
  assert.deepEqual(overlaps, [{ location: 'src/a.ts:4', dimensions: ['correctness', 'security'] }])
  assert.doesNotMatch(prompt, /flagged by 2 or more workers/)
  assert.ok(trace.logs.some((l) => /Dropped 1 repeated finding/.test(l)))
})

test('route mode: code rewrites ./ and worktree-absolute finding paths to repo-relative form', async () => {
  const { result } = await run(ROUTE_ARGS, {
    reconcile: () => reconcileOk({ findings: [finding({ file: './src/a.ts' }), finding({ file: '/tmp/worktrees/parent/src/b.ts', line: 2 })] }),
  })

  assert.equal(result.status, 'ok')
  assert.deepEqual(result.findings.map((f) => f.file), ['src/a.ts', 'src/b.ts'])
})

test('route mode: code derives the medium-plus and cheap-low flags from the returned findings', async () => {
  const { result, trace } = await run(ROUTE_ARGS, {
    reconcile: () => reconcileOk({ has_medium_plus_findings: false, has_cheap_lows: false, findings: [finding({ severity: 'high' }), finding({ severity: 'low', fix_cost_now: 'contained', line: 2 })] }),
  })

  assert.equal(result.has_medium_plus_findings, true)
  assert.equal(result.has_cheap_lows, true)
  assert.ok(trace.logs.some((l) => /flags disagree with its findings/.test(l)))
})

test('a review finding without severity or file fails the schema in plain mode', async () => {
  const { trace } = await run(BASE_ARGS)
  const schema = trace.agents.find((c) => c.opts.label.startsWith('review:')).opts.schema

  for (const key of ['severity', 'file', 'line', 'claim']) {
    const partial = Object.fromEntries(Object.entries(finding()).filter(([k]) => k !== key && k !== 'fix_cost_now'))
    assert.throws(() => validate({ status: 'ok', findings: [partial] }, schema), { name: 'SchemaError' }, key)
  }
})

test('a low budget blocks before the review wave with zero reviewers', async () => {
  const { result, labels } = await run(BASE_ARGS, {}, { budgetTotal: 100000, budgetSpent: 80000 })

  assert.equal(result.status, 'blocked')
  assert.match(result.error, /budget/)
  assert.deepEqual(labels, ['packet'])
})

test('an argument error returns the exact call shape', async () => {
  for (const args of [{ range: 'origin/main...HEAD' }, 'not json']) {
    const { result, labels } = await run(args)

    assert.equal(result.status, 'blocked')
    assert.match(result.usage, /workflow\('age-fanout', \{ worktree_path: /)
    assert.ok(result.error.includes(result.usage))
    assert.deepEqual(labels, [])
  }
})
