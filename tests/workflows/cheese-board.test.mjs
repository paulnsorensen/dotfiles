import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow } from './harness.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/cheese-board.js')
const STAMP = '2026-10-14'
const SPECS_DIR = '/data/cheese/repo/specs'
const REPORT = `/data/cheese/repo/notes/cheese-board-${STAMP}.md`

const issue = (number, title) => ({ number, kind: 'issue', title })
const ground = (number, title, verdict) => ({
  item: issue(number, title),
  ground: { number, kind: 'issue', title, verdict, evidence: [{ claim: 'checked', citation: `src/a.js:${number}` }], summary: `summary ${number}`, recommendation: 'fix now' },
  verify: null,
})

// Issue 1 is fixable, 2 is a certain close, 3 needs a human, and 4 needs design.
const TRIAGE = {
  items: [issue(1, 'Banner missing'), issue(2, 'Old crash'), issue(3, 'Unclear report'), issue(4, 'Auth redesign'), issue(5, 'Never grounded')],
  grounded: [
    ground(1, 'Banner missing', 'valid'),
    { ...ground(2, 'Old crash', 'superseded'), verify: { number: 2, refuted: false, final_verdict: 'superseded', note: 'ok' }, verifyFailed: false },
    ground(3, 'Unclear report', 'needs-info'),
    ground(4, 'Auth redesign', 'valid'),
  ],
  lenses: [],
  routing: {
    routed: [
      { number: 1, kind: 'issue', title: 'Banner missing', route: 'fix-now', rank: 1, why: '/cook' },
      { number: 2, kind: 'issue', title: 'Old crash', route: 'close', rank: 1, why: 'fixed', close_reason: 'completed', confidence: 'certain', comment: 'fixed in abc123' },
      { number: 3, kind: 'issue', title: 'Unclear report', route: 'needs-human', rank: 1, why: 'no repro' },
      { number: 4, kind: 'issue', title: 'Auth redesign', route: 'needs-design', rank: 1, why: '/mold' },
    ],
    domains: [],
    links: [],
    summary: 'done',
  },
}

const IDEAS = { ideas: [
  { title: 'Version banner everywhere', summary: 'same as #1', source: 'args', existing_spec: '', duplicate_of: '#1' },
  { title: 'Faster sync', summary: 'cache the render step', source: 'wiki/roadmap.md', existing_spec: '', duplicate_of: '' },
  { title: 'Old plan', summary: 'already specced', source: `${SPECS_DIR}/old-plan.md`, existing_spec: `${SPECS_DIR}/old-plan.md`, duplicate_of: '' },
] }

const initiative = (id, overrides = {}) => ({
  id, theme: 'TH-1', title: `title ${id}`, outcome: `outcome ${id}`, items: [], depends_on: [], lane: 'spec', slug: '',
  priority: 1, leverage_triggers: [], open_questions: [], rationale: `why ${id}`, ...overrides,
})

// Strategy items are #1, #4, and IDEA-2. IDEA-1 merges into #1; IDEA-3 is already specced.
const STRATEGY = {
  themes: [{ id: 'TH-1', name: 'Polish', thesis: 'Make the tool feel finished.' }, { id: 'TH-2', name: 'Unused', thesis: 'Nothing uses this.' }],
  initiatives: [
    initiative('IN-1', { items: ['#1'], slug: 'version-banner' }),
    initiative('IN-2', { items: ['IDEA-2'], slug: 'sync-cache', depends_on: ['IN-1'], priority: 2 }),
    initiative('IN-3', { items: ['#4'], lane: 'mold', leverage_triggers: ['auth'] }),
  ],
  parked: [],
  summary: 'Polish first, then speed.',
}

const DRAFT = {
  intent: 'Print a version banner.', confidence: 'high', blast_radius: 'low', inputs: 'issue #1', outputs: 'a banner',
  verification: 'bin/demo --version exits 0', contract: 'The demo command prints a banner.', goals: ['Print the banner from bin/demo.'],
  grounding: [{ probe: 'wiki', outcome: 'miss', evidence: 'no page | none' }, { probe: 'explorer', outcome: 'hit', evidence: 'bin/demo:1' }],
  criteria: ['`bin/demo --version` exits 0.', 'The banner | starts with demo.'], non_goals: ['No other command changes.'],
  leverage_triggers: [], open_questions: [],
}

