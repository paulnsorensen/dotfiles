import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow } from './harness.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/cheese-board.js')
const STAMP = '2026-10-14'
const SPECS_DIR = '/data/cheese/repo/specs'
// mold artifact-path notes prints a checkout-relative path.
const REPORT = `.cheese/notes/cheese-board-${STAMP}.md`

const issue = (number, title) => ({ number, kind: 'issue', title })
const ground = (number, title, verdict) => ({
  item: issue(number, title),
  ground: { number, kind: 'issue', title, verdict, evidence: [{ claim: 'checked', citation: `src/a.js:${number}` }], summary: `summary ${number}`, recommendation: 'fix now' },
  verify: null,
})

// Issue 1 is fixable, 2 is a certain close, 3 needs a human, and 4 needs design.
const TRIAGE = {
  items: [issue(1, 'Banner missing'), issue(2, 'Old crash'), issue(3, 'Unclear report'), issue(4, 'Auth redesign')],
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
  priority: 1, leverage_triggers: [], open_questions: [], overrides: [], research_questions: [], rationale: `why ${id}`, ...overrides,
})

// D-1 constrains #1; D-2 is repo-wide.
const GROUNDING = {
  decisions: [
    { statement: 'Specs live in the durable corpus.', kind: 'adr', citation: 'adr/specs.md:3', items: ['#1'] },
    { statement: 'Every shell change needs Bats coverage.', kind: 'locked', citation: 'conventions.md:9', items: [] },
  ],
  prior_research: [],
}

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
    if (label.startsWith('advise:')) return { verdict: 'approve', concerns: [], guidance: 'ok', blocking_questions: [] }
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
    if (label === 'ground') return GROUNDING
    if (label === 'record:strategy') return { corpus: 'repo:dotfiles:wiki', path: `strategy/cheese-board-${STAMP}.md` }
    throw new Error(`unexpected agent ${label}`)
  }
}

const RESEARCH = {
  question: 'q', answer: 'Upstream prints the version on stdout.', confidence: 'certain', confidence_justification: '',
  evidence_table: [{ claim: 'prints on stdout', confidence: 'certain', citation: 'https://example.com/docs' }],
  conflicts: [], open_questions: [], report_path: '/data/cheese/repo/research/banner.md', recommended_next_step: '', prototype: null,
}

