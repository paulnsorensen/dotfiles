import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow } from './harness.mjs'
import { digestOf } from './prelude-digest.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/cheese-board.js')
const STAMP = '2026-10-14'
const SPECS_DIR = '/data/cheese/repo/specs'
const REPORT = `.cheese/notes/cheese-board-${STAMP}.md`

const issue = (number, title) => ({ number, kind: 'issue', title })
const ground = (number, title, verdict) => ({
  item: issue(number, title),
  ground: { number, kind: 'issue', title, verdict, evidence: [{ claim: 'checked', citation: `src/a.js:${number}` }], summary: `summary ${number}`, recommendation: 'fix now' },
  verify: null,
})

const TRIAGE = {
  items: [issue(1, 'Banner missing')],
  grounded: [ground(1, 'Banner missing', 'valid')],
  lenses: [],
  routing: { routed: [{ number: 1, kind: 'issue', title: 'Banner missing', route: 'fix-now', rank: 1, why: '/cook' }], domains: [], links: [], summary: 'done' },
}
const IDEAS = { ideas: [{ title: 'Faster sync', summary: 'cache the render step', source: 'wiki/roadmap.md', existing_spec: '', duplicate_of: '' }] }

const initiative = (id, overrides = {}) => ({
  id, theme: 'TH-1', title: `title ${id}`, outcome: `outcome ${id}`, items: [], depends_on: [], lane: 'spec', slug: '',
  priority: 1, leverage_triggers: [], open_questions: [], overrides: [], research_questions: [], rationale: `why ${id}`, ...overrides,
})
const GROUNDING = {
  decisions: [{ statement: 'Specs live in the durable corpus.', kind: 'adr', citation: 'adr/specs.md:3', items: ['#1'] }],
  prior_research: [],
}
const strategyOf = (first = {}) => ({
  themes: [{ id: 'TH-1', name: 'Polish', thesis: 'Make the tool feel finished.' }],
  initiatives: [
    initiative('IN-1', { items: ['#1'], slug: 'version-banner', ...first }),
    initiative('IN-2', { items: ['IDEA-1'], slug: 'sync-cache', priority: 2 }),
  ],
  parked: [],
  summary: 'Polish first, then speed.',
})
const DRAFT = {
  intent: 'Print a version banner.', confidence: 'high', blast_radius: 'low', inputs: 'issue #1', outputs: 'a banner',
  verification: 'bin/demo --version exits 0', contract: 'The demo command prints a banner.', goals: ['Print the banner from bin/demo.'],
  grounding: [{ probe: 'wiki', outcome: 'miss', evidence: 'no page' }, { probe: 'explorer', outcome: 'hit', evidence: 'bin/demo:1' }],
  criteria: ['`bin/demo --version` exits 0.'], non_goals: ['No other command changes.'],
  leverage_triggers: [], open_questions: [],
}
const APPROVE = { verdict: 'approve', concerns: [], guidance: 'ok', blocking_questions: [] }
const REVISE = { verdict: 'revise', concerns: ['Split the work differently.'], guidance: 'rethink', blocking_questions: [] }

const specText = (prompt) => JSON.parse(/<data name="spec_text">\n([\s\S]*?)\n<\/data>/.exec(prompt)[1])
const chars = (text) => [...text].length

function responder(overrides = {}, strategy = strategyOf()) {
  return ({ prompt, opts }) => {
    const label = opts.label
    if (Object.hasOwn(overrides, label)) {
      const value = overrides[label]
      return typeof value === 'function' ? value({ prompt, opts }) : value
    }
    if (label === 'ideas') return IDEAS
    if (label.startsWith('strategist:') || label.startsWith('synthesize:')) return strategy
    if (label.startsWith('advise:')) return APPROVE
    if (label === 'resolve') {
      const slugs = JSON.parse(/<data name="slugs">\n([\s\S]*?)\n<\/data>/.exec(prompt)[1])
      return { specs: slugs.map((slug) => ({ slug, path: `${SPECS_DIR}/${slug}.md`, exists: false })), report_path: REPORT }
    }
    if (label.startsWith('draft:')) return DRAFT
    if (label.startsWith('taste:')) return { verdict: 'pass', concerns: [] }
    if (label.startsWith('install:')) {
      return { path: `${SPECS_DIR}/${label.split(':')[1]}.md`, target_existed: false, chars: chars(specText(prompt)), validate_exit: 0, validate_output: '{"valid": true}', candidate_curds: 1, installed: true }
    }
    if (label === 'verify:specs') {
      const paths = JSON.parse(/<data name="paths">\n([\s\S]*?)\n<\/data>/.exec(prompt)[1])
      return { results: paths.map((p) => ({ path: p, valid: true, candidate_curds: 1, note: '' })) }
    }
    if (label.startsWith('write:report')) {
      const report = JSON.parse(/<data name="report">\n([\s\S]*?)\n<\/data>/.exec(prompt)[1])
      return { path: REPORT, chars: chars(report) }
    }
    if (label === 'ground') return GROUNDING
    if (label === 'record:strategy') return { corpus: 'repo:dotfiles:wiki', path: `strategy/cheese-board-${STAMP}.md` }
    throw new Error(`unexpected agent ${label}`)
  }
}

