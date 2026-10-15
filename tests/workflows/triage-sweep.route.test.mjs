import assert from 'node:assert/strict'
import test from 'node:test'

import { createRuntime, loadWorkflow } from './harness.mjs'
import { ground, issue, labels, path, plain, pr, readData, responder, verify } from './triage-sweep.fixtures.mjs'

const routeEntry = (number, route, rank, extra = {}) => ({
  number, route, rank, why: `why ${number}`, close_reason: '', duplicate_of: 0, confidence: '', comment: '', ...extra,
})

test('code gates the close plan, fills omitted items, and counts the routes', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: responder({
      gather: [issue(1), issue(2), issue(3)],
      grounds: { 2: 'stale', 3: 'stale' },
      verifies: { 3: verify(3, true, 'valid') },
      route: () => ({
        routed: [
          routeEntry(1, 'close', 1, { close_reason: 'completed', confidence: 'certain', comment: 'c' }),
          routeEntry(2, 'close', 5, { close_reason: 'not planned', confidence: 'certain', comment: 'Stale since #9.' }),
          routeEntry(2, 'fix-now', 1),
          routeEntry(99, 'fix-now', 1),
        ],
        domains: [{ name: 'core', contained: [1, 99], cross_cutting: [], overlays: [], revalidate: [3], note: '' }],
        summary: 'summary',
      }),
    }),
  })

  const result = await workflow.run({ ...globals, args: 'owner/name' })
  const routing = plain(result.routing)

  assert.deepEqual(routing.routed.map((r) => [r.number, r.route, r.rank]), [[2, 'close', 1], [1, 'needs-human', 1], [3, 'needs-human', 2]])
  assert.deepEqual(routing.routed[0], {
    number: 2, kind: 'issue', title: 'issue 2', route: 'close', rank: 1, why: 'why 2',
    close_reason: 'not planned', confidence: 'certain', comment: 'Stale since #9.',
  })
  assert.match(routing.routed[1].why, /close verdict is not verified/)
  assert.match(routing.routed[2].why, /Route omitted this item/)
  assert.equal(Object.hasOwn(routing.routed[2], 'close_reason'), false)
  assert.deepEqual(routing.counts, { 'fix-now': 0, 'needs-design': 0, deferred: 0, rescope: 0, close: 1, 'needs-human': 2 })
  assert.deepEqual(routing.domains[0].contained, [1])
  assert.equal(result.status, 'done')
  const prompt = trace.agents.find(({ opts }) => opts.label === 'route').prompt
  assert.doesNotMatch(prompt, /how many/i)
  assert.deepEqual(readData(prompt, 'items').map((d) => [d.number, d.closable]), [[1, false], [2, true], [3, false]])
})

test('code merges Ground and lens links, drops narrative and unknown links, and keeps the weaker type on a disagreement', async () => {
  const workflow = await loadWorkflow(path)
  const link = (from, to, type, evidence = `${type} evidence`) => ({ from, to, type, evidence })
  const { globals, trace } = createRuntime({
    respond: responder({
      gather: [issue(1), issue(2), issue(3)],
      grounds: { 1: ground(1, 'valid', { links: [link(1, 2, 'narrative', 'body mentions #2')] }) },
      map: ({ opts }) => ({
        'map:code': { touches: [{ number: 1, areas: ['src/a.js'] }], links: [link(1, 2, 'shared-seam'), link(2, 3, 'hard-coupling', 'schema.js:9')] },
        'map:tests': { touches: [], links: [link(2, 1, 'ordering')] },
        'map:docs': { touches: [], links: [link(1, 99, 'umbrella'), link(3, 3, 'ordering')] },
      })[opts.label],
    }),
  })

  const result = await workflow.run({ ...globals, args: 'owner/name' })
  const routing = plain(result.routing)

  assert.deepEqual(routing.links.map((l) => [l.from, l.to, l.type]), [[1, 2, 'shared-seam'], [2, 3, 'hard-coupling']])
  assert.match(routing.links[0].evidence, /disagree/)
  assert.equal(routing.hard_couplings, 1)
  const prompt = trace.agents.find(({ opts }) => opts.label === 'route').prompt
  assert.deepEqual(readData(prompt, 'links'), routing.links)
  assert.deepEqual(readData(prompt, 'lens-findings').map((l) => l.lens), ['code', 'tests', 'docs'])
  assert.equal(JSON.stringify(readData(prompt, 'lens-findings')).includes('"links"'), false)
  for (const { opts } of trace.agents.filter(({ opts }) => opts.label.startsWith('map:'))) {
    assert.deepEqual([opts.agentType, opts.effort], ['explorer', 'high'])
  }
})

