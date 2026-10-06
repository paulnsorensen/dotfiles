import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow } from './harness.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/cheese-factory.js')

// ---- fixtures (each matches its phase agent's response schema) ----

function curd(slug, depends_on = []) {
  return { slug, brief: `build ${slug}`, depends_on }
}

function plan(curds, landing_shape = '') {
  return { mode: 'resolved', spec_path: '/specs/parent.md', slug: 'parent', landing_shape, curds }
}

const REF = (slug) => `wheypoint:acme/factory-parent--${slug}@rev-0123456789ab`
const CLEAN = ['dispatch_coder', 'dispatch_review', 'finish']
const FORK = { question: 'Which base?', options: [{ option: 'main', breaks: 'imports' }, { option: 'stack', breaks: 'bookkeeping' }] }

// A scripted run. `boss[slug]` is a queue of actions; each boss turn pops one.
// `over[label]` replaces the default response for one agent label.
function responder({ curds, boss, landing = '', coder = () => ({}), over = {}, gate = true }) {
  const queues = Object.fromEntries(Object.entries(boss).map(([k, v]) => [k, [...v]]))
  const stamp = gate ? { record_status: 'active' } : {}
  return ({ opts }) => {
    const label = opts.label || ''
    if (Object.hasOwn(over, label)) return typeof over[label] === 'function' ? over[label]() : over[label]
    const slug = label.split(':')[1]
    if (label === 'resolve') return plan(curds, landing)
    if (label === 'graph') return { project: 'acme' }
    if (label.startsWith('boss:')) {
      const action = queues[slug].shift()
      if (!action) throw new Error(`boss queue for ${slug} is empty`)
      const base = { role: 'boss', action, wheypoint_ref: REF(slug), ...stamp }
      if (action === 'raise_fork') return { ...base, fork: FORK }
      return action === 'dispatch_coder' ? { ...base, brief: `implement ${slug}` } : base
    }
    if (label.startsWith('code:')) return { role: 'coder', status: 'ok', next: 'age', wheypoint_ref: REF(slug), orientation: 'implemented', worktree_path: `/tmp/wt/${slug}`, ...stamp, ...coder(slug) }
    if (label.startsWith('review:')) return { role: 'reviewer', status: 'ok', next: 'done', wheypoint_ref: REF(slug), orientation: 'reviewed', findings: [], ...stamp }
    if (label.startsWith('press:')) return { status: 'ok', artifact: `.cheese/press/${slug}.md` }
    if (label === 'integrate' || label === 're-merge') return { worktree_path: '/tmp/wt/integration', merged: curds.map((c) => c.slug), conflicted: [], files_changed: 4, lines_changed: 40 }
    if (label === 'age:barrier' || label === 'age:reage') return { status: 'ok', has_medium_plus_findings: false, per_curd: [] }
    if (label.startsWith('cure:')) return { status: 'ok', committed: true }
    if (label === 'plate') return { results: curds.map((c) => ({ slug: c.slug, status: 'plated', pr_url: `https://example.test/pr/${c.slug}` })) }
    throw new Error(`unexpected agent label ${label}`)
  }
}

async function run(respond, args, extra = {}) {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond })
  const result = await workflow.run({ ...globals, ...extra, args })
  return { result, trace, labels: trace.agents.map((a) => a.opts.label) }
}

// Workflow values come from a vm realm; compare their plain JSON form.
const same = (actual, expected, message) => assert.deepEqual(JSON.parse(JSON.stringify(actual)), expected, message)
const call = (trace, label) => trace.agents.find((a) => a.opts.label === label)
const status = (result, slug) => result.curds.find((c) => c.slug === slug).status

// ---- Resolve ----

test('no spec lists candidates and dispatches nothing else', async () => {
  const { result, labels } = await run(({ opts }) => {
    assert.equal(opts.label, 'resolve')
    return { mode: 'candidates', candidates: ['spec-a'] }
  }, {})
  same(result, { candidates: ['spec-a'] })
  same(labels, ['resolve'])
})