const specText = (prompt) => JSON.parse(/<data name="spec_text">\n([\s\S]*?)\n<\/data>/.exec(prompt)[1])
const chars = (text) => [...text].length
const installed = (slug, prompt, overrides = {}) => ({
  path: `${SPECS_DIR}/${slug}.md`, target_existed: false, chars: chars(specText(prompt)), validate_exit: 0, validate_output: '{"valid": true}',
  candidate_curds: 1, installed: true, ...overrides,
})

function responder(overrides = {}) {
  return ({ prompt, opts }) => {
    const label = opts.label
    if (Object.hasOwn(overrides, label)) {
      const value = overrides[label]
      return typeof value === 'function' ? value({ prompt, opts }) : value
    }
    if (label === 'ideas') return IDEAS
    if (label.startsWith('strategist:') || label.startsWith('synthesize:')) return STRATEGY
    if (label.startsWith('advise:')) return { verdict: 'approve', concerns: [], guidance: 'ok' }
    if (label === 'resolve') {
      const slugs = JSON.parse(/<data name="slugs">\n([\s\S]*?)\n<\/data>/.exec(prompt)[1])
      return { specs: slugs.map((slug) => ({ slug, path: `${SPECS_DIR}/${slug}.md`, exists: false })), report_path: REPORT }
    }
    if (label.startsWith('draft:')) return DRAFT
    if (label.startsWith('taste:')) return { verdict: 'pass', concerns: [] }
    if (label.startsWith('install:')) return installed(label.split(':')[1], prompt)
    if (label === 'verify:specs') {
      const paths = JSON.parse(/<data name="paths">\n([\s\S]*?)\n<\/data>/.exec(prompt)[1])
      return { results: paths.map((p) => ({ path: p, valid: true, candidate_curds: 1, note: '' })) }
    }
    if (label === 'write:report') {
      const report = JSON.parse(/<data name="report">\n([\s\S]*?)\n<\/data>/.exec(prompt)[1])
      return { path: REPORT, chars: chars(report) }
    }
    throw new Error(`unexpected agent ${label}`)
  }
}

async function runBoard({ args = STAMP, overrides = {}, triage = TRIAGE } = {}) {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: responder(overrides) })
  const children = []
  const result = await workflow.run({
    ...globals,
    args,
    workflow: async (name, childArgs) => {
      children.push({ name, childArgs })
      if (triage instanceof Error) throw triage
      return triage
    },
  })
  // Values built inside the vm realm fail deepStrictEqual on prototype identity, so copy them into this realm.
  return { result: JSON.parse(JSON.stringify(result)), trace, children: JSON.parse(JSON.stringify(children)), labels: trace.agents.map(({ opts }) => opts.label) }
}

test('cheese-board blocks before any agent when the stamp is missing or malformed', async () => {
  for (const args of [null, 'yesterday', { repo: 'a/b' }, { stamp: STAMP, repo: 'bad repo' }]) {
    const { result, labels, children } = await runBoard({ args })
    assert.equal(result.status, 'blocked')
    assert.deepEqual(labels, [])
    assert.deepEqual(children, [])
  }
})