test('a crashed Route returns the grounded results as partial instead of rejecting the run', async () => {
  const workflow = await loadWorkflow(path)
  const { globals } = createRuntime({
    respond: responder({ gather: [issue(1), issue(2)], route: () => { throw new Error('route crashed') } }),
  })

  const result = await workflow.run({ ...globals, args: 'owner/name' })

  assert.equal(result.routing, null)
  assert.equal(result.status, 'partial')
  assert.equal(result.grounded.length, 2)
  assert.ok(result.gaps.some((gap) => /Route/.test(gap)), JSON.stringify(result.gaps))
})

test('a budget below the floor blocks the run before the first agent', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: responder({ gather: [issue(1)] }), budgetTotal: 100000, budgetSpent: 60000 })

  const result = await workflow.run({ ...globals, args: 'owner/name' })

  assert.equal(result.status, 'blocked')
  assert.match(result.reason, /budget/)
  assert.equal(trace.agents.length, 0)
})

test('a budget that drops below the floor mid-run skips Map and Route and keeps the grounded results', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: responder({ gather: [issue(1), issue(2)] }) })
  const total = 1000000
  const spent = () => (trace.agents.length >= 2 ? 990000 : 0)
  const budget = { total, spent, remaining: () => Math.max(0, total - spent()) }

  const result = await workflow.run({ ...globals, budget, args: 'owner/name' })

  assert.deepEqual(labels(trace), ['gather', 'ground:b1'])
  assert.equal(result.status, 'partial')
  assert.equal(result.grounded.length, 2)
  assert.equal(result.routing, null)
  assert.ok(result.gaps.some((gap) => /budget/.test(gap)), JSON.stringify(result.gaps))
})

test('map:false skips Map, and Map reads at most 60 still-open items with the rest logged', async () => {
  const workflow = await loadWorkflow(path)

  const off = createRuntime({ respond: responder({ gather: [issue(1), issue(2)] }) })
  await workflow.run({ ...off.globals, args: { map: false } })
  assert.equal(labels(off.trace).some((l) => l.startsWith('map:')), false)

  const many = Array.from({ length: 61 }, (_, i) => issue(i + 1))
  const { globals, trace } = createRuntime({ respond: responder({ gather: many }) })
  const result = await workflow.run({ ...globals, args: { limit: 61 } })
  const mapCall = trace.agents.find(({ opts }) => opts.label === 'map:code')
  assert.equal(readData(mapCall.prompt, 'survivors').length, 60)
  assert.match(trace.logs.join('\n'), /1 still-open item\(s\) past the Map cap/)
  assert.equal(result.status, 'partial')
})

test('the worst case at limit 200 for both kinds stays far below the 1000-agent runtime cap', async () => {
  const workflow = await loadWorkflow(path)
  const gather = [...Array.from({ length: 200 }, (_, i) => issue(i + 1)), ...Array.from({ length: 200 }, (_, i) => pr(i + 201))]
  const base = responder({ gather, grounds: Object.fromEntries(gather.map((i) => [i.number, 'stale'])) })
  const { globals, trace } = createRuntime({
    // Every first Ground round misses, so each batch takes its redo; every close verdict then needs Verify.
    respond: (call) => (/^ground:b\d+$/.test(call.opts.label) ? { results: [] } : base(call)),
  })

  const result = await workflow.run({ ...globals, args: { limit: 200 } })

  // 1 gather + 100 ground + 100 redo + 100 verify + 1 route; Map is skipped because every item closes.
  assert.equal(trace.agents.length, 302)
  assert.equal(result.grounded.length, 400)
  assert.equal(result.status, 'done')
})
