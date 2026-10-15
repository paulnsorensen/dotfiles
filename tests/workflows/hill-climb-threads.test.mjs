import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime as baseRuntime, loadWorkflow } from './harness.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/hill-climb-threads.js')

const ADOPTED = { status: 'already-gated', branch: '', note: 'CI runs the ratchet' }
const createRuntime = ({ respond = () => { throw new Error('agent fixture missing') }, ...rest } = {}) =>
  baseRuntime({ ...rest, respond: (call) => (call.opts.label === 'adopt' ? ADOPTED : respond(call)) })

const sha = (c) => c.repeat(40)
const thread = (slug, extra = {}) => ({ slug, journey: `${slug} journey`, metric: `${slug}.count`, direction: 'lower', benchmark: '', ...extra })
const climb = (status, extra = {}) => ({
  status,
  worktree_path: '/tmp/wt/a',
  head: sha('a'),
  change: `${status} change`,
  commit: '',
  stop_reason: '',
  reverted_commits: [],
  existing_commits: [],
  benchmark: '',
  ...extra,
})
const labels = (trace) => trace.agents.map(({ opts }) => opts.label).filter((l) => l !== 'adopt')
const agentFor = (trace, label) => trace.agents.find(({ opts }) => opts.label === label)
const publishCount = (trace) => labels(trace).filter((l) => l === 'publish').length
const published = (slugs) => ({ results: slugs.map((slug) => ({ slug, status: 'opened', pr_url: `https://example.test/pr/${slug}`, note: '' })) })

test('a bare string goal runs Survey, climbs each thread, and verifies only claimed gains', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'survey') return { threads: [thread('sidebar'), thread('composer')] }
      if (opts.label === 'climb:sidebar#1') return climb('improved', { before: 10, after: 8, commit: 'aaa0001' })
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
  // An unset model inherits the parent model, so every worker names sonnet; survey gets its model from the explorer type.
  assert.deepEqual(trace.agents.filter(({ opts }) => !opts.agentType && opts.model !== 'sonnet').map(({ opts }) => opts.label), [])
})

test('every round runs a coder in a fresh worktree that starts at the head code recorded', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      const round = opts.label.split('#')[1]
      if (opts.label.startsWith('climb:')) return climb('no-gain', { worktree_path: `/tmp/wt/sidebar-${round}`, head: sha(round) })
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { threads: [thread('sidebar')], rounds: 5 } })

  const climbs = trace.agents.filter(({ opts }) => opts.label.startsWith('climb:'))
  assert.equal(climbs.length, 3, 'three dry rounds hit the default dry limit')
  for (const c of climbs) {
    assert.equal(c.opts.isolation, 'worktree', `${c.opts.label} is isolated, so the worktree guard allows its writes`)
    assert.equal(c.opts.agentType, 'coder')
    assert.match(c.prompt, /Done means:/)
    assert.match(c.prompt, /Scope fence:/)
    assert.match(c.prompt, /git update-ref refs\/heads\/hill-climb\/sidebar HEAD/)
    assert.match(c.prompt, /hill-climb\/SKILL\.md with tilth_read/)
    assert.doesNotMatch(c.prompt, /git -C|through the Skill tool|existing worktree/)
  }
  assert.match(climbs[0].prompt, /git branch hill-climb\/sidebar/)
  assert.match(climbs[0].prompt, /git checkout --detach hill-climb\/sidebar/)
  assert.match(climbs[1].prompt, new RegExp(`git checkout --detach ${sha('1')}`))
  assert.match(climbs[2].prompt, new RegExp(`rev-parse refs/heads/hill-climb/sidebar\` prints ${sha('2')}`))
  assert.equal(result.threads[0].outcome, 'diminishing-returns')
  assert.equal(result.threads[0].head, sha('3'))
  assert.equal(result.threads[0].worktree, '/tmp/wt/sidebar-3')
  assert.ok(!labels(trace).includes('survey'), 'explicit threads skip Survey')
})

test('a round that returns an invalid head blocks the thread', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: () => climb('no-gain', { head: 'HEAD; rm -rf /' }) })

  const result = await workflow.run({ ...globals, args: { threads: [thread('s')], rounds: 3 } })

  assert.equal(result.threads[0].outcome, 'blocked: invalid head')
  assert.deepEqual(labels(trace), ['climb:s#1'])
})