test('cheese-board turns triage and ideas into a strategy, one verified spec wave, and side lists', async () => {
  const { result, labels, children, trace } = await runBoard({ args: { stamp: STAMP, repo: 'owner/name', limit: 12 } })

  assert.deepEqual(children, [{ name: 'triage-sweep', childArgs: { scope: 'issues', limit: 12, repo: 'owner/name' } }])
  assert.equal(result.status, 'ok')
  assert.equal(result.report_path, REPORT)
  // IN-2 depends on IN-1, so the queue has two waves.
  assert.deepEqual(result.factory_queue.map((wave) => wave.map((q) => q.slug)), [['version-banner'], ['sync-cache']])
  assert.equal(result.factory_queue[0][0].command, `/cheese-factory ${SPECS_DIR}/version-banner.md`)
  assert.deepEqual(result.blocked, [])
  assert.deepEqual(result.mold.map((m) => m.initiative), ['IN-3'])
  assert.deepEqual(result.close_batch.map((c) => c.id), ['#2'])
  assert.deepEqual(result.needs_human.map((h) => h.id), ['#3'])
  assert.deepEqual(result.ungrounded.map((u) => u.id), ['#5'])
  assert.deepEqual(result.already_specced.map((a) => a.path), [`${SPECS_DIR}/old-plan.md`])
  // The unused theme is dropped in code.
  assert.deepEqual(result.strategy.themes.map((t) => t.id), ['TH-1'])

  // Strategists see only live items: no close, no human, no merged or already-specced idea.
  const strategist = trace.agents.find(({ opts }) => opts.label === 'strategist:leverage')
  const context = JSON.parse(/<data name="context">\n([\s\S]*?)\n<\/data>/.exec(strategist.prompt)[1])
  assert.deepEqual(context.items.map((i) => i.id), ['#1', '#4', 'IDEA-2'])
  assert.deepEqual(context.items[0].merged_ideas, ['same as #1'])

  assert.deepEqual(labels, [
    'ideas', 'strategist:leverage', 'strategist:risk', 'strategist:architecture', 'synthesize:r0', 'advise:strategy:0', 'resolve',
    'draft:version-banner:r0', 'draft:sync-cache:r0', 'taste:version-banner:r0', 'taste:sync-cache:r0',
    'install:version-banner:r0', 'install:sync-cache:r0', 'verify:specs', 'write:report', 'advise:done',
  ])

  // The two highest-leverage judgments run on Opus; the strategists keep their agent-type default.
  const modelOf = (label) => trace.agents.find(({ opts }) => opts.label === label).opts.model
  assert.equal(modelOf('synthesize:r0'), 'opus')
  assert.equal(modelOf('draft:version-banner:r0'), 'opus')
  assert.equal(modelOf('strategist:risk'), undefined)
})