async function runBoard({ args = { stamp: STAMP }, overrides = {}, strategy = strategyOf(), research = null } = {}) {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: responder(overrides, strategy), budgetTotal: null, budgetSpent: 0 })
  const result = await workflow.run({
    ...globals,
    args,
    workflow: async (name) => {
      if (name === 'brie-ground') {
        if (!research) throw new Error('unexpected research')
        return research()
      }
      return TRIAGE
    },
  })
  return { result: JSON.parse(JSON.stringify(result)), trace, labels: trace.agents.map(({ opts }) => opts.label), prompts: trace.agents.map(({ prompt }) => prompt) }
}

const resumeWith = (paused, answers, extra = {}) => ({ stamp: STAMP, state: paused.state, digest: paused.digest, answers, ...extra })
const PAUSED_STRATEGY = { 'advise:strategy:0': REVISE, 'advise:strategy:1': REVISE }

test('AC-1: an unsettled strategy advisor returns needs-input at the revision cap', async () => {
  const { result, labels } = await runBoard({ overrides: PAUSED_STRATEGY })
  assert.equal(result.status, 'needs-input')
  assert.equal(result.checkpoint, 'strategy')
  assert.equal(result.questions.length, 1)
  const q = result.questions[0]
  assert.equal(q.id, 'S-1')
  for (const field of ['initiative', 'question', 'options', 'recommended', 'evidence']) assert.ok(Object.hasOwn(q, field), `question has ${field}`)
  assert.ok(q.question.length > 0)
  assert.ok(Array.isArray(q.options))
  assert.equal(result.state.checkpoint, 'strategy')
  assert.deepEqual(result.state.questions, result.questions)
  assert.match(result.usage, /Re-run cheese-board with/)
  assert.match(result.digest, /^[0-9a-f]{16}$/)
  assert.ok(labels.includes('synthesize:r1'))
  assert.ok(!labels.some((l) => l.startsWith('draft:')))
})

test('AC-1: auto true keeps the one-revision needs-input result with no resume channel', async () => {
  const { result } = await runBoard({ args: { stamp: STAMP, auto: true }, overrides: PAUSED_STRATEGY })
  assert.equal(result.status, 'needs-input')
  assert.match(result.usage, /auto run cannot resume/)
})

test('AC-2: a strategy resume skips Gather, Ground, and the first-round Strategy', async () => {
  const first = await runBoard({ overrides: PAUSED_STRATEGY })
  const { result, labels } = await runBoard({ args: resumeWith(first.result, { 1: 'Keep both initiatives.' }) })
  assert.equal(result.status, 'ok')
  for (const skipped of ['ideas', 'ground', 'synthesize:r0']) assert.ok(!labels.includes(skipped), skipped)
  assert.ok(!labels.some((l) => l.startsWith('strategist:')))
  assert.ok(labels.includes('synthesize:r1'))
})

test('AC-3: a tampered state or a bad answer blocks before any agent runs', async () => {
  const first = (await runBoard({ overrides: PAUSED_STRATEGY })).result
  const tampered = { ...first.state, gaps: ['edited'] }
  const cases = [
    { ...resumeWith(first, { 1: 'x' }), state: tampered },
    resumeWith(first, { 9: 'x' }),
    resumeWith(first, { 1: '' }),
    { ...resumeWith(first, { 1: 'x' }), digest: 'nope' },
    { ...resumeWith(first, { 1: 'x' }), auto: true },
    { ...resumeWith(first, { 1: 'x' }), lanes: { 'IN-9': 'spec' } },
    { ...resumeWith(first, { 1: 'x' }), lanes: { 'IN-1': 'archive' } },
  ]
  for (const args of cases) {
    const { result, labels } = await runBoard({ args })
    assert.equal(result.status, 'blocked')
    assert.deepEqual(labels, [])
  }
})

test('AC-3: a multi-error resume returns every error, and a closed question rejects a free answer', async () => {
  const first = (await runBoard({ overrides: PAUSED_STRATEGY })).result
  const multi = (await runBoard({ args: { ...resumeWith(first, { 9: 'x' }), digest: 'nope', lanes: { 'IN-9': 'spec' } } })).result
  assert.equal(multi.status, 'blocked')
  assert.ok(multi.errors.length >= 2, multi.errors.join('; '))

  const strategy = strategyOf({ overrides: ['D-1'] })
  const override = (await runBoard({ strategy })).result
  const closed = await runBoard({ args: resumeWith(override, { 1: 'maybe' }), strategy })
  assert.equal(closed.result.status, 'blocked')
  assert.match(closed.result.error, /must be one of spec, mold/)
  assert.deepEqual(closed.labels, [])

  const spec = (await runBoard({ overrides: { 'draft:version-banner:r0': { ...DRAFT, open_questions: ['Which banner format?'] } } })).result
  const late = await runBoard({ args: resumeWith(spec, { 1: 'x' }, { lanes: { 'IN-1': 'mold' } }) })
  assert.equal(late.result.status, 'blocked')
  assert.match(late.result.error, /lanes applies only at the strategy checkpoint/)
})

test('a bare stamp string parses as an interactive run', async () => {
  const { result } = await runBoard({ args: STAMP })
  assert.equal(result.status, 'ok', result.error)
})

