// Ground and Research tests (ADR-018): wiki decisions and brie-ground answers reach the plan, and research fails closed.
import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow } from './harness.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/cheese-factory.js')

const sha = (n) => n.toString(16).padStart(40, '0')
const SPEC = '# Spec\n\n## Acceptance\n\n- AC-1: WHEN x THE SYSTEM SHALL y.\n'
const approve = () => ({ verdict: 'approve', concerns: [], guidance: '' })
const decision = { statement: 'Workflows never merge PRs.', kind: 'adr', citation: 'adr/cheese-factory-workflow.md:12', items: ['SPEC'] }
const ground = (over = {}) => ({ decisions: [], prior_research: [], research_questions: [], ...over })
const answer = (question, over = {}) => ({ answer: `answer to ${question}`, confidence: 'certain', report_path: '/research/r.md', evidence_table: [{ citation: 'https://example.test/doc' }], ...over })

const table = {
  resolve: () => ({ mode: 'resolved', base_sha: sha(0xba5e), spec_path: '/specs/parent.md', spec_text: SPEC, curd_count: { slug: 'parent', candidate_curds: 1, blast_radius: 'medium' } }),
  ground: () => ground(),
  criteria: () => ({ criteria: [{ id: 'AC-1', statement: 'y', check_kind: 'command', check: 'test -e src/parent.js' }] }),
  'advise:plan': approve,
  'cook:parent': () => ({ status: 'ok', head_sha: sha(1), worktree_path: '/tmp/worktrees/parent', artifact: '.cheese/cook/parent.md', orientation: 'x' }),
  'taste:parent': () => ({ verdict: 'pass', lenses: [{ lens: 'drift', verdict: 'pass', note: '' }], issues: [], recommendation: 'pass' }),
  'press:parent': () => ({ status: 'ok', head_sha: sha(2), artifact: '.cheese/press/parent.md', orientation: 'x' }),
  integrate: () => ({ worktree_path: '/repo/.claude/worktrees/integration', merged: ['parent'], conflicted: [], head: sha(0x1ead), files_by_slug: { parent: ['src/parent.js'] }, files_changed: 1, lines_changed: 1 }),
  'age:barrier': () => ({ status: 'ok', artifact: '.cheese/age/barrier.md', has_medium_plus_findings: false, findings: [], reviewed_slugs: ['parent'] }),
  'verify:AC-1': () => ({ criterion: 'AC-1', passes: true, evidence: 'exit 0', tree_clean: true, missing_paths: [] }),
  'advise:done': approve,
  plate: () => ({ results: [{ slug: 'parent', status: 'ok', pr_url: 'https://example.test/pr/parent' }] }),
  cleanup: () => ({ removed: [] }),
}

async function run(over = {}, child = () => { throw new Error('no research expected') }) {
  const full = { ...table, ...over }
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      const fn = full[opts.label.replace(/(:(redo|repair|retry)\d+)+$/, '')]
      if (!fn) throw new Error(`unexpected agent ${opts.label}`)
      return fn()
    },
  })
  const research = []
  const result = await workflow.run({ ...globals, args: { spec: 'parent' }, workflow: async (name, q) => { research.push({ name, q }); return child(q) } })
  const labels = trace.agents.map(({ opts }) => opts.label)
  const promptOf = (label) => trace.agents.find(({ opts }) => opts.label === label).prompt
  return { result: JSON.parse(JSON.stringify(result)), trace, labels, promptOf, research }
}

const dataOf = (text, name) => {
  const m = new RegExp(`<data name="${name}">\\n([\\s\\S]*?)\\n</data>`).exec(text)
  return m ? JSON.parse(m[1]) : null
}

test('ground_runsAfterResolveAndBeforeCriteria_asAReadOnlyExplorer', async () => {
  const { labels, trace } = await run()

  assert.deepEqual(labels.slice(0, 3), ['resolve', 'ground', 'criteria'])
  assert.equal(trace.agents[1].opts.agentType, 'explorer')
  assert.deepEqual(dataOf(trace.agents[1].prompt, 'items'), ['SPEC', 'AC-1'])
})