test('a missing spec fails loud with the usage line', async () => {
  const { result, labels } = await run(() => ({ mode: 'missing', usage: 'Usage: /cheese-factory <spec> — spec not found at /x.md' }), { spec: 'x' })
  assert.match(result.error, /^Usage:/)
  same(labels, ['resolve'])
})

test('an invalid spec arg fails before any agent; bare and JSON-quoted strings are the spec', async () => {
  const none = await run(() => { throw new Error('no agent expected') }, { spec: '../etc/passwd' })
  assert.match(none.result.error, /^Invalid spec arg/)
  assert.equal(none.labels.length, 0)
  for (const args of ['parent', '"parent"', '~/specs/parent.md']) {
    const { trace } = await run(responder({ curds: [curd('alpha')], boss: { alpha: CLEAN } }), args)
    assert.match(call(trace, 'resolve').prompt, new RegExp(`A spec was given: "${args.replace(/"/g, '')}"`))
  }
})

test('an invalid curd plan stops before the graph', async () => {
  const plans = [
    [curd('alpha', ['beta']), curd('beta', ['alpha'])],
    [curd('alpha', ['ghost'])],
    [curd('alpha'), curd('alpha')],
    [curd('Bad Slug')],
  ]
  for (const curds of plans) {
    const { result, labels } = await run(responder({ curds, boss: {} }), { spec: 'parent' })
    assert.match(result.error, /^invalid curd plan/)
    same(labels, ['resolve'])
  }
})

// ---- Curd boss loop ----

test('a clean curd runs boss -> coder -> boss -> reviewer -> boss, then press, integrate, age, and plate', async () => {
  const { result, trace, labels } = await run(responder({ curds: [curd('alpha')], boss: { alpha: CLEAN } }), { spec: 'parent' })
  same(labels, ['resolve', 'graph', 'boss:alpha:t1', 'code:alpha:t1', 'boss:alpha:t2', 'review:alpha:t2', 'boss:alpha:t3', 'press:alpha', 'integrate', 'age:barrier', 'plate'])
  assert.equal(result.status, 'done')
  same(result.summary, { clean: 1 })
  assert.equal(result.curds[0].pr_url, 'https://example.test/pr/alpha')
  const roles = Object.fromEntries(trace.agents.map((a) => [a.opts.label, [a.opts.agentType, a.opts.model]]))
  same(roles['boss:alpha:t1'], ['generalist', 'opus'])
  same(roles['code:alpha:t1'], ['coder', 'sonnet'])
  same(roles['review:alpha:t2'], ['reviewer', 'opus'])
  assert.match(call(trace, 'review:alpha:t2').prompt, /^Review mode: severity-report\n/)
  assert.match(call(trace, 'age:barrier').prompt, /^Review mode: severity-report\n/)
})