test('a refuted gain is not counted, and the next round is told to revert it', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'climb:sidebar#1') return climb('improved', { before: 10, after: 2, commit: 'bad0001' })
      if (opts.label === 'verify:sidebar#1') return { confirmed: false, note: 'test deleted' }
      if (opts.label === 'climb:sidebar#2') return climb('stopped', { stop_reason: 'diminishing-returns', reverted_commits: ['bad0001'] })
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { threads: [thread('sidebar')], publish: true } })

  const round2 = trace.agents.find(({ opts }) => opts.label === 'climb:sidebar#2')
  assert.match(round2.prompt, /commit bad0001: the verifier refuted it: test deleted/)
  assert.match(round2.prompt, /Revert each commit/)
  assert.equal(result.threads[0].gains, 0)
  assert.equal(result.threads[0].history[0].status, 'refuted')
  assert.equal(publishCount(trace), 0, 'no verified gain means no PR')
  assert.equal(result.threads[0].pendingRefutation, false, 'reverted_commits clears the refutation')
})

test('a confirmed gain followed by a refuted gain is not published', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'climb:s#1') return climb('improved', { commit: 'c100001' })
      if (opts.label === 'verify:s#1') return { confirmed: true, note: 'ok' }
      if (opts.label === 'climb:s#2') return climb('improved', { commit: 'c200002', head: sha('b') })
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
      if (opts.label === 'climb:s#1') return climb('improved', { commit: 'c100001' })
      if (opts.label === 'verify:s#1') return { confirmed: true, note: 'ok' }
      if (opts.label === 'climb:s#2') return climb('improved', { commit: 'c200002', head: sha('b') })
      if (opts.label === 'verify:s#2') return { confirmed: false, note: 'noisy' }
      if (opts.label === 'climb:s#3') return climb('blocked')
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { threads: [thread('s')], rounds: 3, publish: true } })

  assert.equal(result.threads[0].pendingRefutation, true)
  assert.equal(publishCount(trace), 0)
  assert.match(agentFor(trace, 'climb:s#3').prompt, /commit c200002: the verifier refuted it/)
})

test('alternating gains reset the dry counter, so dryLimit 2 reaches round 4', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      const round = Number(opts.label.split('#')[1])
      if (opts.label.startsWith('climb:')) return round % 2 ? climb('improved', { commit: `c${round}00000`, head: sha(String(round)) }) : climb('no-gain', { head: sha(String(round)) })
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

test('Adopt runs once before Climb as a coder in its own worktree and the climb prompt scopes CI out', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: () => climb('no-gain') })

  const result = await workflow.run({ ...globals, args: { threads: [thread('a'), thread('b')], rounds: 1 } })

  const adopts = trace.agents.filter(({ opts }) => opts.label === 'adopt')
  assert.equal(adopts.length, 1)
  assert.equal(adopts[0].opts.phase, 'Adopt')
  assert.equal(adopts[0].opts.isolation, 'worktree')
  assert.equal(adopts[0].opts.agentType, 'coder')
  assert.match(adopts[0].prompt, /Done means:/)
  assert.match(adopts[0].prompt, /Scope fence:/)
  assert.match(adopts[0].prompt, /with tilth_read/)
  assert.ok(trace.agents[0].opts.label === 'adopt', 'Adopt precedes every climb')
  assert.match(adopts[0].prompt, /perf\/ratchet\/\*\.json/)
  assert.match(agentFor(trace, 'climb:a#1').prompt, /CI wiring for the ratchet is already done/)
  assert.match(agentFor(trace, 'climb:a#1').prompt, /workflow owns the dry-streak stop/)
  assert.deepEqual({ ...result.adopt }, ADOPTED)
})

test('the survey prompt names tilth_read for the skill files', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: () => ({ threads: [] }) })

  await workflow.run({ ...globals, args: 'g' })

  assert.equal(agentFor(trace, 'survey').opts.agentType, 'explorer')
  assert.match(agentFor(trace, 'survey').prompt, /metrics\.md with tilth_read/)
})

test('a returned benchmark reaches the verifier, which checks the exact head in t.worktree', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'climb:s#1') return climb('improved', { worktree_path: '/tmp/wt/s', head: sha('c'), commit: 'c100001', benchmark: 'node bench.js' })
      if (opts.label === 'verify:s#1') return { confirmed: true, note: 'ok' }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  await workflow.run({ ...globals, args: { threads: [thread('s')], rounds: 1 } })

  const prompt = agentFor(trace, 'verify:s#1').prompt
  assert.match(prompt, /Benchmark: node bench\.js/)
  assert.match(prompt, /Worktree: \/tmp\/wt\/s\./)
  assert.match(prompt, new RegExp(`git -C /tmp/wt/s rev-parse HEAD\` prints ${sha('c')}`))
  assert.match(prompt, /python3 ~\/\.claude\/skills\/hill-climb\/scripts\/ratchet\.py check --file/)
})