test('ground_decision_reachesAdvisorsCookAndTaste_andTheReport', async () => {
  const { result, promptOf } = await run({ ground: () => ground({ decisions: [decision] }) })

  const expected = [{ id: 'D-1', ...decision }]
  assert.deepEqual(dataOf(promptOf('advise:plan'), 'payload').grounding.decisions, expected)
  assert.deepEqual(dataOf(promptOf('advise:done'), 'payload').grounding.decisions, expected)
  assert.deepEqual(dataOf(promptOf('cook:parent'), 'grounding').decisions, expected)
  assert.deepEqual(dataOf(promptOf('taste:parent'), 'locked_decisions'), expected)
  assert.deepEqual(result.grounding.decisions, expected)
  assert.equal(result.status, 'ok')
})

test('ground_emptyGrounding_addsNoGroundingBlockToCook', async () => {
  const { promptOf } = await run()

  assert.equal(dataOf(promptOf('cook:parent'), 'grounding'), null)
})

test('ground_unknownItemRef_isRedoneBeforeTheRunUsesIt', async () => {
  let n = 0
  const { labels, result } = await run({ ground: () => (n++ ? ground({ decisions: [decision] }) : ground({ decisions: [{ ...decision, items: ['AC-9'] }] })) })

  assert.ok(labels.includes('ground:redo1'))
  assert.deepEqual(result.grounding.decisions[0].items, ['SPEC'])
})

test('ground_failure_isAGap_runStillPlates_andEndsPartial', async () => {
  const { result, labels } = await run({ ground: () => null })

  assert.ok(labels.includes('plate'))
  assert.equal(result.status, 'partial')
  assert.deepEqual(result.gaps, ['wiki grounding failed; the run planned without recorded decisions'])
  assert.deepEqual(result.grounding, { decisions: [], prior_research: [], research: [] })
})

test('research_settledAnswer_reachesTheAdvisorAndCook', async () => {
  const { result, research, promptOf, trace } = await run({ ground: () => ground({ research_questions: ['Does gh support --match-head-commit?'] }) }, (q) => answer(q))

  assert.deepEqual(research, [{ name: 'brie-ground', q: 'Does gh support --match-head-commit?' }])
  const found = { question: 'Does gh support --match-head-commit?', answer: 'answer to Does gh support --match-head-commit?', confidence: 'certain', report_path: '/research/r.md', citations: ['https://example.test/doc'] }
  assert.deepEqual(dataOf(promptOf('advise:plan'), 'payload').grounding.research, [found])
  assert.deepEqual(dataOf(promptOf('cook:parent'), 'grounding').research, [found])
  assert.deepEqual(trace.phases.slice(0, 4), ['Resolve', 'Ground', 'Research', 'Criteria'])
  assert.equal(result.status, 'ok')
})

test('research_repeatedQuestion_runsOneChild', async () => {
  const { research } = await run({ ground: () => ground({ research_questions: ['Is X current?', '  Is   X current? '] }) }, (q) => answer(q))

  assert.equal(research.length, 1)
})

test('research_dontKnow_blocksBeforeAnyPlan_andRoutesToMold', async () => {
  const { result, labels } = await run({ ground: () => ground({ research_questions: ['Is X current?'] }) }, () => answer('x', { confidence: 'dont_know', open_questions: ['Which X?'] }))

  assert.equal(result.status, 'blocked')
  assert.match(result.reason, /could not settle: Is X current\?; settle it in \/mold/)
  assert.deepEqual(result.open_questions, ['Is X current?', 'Which X?'])
  assert.deepEqual(labels, ['resolve', 'ground'])
})

test('research_failedChild_blocksTheRunWithNoCook', async () => {
  const { result, labels } = await run({ ground: () => ground({ research_questions: ['Is X current?'] }) }, () => { throw new Error('tavily down') })

  assert.equal(result.status, 'blocked')
  assert.equal(result.reason, 'research failed: Is X current?')
  assert.deepEqual(labels, ['resolve', 'ground'])
})

test('research_overTheCap_blocksWithEveryQuestionAndRunsNoChild', async () => {
  const questions = ['q1', 'q2', 'q3', 'q4']
  const { result, research, labels } = await run({ ground: () => ground({ research_questions: questions }) })

  assert.equal(result.status, 'blocked')
  assert.match(result.reason, /4 external questions open, over the cap of 3/)
  assert.deepEqual(result.open_questions, questions)
  assert.equal(research.length, 0)
  assert.deepEqual(labels, ['resolve', 'ground'])
})