test('AC-4: a drafter open question gives a spec needs-input, and a resume redrafts only that initiative', async () => {
  const asked = { 'draft:version-banner:r0': { ...DRAFT, open_questions: ['Which banner format?'] } }
  const first = await runBoard({ overrides: asked })
  assert.equal(first.result.status, 'needs-input')
  assert.equal(first.result.checkpoint, 'spec')
  assert.equal(first.result.questions[0].initiative, 'IN-1')
  assert.ok(first.labels.includes('draft:sync-cache:r0'))

  const second = await runBoard({ args: resumeWith(first.result, { 1: 'Plain text banner.' }) })
  assert.equal(second.result.status, 'ok')
  assert.deepEqual(second.labels.filter((l) => l.startsWith('draft:')), ['draft:version-banner:r0'])
  assert.ok(second.prompts.some((p) => p.includes('Plain text banner.')))
  assert.ok(!second.labels.includes('resolve'))
  assert.ok(!second.result.mold.some((m) => m.initiative === 'IN-1'))
})

test('AC-4: a redraft with a new open question asks again with only the unanswered question', async () => {
  const first = await runBoard({ overrides: { 'draft:version-banner:r0': { ...DRAFT, open_questions: ['Which banner format?'] } } })
  const again = await runBoard({
    args: resumeWith(first.result, { 1: 'Plain text banner.' }),
    overrides: { 'draft:version-banner:r0': { ...DRAFT, open_questions: ['Which stream?'] } },
  })
  assert.equal(again.result.status, 'needs-input')
  assert.equal(again.result.checkpoint, 'spec')
  assert.equal(again.result.questions.length, 1)
  assert.match(again.result.questions[0].question, /Which stream\?/)

  const done = await runBoard({ args: resumeWith(again.result, { 1: 'stdout' }) })
  assert.equal(done.result.status, 'ok')
  assert.ok(done.prompts.some((p) => p.includes('Plain text banner.') && p.includes('stdout')))
})