test('a gain that names no commit is verified at its head', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'climb:s#1') return climb('improved', { head: sha('d'), commit: '' })
      if (opts.label === 'verify:s#1') return { confirmed: false, note: 'no' }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { threads: [thread('s')], rounds: 1 } })

  assert.match(agentFor(trace, 'verify:s#1').prompt, new RegExp(`commit\\(s\\) ${sha('d')}:`))
  assert.equal(result.threads[0].history[0].commit, sha('d'), 'a later revert can name the refuted commit')
})

test('a gain that names no commit and leaves head unmoved counts as no-gain', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'climb:s#1') return climb('no-gain', { head: sha('e') })
      if (opts.label === 'climb:s#2') return climb('improved', { head: sha('e'), commit: '' })
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { threads: [thread('s')], rounds: 2 } })

  assert.ok(!agentFor(trace, 'verify:s#2'))
  assert.equal(result.threads[0].history[1].status, 'no-gain')
})

test('a numeric threads arg caps the Survey result and logs the dropped threads', async () => {
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
  assert.ok(trace.logs.some((l) => /dropped: c, d/.test(l)), trace.logs.join('\n'))
})

test('a JSON object string arg is parsed, not used as the goal', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: () => climb('no-gain') })

  const result = await workflow.run({ ...globals, args: JSON.stringify({ threads: [thread('s')], rounds: 1 }) })

  assert.deepEqual(labels(trace), ['climb:s#1'])
  assert.equal(result.goal, '')
})

test('a publish agent that throws is reported as failed with its reason', async () => {
  const workflow = await loadWorkflow(path)
  const { globals } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'climb:s#1') return climb('improved', { commit: 'c100001' })
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
      if (opts.label === 'climb:sidebar#1') return climb('improved', { commit: 'c100001' })
      if (opts.label === 'verify:sidebar#1') throw new Error('verifier crashed')
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { threads: [thread('sidebar')], rounds: 1 } })

  assert.equal(result.threads.length, 1)
  assert.equal(result.threads[0].gains, 0)
  assert.equal(result.threads[0].pendingRefutation, true)
})

test('publish=true batches every thread with a verified gain into one publish agent', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'climb:good#1') return climb('improved', { worktree_path: '/tmp/wt/good', before: 5, after: 4, commit: 'a000001' })
      if (opts.label === 'climb:also#1') return climb('improved', { worktree_path: '/tmp/wt/also', before: 9, after: 7, commit: 'a000002', head: sha('f') })
      if (opts.label.startsWith('verify:')) return { confirmed: true, note: 'ok' }
      if (opts.label === 'climb:flat#1') return climb('no-gain', { worktree_path: '/tmp/wt/flat' })
      if (opts.label === 'publish') return published(['good', 'stray'])
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { threads: [thread('good'), thread('flat'), thread('also')], rounds: 1, publish: true } })

  assert.equal(publishCount(trace), 1, 'one agent publishes every thread')
  const call = agentFor(trace, 'publish')
  assert.equal(call.opts.isolation, 'worktree')
  assert.match(call.prompt, /DRAFT pull request/)
  assert.match(call.prompt, /\(5 -> 4\)/)
  assert.match(call.prompt, /branch hill-climb\/good/)
  assert.match(call.prompt, new RegExp(`branch hill-climb/also, head ${sha('f')}`))
  assert.doesNotMatch(call.prompt, /hill-climb\/flat/)
  const bySlug = (slug) => result.threads.find((t) => t.slug === slug)
  assert.equal(bySlug('good').publish.pr_url, 'https://example.test/pr/good')
  assert.equal(bySlug('also').publish.status, 'failed', 'a thread missing from the reply is failed, not silently dropped')
  assert.equal(bySlug('flat').publish, null)
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
    args: { threads: [thread('ok'), thread('Bad Slug'), thread('ok'), { ...thread('x'), slug: 12345 }], ratchetDir: '../escape' },
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

test('missing goal and threads returns an error and the call shape without dispatching agents', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime()

  const result = await workflow.run({ ...globals, args: undefined })

  assert.equal(result.error, 'missing goal')
  assert.match(result.usage, /goal string/)
  assert.equal(trace.agents.length, 0)
})

