// Cure group C tests: typed SHA plumbing (trim in normalizeEnums, short-SHA repair path) and cook answers.
// Each test pins one behavior and fails when that behavior regresses.
import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, withAdvisors } from './cheese-factory.fixtures.mjs'
import { loadWorkflow } from './harness.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/cheese-factory.js')

const sha = (n) => n.toString(16).padStart(40, '0')
const BASE_SHA = sha(0xba5e)
const FULL = 'abcdef0123456789abcdef0123456789abcdef01'
const SHORT = FULL.slice(0, 12)
const SCRATCH = (name) => `/repo/.claude/worktrees/${name}`

const resolved = { mode: 'resolved', base_sha: BASE_SHA, spec_path: '/specs/parent.md', spec_text: 'spec body', curd_count: { slug: 'parent', candidate_curds: 1, blast_radius: 'medium' } }
const cookOk = (head_sha = sha(1)) => ({ status: 'ok', head_sha, worktree_path: SCRATCH('cook'), artifact: '.cheese/cook/parent.md', orientation: 'done' })
const tastePass = { verdict: 'pass', lenses: [{ lens: 'drift', verdict: 'pass', note: '' }], issues: [], recommendation: 'pass' }
const pressOk = (head_sha = sha(2)) => ({ status: 'ok', head_sha, artifact: '.cheese/press/parent.md', orientation: 'ok' })
const integrateOk = (head = sha(0x1ead)) => ({ worktree_path: SCRATCH('integ'), merged: ['parent'], conflicted: [], head, files_by_slug: { parent: ['src/parent.js'] }, files_changed: 5, lines_changed: 50 })
const ageClean = { status: 'ok', artifact: '.cheese/age/x.md', has_medium_plus_findings: false, findings: [], reviewed_slugs: ['parent'], has_cheap_lows: false }

const defaults = {
  resolve: () => resolved,
  'cook:parent': () => cookOk(),
  'taste:parent': () => tastePass,
  'press:parent': () => pressOk(),
  integrate: () => integrateOk(),
  'age:barrier': () => ageClean,
  plate: () => ({ results: [{ slug: 'parent', status: 'ok', pr_url: 'https://example.test/pr' }] }),
  cleanup: () => ({ removed: [] }),
}

const responder = (over) => (call) => {
  const label = call.opts.label
  const entry = Object.hasOwn(over, label) ? over[label] : defaults[label]
  if (entry === undefined) throw new Error(`unexpected agent ${label}`)
  return typeof entry === 'function' ? entry(call) : entry
}

// lenient skips the harness schema validation, so a test can model a runtime that lets a malformed field through.
async function run(over = {}, { lenient = false } = {}) {
  const workflow = await loadWorkflow(path)
  const respond = withAdvisors(responder(over))
  const { globals, trace } = createRuntime({ respond })
  if (lenient) {
    globals.agent = async (prompt, opts = {}) => {
      const call = { prompt, opts, index: trace.agents.length }
      trace.agents.push(call)
      try {
        return await respond(call)
      } catch (e) {
        if (/^unexpected agent/.test(e && e.message)) trace.unscripted.push(opts.label)
        throw e
      }
    }
    globals.agent.unscripted = trace.unscripted
  }
  const result = await workflow.run({ ...globals, args: { spec: 'parent' } })
  return { result, trace }
}

const labelsOf = (trace) => trace.agents.map(({ opts }) => opts.label)
const fence = (prompt, name) => new RegExp(`<data name="${name}">\\n([\\s\\S]*?)\\n</data>`).exec(prompt)[1]

test('typed_shortShaWithFormError_repairsTheExpandedValueWithoutARedo', async () => {
  const { result, trace } = await run({
    'press:parent': { status: 'ok', head_sha: SHORT, artifact: '.cheese/press/parent.md', orientation: 42 },
    'press:parent:sha': { sha: FULL },
    'press:parent:repair1': ({ prompt }) => ({ ...JSON.parse(fence(prompt, 'object')), orientation: 'ok' }),
  }, { lenient: true })

  const labels = labelsOf(trace)
  assert.equal(labels.some((l) => l.startsWith('press:parent:redo')), false)
  assert.equal(labels.filter((l) => l === 'press:parent:repair1').length, 1)
  const repair = trace.agents.find(({ opts }) => opts.label === 'press:parent:repair1')
  assert.equal(repair.opts.agentType, 'formatter')
  assert.equal(JSON.parse(fence(repair.prompt, 'object')).head_sha, FULL)
  assert.equal(result.curds[0].status, 'clean')
  const integrateCall = trace.agents.find(({ opts }) => opts.label === 'integrate')
  assert.match(integrateCall.prompt, new RegExp(FULL))
})

test('cookCurd_shortHeadSha_expandsOnceAndPassesTheFullShaDownstream', async () => {
  const { trace } = await run({
    'cook:parent': () => cookOk(SHORT),
    'cook:parent:sha': { sha: FULL },
  })

  assert.equal(labelsOf(trace).filter((l) => l === 'cook:parent:sha').length, 1)
  assert.equal(labelsOf(trace).some((l) => l.startsWith('salvage')), false)
  const taste = trace.agents.find(({ opts }) => opts.label === 'taste:parent')
  assert.match(taste.prompt, new RegExp(FULL))
})

test('cookCurd_blockedWithReason_stopsWithTheReasonAndSkipsSalvage', async () => {
  const { result, trace } = await run({
    'cook:parent': () => ({ status: 'blocked: needs the vault token', orientation: 'x' }),
  })

  assert.equal(result.curds[0].status, 'failed')
  assert.match(result.curds[0].excluded_reason, /last status: blocked.*needs the vault token/)
  assert.equal(labelsOf(trace).some((l) => l.startsWith('salvage') || l.startsWith('cook:parent:c')), false)
})

test('cookCurd_outOfEnumStatus_staysOnTheSalvagePathAndNeverRedoesTheCook', async () => {
  const { result, trace } = await run({
    'cook:parent': () => ({ status: 'wedged', orientation: 'x' }),
    'salvage:parent': { found: false },
  })

  assert.equal(result.curds[0].status, 'failed')
  assert.equal(labelsOf(trace).filter((l) => l.startsWith('salvage')).length, 1)
  assert.equal(labelsOf(trace).filter((l) => l.startsWith('cook:parent')).length, 1)
})

test('normalizeEnums_paddedShas_reachPromptsAndResultsTrimmed', async () => {
  const { result, trace } = await run({
    'cook:parent': () => cookOk(`  ${sha(1)}\n`),
    'press:parent': () => pressOk(` ${sha(2)} `),
    integrate: () => integrateOk(` ${sha(0x1ead)} `),
  })

  assert.equal(result.curds[0].status, 'clean')
  const taste = trace.agents.find(({ opts }) => opts.label === 'taste:parent')
  assert.ok(taste.prompt.includes(sha(1)) && !taste.prompt.includes(` ${sha(1)}`))
  const integrateCall = trace.agents.find(({ opts }) => opts.label === 'integrate')
  assert.deepEqual(JSON.parse(fence(integrateCall.prompt, 'branches'))[0].sha, sha(2))
  const age = trace.agents.find(({ opts }) => opts.label === 'age:barrier')
  assert.ok(age.prompt.includes(sha(0x1ead)))
  assert.equal(age.prompt.includes(` ${sha(0x1ead)} `), false)
})
