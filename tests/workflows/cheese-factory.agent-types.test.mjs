// Agent type and prompt tests: each helper call runs on a named agent type, and each prompt names the tilth reader.
import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow } from './harness.mjs'
import { verifyFrom } from './cheese-factory.fixtures.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/cheese-factory.js')

const sha = (n) => n.toString(16).padStart(40, '0')
const SPEC = '# Spec\n\n## Acceptance\n\n- AC-1: WHEN x THE SYSTEM SHALL y.\n'
const approve = () => ({ verdict: 'approve', concerns: [], guidance: '' })
const resolved = (curds = 1) => ({ mode: 'resolved', base_sha: sha(0xba5e), spec_path: '/specs/parent.md', spec_text: SPEC, curd_count: { slug: 'parent', candidate_curds: curds, blast_radius: 'medium' } })

const table = {
  resolve: () => resolved(),
  ground: () => ({ decisions: [], prior_research: [], research_questions: [] }),
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

async function run(over = {}, args = { spec: 'parent' }) {
  const full = { ...table, ...over }
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: (call) => {
      const key = call.opts.label.replace(/(:(redo|repair|retry)\d+)+$/, '')
      const fn = full[key] || (key === 'verify' && verifyFrom(full, () => null))
      if (!fn) throw new Error(`unexpected agent ${call.opts.label}`)
      return fn(call)
    },
  })
  const result = await workflow.run({ ...globals, args, workflow: async () => { throw new Error('no research expected') } })
  const call = (label) => trace.agents.find(({ opts }) => opts.label === label)
  return { result: JSON.parse(JSON.stringify(result)), call }
}

test('resolve_runsAsAnExplorer_andReadsTheSpecWithTilth', async () => {
  const { call } = await run()

  assert.equal(call('resolve').opts.agentType, 'explorer')
  assert.match(call('resolve').prompt, /read the spec's full text with mcp__tilth__tilth_read/)
})

test('skillStep_namesTheTilthReaderForTheSkillFile', async () => {
  const { call } = await run()

  assert.match(call('cook:parent').prompt, /SKILL\.md with mcp__tilth__tilth_read and follow it/)
})

test('shortSha_expansion_runsAsAnExplorer', async () => {
  const { call } = await run({
    'cook:parent': () => ({ status: 'ok', head_sha: 'abc1234', worktree_path: '/tmp/worktrees/parent', artifact: '.cheese/cook/parent.md', orientation: 'x' }),
    'cook:parent:sha': () => ({ sha: `abc1234${'0'.repeat(33)}` }),
  })

  assert.equal(call('cook:parent:sha').opts.agentType, 'explorer')
})

test('salvage_runsAsAnExplorer', async () => {
  const { call } = await run({
    'cook:parent': () => { throw new Error('cook crashed') },
    'salvage:parent': () => ({ found: false }),
  })

  assert.equal(call('salvage:parent').opts.agentType, 'explorer')
})

test('decomposePlan_runsAsAnExplorer', async () => {
  const { call } = await run({ resolve: () => resolved(2), 'decompose:plan': () => null })

  assert.equal(call('decompose:plan').opts.agentType, 'explorer')
})

test('miniSpecPrompt_citesTheHomeMoldSkillPath', async () => {
  const curds = [{ slug: 'a', brief: 'a', files: ['src/a.js'] }, { slug: 'b', brief: 'b', files: ['src/b.js'] }]
  const { call } = await run({ resolve: () => resolved(2), 'decompose:plan': () => ({ curds }), 'decompose:write-minispecs': () => null })

  const text = call('decompose:write-minispecs').prompt
  assert.match(text, /read ~\/\.claude\/skills\/mold\/SKILL\.md § Agent-invoked mini-spec mode with mcp__tilth__tilth_read/)
})

test('invalidSpecArg_returnsTheUsage', async () => {
  const { result } = await run({}, { spec: 'a/../b' })

  assert.equal(result.error, 'Invalid spec arg: a/../b')
  assert.match(result.usage, /^Usage: \/cheese-factory \{ spec: <slug-or-path> \}/)
})

test('cleanup_runsAsARunner_andKeepsItsReadOnlyRetry', async () => {
  const { call } = await run({ cleanup: () => { throw new Error('flaky') } })

  assert.equal(call('cleanup').opts.agentType, 'runner')
  assert.ok(call('cleanup:retry1'), 'a runner is not a writer, so a cleanup throw retries')
})