test('a null Adopt result becomes a failed Adopt and the climb prompt does not claim CI is wired', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = baseRuntime({ respond: () => climb('no-gain') })
  const inner = globals.agent
  globals.agent = (prompt, opts) => (opts.label === 'adopt' ? (trace.agents.push({ prompt, opts }), Promise.resolve(null)) : inner(prompt, opts))

  const result = await workflow.run({ ...globals, args: { threads: [thread('s')], rounds: 1 } })

  assert.equal(result.adopt.status, 'failed')
  assert.equal(result.adopt.note, 'adopt agent returned nothing')
  const prompt = agentFor(trace, 'climb:s#1').prompt
  assert.doesNotMatch(prompt, /already done by the workflow/)
  assert.match(prompt, /not done \(Adopt failed\)/)
})

test('a skipped Adopt is not described as done in the climb prompt', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = baseRuntime({
    respond: ({ opts }) => (opts.label === 'adopt' ? { status: 'skipped', branch: '', note: 'no CI' } : climb('no-gain')),
  })

  await workflow.run({ ...globals, args: { threads: [thread('s')], rounds: 1 } })

  assert.match(agentFor(trace, 'climb:s#1').prompt, /not done \(Adopt skipped\)/)
})

test('existing commits the verifier refutes block publish until a later round reverts them', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'climb:s#1') return climb('no-gain', { existing_commits: ['e1d0001'] })
      if (opts.label === 'verify-existing:s') return { confirmed: false, note: 'stale' }
      if (opts.label === 'climb:s#2') return climb('improved', { commit: 'f000001', head: sha('b') })
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { threads: [thread('s')], rounds: 2, publish: true } })

  assert.match(agentFor(trace, 'climb:s#1').prompt, /git log --format=%H <default-branch>\.\.hill-climb\/s/)
  assert.match(agentFor(trace, 'verify-existing:s').prompt, /commit\(s\) e1d0001:/)
  assert.match(agentFor(trace, 'climb:s#2').prompt, /commit e1d0001: it predates this run and the verifier refuted it: stale/)
  assert.ok(!agentFor(trace, 'verify:s#2'), 'no gain is verified while an unverified commit sits below it')
  assert.equal(result.threads[0].gains, 0)
  assert.equal(result.threads[0].pendingRefutation, true)
  assert.equal(publishCount(trace), 0)
})

test('reverting a refuted existing commit clears it and lets a later verified gain publish', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'climb:s#1') return climb('no-gain', { existing_commits: ['e1d0001'] })
      if (opts.label === 'verify-existing:s') return { confirmed: false, note: 'stale' }
      if (opts.label === 'climb:s#2') return climb('no-gain', { reverted_commits: ['e1d0001'], head: sha('b') })
      if (opts.label === 'climb:s#3') return climb('improved', { commit: 'f000001', head: sha('c') })
      if (opts.label === 'verify:s#3') return { confirmed: true, note: 'ok' }
      if (opts.label === 'publish') return published(['s'])
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { threads: [thread('s')], rounds: 3, publish: true } })

  assert.equal(result.threads[0].pendingRefutation, false)
  assert.equal(publishCount(trace), 1)
})

test('existing commits the verifier confirms are kept: no revert prompt, and a later verified gain publishes', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'climb:s#1') return climb('no-gain', { existing_commits: ['e1d0001', 'e1d0002'] })
      if (opts.label === 'verify-existing:s') return { confirmed: true, note: 'ok' }
      if (opts.label === 'climb:s#2') return climb('improved', { commit: 'f000001', head: sha('b') })
      if (opts.label === 'verify:s#2') return { confirmed: true, note: 'ok' }
      if (opts.label === 'publish') return published(['s'])
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { threads: [thread('s')], rounds: 2, publish: true } })

  assert.match(agentFor(trace, 'verify-existing:s').prompt, /commit\(s\) e1d0001 e1d0002:/)
  assert.doesNotMatch(agentFor(trace, 'climb:s#2').prompt, /Revert each commit/)
  assert.equal(result.threads[0].pendingRefutation, false)
  assert.equal(result.threads[0].gains, 1)
  assert.equal(publishCount(trace), 1)
})

test('two refutations are both tracked and reverting one keeps the thread unpublished', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'climb:s#1') return climb('improved', { commit: 'c100001' })
      if (opts.label === 'verify:s#1') return { confirmed: false, note: 'noisy' }
      if (opts.label === 'climb:s#2') return climb('improved', { commit: 'c200002', head: sha('b') })
      if (opts.label === 'climb:s#3') return climb('no-gain', { reverted_commits: ['c200002'], head: sha('c') })
      if (opts.label === 'climb:s#4') return climb('no-gain', { head: sha('c') })
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { threads: [thread('s')], rounds: 4, dryLimit: 4, publish: true } })

  const round3 = agentFor(trace, 'climb:s#3').prompt
  assert.match(round3, /commit c100001: the verifier refuted it: noisy/)
  assert.match(round3, /commit c200002:/)
  assert.match(agentFor(trace, 'climb:s#4').prompt, /commit c100001:/)
  assert.doesNotMatch(agentFor(trace, 'climb:s#4').prompt, /commit c200002:/)
  assert.equal(result.threads[0].pendingRefutation, true)
  assert.equal(publishCount(trace), 0)
})