test('research_budgetFloor_blocksBeforeTheChild', async () => {
  const workflow = await loadWorkflow(path)
  const { globals } = createRuntime({
    respond: ({ opts }) => (opts.label === 'resolve' ? table.resolve() : ground({ research_questions: ['q1'] })),
    budgetTotal: 100000,
    budgetSpent: 60000,
  })
  let called = false
  const result = await workflow.run({ ...globals, args: { spec: 'parent' }, workflow: async () => { called = true } })

  assert.equal(result.status, 'blocked')
  assert.equal(result.reason, 'budget floor reached before research')
  assert.equal(called, false)
})

test('taste_roadmapDecision_isContextOnly_notLocked', async () => {
  const roadmap = { ...decision, kind: 'roadmap', statement: 'Prefer workflows over skills.' }
  const { promptOf } = await run({ ground: () => ground({ decisions: [decision, roadmap] }) })

  const prompt = promptOf('taste:parent')
  assert.deepEqual(dataOf(prompt, 'locked_decisions').map((d) => d.id), ['D-1'])
  assert.deepEqual(dataOf(prompt, 'context_decisions').map((d) => d.id), ['D-2'])
  assert.match(prompt, /never halt on them/)
})

test('cookContinuation_carriesTheGroundingBlock', async () => {
  const checkpoint = sha(0x77)
  const { promptOf } = await run({
    ground: () => ground({ decisions: [decision] }),
    'cook:parent': () => ({ status: 'partial', head_sha: checkpoint, checkpoint, completed: 'half', remaining: 'rest', source_ranges: ['src/parent.js#1-2'], orientation: 'low context' }),
    'cook:parent:c1': table['cook:parent'],
  })

  assert.deepEqual(dataOf(promptOf('cook:parent:c1'), 'grounding').decisions, [{ id: 'D-1', ...decision }])
})

const multi = {
  resolve: () => ({ ...table.resolve(), curd_count: { slug: 'parent', candidate_curds: 3, blast_radius: 'medium' } }),
  'decompose:plan': () => ({ curds: [{ slug: 'a', brief: 'do a', files: ['a.js'] }, { slug: 'c', brief: 'do c', files: ['c.js'] }] }),
  'decompose:write-minispecs': () => ({ curds: [{ slug: 'a', spec_path: '/specs/parent--a.md' }, { slug: 'c', spec_path: '/specs/parent--c.md' }] }),
  ...Object.fromEntries(['a', 'c'].flatMap((s) => [
    [`cook:${s}`, () => ({ status: 'ok', head_sha: sha(1), worktree_path: `/tmp/worktrees/${s}`, artifact: `.cheese/cook/${s}.md`, orientation: 'x' })],
    [`taste:${s}`, table['taste:parent']],
    [`press:${s}`, () => ({ status: 'ok', head_sha: sha(2), artifact: `.cheese/press/${s}.md`, orientation: 'x' })],
  ])),
  integrate: () => ({ ...table.integrate(), merged: ['a', 'c'], files_by_slug: { a: ['a.js'], c: ['c.js'] } }),
  'age:barrier': () => ({ ...table['age:barrier'](), reviewed_slugs: ['a', 'c'] }),
  plate: () => ({ results: ['a', 'c'].map((slug) => ({ slug, status: 'ok', pr_url: `https://example.test/pr/${slug}` })) }),
}

test('decompose_getsTheGroundingBlock', async () => {
  const { promptOf } = await run({ ...multi, ground: () => ground({ decisions: [decision] }) })

  assert.deepEqual(dataOf(promptOf('decompose:plan'), 'grounding').decisions, [{ id: 'D-1', ...decision }])
  assert.match(promptOf('decompose:plan'), /Return at most 12 curds/)
})

test('research_threeChildren_lowerTheCurdCapUnderTheAgentCap', async () => {
  const { promptOf, trace } = await run({ ...multi, ground: () => ground({ research_questions: ['q1', 'q2', 'q3'] }) }, (q) => answer(q))

  assert.match(promptOf('decompose:plan'), /Return at most 9 curds/)
  assert.ok(trace.logs.some((l) => /3 research child\(ren\) leave room for 9 curds/.test(l)))
})

test('research_oneChild_keepsTheFullCurdCap', async () => {
  const { promptOf } = await run({ ...multi, ground: () => ground({ research_questions: ['q1'] }) }, (q) => answer(q))

  assert.match(promptOf('decompose:plan'), /Return at most 12 curds/)
})
