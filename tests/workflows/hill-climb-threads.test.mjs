import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime as baseRuntime, loadWorkflow } from './harness.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/hill-climb-threads.js')

const ADOPTED = { status: 'already-gated', note: 'CI runs the ratchet' }
const createRuntime = ({ respond = () => { throw new Error('agent fixture missing') }, ...rest } = {}) =>
  baseRuntime({ ...rest, respond: (call) => (call.opts.label === 'adopt' ? ADOPTED : respond(call)) })

const thread = (slug, extra = {}) => ({ slug, journey: `${slug} journey`, metric: `${slug}.count`, direction: 'lower', ...extra })
const climb = (status, extra = {}) => ({
  status,
  worktree_path: '/tmp/wt/a',
  change: `${status} change`,
  ...extra,
})
const labels = (trace) => trace.agents.map(({ opts }) => opts.label).filter((l) => l !== 'adopt')
const agentFor = (trace, label) => trace.agents.find(({ opts }) => opts.label === label)
const publishCount = (trace) => labels(trace).filter((l) => l.startsWith('publish:')).length

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
  assert.match(climbs[0].prompt, /git checkout -b hill-climb\/sidebar/)
  assert.match(climbs[0].prompt, /git checkout hill-climb\/sidebar/)
  assert.match(climbs[0].prompt, /another worktree holds the branch/)
  for (const later of climbs.slice(1)) {
    assert.equal(later.opts.isolation, undefined)
    assert.match(later.prompt, /existing worktree at \/tmp\/wt\/sidebar/)
    assert.match(later.prompt, /git -C \/tmp\/wt\/sidebar/)
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
      if (opts.label === 'climb:sidebar#2') return climb('stopped', { stop_reason: 'diminishing-returns', reverted: true })
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { threads: [thread('sidebar')], publish: true } })

  const round2 = trace.agents.find(({ opts }) => opts.label === 'climb:sidebar#2')
  assert.match(round2.prompt, /commit bad1, and the verifier refuted it: test deleted/)
  assert.match(round2.prompt, /Revert that commit/)
  assert.equal(result.threads[0].gains, 0)
  assert.equal(result.threads[0].history[0].status, 'refuted')
  assert.equal(publishCount(trace), 0, 'no verified gain means no PR')
  assert.equal(result.threads[0].pendingRefutation, false, 'reverted=true clears the refutation')
})

test('a confirmed gain followed by a refuted gain is not published', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'climb:s#1') return climb('improved', { commit: 'c1' })
      if (opts.label === 'verify:s#1') return { confirmed: true, note: 'ok' }
      if (opts.label === 'climb:s#2') return climb('improved', { commit: 'c2' })
      if (opts.label === 'verify:s#2') return { confirmed: false, note: 'noisy' }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { threads: [thread('s')], rounds: 2, publish: true } })

  assert.equal(publishCount(trace), 0)
  assert.equal(result.threads[0].gains, 1)
  assert.equal(result.threads[0].pendingRefutation, true)
})

test('a refutation survives a later round that does not report a revert', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'climb:s#1') return climb('improved', { commit: 'c1' })
      if (opts.label === 'verify:s#1') return { confirmed: true, note: 'ok' }
      if (opts.label === 'climb:s#2') return climb('improved', { commit: 'c2' })
      if (opts.label === 'verify:s#2') return { confirmed: false, note: 'noisy' }
      if (opts.label === 'climb:s#3') return climb('blocked')
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { threads: [thread('s')], rounds: 3, publish: true } })

  assert.equal(result.threads[0].pendingRefutation, true)
  assert.equal(publishCount(trace), 0)
  assert.match(agentFor(trace, 'climb:s#3').prompt, /commit c2, and the verifier refuted it/)
})

test('alternating gains reset the dry counter, so dryLimit 2 reaches round 4', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      const round = Number(opts.label.split('#')[1])
      if (opts.label.startsWith('climb:')) return round % 2 ? climb('improved', { commit: `c${round}` }) : climb('no-gain')
      if (opts.label.startsWith('verify:')) return { confirmed: true, note: 'ok' }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { threads: [thread('s')], rounds: 6, dryLimit: 2 } })

  assert.equal(labels(trace).filter((l) => l.startsWith('climb:')).length, 6)
  assert.equal(result.threads[0].outcome, 'rounds-exhausted')
})

test('dryLimit 1 stops after the first dry round', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: () => climb('no-gain') })

  const result = await workflow.run({ ...globals, args: { threads: [thread('s')], rounds: 5, dryLimit: 1 } })

  assert.equal(labels(trace).length, 1)
  assert.equal(result.threads[0].outcome, 'diminishing-returns')
})

