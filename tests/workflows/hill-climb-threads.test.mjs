import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow } from './harness.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/hill-climb-threads.js')

const thread = (slug, extra = {}) => ({ slug, journey: `${slug} journey`, metric: `${slug}.count`, direction: 'lower', ...extra })
const climb = (status, extra = {}) => ({
  status,
  worktree_path: '/tmp/wt/a',
  change: `${status} change`,
  next_candidate: 'next',
  ...extra,
})
const labels = (trace) => trace.agents.map(({ opts }) => opts.label)

test('a bare string goal runs Survey, climbs each thread, and verifies only claimed gains', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'survey') return { threads: [thread('sidebar'), thread('composer')] }
      if (opts.label === 'climb:sidebar#1') return climb('improved', { before: 10, after: 8, commit: 'aaa' })
      if (opts.label === 'verify:sidebar#1') return { confirmed: true, note: 'ok' }
      if (opts.label === 'climb:sidebar#2') return climb('stopped', { stop_reason: 'needs-human' })
      if (opts.label === 'climb:composer#1') return climb('blocked', { worktree_path: '/tmp/wt/b' })
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: 'make chat faster' })

  assert.match(trace.agents[0].prompt, /Goal: make chat faster/)
  assert.match(trace.agents[0].prompt, /at most 3 threads/)
  assert.deepEqual([...labels(trace)].sort(), ['climb:composer#1', 'climb:sidebar#1', 'climb:sidebar#2', 'survey', 'verify:sidebar#1'])
  const sidebar = result.threads.find((t) => t.slug === 'sidebar')
  assert.equal(sidebar.gains, 1)
  assert.equal(sidebar.outcome, 'stopped: needs-human')
  assert.equal(result.threads.find((t) => t.slug === 'composer').outcome, 'blocked')
})

test('round 1 isolates a worktree and later rounds reuse its path without isolation', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label.startsWith('climb:')) return climb('no-gain', { worktree_path: '/tmp/wt/sidebar' })
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { threads: [thread('sidebar')], rounds: 5 } })

  const climbs = trace.agents.filter(({ opts }) => opts.label.startsWith('climb:'))
  assert.equal(climbs.length, 3, 'three dry rounds hit the default dry limit')
  assert.equal(climbs[0].opts.isolation, 'worktree')
  assert.match(climbs[0].prompt, /git checkout -B hill-climb\/sidebar/)
  for (const later of climbs.slice(1)) {
    assert.equal(later.opts.isolation, undefined)
    assert.match(later.prompt, /existing worktree at \/tmp\/wt\/sidebar/)
  }
  assert.equal(result.threads[0].outcome, 'diminishing-returns')
  assert.ok(!labels(trace).includes('survey'), 'explicit threads skip Survey')
})

test('a refuted gain is not counted, and the next round is told to revert it', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'climb:sidebar#1') return climb('improved', { before: 10, after: 2, commit: 'bad1' })
      if (opts.label === 'verify:sidebar#1') return { confirmed: false, note: 'test deleted' }
      if (opts.label === 'climb:sidebar#2') return climb('stopped', { stop_reason: 'diminishing-returns' })
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { threads: [thread('sidebar')], publish: true } })

  const round2 = trace.agents.find(({ opts }) => opts.label === 'climb:sidebar#2')
  assert.match(round2.prompt, /commit bad1, and the verifier refuted it: test deleted/)
  assert.match(round2.prompt, /Revert that commit/)
  assert.equal(result.threads[0].gains, 0)
  assert.equal(result.threads[0].history[0].status, 'refuted')
  assert.ok(!labels(trace).some((l) => l.startsWith('publish:')), 'no verified gain means no PR')
})

test('a crashed verifier refutes the gain instead of passing it', async () => {
  const workflow = await loadWorkflow(path)
  const { globals } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'climb:sidebar#1') return climb('improved', { commit: 'c1' })
      if (opts.label === 'verify:sidebar#1') throw new Error('verifier crashed')
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { threads: [thread('sidebar')], rounds: 1 } })

  assert.equal(result.threads.length, 1)
  assert.equal(result.threads[0].gains, 0)
  assert.equal(result.threads[0].pendingRefutation, true)
})

test('publish=true opens a draft PR only for threads with a verified gain', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'climb:good#1') return climb('improved', { worktree_path: '/tmp/wt/good', before: 5, after: 4, commit: 'g1' })
      if (opts.label === 'verify:good#1') return { confirmed: true, note: 'ok' }
      if (opts.label === 'climb:flat#1') return climb('no-gain', { worktree_path: '/tmp/wt/flat' })
      if (opts.label === 'publish:good') return { status: 'opened', pr_url: 'https://example.test/pr/1' }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { threads: [thread('good'), thread('flat')], rounds: 1, publish: true } })

  assert.deepEqual(labels(trace).filter((l) => l.startsWith('publish:')), ['publish:good'])
  const prompt = trace.agents.find(({ opts }) => opts.label === 'publish:good').prompt
  assert.match(prompt, /DRAFT pull request/)
  assert.match(prompt, /\(5 -> 4\)/)
  assert.equal(result.threads.find((t) => t.slug === 'good').publish.pr_url, 'https://example.test/pr/1')
  assert.equal(result.threads.find((t) => t.slug === 'flat').publish, null)
})

test('unsafe slugs, unsafe ratchet dirs, and invalid worktree paths are rejected', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'climb:ok#1') return climb('no-gain', { worktree_path: 'relative; rm -rf /' })
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({
    ...globals,
    args: { threads: [thread('ok'), thread('Bad Slug'), thread('ok')], ratchetDir: '../escape' },
  })

  assert.deepEqual(labels(trace), ['climb:ok#1'])
  assert.match(trace.agents[0].prompt, /Ratchet file: perf\/ratchet\/ok\.json/)
  assert.equal(result.threads.length, 1)
  assert.equal(result.threads[0].outcome, 'blocked: invalid worktree path')
  assert.equal(result.ratchetDir, 'perf/ratchet')
})

test('missing goal and threads returns an error without dispatching agents', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime()

  const result = await workflow.run({ ...globals, args: undefined })

  assert.equal(result.error, 'missing goal')
  assert.equal(trace.agents.length, 0)
})