test('a changed benchmark replaces a preset benchmark before verification', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'climb:s#1') return climb('improved', { commit: 'c100001', benchmark: 'node new-bench.js' })
      if (opts.label === 'verify:s#1') return { confirmed: true, note: 'ok' }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  await workflow.run({ ...globals, args: { threads: [thread('s', { benchmark: 'node old-bench.js' })], rounds: 1 } })

  assert.match(agentFor(trace, 'verify:s#1').prompt, /Benchmark: node new-bench\.js/)
})

test('result.resume carries thread specs and Adopt, so a rerun skips Survey and Adopt', async () => {
  const workflow = await loadWorkflow(path)
  const first = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'survey') return { threads: [thread('s', { benchmark: 'node b.js' })] }
      if (opts.label === 'climb:s#1') return climb('improved', { commit: 'c100001', before: 5, after: 4, head: sha('c') })
      if (opts.label === 'verify:s#1') return { confirmed: true, note: 'ok' }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...first.globals, args: { goal: 'g', rounds: 1 } })
  const resume = JSON.parse(JSON.stringify(result.resume))

  assert.deepEqual(resume.threads, [{ ...thread('s', { benchmark: 'node b.js' }), head: sha('c'), verified: true, gains: [{ change: 'improved change', before: 5, after: 4 }] }])
  assert.deepEqual(resume.adopt, ADOPTED)

  const second = createRuntime({ respond: () => climb('no-gain', { head: sha('c') }) })
  await workflow.run({ ...second.globals, args: { ...resume, rounds: 1 } })

  assert.deepEqual(second.trace.agents.map(({ opts }) => opts.label), ['climb:s#1'])
})

test('rounds 0 publishes the verified threads of an earlier run without another climb', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: ({ opts }) => (opts.label === 'publish' ? published(['s']) : climb('no-gain')) })
  const carried = [
    { ...thread('s'), head: sha('c'), verified: true, gains: [{ change: 'cache', before: 5, after: 4 }] },
    { ...thread('t'), head: sha('d'), verified: false, gains: [] },
  ]

  const result = await workflow.run({ ...globals, args: { threads: carried, rounds: 0, publish: true } })

  assert.deepEqual(trace.agents.map(({ opts }) => opts.label), ['publish'])
  assert.match(trace.agents[0].prompt, new RegExp(`branch hill-climb/s, head ${sha('c')}`))
  assert.match(trace.agents[0].prompt, /cache \(5 -> 4\)/)
  assert.doesNotMatch(trace.agents[0].prompt, /hill-climb\/t/)
  assert.equal(result.threads.find((t) => t.slug === 's').publish.status, 'opened')
})

test('rounds 0 without publish returns the call shape and starts no agent', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime()

  const result = await workflow.run({ ...globals, args: { threads: [thread('s')], rounds: 0 } })

  assert.equal(trace.agents.length, 0)
  assert.match(result.error, /rounds 0/)
  assert.match(result.usage, /rounds:0/)
})

test('every agent schema marks each property required, except the optional climb measurements', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'survey') return { threads: [thread('s')] }
      if (opts.label === 'climb:s#1') return climb('improved', { commit: 'c100001' })
      if (opts.label === 'verify:s#1') return { confirmed: true, note: 'ok' }
      if (opts.label === 'publish') return published(['s'])
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  await workflow.run({ ...globals, args: { goal: 'g', rounds: 1, publish: true } })

  const optional = new Set(['before', 'after'])
  const missing = []
  const walk = (schema, at) => {
    if (schema.properties) {
      for (const key of Object.keys(schema.properties)) {
        if (!(schema.required || []).includes(key) && !optional.has(key)) missing.push(`${at}.${key}`)
        walk(schema.properties[key], `${at}.${key}`)
      }
    }
    if (schema.items) walk(schema.items, `${at}[]`)
  }
  for (const { opts } of trace.agents) walk(opts.schema, opts.label)
  assert.deepEqual(missing, [])
  assert.deepEqual(trace.agents.map(({ opts }) => opts.label), ['survey', 'adopt', 'climb:s#1', 'verify:s#1', 'publish'])
})