test('AC-6: an override asks, and the answer spec keeps the lane and records the decision in the spec', async () => {
  const strategy = strategyOf({ overrides: ['D-1'] })
  const first = await runBoard({ strategy })
  assert.equal(first.result.status, 'needs-input')
  assert.equal(first.result.checkpoint, 'strategy')
  const q = first.result.questions[0]
  assert.equal(q.initiative, 'IN-1')
  assert.deepEqual(q.options, ['spec', 'mold'])
  assert.equal(q.recommended, 'mold')

  const second = await runBoard({ args: resumeWith(first.result, { [q.id]: 'spec' }), strategy })
  assert.equal(second.result.status, 'ok')
  assert.equal(second.result.strategy.initiatives.find((i) => i.id === 'IN-1').lane, 'spec')
  assert.ok(second.labels.includes('install:version-banner:r0'))
  const install = second.prompts[second.labels.indexOf('install:version-banner:r0')]
  assert.match(specText(install), /## Decision overrides/)
  const report = second.prompts[second.labels.indexOf('write:report')]
  assert.match(report, /kept in the spec lane by the user/)
})

test('AC-6: the answer mold routes the overriding initiative to mold', async () => {
  const strategy = strategyOf({ overrides: ['D-1'] })
  const first = await runBoard({ strategy })
  const second = await runBoard({ args: resumeWith(first.result, { 1: 'mold' }), strategy })
  assert.equal(second.result.status, 'ok')
  assert.equal(second.result.strategy.initiatives.find((i) => i.id === 'IN-1').lane, 'mold')
  assert.ok(!second.labels.includes('draft:version-banner:r0'))
})

test('AC-7: a leverage trigger asks mold or spec anyway, with mold recommended', async () => {
  const strategy = strategyOf({ leverage_triggers: ['auth'] })
  const first = await runBoard({ strategy })
  assert.equal(first.result.status, 'needs-input')
  assert.equal(first.result.checkpoint, 'spec')
  const q = first.result.questions[0]
  assert.deepEqual(q.options, ['mold', 'spec anyway'])
  assert.equal(q.recommended, 'mold')
  assert.ok(!first.labels.includes('draft:version-banner:r0'))

  const anyway = await runBoard({ args: resumeWith(first.result, { [q.id]: 'spec anyway' }), strategy })
  assert.equal(anyway.result.status, 'ok')
  assert.ok(anyway.labels.includes('draft:version-banner:r0'))
  assert.ok(anyway.labels.includes('install:version-banner:r0'))
  assert.ok(anyway.result.factory_queue.flat().some((e) => e.slug === 'version-banner'))

  const mold = await runBoard({ args: resumeWith(first.result, { [q.id]: 'mold' }), strategy })
  assert.ok(!mold.labels.includes('draft:version-banner:r0'))
  assert.ok(mold.result.mold.some((m) => m.initiative === 'IN-1'))
})

test('AC-8: an unapproved done advisor pauses, approve records, and a fix edits the report once', async () => {
  const first = await runBoard({ overrides: { 'advise:done': REVISE } })
  assert.equal(first.result.status, 'needs-input')
  assert.equal(first.result.checkpoint, 'done')
  const q = first.result.questions[0]
  assert.ok(q.options.includes('approve'))
  assert.ok(!first.labels.includes('record:strategy'))

  const approved = await runBoard({ args: resumeWith(first.result, { [q.id]: 'approve' }) })
  assert.equal(approved.result.status, 'ok')
  assert.ok(approved.labels.includes('record:strategy'))
  for (const skipped of ['ideas', 'ground', 'resolve', 'verify:specs', 'write:report', 'write:report:fix']) assert.ok(!approved.labels.includes(skipped), skipped)

  const fixed = await runBoard({ args: resumeWith(first.result, { [q.id]: 'Add a rollout note.' }) })
  assert.ok(fixed.labels.includes('write:report:fix'))
  assert.ok(fixed.labels.includes('advise:done:r1'))
  assert.ok(!fixed.labels.includes('verify:specs'))
})

const dataOf = (prompt, name) => JSON.parse(new RegExp(`<data name="${name}">\\n([\\s\\S]*?)\\n</data>`).exec(prompt)[1])
const promptOf = (run, label) => run.prompts[run.labels.indexOf(label)]
const TWO_DECISIONS = {
  decisions: [
    { statement: 'Specs live in the durable corpus.', kind: 'adr', citation: 'adr/specs.md:3', items: ['#1'] },
    { statement: 'Banners stay out of the CLI.', kind: 'adr', citation: 'adr/cli.md:9', items: ['#1'] },
  ],
  prior_research: [],
}

test('F1: a fresh revision round sends the last concerns and guidance to the advisor', async () => {
  const run = await runBoard({ overrides: PAUSED_STRATEGY })
  const payload = dataOf(promptOf(run, 'advise:strategy:1'), 'payload')
  assert.deepEqual(payload.prior_concerns, REVISE.concerns)
  assert.equal(payload.guidance, REVISE.guidance)
  assert.ok(!Object.hasOwn(dataOf(promptOf(run, 'advise:strategy:0'), 'payload'), 'prior_concerns'))
  assert.ok(!Object.hasOwn(payload, 'user_answers'))
})

test('F1: a strategy resume sends the user answers to the advisor and the synthesis, and the prompt marks them resolved', async () => {
  const first = await runBoard({ overrides: PAUSED_STRATEGY })
  const run = await runBoard({ args: resumeWith(first.result, { 1: 'Keep both initiatives.' }) })
  assert.equal(run.result.status, 'ok')
  const payload = dataOf(promptOf(run, 'advise:strategy:1'), 'payload')
  assert.deepEqual(payload.prior_concerns, REVISE.concerns)
  assert.equal(payload.guidance, REVISE.guidance)
  assert.deepEqual(payload.user_answers.map((a) => a.answer), ['Keep both initiatives.'])
  assert.match(promptOf(run, 'advise:strategy:1'), /counts as resolved/)
  assert.match(promptOf(run, 'synthesize:r1'), /Keep both initiatives\./)
})

test('F1 and F13: a strategy concern row offers approve, and answering approve settles without a revision', async () => {
  const first = await runBoard({ overrides: PAUSED_STRATEGY })
  const q = first.result.questions[0]
  assert.deepEqual(q.options, ['approve'])
  assert.equal(q.kind, 'approve')
  const run = await runBoard({ args: resumeWith(first.result, { 1: 'approve' }) })
  assert.equal(run.result.status, 'ok')
  assert.ok(!run.labels.includes('synthesize:r1'))
  assert.ok(!run.labels.some((l) => l.startsWith('advise:strategy')))
})

test('F13: an advisor blocking question pauses as an open question with its options and evidence', async () => {
  const blocking = { verdict: 'approve', concerns: [], guidance: 'g', blocking_questions: [{ question: 'Pick A or B?', options: ['A', 'B'], recommended: 'A', evidence: 'the data cannot settle it' }] }
  const { result } = await runBoard({ overrides: { 'advise:strategy:0': blocking } })
  assert.equal(result.status, 'needs-input')
  assert.equal(result.questions.length, 1)
  const q = result.questions[0]
  assert.equal(q.question, 'Pick A or B?')
  assert.deepEqual(q.options, ['A', 'B'])
  assert.equal(q.recommended, 'A')
  assert.equal(q.evidence, 'the data cannot settle it')
  assert.equal(q.kind, 'open')
})

test('F13: override, trigger, and open questions carry their kind', async () => {
  const override = (await runBoard({ strategy: strategyOf({ overrides: ['D-1'] }) })).result
  assert.equal(override.questions[0].kind, 'override')
  const spec = (await runBoard({ overrides: { 'draft:version-banner:r0': { ...DRAFT, leverage_triggers: ['touches a shared path'], open_questions: ['Which format?'] } } })).result
  assert.deepEqual(spec.questions.filter((q) => q.initiative === 'IN-1').map((q) => q.kind), ['trigger', 'open'])
})

test('F3: a re-synthesis that changes the override set asks again instead of reusing the old decision', async () => {
  const strategy = strategyOf({ overrides: ['D-1'] })
  const widened = strategyOf({ overrides: ['D-1', 'D-2'] })
  const first = await runBoard({ strategy, overrides: { ground: TWO_DECISIONS, 'advise:strategy:0': REVISE, 'advise:strategy:1': REVISE } })
  assert.equal(first.result.status, 'needs-input')
  const overrideQ = first.result.questions.find((q) => q.kind === 'override')
  const freeQ = first.result.questions.find((q) => q.kind === 'approve')
  const run = await runBoard({
    args: resumeWith(first.result, { [freeQ.id]: 'Rework it.', [overrideQ.id]: 'spec' }),
    strategy,
    overrides: { 'synthesize:r1': widened },
  })
  assert.equal(run.result.status, 'needs-input')
  const again = run.result.questions.find((q) => q.kind === 'override')
  assert.ok(again, 'the override is asked again')
  assert.match(again.question, /D-1, D-2/)
})

test('F10: a lane move persists in the state and applies on a later resume', async () => {
  const first = await runBoard({ overrides: PAUSED_STRATEGY })
  const second = await runBoard({ args: resumeWith(first.result, { 1: 'x' }, { lanes: { 'IN-2': 'mold' } }), overrides: { 'advise:strategy:1': REVISE } })
  assert.equal(second.result.status, 'needs-input')
  assert.deepEqual(second.result.state.user_lanes, { 'IN-2': 'mold' })
  const third = await runBoard({ args: resumeWith(second.result, { 1: 'y' }) })
  assert.equal(third.result.status, 'ok')
  assert.deepEqual(third.labels.filter((l) => l.startsWith('draft:')), ['draft:version-banner:r0'])
})

test('F10: a malformed user_lanes in the state blocks the resume', async () => {
  const first = (await runBoard({ overrides: PAUSED_STRATEGY })).result
  const { result, labels } = await runBoard({ args: { ...resumeWith(first, { 1: 'x' }), state: { ...first.state, user_lanes: { 'IN-1': 'archive' } } } })
  assert.equal(result.status, 'blocked')
  assert.match(result.error, /user_lanes/)
  assert.deepEqual(labels, [])
})

test('F12: a lane move past maxSpecs blocks with one shape, before any spec agent runs', async () => {
  const strategy = { ...strategyOf(), initiatives: [initiative('IN-1', { items: ['#1'], slug: 'version-banner' }), initiative('IN-2', { items: ['IDEA-1'], lane: 'mold', priority: 2 })] }
  const args = { stamp: STAMP, maxSpecs: 1 }
  const first = await runBoard({ args, strategy, overrides: PAUSED_STRATEGY })
  assert.equal(first.result.status, 'needs-input')
  const run = await runBoard({ args: { ...resumeWith(first.result, { 1: 'x' }, { lanes: { 'IN-2': 'spec' } }), maxSpecs: 1 }, strategy })
  assert.equal(run.result.status, 'blocked')
  assert.match(run.result.error, /2 spec initiatives; the limit is 1/)
  assert.deepEqual(run.result.errors, [run.result.error])
  assert.ok(!run.labels.some((l) => l.startsWith('draft:')))
})

test('F16: a collision suffix keeps the slug within 64 characters', async () => {
  const long = 'a'.repeat(70)
  const strategy = { ...strategyOf(), initiatives: [
    initiative('IN-1', { items: ['#1'], slug: 'a'.repeat(64), title: long }),
    initiative('IN-2', { items: ['IDEA-1'], lane: 'mold', title: long, priority: 2 }),
  ] }
  const first = await runBoard({ strategy, overrides: PAUSED_STRATEGY })
  const run = await runBoard({ args: resumeWith(first.result, { 1: 'x' }, { lanes: { 'IN-2': 'spec' } }), strategy })
  const slugs = dataOf(promptOf(run, 'resolve'), 'slugs')
  assert.equal(slugs.length, 2)
  for (const slug of slugs) assert.match(slug, /^[a-z0-9]+(-[a-z0-9]+)*$/)
  for (const slug of slugs) assert.ok(slug.length <= 64, `${slug.length} characters`)
  assert.equal(new Set(slugs).size, 2)
})

// The digest is a plain hash, so a hostile caller can edit a state and sign it again.
const signed = (state) => ({ state, digest: digestOf({ stamp: STAMP, checkpoint: state.checkpoint, state }) })
const ASKED = { 'draft:version-banner:r0': { ...DRAFT, open_questions: ['Which banner format?'] } }

test('F2: the checkpoint stores maxSpecs, and a resume keeps it without the argument', async () => {
  const strategy = { ...strategyOf(), initiatives: [initiative('IN-1', { items: ['#1'], slug: 'version-banner' }), initiative('IN-2', { items: ['IDEA-1'], lane: 'mold', priority: 2 })] }
  const first = await runBoard({ args: { stamp: STAMP, maxSpecs: 1 }, strategy, overrides: PAUSED_STRATEGY })
  assert.equal(first.result.state.max_specs, 1)
  const run = await runBoard({ args: resumeWith(first.result, { 1: 'x' }, { lanes: { 'IN-2': 'spec' } }), strategy })
  assert.equal(run.result.status, 'blocked')
  assert.match(run.result.error, /2 spec initiatives; the limit is 1/)
  assert.deepEqual(run.labels, [])
})

test('F2: a state without a positive integer max_specs blocks the resume', async () => {
  const first = (await runBoard({ overrides: PAUSED_STRATEGY })).result
  assert.equal(first.state.max_specs, 8)
  for (const bad of [undefined, 0, 1.5, '8']) {
    const { result, labels } = await runBoard({ args: { stamp: STAMP, answers: { 1: 'x' }, ...signed({ ...first.state, max_specs: bad }) } })
    assert.equal(result.status, 'blocked')
    assert.match(result.error, /args\.state\.max_specs must be a positive integer/)
    assert.deepEqual(labels, [])
  }
})

test('F8: a spec resume rejects a restored resolved path that fails checkResolve, before any agent', async () => {
  const first = (await runBoard({ overrides: ASKED })).result
  assert.equal(first.checkpoint, 'spec')
  const state = JSON.parse(JSON.stringify(first.state))
  state.resolved.specs[0].path = '/etc/passwd'
  const { result, labels } = await runBoard({ args: { stamp: STAMP, answers: { 1: 'Plain text.' }, ...signed(state) } })
  assert.equal(result.status, 'blocked')
  assert.match(result.error, /^resume rejected: .*path must be the absolute artifact-path result ending in \/specs\//)
  assert.deepEqual(result.errors.length, 1)
  assert.deepEqual(labels, [])
})

test('F8: a spec resume rejects an invalid restored initiative slug, before any agent', async () => {
  const first = (await runBoard({ overrides: ASKED })).result
  const state = JSON.parse(JSON.stringify(first.state))
  state.strategy.initiatives.find((i) => i.id === 'IN-1').slug = '../escape'
  const { result, labels } = await runBoard({ args: { stamp: STAMP, answers: { 1: 'Plain text.' }, ...signed(state) } })
  assert.equal(result.status, 'blocked')
  assert.match(result.error, /IN-1 has an invalid slug/)
  assert.deepEqual(labels, [])
})

test('F8: a done resume rejects a restored report path outside the report name', async () => {
  const first = (await runBoard({ overrides: { 'advise:done': REVISE } })).result
  assert.equal(first.checkpoint, 'done')
  const state = JSON.parse(JSON.stringify(first.state))
  state.resolved.report_path = '/tmp/evil.md'
  const { result, labels } = await runBoard({ args: { stamp: STAMP, answers: { [first.questions[0].id]: 'approve' }, ...signed(state) } })
  assert.equal(result.status, 'blocked')
  assert.match(result.error, /report_path must be the artifact-path result/)
  assert.deepEqual(labels, [])
})

test('F9 and F5: a checkpoint with no focus rejects a new focus, and a stored focus restores or rejects a different one', async () => {
  const plain = (await runBoard({ overrides: PAUSED_STRATEGY })).result
  assert.equal(plain.state.focus, null)
  const added = await runBoard({ args: resumeWith(plain, { 1: 'x' }, { focus: 'new scope' }) })
  assert.equal(added.result.status, 'blocked')
  assert.match(added.result.error, /args\.focus differs from args\.state\.focus/)
  assert.deepEqual(added.labels, [])

  const focused = (await runBoard({ args: { stamp: STAMP, focus: 'ship the banner' }, overrides: PAUSED_STRATEGY })).result
  assert.equal(focused.state.focus, 'ship the banner')
  const kept = await runBoard({ args: resumeWith(focused, { 1: 'Keep both initiatives.' }) })
  assert.equal(kept.result.status, 'ok')
  assert.match(promptOf(kept, 'synthesize:r1'), /ship the banner/)
  const same = await runBoard({ args: resumeWith(focused, { 1: 'Keep both initiatives.' }, { focus: 'ship the banner' }) })
  assert.equal(same.result.status, 'ok')
  const other = await runBoard({ args: resumeWith(focused, { 1: 'x' }, { focus: 'something else' }) })
  assert.equal(other.result.status, 'blocked')
  assert.match(other.result.error, /args\.focus differs from args\.state\.focus/)
})

test('F11: an auto run whose strategy advisor fails returns no questions, no state, and no digest', async () => {
  const { result } = await runBoard({ args: { stamp: STAMP, auto: true }, overrides: Object.fromEntries(['advise:strategy:0', 'advise:strategy:0:redo1', 'advise:strategy:0:redo2', 'advise:strategy:0:repair1', 'advise:strategy:0:repair2'].map((label) => [label, { bogus: true }])) })
  assert.equal(result.status, 'needs-input')
  assert.deepEqual(result.questions, [])
  assert.ok(!Object.hasOwn(result, 'state'))
  assert.ok(!Object.hasOwn(result, 'digest'))
  assert.equal(result.reason, 'advisor returned no valid advice')
})

test('F15: the research cap carries across a resume through research_used', async () => {
  const strategy = { ...strategyOf(), initiatives: [
    initiative('IN-1', { items: ['#1'], slug: 'version-banner', leverage_triggers: ['auth'], research_questions: ['d?'] }),
    initiative('IN-2', { items: ['IDEA-1'], slug: 'sync-cache', priority: 2, research_questions: ['a?', 'b?'] }),
    initiative('IN-3', { slug: 'third-spec', priority: 3, research_questions: ['c?', 'e?'] }),
  ] }
  const RESEARCH = { question: 'q', answer: 'Answer.', confidence: 'certain', confidence_justification: '', evidence_table: [], conflicts: [], open_questions: [], report_path: '', recommended_next_step: '', prototype: null }
  let calls = 0
  const research = () => { calls++; return RESEARCH }
  const first = await runBoard({ strategy, research, overrides: { 'draft:sync-cache:r0': { ...DRAFT, open_questions: ['Which cache?'] } } })
  assert.equal(first.result.checkpoint, 'spec')
  assert.equal(first.result.state.research_used, 4)
  assert.equal(calls, 4)
  const ids = Object.fromEntries(first.result.questions.map((q) => [q.initiative, q.id]))
  calls = 0
  const run = await runBoard({ args: resumeWith(first.result, { [ids['IN-1']]: 'spec anyway', [ids['IN-2']]: 'In memory.' }), strategy, research })
  assert.equal(calls, 0)
  assert.deepEqual(run.labels.filter((l) => l.startsWith('draft:')), ['draft:sync-cache:r0'])
  const molded = run.result.mold.find((m) => m.initiative === 'IN-1')
  assert.match(molded.reason, /research cap of 4 reached; unresearched: d\?/)
})

const TWO_CONCERNS = { verdict: 'revise', concerns: ['Order the mold list.', 'Cite the right line.'], guidance: 'two fixes', blocking_questions: [] }
const BAD_FIX = Object.fromEntries(['write:report:fix', 'write:report:fix:redo1', 'write:report:fix:redo2', 'write:report:fix:redo3'].map((label) => [label, { path: 'wrong.md', chars: 1 }]))

test('F5: a done checkpoint with two questions blocks until every one has an answer', async () => {
  const first = (await runBoard({ overrides: { 'advise:done': TWO_CONCERNS } })).result
  assert.deepEqual(first.questions.map((q) => q.id), ['D-1', 'D-2'])
  const { result, labels } = await runBoard({ args: resumeWith(first, { 'D-1': 'approve' }) })
  assert.equal(result.status, 'blocked')
  assert.match(result.error, /the done checkpoint needs an answer to D-2/)
  assert.deepEqual(labels, [])
})

test('F4: a failed report fix adds a gap and sends no fixes_applied to the done advisor', async () => {
  const first = (await runBoard({ overrides: { 'advise:done': REVISE } })).result
  const run = await runBoard({ args: resumeWith(first, { 'D-1': 'Add a rollout note.' }), overrides: { ...BAD_FIX, 'advise:done:r1': REVISE } })
  assert.ok(run.labels.includes('write:report:fix'))
  assert.ok(!Object.hasOwn(dataOf(promptOf(run, 'advise:done:r1'), 'payload'), 'fixes_applied'))
  assert.ok(run.result.gaps.some((g) => /report fix failed/.test(g)))
  assert.deepEqual(run.result.state.fixes_applied, [])
})

test('F4: a second fix round rebuilds the report with the earlier fixes', async () => {
  const first = (await runBoard({ overrides: { 'advise:done': REVISE } })).result
  const one = await runBoard({ args: resumeWith(first, { 'D-1': 'Add a rollout note.' }), overrides: { 'advise:done:r1': REVISE } })
  assert.deepEqual(dataOf(promptOf(one, 'advise:done:r1'), 'payload').fixes_applied.map((f) => f.answer), ['Add a rollout note.'])
  assert.deepEqual(one.result.state.fixes_applied.map((f) => f.answer), ['Add a rollout note.'])
  const two = await runBoard({ args: resumeWith(one.result, { 'D-1': 'Fix the citation.' }), overrides: { 'advise:done:r1': REVISE } })
  assert.deepEqual(dataOf(promptOf(two, 'write:report:fix'), 'fixes').map((f) => f.answer), ['Add a rollout note.', 'Fix the citation.'])
  assert.deepEqual(two.result.state.fixes_applied.map((f) => f.answer), ['Add a rollout note.', 'Fix the citation.'])
})

test('F4: a later fix that succeeds drops the failed-fix gap from the done advisor payload', async () => {
  const first = (await runBoard({ overrides: { 'advise:done': REVISE } })).result
  const failed = await runBoard({ args: resumeWith(first, { 'D-1': 'Add a rollout note.' }), overrides: { ...BAD_FIX, 'advise:done:r1': REVISE } })
  assert.ok(failed.result.gaps.some((g) => /report fix failed/.test(g)))
  const run = await runBoard({ args: resumeWith(failed.result, { 'D-1': 'Fix the citation.' }), overrides: { 'advise:done:r1': REVISE } })
  assert.ok(!dataOf(promptOf(run, 'advise:done:r1'), 'payload').gaps.some((g) => /report fix failed/.test(g)))
  assert.ok(!run.result.gaps.some((g) => /report fix failed/.test(g)))
})

test('F4: a failed fix stays pending and rides the next fix round, and the gap clears only then', async () => {
  const first = (await runBoard({ overrides: { 'advise:done': REVISE } })).result
  const failed = await runBoard({ args: resumeWith(first, { 'D-1': 'Add a rollout note.' }), overrides: { ...BAD_FIX, 'advise:done:r1': REVISE } })
  assert.deepEqual(failed.result.state.fixes_pending.map((f) => f.answer), ['Add a rollout note.'])
  assert.deepEqual(failed.result.state.fixes_applied, [])
  assert.ok(failed.result.gaps.some((g) => /report fix failed/.test(g)))
  const again = await runBoard({ args: resumeWith(failed.result, { 'D-1': 'Fix the citation.' }), overrides: { ...BAD_FIX, 'advise:done:r1': REVISE } })
  assert.deepEqual(again.result.state.fixes_pending.map((f) => f.answer), ['Add a rollout note.', 'Fix the citation.'])
  assert.ok(again.result.gaps.some((g) => /report fix failed/.test(g)))
  const run = await runBoard({ args: resumeWith(failed.result, { 'D-1': 'Fix the citation.' }), overrides: { 'advise:done:r1': REVISE } })
  assert.deepEqual(dataOf(promptOf(run, 'write:report:fix'), 'fixes').map((f) => f.answer), ['Add a rollout note.', 'Fix the citation.'])
  assert.deepEqual(run.result.state.fixes_applied.map((f) => f.answer), ['Add a rollout note.', 'Fix the citation.'])
  assert.deepEqual(run.result.state.fixes_pending, [])
  assert.ok(!run.result.gaps.some((g) => /report fix failed/.test(g)))
  const bad = await runBoard({ args: { ...resumeWith(failed.result, { 'D-1': 'x' }), state: { ...failed.result.state, fixes_pending: 'no' } } })
  assert.equal(bad.result.status, 'blocked')
  assert.match(JSON.stringify(bad.result), /fixes_pending must be an array/)
})

const TWO_CONCERN_STRATEGY = { 'advise:strategy:0': TWO_CONCERNS, 'advise:strategy:1': TWO_CONCERNS }

test('R1: a strategy checkpoint with two concerns blocks until every one has an answer', async () => {
  const first = (await runBoard({ overrides: TWO_CONCERN_STRATEGY })).result
  assert.equal(first.checkpoint, 'strategy')
  assert.deepEqual(first.questions.map((q) => q.id), ['S-1', 'S-2'])
  const { result, labels } = await runBoard({ args: resumeWith(first, { 1: 'approve' }) })
  assert.equal(result.status, 'blocked')
  assert.match(result.error, /the strategy checkpoint needs an answer to S-2/)
  assert.deepEqual(labels, [])
})

test('R1: a lanes-only resume with an open concern stays blocked and names the question', async () => {
  const first = (await runBoard({ overrides: PAUSED_STRATEGY })).result
  const { result, labels } = await runBoard({ args: { stamp: STAMP, state: first.state, digest: first.digest, lanes: { 'IN-1': 'mold' } } })
  assert.equal(result.status, 'blocked')
  assert.match((result.errors ?? [result.error]).join('; '), /the strategy checkpoint needs an answer to S-1/)
  assert.deepEqual(labels, [])
})

test('S3: answering approve on the no-valid-advice row settles the strategy without another advisor call', async () => {
  const bogus = Object.fromEntries(['advise:strategy:0', 'advise:strategy:0:redo1', 'advise:strategy:0:redo2', 'advise:strategy:0:repair1', 'advise:strategy:0:repair2'].map((label) => [label, { bogus: true }]))
  const first = (await runBoard({ overrides: bogus })).result
  assert.equal(first.status, 'needs-input')
  assert.equal(first.reason, 'advisor returned no valid advice')
  const run = await runBoard({ args: resumeWith(first, { 1: 'approve' }) })
  assert.equal(run.result.status, 'ok')
  assert.ok(!run.labels.some((l) => l.startsWith('advise:strategy')))
})

test('S3: an approved strategy with only override questions settles once they are answered', async () => {
  const strategy = strategyOf({ overrides: ['D-1'] })
  const first = (await runBoard({ strategy })).result
  assert.equal(first.checkpoint, 'strategy')
  assert.equal(first.state.approved, true)
  assert.ok(first.questions.every((q) => q.kind === 'override'))
  const run = await runBoard({ args: resumeWith(first, { [first.questions[0].id]: 'mold' }), strategy })
  assert.equal(run.result.status, 'ok')
  assert.ok(!run.labels.some((l) => l.startsWith('advise:strategy')))
})

test('R2: a resume plans with the stored maxSpecs and rejects a different maxSpecs argument', async () => {
  const strategy = { ...strategyOf(), initiatives: [initiative('IN-1', { items: ['#1'], slug: 'version-banner' }), initiative('IN-2', { items: ['IDEA-1'], lane: 'mold', priority: 2 })] }
  const first = (await runBoard({ args: { stamp: STAMP, maxSpecs: 1 }, strategy, overrides: PAUSED_STRATEGY })).result
  const run = await runBoard({ args: resumeWith(first, { 1: 'x' }), strategy })
  assert.match(promptOf(run, 'synthesize:r1'), /at most 1 spec initiatives/)
  const other = await runBoard({ args: resumeWith(first, { 1: 'x' }, { maxSpecs: 2 }), strategy })
  assert.equal(other.result.status, 'blocked')
  assert.match(other.result.error, /args\.maxSpecs differs from args\.state\.max_specs/)
  assert.deepEqual(other.labels, [])
})

test('R4: a state whose override question names a missing initiative blocks without a throw', async () => {
  const first = (await runBoard({ overrides: PAUSED_STRATEGY })).result
  const state = JSON.parse(JSON.stringify(first.state))
  state.questions.push({ id: 'S-9', initiative: 'IN-99', kind: 'override', question: 'Keep it?', options: ['spec', 'mold'], recommended: 'mold', evidence: '', closed: true })
  const { result, labels } = await runBoard({ args: { stamp: STAMP, answers: { 1: 'x', 'S-9': 'spec' }, ...signed(state) } })
  assert.equal(result.status, 'blocked')
  assert.match(result.error, /names no strategy initiative: S-9/)
  assert.deepEqual(labels, [])
})

test('F14: the wiki record names the user when the user approves and the advisor otherwise', async () => {
  const first = (await runBoard({ overrides: { 'advise:done': REVISE } })).result
  const byUser = await runBoard({ args: resumeWith(first, { 'D-1': 'approve' }) })
  assert.match(promptOf(byUser, 'record:strategy'), /The user approved this strategy at the done checkpoint/)
  assert.doesNotMatch(promptOf(byUser, 'record:strategy'), /done advisor approved/)
  const byAdvisor = await runBoard()
  assert.match(promptOf(byAdvisor, 'record:strategy'), /The cheese-board done advisor approved this strategy/)
  assert.doesNotMatch(promptOf(byAdvisor, 'record:strategy'), /The user approved/)
})