test('low budget stops a thread before its first round', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ budgetTotal: 10_000, budgetSpent: 0 })

  const result = await workflow.run({ ...globals, args: { threads: [thread('s')] } })

  assert.equal(labels(trace).length, 0)
  assert.equal(result.threads[0].outcome, 'budget')
})

test('Adopt runs once before Climb in its own worktree and the climb prompt scopes CI out', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: () => climb('no-gain') })

  const result = await workflow.run({ ...globals, args: { threads: [thread('a'), thread('b')], rounds: 1 } })

  const adopts = trace.agents.filter(({ opts }) => opts.label === 'adopt')
  assert.equal(adopts.length, 1)
  assert.equal(adopts[0].opts.phase, 'Adopt')
  assert.equal(adopts[0].opts.isolation, 'worktree')
  assert.ok(trace.agents[0].opts.label === 'adopt', 'Adopt precedes every climb')
  assert.match(adopts[0].prompt, /perf\/ratchet\/\*\.json/)
  assert.match(agentFor(trace, 'climb:a#1').prompt, /CI wiring for the ratchet is already done/)
  assert.match(agentFor(trace, 'climb:a#1').prompt, /workflow owns the dry-streak stop/)
  assert.deepEqual(result.adopt, ADOPTED)
})

test('a returned benchmark reaches the verifier, which uses t.worktree and the absolute ratchet path', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'climb:s#1') return climb('improved', { worktree_path: '/tmp/wt/s', commit: 'c1', benchmark: 'node bench.js' })
      if (opts.label === 'verify:s#1') return { confirmed: true, note: 'ok' }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  await workflow.run({ ...globals, args: { threads: [thread('s')], rounds: 1 } })

  const prompt = agentFor(trace, 'verify:s#1').prompt
  assert.match(prompt, /Benchmark: node bench\.js/)
  assert.match(prompt, /Worktree: \/tmp\/wt\/s\./)
  assert.match(prompt, /~\/\.claude\/skills\/hill-climb\/scripts\/ratchet\.py check --file/)
})

test('a later round that returns a different worktree path blocks the thread', async () => {
  const workflow = await loadWorkflow(path)
  const { globals } = createRuntime({
    respond: ({ opts }) => climb('no-gain', { worktree_path: opts.label.endsWith('#1') ? '/tmp/wt/a' : '/tmp/wt/other' }),
  })

  const result = await workflow.run({ ...globals, args: { threads: [thread('s')], rounds: 3 } })

  assert.equal(result.threads[0].outcome, 'blocked: worktree path changed')
})

test('a numeric threads arg caps the Survey result', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'survey') return { threads: [thread('a'), thread('b'), thread('c'), thread('d')] }
      return climb('blocked')
    },
  })

  const result = await workflow.run({ ...globals, args: { goal: 'g', threads: 2 } })

  assert.deepEqual([...result.threads.map((t) => t.slug)], ['a', 'b'])
  assert.equal(labels(trace).filter((l) => l.startsWith('climb:')).length, 2)
})

test('a publish agent that throws is reported as failed with its reason', async () => {
  const workflow = await loadWorkflow(path)
  const { globals } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'climb:s#1') return climb('improved', { commit: 'c1' })
      if (opts.label === 'verify:s#1') return { confirmed: true, note: 'ok' }
      throw new Error('gh exploded')
    },
  })

  const result = await workflow.run({ ...globals, args: { threads: [thread('s')], rounds: 1, publish: true } })

  assert.equal(result.threads[0].publish.status, 'failed')
  assert.match(result.threads[0].publish.note, /gh exploded/)
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
  assert.match(agentFor(trace, 'climb:ok#1').prompt, /Ratchet file: perf\/ratchet\/ok\.json/)
  assert.equal(result.threads.length, 1)
  assert.equal(result.threads[0].outcome, 'blocked: invalid worktree path')
  assert.equal(result.ratchetDir, 'perf/ratchet')
})

test('an absolute ratchetDir falls back to the default', async () => {
  const workflow = await loadWorkflow(path)
  const { globals } = createRuntime({ respond: () => climb('blocked') })

  const result = await workflow.run({ ...globals, args: { threads: [thread('s')], ratchetDir: '/abs/ratchet' } })

  assert.equal(result.ratchetDir, 'perf/ratchet')
})

test('missing goal and threads returns an error without dispatching agents', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime()

  const result = await workflow.run({ ...globals, args: undefined })

  assert.equal(result.error, 'missing goal')
  assert.equal(trace.agents.length, 0)
})