test('a coder gets only the curd ref and the boss brief, never prior handback JSON (AC-5)', async () => {
  const { trace } = await run(responder({ curds: [curd('alpha')], boss: { alpha: ['dispatch_coder', 'dispatch_coder', 'dispatch_review', 'finish'] } }), { spec: 'parent' })
  const coders = trace.agents.filter((a) => a.opts.label.startsWith('code:'))
  assert.equal(coders.length, 2)
  for (const c of coders) {
    assert.match(c.prompt, /Curd record: wheypoint:acme\/factory-parent--alpha\./)
    assert.match(c.prompt, /Brief: implement alpha/)
    assert.doesNotMatch(c.prompt, /"orientation":"implemented"|Last worker result/)
  }
  assert.equal(coders[0].opts.isolation, 'worktree')
  assert.match(coders[0].prompt, /git checkout -B curd\/alpha origin\/main/)
  assert.equal(coders[1].opts.isolation, undefined)
  assert.match(coders[1].prompt, /cd \/tmp\/wt\/alpha first/)
  assert.match(call(trace, 'boss:alpha:t2').prompt, /Last worker result: \{"action":"dispatch_coder","status":"ok","next":"age"/)
})

test('a dependent curd branches from its dependency and stacks on it at plate', async () => {
  const curds = [curd('alpha'), curd('beta', ['alpha'])]
  const { result, trace, labels } = await run(responder({ curds, boss: { alpha: CLEAN, beta: CLEAN }, landing: 'stacked_linear' }), { spec: 'parent' })
  assert.ok(labels.indexOf('boss:alpha:t3') < labels.indexOf('boss:beta:t1'), 'beta waits for alpha to finish')
  assert.match(call(trace, 'code:beta:t1').prompt, /git checkout -B curd\/beta curd\/alpha/)
  assert.match(call(trace, 'review:beta:t2').prompt, /dependency branches \["curd\/alpha"\] were reviewed already/)
  assert.match(call(trace, 'integrate').prompt, /\["curd\/alpha","curd\/beta"\]/)
  const plate = call(trace, 'plate').prompt
  assert.match(plate, /landing shape "stacked_linear"/)
  assert.match(plate, /\{"slug":"beta","branch":"curd\/beta","base":"curd\/alpha"\}/)
  same(result.summary, { clean: 2 })
})

test('a curd with no finish after the turn cap stalls and is not plated', async () => {
  const { result, labels } = await run(responder({ curds: [curd('alpha')], boss: { alpha: Array(12).fill('dispatch_coder') } }), { spec: 'parent' })
  assert.equal(status(result, 'alpha'), 'stalled')
  assert.equal(labels.filter((l) => l.startsWith('boss:')).length, 12)
  assert.ok(!labels.includes('plate'))
})

test('a boss review before any coder, or a dispatch without a brief, fails the curd', async () => {
  const early = await run(responder({ curds: [curd('alpha')], boss: { alpha: ['dispatch_review'] } }), { spec: 'parent' })
  assert.match(early.result.curds[0].reason, /review before any coder/)
  const blank = await run(responder({ curds: [curd('alpha')], boss: { alpha: ['dispatch_coder'] }, over: { 'boss:alpha:t1': { role: 'boss', action: 'dispatch_coder', wheypoint_ref: REF('alpha'), brief: ' ' } } }), { spec: 'parent' })
  assert.match(blank.result.curds[0].reason, /without a brief/)
})

test('a missing gate stamp logs once and does not stop the run', async () => {
  const { result, trace } = await run(responder({ curds: [curd('alpha')], boss: { alpha: CLEAN }, gate: false }), { spec: 'parent' })
  assert.equal(result.status, 'done')
  assert.equal(trace.logs.filter((l) => l.includes('handback gate did not report')).length, 1)
})

// ---- Forks: park, return, resume ----

test('a boss fork parks its curd, siblings finish, and the run returns before press (AC-6)', async () => {
  const curds = [curd('alpha'), curd('beta'), curd('gamma', ['alpha'])]
  const { result, labels } = await run(responder({ curds, boss: { alpha: ['raise_fork'], beta: CLEAN, gamma: CLEAN } }), { spec: 'parent' })
  assert.equal(result.status, 'gated')
  same(result.forks, [{ slug: 'alpha', record: 'wheypoint:acme/factory-parent--alpha', fork: FORK }])
  same(result.curds.map((c) => [c.slug, c.state]), [['alpha', 'parked'], ['beta', 'finished'], ['gamma', 'blocked']])
  assert.ok(!labels.some((l) => l.includes(':gamma:')), 'a dependent of a parked curd never dispatches')
  assert.ok(!labels.some((l) => l.startsWith('press:') || l === 'integrate'))
})

test('resume replays the original calls first, then continues the answered fork and its dependents (AC-7)', async () => {
  const curds = [curd('alpha'), curd('beta'), curd('gamma', ['alpha'])]
  const boss = { alpha: ['dispatch_coder', 'raise_fork', 'dispatch_review', 'finish'], beta: CLEAN, gamma: CLEAN }
  const first = await run(responder({ curds, boss }), { spec: 'parent' })
  assert.equal(first.result.status, 'gated')

  const resumed = await run(responder({ curds, boss }), { spec: 'parent', answers: { alpha: 'stack on main' } })
  const prefix = first.trace.agents.map((a) => [a.opts.label, a.prompt])
  same(resumed.trace.agents.slice(0, prefix.length).map((a) => [a.opts.label, a.prompt]), prefix, 'pass 1 is a cache-identical replay')
  const live = resumed.labels.slice(prefix.length)
  same(live.slice(0, 3), ['boss:alpha:t3', 'review:alpha:t3', 'boss:alpha:t4'])
  assert.ok(live.includes('boss:gamma:t1'), 'the blocked dependent runs after its dependency finishes')
  assert.match(call(resumed.trace, 'boss:alpha:t3').prompt, /The user answered your open fork: "stack on main"/)
  assert.doesNotMatch(call(resumed.trace, 'boss:alpha:t4').prompt, /The user answered/)
  assert.equal(resumed.result.status, 'done')
  same(resumed.result.summary, { clean: 3 })
})

test('a second fork on a resumed curd parks again and takes the next answer in order', async () => {
  const curds = [curd('alpha')]
  const boss = () => ({ alpha: ['raise_fork', 'raise_fork', 'dispatch_coder', 'dispatch_review', 'finish'] })
  const once = await run(responder({ curds, boss: boss() }), { spec: 'parent', answers: { alpha: 'first' } })
  assert.equal(once.result.status, 'gated')
  assert.equal(once.result.forks[0].slug, 'alpha')
  const twice = await run(responder({ curds, boss: boss() }), { spec: 'parent', answers: { alpha: ['first', 'second'] } })
  assert.equal(twice.result.status, 'done')
  assert.match(call(twice.trace, 'boss:alpha:t3').prompt, /answered your open fork: "second"/)
})

test('a gated coder parks the curd; the answer goes to the next boss turn', async () => {
  const curds = [curd('alpha')]
  const coder = () => ({ status: 'gated: which schema version?', next: 'hold' })
  const parked = await run(responder({ curds, boss: { alpha: ['dispatch_coder'] }, coder }), { spec: 'parent' })
  assert.equal(parked.result.status, 'gated')
  assert.equal(parked.result.forks[0].fork.question, 'which schema version?')
  const resumed = await run(responder({ curds, boss: { alpha: ['dispatch_coder', 'finish'] }, coder }), { spec: 'parent', answers: { alpha: 'v2' } })
  assert.match(call(resumed.trace, 'boss:alpha:t2').prompt, /answered your open fork: "v2"/)
  assert.match(call(resumed.trace, 'boss:alpha:t2').prompt, /"status":"gated: which schema version\?"/)
})

// ---- Stop statuses and barriers (AC-8) ----

test('a coder halt keeps the curd out of integrate and plate', async () => {
  const curds = [curd('alpha'), curd('beta')]
  const coder = (slug) => (slug === 'beta' ? { status: 'halt: gate failed', next: 'hold' } : {})
  const { result, trace } = await run(responder({ curds, boss: { alpha: CLEAN, beta: CLEAN }, coder }), { spec: 'parent' })
  assert.equal(status(result, 'beta'), 'halted')
  assert.doesNotMatch(call(trace, 'integrate').prompt, /curd\/beta/)
  assert.doesNotMatch(call(trace, 'plate').prompt, /curd\/beta/)
})

test('a press halt marks the curd dirty and blocks its dependent', async () => {
  const curds = [curd('alpha'), curd('beta', ['alpha']), curd('gamma')]
  const { result, trace } = await run(responder({ curds, boss: { alpha: CLEAN, beta: CLEAN, gamma: CLEAN }, over: { 'press:alpha': { status: 'halt: tests would not go red' } } }), { spec: 'parent' })
  assert.equal(status(result, 'alpha'), 'dirty')
  assert.equal(status(result, 'beta'), 'blocked')
  assert.equal(status(result, 'gamma'), 'clean')
  assert.match(call(trace, 'integrate').prompt, /\["curd\/gamma"\]/)
})

test('an integrate conflict fails that curd and keeps the merged one clean', async () => {
  const curds = [curd('alpha'), curd('beta')]
  const over = { integrate: { worktree_path: '/tmp/wt/integration', merged: ['alpha'], conflicted: ['beta'], files_changed: 2, lines_changed: 10 } }
  const { result } = await run(responder({ curds, boss: { alpha: CLEAN, beta: CLEAN }, over }), { spec: 'parent' })
  assert.equal(status(result, 'alpha'), 'clean')
  assert.equal(status(result, 'beta'), 'failed')
  assert.match(result.curds.find((c) => c.slug === 'beta').reason, /merge conflict/)
})

// ---- Age, Cure, Re-age ----

const flagged = (slugs) => ({ status: 'ok', has_medium_plus_findings: true, per_curd: slugs.map((slug) => ({ slug, has_medium_plus_findings: true, findings: [{ severity: 'high', file: `${slug}.js`, claim: 'bug' }] })) })

test('a routed finding cures that curd, and a clean re-age keeps it in plate', async () => {
  const curds = [curd('alpha'), curd('beta')]
  const { result, labels, trace } = await run(responder({ curds, boss: { alpha: CLEAN, beta: CLEAN }, over: { 'age:barrier': flagged(['alpha']) } }), { spec: 'parent' })
  same(labels.slice(labels.indexOf('age:barrier')), ['age:barrier', 'cure:alpha', 're-merge', 'age:reage', 'plate'])
  assert.match(call(trace, 'cure:alpha').prompt, /cd \/tmp\/wt\/alpha first/)
  assert.match(call(trace, 'age:reage').prompt, /"claim":"bug"/)
  same(result.summary, { clean: 2 })
})

test('a cure that halts or commits nothing marks the curd dirty and skips re-age', async () => {
  for (const cure of [{ status: 'halt: cannot fix', committed: true }, { status: 'ok', committed: false }]) {
    const { result, labels } = await run(responder({ curds: [curd('alpha')], boss: { alpha: CLEAN }, over: { 'age:barrier': flagged(['alpha']), 'cure:alpha': cure } }), { spec: 'parent' })
    assert.equal(status(result, 'alpha'), 'dirty')
    assert.ok(!labels.includes('age:reage'))
    assert.ok(!labels.includes('plate'))
  }
})

test('a re-age that still flags a curd marks it dirty', async () => {
  const curds = [curd('alpha'), curd('beta')]
  const over = { 'age:barrier': flagged(['alpha', 'beta']), 'age:reage': flagged(['beta']) }
  const { result } = await run(responder({ curds, boss: { alpha: CLEAN, beta: CLEAN }, over }), { spec: 'parent' })
  assert.equal(status(result, 'alpha'), 'clean')
  assert.equal(status(result, 'beta'), 'dirty')
})

test('medium+ findings without per-curd routing mark every integrated curd dirty', async () => {
  const over = { 'age:barrier': { status: 'ok', has_medium_plus_findings: true, per_curd: [] } }
  const { result, labels } = await run(responder({ curds: [curd('alpha')], boss: { alpha: CLEAN }, over }), { spec: 'parent' })
  assert.equal(status(result, 'alpha'), 'dirty')
  assert.ok(!labels.includes('plate'))
})

test('a large integrated diff dispatches age-fanout and falls back to one reviewer when it throws', async () => {
  const over = { integrate: { worktree_path: '/tmp/wt/integration', merged: ['alpha'], conflicted: [], files_changed: 20, lines_changed: 900 } }
  const calls = []
  const fanout = async (name, args) => { calls.push([name, args]); return { status: 'ok', has_medium_plus_findings: false, per_curd: [] } }
  const used = await run(responder({ curds: [curd('alpha')], boss: { alpha: CLEAN }, over }), { spec: 'parent' }, { workflow: fanout })
  same(calls, [['age-fanout', { worktree_path: '/tmp/wt/integration', range: 'origin/main...HEAD', slug: 'parent', route_curds: [{ slug: 'alpha', branch: 'curd/alpha', depends_on: [] }] }]])
  assert.ok(!used.labels.includes('age:barrier'))

  const fallback = await run(responder({ curds: [curd('alpha')], boss: { alpha: CLEAN }, over }), { spec: 'parent' })
  assert.ok(fallback.labels.includes('age:barrier'))
  assert.equal(fallback.result.status, 'done')
})