test('cheese-board renders a mini-spec with numbered AC lines, goals, sources, and pipe-free table cells', async () => {
  const { trace } = await runBoard()
  const install = trace.agents.find(({ opts }) => opts.label === 'install:version-banner:r0')
  const text = specText(install.prompt)

  assert.match(text, /^---\nslug: version-banner\nstatus: draft\nsource: agent-mini-spec\ncreated: 2026-10-14\n/)
  assert.match(text, /^intent: Print a version banner\.$/m)
  assert.match(text, /^inputs: "issue #1"$/m)
  assert.match(text, /^## Goals\n- Print the banner from bin\/demo\.$/m)
  assert.match(text, /^- AC-1: `bin\/demo --version` exits 0\.\n- AC-2: The banner \| starts with demo\.$/m)
  assert.match(text, /^\| wiki \| miss \| no page \/ none \|$/m)
  assert.match(text, /^\| explorer \| hit \| bin\/demo:1 \|$/m)
  assert.match(text, /^- Strategy: IN-1 title IN-1 \(TH-1 Polish\), cheese-board 2026-10-14$/m)
  assert.match(text, /^- #1: Banner missing$/m)
})

test('cheese-board redoes a synthesis that leaves an item unplaced', async () => {
  const unplaced = { ...STRATEGY, initiatives: STRATEGY.initiatives.filter((i) => i.id !== 'IN-2') }
  const { result, labels, trace } = await runBoard({ overrides: { 'synthesize:r0': unplaced } })

  assert.equal(result.status, 'ok')
  const redo = trace.agents.find(({ opts }) => opts.label === 'synthesize:r0:redo1')
  assert.ok(redo, labels.join(', '))
  assert.match(redo.prompt, /IDEA-2 is not placed/)
})

test('cheese-board repairs a bare issue number as a form error', async () => {
  const bare = { ...STRATEGY, initiatives: STRATEGY.initiatives.map((i) => (i.id === 'IN-1' ? { ...i, items: ['1'] } : i)) }
  const { labels } = await runBoard({ overrides: { 'synthesize:r0': bare } })

  assert.ok(labels.includes('synthesize:r0:repair1'), labels.join(', '))
  assert.equal(labels.includes('synthesize:r0:redo1'), false)
})

test('cheese-board blocks a dependent spec when its prerequisite goes to mold', async () => {
  const { result, labels } = await runBoard({ overrides: { 'draft:version-banner:r0': { ...DRAFT, open_questions: ['Which banner format?'] } } })

  assert.equal(labels.includes('install:version-banner:r0'), false)
  assert.deepEqual(result.factory_queue, [])
  assert.deepEqual(result.blocked.map((b) => [b.slug, b.blocked_by]), [['sync-cache', ['IN-1 moved to /mold']]])
  assert.deepEqual(result.mold.map((m) => m.initiative).sort(), ['IN-1', 'IN-3'])
  assert.deepEqual(result.mold.find((m) => m.initiative === 'IN-1').open_questions, ['Which banner format?'])
})

test('cheese-board redrafts once after a failed gate, then routes the spec to mold', async () => {
  const failGate = ({ prompt }) => installed('version-banner', prompt, { validate_exit: 1, validate_output: 'missing Contract', installed: false })
  const { result, labels, trace } = await runBoard({ overrides: { 'install:version-banner:r0': failGate, 'install:version-banner:r1': failGate } })

  assert.ok(labels.includes('draft:version-banner:r1'))
  const redraft = trace.agents.find(({ opts }) => opts.label === 'draft:version-banner:r1')
  assert.match(redraft.prompt, /validate-spec exit 1: missing Contract/)
  assert.equal(labels.includes('draft:version-banner:r2'), false)
  assert.match(result.mold.find((m) => m.initiative === 'IN-1').reason, /2 rounds/)
  assert.equal(result.status, 'ok')
})

test('cheese-board rejects an install report that claims success for a failed gate', async () => {
  const lying = ({ prompt }) => installed('version-banner', prompt, { validate_exit: 1, installed: true })
  const overrides = Object.fromEntries(['', ':redo1', ':redo2'].map((s) => [`install:version-banner:r0${s}`, lying]))
  const { result, labels } = await runBoard({ overrides })

  assert.ok(labels.includes('install:version-banner:r0:redo2'))
  assert.equal(labels.includes('install:version-banner:r0:redo3'), false)
  assert.equal(result.spec_failures.find((f) => f.slug === 'version-banner').status, 'failed')
  assert.equal(result.status, 'partial')
})

test('cheese-board keeps an existing spec and never overwrites it', async () => {
  const resolveExisting = ({ prompt }) => {
    const slugs = JSON.parse(/<data name="slugs">\n([\s\S]*?)\n<\/data>/.exec(prompt)[1])
    return { specs: slugs.map((slug) => ({ slug, path: `${SPECS_DIR}/${slug}.md`, exists: slug === 'version-banner' })), report_path: REPORT }
  }
  const { result, labels } = await runBoard({ overrides: { resolve: resolveExisting } })

  assert.equal(labels.includes('draft:version-banner:r0'), false)
  assert.deepEqual(result.blocked.map((b) => b.blocked_by), [['IN-1 has a spec from an earlier run; confirm it covers the outcome']])
})

test('cheese-board sends close verdicts to needs-human when triage routing is missing', async () => {
  const { result } = await runBoard({ triage: { ...TRIAGE, routing: null } })

  assert.deepEqual(result.close_batch, [])
  assert.deepEqual(result.needs_human.map((h) => h.id), ['#2', '#3'])
})

test('cheese-board stops at the advisor and never drafts a spec', async () => {
  const { result, labels } = await runBoard({ overrides: { 'advise:strategy:0': { verdict: 'stop', concerns: ['wrong goal'], guidance: 'stop' } } })

  assert.equal(result.status, 'stopped')
  assert.equal(labels.some((l) => l.startsWith('draft:') || l === 'resolve'), false)
})

test('cheese-board reports a partial run when the triage child fails', async () => {
  const strategy = { ...STRATEGY, initiatives: [initiative('IN-1', { items: ['IDEA-1', 'IDEA-2'], slug: 'sync-cache' })] }
  const { result } = await runBoard({ triage: new Error('child failed'), overrides: { 'strategist:leverage': strategy, 'strategist:risk': strategy, 'strategist:architecture': strategy, 'synthesize:r0': strategy } })

  assert.equal(result.status, 'partial')
  assert.deepEqual(result.gaps, ['triage-sweep failed; no issue was triaged'])
  assert.deepEqual(result.factory_queue.map((wave) => wave.map((q) => q.slug)), [['sync-cache']])
})