async function runBoard({ args = { stamp: STAMP, auto: true }, overrides = {}, triage = TRIAGE, research = () => RESEARCH, budgetTotal = null, budgetSpent = 0 } = {}) {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: responder(overrides), budgetTotal, budgetSpent })
  const children = []
  const result = await workflow.run({
    ...globals,
    args,
    workflow: async (name, childArgs) => {
      children.push({ name, childArgs })
      if (name === 'brie-ground') return research(childArgs)
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

test('cheese-board blocks with the exact call shape when no stamp is given, and keeps a bare focus', async () => {
  for (const args of [null, {}]) {
    const { result, labels } = await runBoard({ args })
    assert.equal(result.status, 'blocked')
    assert.match(result.error, /call shape: \/cheese-board YYYY-MM-DD/)
    assert.match(result.error, /focus\?/)
    assert.deepEqual(labels, [])
  }
  const { result, labels } = await runBoard({ args: 'bugs related to routines' })
  assert.equal(result.status, 'blocked')
  assert.equal(result.focus, 'bugs related to routines')
  assert.deepEqual(labels, [])
})

test('cheese-board reads a date string as the stamp and passes no focus', async () => {
  const { result, trace } = await runBoard({ args: STAMP })
  assert.equal(result.status, 'ok')
  assert.equal(result.report_path, REPORT)
  assert.ok(trace.agents.every((a) => !a.prompt.includes('<data name="focus">')))
})

test('cheese-board passes an object focus to the idea explorer and every strategist', async () => {
  const focus = 'bugs related to routines'
  const { result, trace } = await runBoard({ args: { stamp: STAMP, focus } })
  assert.equal(result.status, 'ok')
  assert.equal(result.report_path, REPORT)
  const withFocus = (label) => trace.agents.filter((a) => a.opts.label === label || a.opts.label.startsWith(label)).map((a) => a.prompt)
  const prompts = [...withFocus('ideas'), ...withFocus('strategist:'), ...withFocus('synthesize')]
  assert.ok(prompts.length >= 5, `expected ideas, 3 strategists and a synthesis, got ${prompts.length}`)
  for (const p of prompts) {
    assert.ok(p.includes(`<data name="focus">\n"${focus}"\n</data>`))
  }
  assert.ok(withFocus('strategist:').every((p) => p.includes('Limit the strategy to this focus')))
})

test('cheese-board takes a JSON string with both stamp and focus', async () => {
  const { result, trace } = await runBoard({ args: JSON.stringify({ stamp: STAMP, focus: 'sync speed' }) })
  assert.equal(result.status, 'ok')
  assert.ok(trace.agents.find((a) => a.opts.label === 'ideas').prompt.includes('sync speed'))
})

test('cheese-board turns triage and ideas into a strategy, one verified spec wave, and side lists', async () => {
  const { result, labels, children, trace } = await runBoard({ args: { stamp: STAMP, auto: true, repo: 'owner/name', limit: 12 } })

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
  assert.deepEqual(result.ungrounded, [])
  assert.deepEqual(result.gaps, [])
  assert.deepEqual(result.already_specced.map((a) => a.path), [`${SPECS_DIR}/old-plan.md`])
  // The unused theme is dropped in code, and the result names it.
  assert.deepEqual(result.strategy.themes.map((t) => t.id), ['TH-1'])
  assert.deepEqual(result.dropped, [{ kind: 'theme', ref: 'TH-2', reason: 'no initiative uses it' }])

  // Strategists see only live items: no close, no human, no merged or already-specced idea.
  const strategist = trace.agents.find(({ opts }) => opts.label === 'strategist:leverage')
  const context = JSON.parse(/<data name="context">\n([\s\S]*?)\n<\/data>/.exec(strategist.prompt)[1])
  assert.deepEqual(context.items.map((i) => i.id), ['#1', '#4', 'IDEA-2'])
  assert.deepEqual(context.items[0].merged_ideas, ['same as #1'])
  // Code assigns decision ids and normalizes item refs before the strategists see them.
  assert.deepEqual(context.decisions.map((d) => [d.id, d.items]), [['D-1', ['#1']], ['D-2', []]])
  assert.deepEqual(result.coverage.decisions, 2)

  // Each drafter sees the decisions that touch its items plus the repo-wide ones.
  const decisionsIn = (label) => JSON.parse(/<data name="decisions">\n([\s\S]*?)\n<\/data>/.exec(trace.agents.find(({ opts }) => opts.label === label).prompt)[1]).map((d) => d.id)
  assert.deepEqual(decisionsIn('draft:version-banner:r0'), ['D-1', 'D-2'])
  assert.deepEqual(decisionsIn('draft:sync-cache:r0'), ['D-2'])

  // The approved strategy lands in the repo wiki.
  assert.deepEqual(result.recorded, { corpus: 'repo:dotfiles:wiki', path: `strategy/cheese-board-${STAMP}.md` })
  const record = trace.agents.find(({ opts }) => opts.label === 'record:strategy')
  assert.match(record.prompt, /# cheese-board strategy 2026-10-14/)
  assert.match(record.prompt, /D-1 \(adr\): Specs live in the durable corpus\. \(adr\/specs\.md:3\)/)

  assert.deepEqual(labels, [
    'ideas', 'ground', 'strategist:leverage', 'strategist:risk', 'strategist:architecture', 'synthesize:r0', 'advise:strategy:0', 'resolve',
    'draft:version-banner:r0', 'draft:sync-cache:r0', 'taste:version-banner:r0', 'taste:sync-cache:r0',
    'install:version-banner:r0', 'install:sync-cache:r0', 'verify:specs', 'write:report', 'advise:done', 'record:strategy',
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

test('cheese-board redrafts once after a failed gate, then reports a spec failure with the last gate error', async () => {
  const failGate = ({ prompt }) => installed('version-banner', prompt, { validate_exit: 1, validate_output: 'missing Contract', installed: false })
  const { result, labels, trace } = await runBoard({ overrides: { 'install:version-banner:r0': failGate, 'install:version-banner:r1': failGate } })

  assert.ok(labels.includes('draft:version-banner:r1'))
  const redraft = trace.agents.find(({ opts }) => opts.label === 'draft:version-banner:r1')
  assert.match(redraft.prompt, /validate-spec exit 1: missing Contract/)
  assert.equal(labels.includes('draft:version-banner:r2'), false)
  assert.equal(result.mold.some((m) => m.initiative === 'IN-1'), false)
  const failure = result.spec_failures.find((f) => f.slug === 'version-banner')
  assert.equal(failure.status, 'failed')
  assert.match(failure.reason, /2 rounds/)
  assert.match(failure.reason, /last gate error: validate-spec exit 1: missing Contract/)
  assert.deepEqual(result.blocked.map((b) => [b.slug, b.blocked_by]), [['sync-cache', ['IN-1 spec failed']]])
  assert.equal(result.status, 'partial')
})

test('cheese-board reports a draft that fails taste every round as a spec failure, not a mold item', async () => {
  const revise = (round) => ({ verdict: 'revise', concerns: [`criteria are vague r${round}`] })
  const { result, labels } = await runBoard({ overrides: { 'taste:version-banner:r0': revise(0), 'taste:version-banner:r1': revise(1) } })

  assert.equal(labels.includes('install:version-banner:r0'), false)
  assert.equal(labels.includes('install:version-banner:r1'), false)
  assert.equal(labels.includes('draft:version-banner:r2'), false)
  assert.equal(result.mold.some((m) => m.initiative === 'IN-1'), false)
  assert.deepEqual(result.mold.map((m) => m.initiative), ['IN-3'])
  const failure = result.spec_failures.find((f) => f.slug === 'version-banner')
  assert.equal(failure.status, 'failed')
  assert.match(failure.reason, /2 rounds/)
  assert.match(failure.reason, /last taste verdict: revise \(criteria are vague r1\)/)
  assert.equal(result.status, 'partial')
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
  const { result, labels } = await runBoard({ overrides: { 'advise:strategy:0': { verdict: 'stop', concerns: ['wrong goal'], guidance: 'stop', blocking_questions: [] } } })

  assert.equal(result.status, 'stopped')
  assert.equal(labels.some((l) => l.startsWith('draft:') || l === 'resolve'), false)
})

test('cheese-board reports a partial run when the triage child fails', async () => {
  const strategy = { ...STRATEGY, initiatives: [initiative('IN-1', { items: ['IDEA-1', 'IDEA-2'], slug: 'sync-cache' })] }
  // Without triage, #1 does not exist, so the grounding cites only repo-wide decisions.
  const ground = { decisions: [GROUNDING.decisions[1]], prior_research: [] }
  const { result } = await runBoard({ triage: new Error('child failed'), overrides: { ground, 'strategist:leverage': strategy, 'strategist:risk': strategy, 'strategist:architecture': strategy, 'synthesize:r0': strategy } })

  assert.equal(result.status, 'partial')
  assert.deepEqual(result.gaps, ['triage-sweep failed; no issue was triaged'])
  assert.deepEqual(result.factory_queue.map((wave) => wave.map((q) => q.slug)), [['sync-cache']])
})

test('cheese-board researches a spec initiative through brie-ground and records it in Provenance', async () => {
  const strategy = { ...STRATEGY, initiatives: STRATEGY.initiatives.map((i) => (i.id === 'IN-1' ? { ...i, research_questions: ['Does upstream print the version on stdout?'] } : i)) }
  const { result, children, trace } = await runBoard({ overrides: { 'synthesize:r0': strategy } })

  assert.deepEqual(children.filter((c) => c.name === 'brie-ground'), [{ name: 'brie-ground', childArgs: 'Does upstream print the version on stdout?' }])
  const draft = trace.agents.find(({ opts }) => opts.label === 'draft:version-banner:r0')
  assert.match(draft.prompt, /Treat the research answers below as settled facts/)
  assert.match(draft.prompt, /<data name="research">/)
  const text = specText(trace.agents.find(({ opts }) => opts.label === 'install:version-banner:r0').prompt)
  assert.match(text, /^## Provenance\n- briesearch: Upstream prints the version on stdout\. \(certain\); artifact: \/data\/cheese\/repo\/research\/banner\.md$/m)
  // A spec without research carries no Provenance section.
  assert.doesNotMatch(specText(trace.agents.find(({ opts }) => opts.label === 'install:sync-cache:r0').prompt), /## Provenance/)
  assert.deepEqual(result.research.map((r) => r.confidence), ['certain'])
  assert.equal(result.status, 'ok')
})

test('cheese-board routes a spec to mold when research cannot settle its question', async () => {
  const strategy = { ...STRATEGY, initiatives: STRATEGY.initiatives.map((i) => (i.id === 'IN-1' ? { ...i, research_questions: ['Unknowable?'] } : i)) }
  const { result, labels } = await runBoard({ overrides: { 'synthesize:r0': strategy }, research: () => ({ ...RESEARCH, confidence: 'dont_know', open_questions: ['Which version?'] }) })

  assert.equal(labels.includes('draft:version-banner:r0'), false)
  const mold = result.mold.find((m) => m.initiative === 'IN-1')
  assert.match(mold.reason, /research could not settle: Unknowable\?/)
  assert.deepEqual(mold.open_questions, ['Unknowable?', 'Which version?'])
})

test('cheese-board fails a spec whose research child throws, without drafting it', async () => {
  const strategy = { ...STRATEGY, initiatives: STRATEGY.initiatives.map((i) => (i.id === 'IN-1' ? { ...i, research_questions: ['Flaky?'] } : i)) }
  const { result, labels } = await runBoard({ overrides: { 'synthesize:r0': strategy }, research: () => { throw new Error('tavily down') } })

  assert.equal(labels.includes('draft:version-banner:r0'), false)
  assert.deepEqual(result.spec_failures.map((f) => [f.slug, f.status, f.reason]), [['version-banner', 'failed', 'research failed: Flaky?']])
  assert.equal(result.status, 'partial')
})

test('cheese-board caps research runs in priority order and moves the overflow to mold', async () => {
  const strategy = { ...STRATEGY, initiatives: [
    ...STRATEGY.initiatives.map((i) => (i.id === 'IN-3' ? i : { ...i, research_questions: [`${i.id} a?`, `${i.id} b?`] })),
    initiative('IN-4', { slug: 'gap-fill', priority: 3, research_questions: ['c?'] }),
  ] }
  const { result, children } = await runBoard({ overrides: { 'synthesize:r0': strategy } })

  assert.equal(children.filter((c) => c.name === 'brie-ground').length, 4)
  const mold = result.mold.find((m) => m.initiative === 'IN-4')
  assert.match(mold.reason, /research cap of 4 reached; unresearched: c\?/)
})

test('cheese-board moves an initiative that overrides a recorded decision to mold', async () => {
  const strategy = { ...STRATEGY, initiatives: STRATEGY.initiatives.map((i) => (i.id === 'IN-1' ? { ...i, overrides: ['D-1'] } : i)) }
  const { result, labels } = await runBoard({ overrides: { 'synthesize:r0': strategy } })

  assert.equal(labels.includes('draft:version-banner:r0'), false)
  assert.match(result.mold.find((m) => m.initiative === 'IN-1').reason, /overrides D-1/)
  assert.deepEqual(result.blocked.map((b) => b.blocked_by), [['IN-1 is in lane mold']])
})

test('cheese-board redoes a strategy that overrides an unknown decision', async () => {
  const strategy = { ...STRATEGY, initiatives: STRATEGY.initiatives.map((i) => (i.id === 'IN-1' ? { ...i, overrides: ['D-9'] } : i)) }
  const { labels, trace } = await runBoard({ overrides: { 'synthesize:r0': strategy } })

  const redo = trace.agents.find(({ opts }) => opts.label === 'synthesize:r0:redo1')
  assert.ok(redo, labels.join(', '))
  assert.match(redo.prompt, /IN-1\.overrides: unknown id 'D-9'/)
})

test('cheese-board continues without decisions when wiki grounding fails, and reports the gap', async () => {
  const { result, labels } = await runBoard({ overrides: { ground: null, 'ground:redo1': null, 'ground:redo2': null } })

  assert.ok(labels.includes('ground:redo2'))
  assert.deepEqual(result.decisions, [])
  assert.deepEqual(result.gaps, ['wiki grounding failed; the strategy ran without recorded decisions'])
  assert.equal(result.status, 'partial')
  assert.ok(labels.includes('synthesize:r0'))
})

test('cheese-board records nothing in the wiki when the done advisor does not approve', async () => {
  const { result, labels } = await runBoard({ overrides: { 'advise:done': { verdict: 'revise', concerns: ['queue order is wrong'], guidance: 'reorder', blocking_questions: [] } } })

  assert.equal(result.status, 'needs-review')
  assert.equal(result.recorded, null)
  assert.equal(labels.includes('record:strategy'), false)
})

// A strategy over ideas only, for runs where no issue reaches the strategy.
const IDEAS_ONLY = { ...STRATEGY, initiatives: [initiative('IN-1', { items: ['IDEA-1', 'IDEA-2'], slug: 'sync-cache' })] }
const ideasOnly = (extra = {}) => ({
  ground: { decisions: [GROUNDING.decisions[1]], prior_research: [] },
  'strategist:leverage': IDEAS_ONLY, 'strategist:risk': IDEAS_ONLY, 'strategist:architecture': IDEAS_ONLY, 'synthesize:r0': IDEAS_ONLY,
  ...extra,
})
const reportOf = (trace) => JSON.parse(/<data name="report">\n([\s\S]*?)\n<\/data>/.exec(trace.agents.find(({ opts }) => opts.label === 'write:report').prompt)[1])

test('cheese-board reports an ungrounded issue as a gap and in the report', async () => {
  const triage = { ...TRIAGE, items: [...TRIAGE.items, issue(5, 'Never grounded')] }
  const { result, trace } = await runBoard({ triage })

  assert.deepEqual(result.ungrounded.map((u) => u.id), ['#5'])
  assert.deepEqual(result.gaps, ['triage-sweep could not ground 1 issue(s): #5'])
  assert.equal(result.coverage.ungrounded, 1)
  assert.equal(result.status, 'partial')
  assert.match(reportOf(trace), /^## Ungrounded issues\n\n- #5 Never grounded: triage-sweep could not ground it$/m)
})

test('cheese-board treats missing routing as a gap only when issues were grounded', async () => {
  const missing = await runBoard({ triage: { ...TRIAGE, routing: null } })
  assert.ok(missing.result.gaps.includes('triage-sweep returned no routing; close verdicts went to needs-human'))

  // An empty backlog returns routing null on purpose.
  const empty = await runBoard({ triage: { items: [], grounded: [], lenses: [], routing: null }, overrides: ideasOnly() })
  assert.deepEqual(empty.result.gaps, [])
  assert.equal(empty.result.status, 'ok')
  assert.equal(empty.trace.logs.some((l) => l.includes('no routing')), false)
})

test('cheese-board sends a likely close to needs-human, not to the close batch', async () => {
  const routed = TRIAGE.routing.routed.map((r) => (r.number === 2 ? { ...r, confidence: 'likely' } : r))
  const { result } = await runBoard({ triage: { ...TRIAGE, routing: { ...TRIAGE.routing, routed } } })

  assert.deepEqual(result.close_batch, [])
  assert.deepEqual(result.needs_human.map((h) => h.id), ['#2', '#3'])
})

test('cheese-board keeps an idea live when it duplicates a close issue', async () => {
  const ideas = { ideas: [{ ...IDEAS.ideas[0], duplicate_of: '#2' }, IDEAS.ideas[1]] }
  const strategy = { ...STRATEGY, parked: [{ item: 'IDEA-1', reason: 'the close batch covers it' }] }
  const { result, trace } = await runBoard({ overrides: { ideas, 'strategist:leverage': strategy, 'strategist:risk': strategy, 'strategist:architecture': strategy, 'synthesize:r0': strategy } })

  const strategist = trace.agents.find(({ opts }) => opts.label === 'strategist:leverage')
  const context = JSON.parse(/<data name="context">\n([\s\S]*?)\n<\/data>/.exec(strategist.prompt)[1])
  assert.deepEqual(context.items.map((i) => i.id), ['#1', '#4', 'IDEA-1', 'IDEA-2'])
  assert.deepEqual(result.parked.map((p) => p.item), ['IDEA-1'])
})

test('cheese-board redoes the ideas call when an idea has no source', async () => {
  const bad = { ideas: [{ ...IDEAS.ideas[1], source: ' ' }] }
  const { labels, trace } = await runBoard({ overrides: { ideas: bad } })

  const redo = trace.agents.find(({ opts }) => opts.label === 'ideas:redo1')
  assert.ok(redo, labels.join(', '))
  assert.match(redo.prompt, /ideas\[0\] needs a title and a source citation/)
})

test('cheese-board repairs a slug that mold would reject', async () => {
  for (const slug of ['version--banner', 'version-banner-', 'a'.repeat(65)]) {
    const bad = { ...STRATEGY, initiatives: STRATEGY.initiatives.map((i) => (i.id === 'IN-1' ? { ...i, slug } : i)) }
    const { labels } = await runBoard({ overrides: { 'synthesize:r0': bad } })
    assert.ok(labels.includes('synthesize:r0:repair1'), `${slug}: ${labels.join(', ')}`)
  }
})

test('cheese-board redoes a strategy with a dependency cycle', async () => {
  const cyclic = { ...STRATEGY, initiatives: STRATEGY.initiatives.map((i) => (i.id === 'IN-1' ? { ...i, depends_on: ['IN-2'] } : i)) }
  const { trace } = await runBoard({ overrides: { 'synthesize:r0': cyclic } })

  assert.match(trace.agents.find(({ opts }) => opts.label === 'synthesize:r0:redo1').prompt, /dependency cycle among IN-1, IN-2/)
})

test('cheese-board moves a spec with more than two research questions to mold without research', async () => {
  const strategy = { ...STRATEGY, initiatives: STRATEGY.initiatives.map((i) => (i.id === 'IN-1' ? { ...i, research_questions: ['a?', 'b?', 'c?'] } : i)) }
  const { result, children } = await runBoard({ overrides: { 'synthesize:r0': strategy } })

  assert.deepEqual(children.filter((c) => c.name === 'brie-ground'), [])
  assert.match(result.mold.find((m) => m.initiative === 'IN-1').reason, /3 research questions exceed 2/)
})

test('cheese-board plans research all or nothing, so no slot is wasted on a partial plan', async () => {
  const strategy = { ...STRATEGY, initiatives: [
    ...STRATEGY.initiatives.map((i) => (i.id === 'IN-1' ? { ...i, research_questions: ['a?', 'b?'] } : i.id === 'IN-2' ? { ...i, research_questions: ['c?'] } : i)),
    initiative('IN-4', { slug: 'two-questions', priority: 3, research_questions: ['d?', 'e?'] }),
    initiative('IN-5', { slug: 'one-question', priority: 4, research_questions: ['f?'] }),
  ] }
  const { result, children } = await runBoard({ overrides: { 'synthesize:r0': strategy } })

  // Spec chains run in parallel, so compare the set of questions.
  assert.deepEqual(children.filter((c) => c.name === 'brie-ground').map((c) => c.childArgs).sort(), ['a?', 'b?', 'c?', 'f?'])
  assert.match(result.mold.find((m) => m.initiative === 'IN-4').reason, /research cap of 4 reached; unresearched: d\? \/ e\?/)
  assert.ok(result.factory_queue.flat().some((q) => q.slug === 'one-question'))
})

test('cheese-board keeps a spec that fails Verify out of the factory queue', async () => {
  const verify = ({ prompt }) => {
    const paths = JSON.parse(/<data name="paths">\n([\s\S]*?)\n<\/data>/.exec(prompt)[1])
    return { results: paths.map((p) => ({ path: p, valid: !p.endsWith('/version-banner.md'), candidate_curds: 1, note: '' })) }
  }
  const { result } = await runBoard({ overrides: { 'verify:specs': verify } })

  assert.deepEqual(result.factory_queue, [])
  assert.deepEqual(result.blocked.map((b) => [b.slug, b.blocked_by]), [['sync-cache', ['IN-1 spec is unverified']]])
  assert.deepEqual(result.spec_failures.map((f) => [f.slug, f.status]), [['version-banner', 'written']])
  assert.equal(result.status, 'partial')
})

test('cheese-board queues nothing when the verify judge returns no verdict', async () => {
  const { result } = await runBoard({ overrides: { 'verify:specs': null, 'verify:specs:redo1': null, 'verify:specs:redo2': null } })

  assert.deepEqual(result.factory_queue, [])
  assert.equal(result.spec_failures.length, 2)
  assert.equal(result.status, 'partial')
})

test('cheese-board reports a failed strategist lens as a gap', async () => {
  const { result } = await runBoard({ overrides: { 'strategist:risk': null, 'strategist:risk:redo1': null, 'strategist:risk:redo2': null } })

  assert.deepEqual(result.gaps, ['the risk strategist failed; the synthesis ran without its lens'])
  assert.equal(result.status, 'partial')
})

test('cheese-board sends the advisor concerns and guidance to the revised synthesis', async () => {
  const revise = { verdict: 'revise', concerns: ['IN-2 is too large'], guidance: 'split IN-2 by module', blocking_questions: [] }
  const { result, trace } = await runBoard({ overrides: { 'advise:strategy:0': revise } })

  const resynth = trace.agents.find(({ opts }) => opts.label === 'synthesize:r1').prompt
  const feedback = JSON.parse(/<data name="advisor_feedback">\n([\s\S]*?)\n<\/data>/.exec(resynth)[1])
  assert.deepEqual(feedback, { concerns: ['IN-2 is too large'], guidance: 'split IN-2 by module' })
  assert.equal(result.status, 'ok')
})

test('cheese-board asks for input after the advisor revises twice', async () => {
  const revise = { verdict: 'revise', concerns: ['still wrong'], guidance: 'rethink', blocking_questions: [] }
  const { result, labels } = await runBoard({ overrides: { 'advise:strategy:0': revise, 'advise:strategy:1': revise } })

  assert.equal(result.status, 'needs-input')
  assert.equal(labels.includes('resolve'), false)
})

test('cheese-board stops before Ground when the budget floor is reached', async () => {
  const { result, labels } = await runBoard({ budgetTotal: 100000, budgetSpent: 60000 })

  assert.equal(result.status, 'blocked')
  assert.match(result.reason, /budget floor reached before Ground/)
  assert.equal(labels.includes('ground'), false)
})

test('cheese-board rejects a resolved path with a parent segment', async () => {
  const bad = ({ prompt }) => {
    const slugs = JSON.parse(/<data name="slugs">\n([\s\S]*?)\n<\/data>/.exec(prompt)[1])
    return { specs: slugs.map((slug) => ({ slug, path: `${SPECS_DIR}/../specs/${slug}.md`, exists: false })), report_path: REPORT }
  }
  const { result } = await runBoard({ overrides: { resolve: bad, 'resolve:redo1': bad, 'resolve:redo2': bad } })

  assert.equal(result.status, 'blocked')
  assert.match(result.reason, /path resolution failed/)
})

test('cheese-board returns dropped seeds and ideas over the cap in the result', async () => {
  const many = { ideas: Array.from({ length: 41 }, (_, n) => ({ title: `idea ${n + 1}`, summary: 's', source: 'wiki/roadmap.md', existing_spec: '', duplicate_of: '' })) }
  const { result } = await runBoard({ args: { stamp: STAMP, auto: true, ideas: ['keep me', 3, '  '] }, overrides: { ideas: many } })

  assert.deepEqual(result.dropped.filter((d) => d.kind !== 'theme'), [
    { kind: 'seed', count: 2, reason: 'not a non-empty string' },
    { kind: 'idea', ref: 'idea 41', reason: 'over the cap of 40 ideas' },
  ])
})

test('cheese-board treats a throwing agent as no output and keeps the run alive', async () => {
  const boom = () => { throw new Error('budget ceiling reached') }
  const { result, trace } = await runBoard({ overrides: { ground: boom, 'ground:redo1': boom, 'ground:redo2': boom } })

  assert.ok(trace.logs.includes('ground: agent threw: budget ceiling reached'), trace.logs.join('\n'))
  assert.deepEqual(result.gaps, ['wiki grounding failed; the strategy ran without recorded decisions'])
  assert.equal(result.status, 'partial')
})

test('cheese-board drops an idea that repeats an earlier title or existing spec, and logs it', async () => {
  const ideas = { ideas: [
    ...IDEAS.ideas,
    { title: 'faster  SYNC!', summary: 'same idea again', source: 'args', existing_spec: '', duplicate_of: '' },
    { title: 'Another old plan', summary: 'same spec', source: 'args', existing_spec: `${SPECS_DIR}/old-plan.md`, duplicate_of: '' },
  ] }
  const { result, trace } = await runBoard({ overrides: { ideas } })

  assert.deepEqual(result.dropped.filter((d) => d.kind === 'idea'), [
    { kind: 'idea', ref: 'faster SYNC!', reason: 'repeats an earlier idea or its existing spec' },
    { kind: 'idea', ref: 'Another old plan', reason: 'repeats an earlier idea or its existing spec' },
  ])
  assert.ok(trace.logs.some((l) => /^Dropped 2 repeated idea\(s\)/.test(l)), trace.logs.join('\n'))
  assert.equal(result.status, 'ok')
})

test('cheese-board runs one brie-ground child for a question that repeats in one initiative', async () => {
  const strategy = { ...STRATEGY, initiatives: STRATEGY.initiatives.map((i) => (i.id === 'IN-1' ? { ...i, research_questions: ['Flaky?', ' flaky? '] } : i)) }
  const { result, children, trace } = await runBoard({ overrides: { 'synthesize:r0': strategy } })

  assert.equal(children.filter((c) => c.name === 'brie-ground').length, 1)
  assert.deepEqual(result.dropped.filter((d) => d.kind === 'research_question'), [
    { kind: 'research_question', ref: 'IN-1: flaky?', reason: 'repeats an earlier question of the same initiative' },
  ])
  assert.ok(trace.logs.includes('IN-1: dropped a repeated research question: flaky?'), trace.logs.join('\n'))
})

test('cheese-board shares one brie-ground child for a question that two initiatives ask, and counts it once against the cap', async () => {
  const strategy = { ...STRATEGY, initiatives: [
    ...STRATEGY.initiatives.map((i) => (i.id === 'IN-3' ? i : { ...i, research_questions: ['Shared?', `${i.id} own?`] })),
    initiative('IN-4', { slug: 'gap-fill', priority: 3, research_questions: ['Last?'] }),
  ] }
  const { result, children, labels } = await runBoard({ overrides: { 'synthesize:r0': strategy } })

  assert.equal(children.filter((c) => c.name === 'brie-ground').length, 4)
  assert.equal(result.mold.some((m) => m.initiative === 'IN-4'), false)
  for (const slug of ['version-banner', 'sync-cache', 'gap-fill']) assert.ok(labels.includes(`draft:${slug}:r0`), slug)
})

test('cheese-board logs an invalid limit or maxSpecs and a maxSpecs clamp', async () => {
  const { trace } = await runBoard({ args: { stamp: STAMP, auto: true, maxSpecs: 99, limit: 'many' } })
  assert.ok(trace.logs.some((l) => /^Requested maxSpecs 99 exceeds max \d+; clamping\.$/.test(l)), trace.logs.join('\n'))
  assert.ok(trace.logs.some((l) => /^args\.limit must be a positive integer; using \d+\.$/.test(l)), trace.logs.join('\n'))

  const invalid = await runBoard({ args: { stamp: STAMP, auto: true, maxSpecs: 0 } })
  assert.ok(invalid.trace.logs.some((l) => /^args\.maxSpecs must be a positive integer; using \d+\.$/.test(l)), invalid.trace.logs.join('\n'))
})

test('cheese-board requires blocking_questions and every question field in the advice schema', async () => {
  const { trace } = await runBoard()
  const schema = trace.agents.find(({ opts }) => opts.label === 'advise:strategy:0').opts.schema

  assert.ok(schema.required.includes('blocking_questions'))
  assert.deepEqual([...schema.properties.blocking_questions.items.required].sort(), ['evidence', 'options', 'question', 'recommended'])
})
