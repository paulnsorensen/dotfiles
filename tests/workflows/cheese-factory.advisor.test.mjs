import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime } from './harness.mjs'
import { loadWorkflow } from './cheese-factory.fixtures.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/cheese-factory.js')

// ---- fixtures: a single-pass run, scripted until the plan advisor decides ----

const sha = (n) => n.toString(16).padStart(40, '0')
const SPEC = '# Spec\n\n## Acceptance\n\n- AC-1: WHEN x THE SYSTEM SHALL y.\n'
const SPEC_WITH_SCOPE = `${SPEC}\n## File scope\n\n- \`src/a.js\`: add the flag\n- \`tests/a.test.js\`\n\n## Non-goals\n\n- \`src/other.js\`\n`
// The shape of the attempt-history spec: inline code in the AC lines, ids out of order, and a table after the list.
const SPEC_ATTEMPT_HISTORY = [
  '---', 'slug: attempt-history', '---', '', '## Acceptance',
  '- AC-1: `test -f a/_history.py` exits 0.',
  '- AC-2: `grep -q \'_history\' a/__init__.py` exits 0.',
  '- AC-21: The test marked gh-241:AC-10 passes.',
  '- AC-16: `uv run pytest a/test_layout.py` exits 0.',
  '', '| Spec AC | marker |', '| --- | --- |', '| AC-21 | gh-241:AC-10 |', '',
].join('\n')

const resolved = (spec_text) => ({ mode: 'resolved', base_sha: sha(0xba5e), spec_path: '/specs/parent.md', spec_text, curd_count: { slug: 'parent', candidate_curds: 1, blast_radius: 'medium' } })
const crit = (id) => ({ id, statement: `statement ${id}`, check_kind: 'command', check: 'test -e src/parent.js' })
const advice = (v, concerns = [], guidance = '') => ({ verdict: v, concerns, guidance })

const table = (spec, ids, adviseTable = {}) => ({
  resolve: () => resolved(spec),
  ground: () => ({ decisions: [], prior_research: [], research_questions: [] }),
  criteria: () => ({ criteria: ids.map(crit) }),
  'advise:plan': () => advice('revise', ['stop here'], 'g'),
  ...adviseTable,
})

async function run(scripts) {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime()
  const agent = async (prompt, opts = {}) => {
    trace.agents.push({ prompt, opts, index: trace.agents.length })
    const fn = scripts[opts.label] || scripts[opts.label.replace(/:r\d+$/, '')]
    if (!fn) throw new Error(`unexpected agent ${opts.label}`)
    return fn({ prompt, opts })
  }
  const result = await workflow.run({ ...globals, agent, args: { spec: 'parent' } })
  return { result, trace }
}

const calls = (trace, label) => trace.agents.filter(({ opts }) => opts.label === label)
const dataOf = (promptText, name) => JSON.parse(new RegExp(`<data name="${name}">\\n([\\s\\S]*?)\\n</data>`).exec(promptText)[1])
const planPayload = (trace) => dataOf(calls(trace, 'advise:plan')[0].prompt, 'payload')

// ---- single-pass payload ----

test('singlePassPayload_withoutFileScope_hasABriefAndNoFilesKey', async () => {
  const { trace } = await run(table(SPEC, ['AC-1']))
  const payload = planPayload(trace)

  assert.equal(payload.single_pass, true)
  assert.equal(payload.curds.length, 1)
  assert.equal(payload.curds[0].brief, 'single pass: cook the whole parent spec in payload.spec')
  assert.equal('files' in payload.curds[0], false)
})

test('singlePassPayload_withFileScopeSection_listsThoseFilesOnly', async () => {
  const { trace } = await run(table(SPEC_WITH_SCOPE, ['AC-1']))
  const [curd] = planPayload(trace).curds

  assert.deepEqual(curd.files, ['src/a.js', 'tests/a.test.js'])
  assert.equal(typeof curd.brief, 'string')
})

test('planAdvisorPrompt_singlePass_saysThatOneCurdCooksTheWholeSpec', async () => {
  const { trace } = await run(table(SPEC, ['AC-1']))
  const text = calls(trace, 'advise:plan')[0].prompt

  assert.match(text, /single_pass true is a valid plan/)
  assert.match(text, /Do not ask for a decomposition, a brief, or a file list/)
})

// ---- round two ----

test('planAdvisorPrompt_roundOne_omitsTheResolveOnlyRule', async () => {
  const { trace } = await run(table(SPEC, ['AC-1']))

  assert.equal(calls(trace, 'advise:plan')[0].prompt.includes('Never reverse a prior concern'), false)
})

test('planAdvisorPrompt_roundTwo_carriesTheResolveOnlyRule', async () => {
  let n = 0
  const { trace } = await run(table(SPEC, ['AC-1'], { 'advise:plan': () => (n++ === 0 ? advice('revise', ['add the registry entry'], 'add it') : advice('revise', ['x'], 'y')) }))
  const text = calls(trace, 'advise:plan:r1')[0].prompt

  assert.match(text, /Judge only whether each prior concern is resolved/)
  assert.match(text, /Raise a new concern only when it makes the work wrong or unsafe/)
  assert.match(text, /Never reverse a prior concern/)
  assert.deepEqual(dataOf(text, 'payload').prior_concerns, ['add the registry entry'])
})

// ---- AC extraction ----

test('acExtraction_attemptHistorySpecFormat_findsEveryAcId', async () => {
  const { trace } = await run(table(SPEC_ATTEMPT_HISTORY, ['AC-1', 'AC-2', 'AC-21', 'AC-16']))
  const payload = planPayload(trace)

  assert.deepEqual(payload.criteria.map((c) => c.id), ['AC-1', 'AC-2', 'AC-21', 'AC-16'])
  assert.deepEqual(dataOf(calls(trace, 'criteria')[0].prompt, 'acceptance_ids'), ['AC-1', 'AC-2', 'AC-21', 'AC-16'])
})
