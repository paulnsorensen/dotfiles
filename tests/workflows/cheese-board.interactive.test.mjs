import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow } from './harness.mjs'

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
const APPROVE = { verdict: 'approve', concerns: [], guidance: 'ok' }
const REVISE = { verdict: 'revise', concerns: ['Split the work differently.'], guidance: 'rethink' }

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

async function runBoard({ args = { stamp: STAMP }, overrides = {}, strategy = strategyOf() } = {}) {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: responder(overrides, strategy), budgetTotal: null, budgetSpent: 0 })
  const result = await workflow.run({
    ...globals,
    args,
    workflow: async (name) => {
      if (name === 'brie-ground') throw new Error('unexpected research')
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
  assert.equal(result.questions[0].id, 'S-1')
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
  ]
  for (const args of cases) {
    const { result, labels } = await runBoard({ args })
    assert.equal(result.status, 'blocked')
    assert.deepEqual(labels, [])
  }
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
})

test('AC-5: an override asks, and the answer spec keeps the lane and records the decision in the spec', async () => {
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
  const install = second.prompts[second.labels.indexOf('install:version-banner:r0')]
  assert.match(specText(install), /## Decision overrides/)
  const report = second.prompts[second.labels.indexOf('write:report')]
  assert.match(report, /kept in the spec lane by the user/)
})

test('AC-5: the answer mold routes the overriding initiative to mold', async () => {
  const strategy = strategyOf({ overrides: ['D-1'] })
  const first = await runBoard({ strategy })
  const second = await runBoard({ args: resumeWith(first.result, { 1: 'mold' }), strategy })
  assert.equal(second.result.status, 'ok')
  assert.equal(second.result.strategy.initiatives.find((i) => i.id === 'IN-1').lane, 'mold')
  assert.ok(!second.labels.includes('draft:version-banner:r0'))
})

test('AC-6: a leverage trigger asks mold or spec anyway, with mold recommended', async () => {
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
