import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime } from './cheese-factory.fixtures.mjs'
import { loadWorkflow } from './harness.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/cheese-factory.js')

const sha = (n) => n.toString(16).padStart(40, '0')
const BASE_SHA = sha(0xba5e)
const slug = 'parent'

const resolved = { mode: 'resolved', base_sha: BASE_SHA, spec_path: '/specs/parent.md', spec_text: 'spec body', curd_count: { slug, candidate_curds: 1, blast_radius: 'medium' } }
const cook = { status: 'ok', head_sha: sha(1), worktree_path: `/tmp/worktrees/${slug}`, artifact: `.cheese/cook/${slug}.md`, orientation: 'implemented' }
const lens = (verdict, note = '') => ({ lens: 'drift', verdict, note })
const taste = (verdict, lenses = [lens(verdict)]) => ({ verdict, lenses, issues: verdict === 'revise' ? ['fix this'] : [], recommendation: verdict })
const pressOk = { status: 'ok', head_sha: sha(2), artifact: '.cheese/press/parent.md', orientation: 'done' }
const integrated = { worktree_path: '/repo/.claude/worktrees/integration', merged: [slug], conflicted: [], head: sha(0x1ead), files_by_slug: { [slug]: ['src/parent.js'] }, files_changed: 5, lines_changed: 50 }
const finding = { dimension: 'correctness', severity: 'medium', fix_cost_now: 'n/a', file: 'src/parent.js', line: 1, claim: 'c', why_it_matters: 'm', fix_direction: 'f' }
const ageWith = (findings) => ({ status: 'ok', artifact: '.cheese/age/b.md', has_medium_plus_findings: findings.length > 0, findings, reviewed_slugs: [slug] })

// Every inline responder scripts cleanup, so the strict harness accepts the run.
function responder(over = {}) {
  return ({ opts }) => {
    const base = opts.label.replace(/:(?:redo|repair|retry)\d+$/, '')
    const table = {
      resolve: resolved,
      [`cook:${slug}`]: cook,
      [`taste:${slug}`]: taste('pass'),
      [`press:${slug}`]: pressOk,
      integrate: integrated,
      'age:barrier': ageWith([]),
      plate: { results: [{ slug, status: 'ok', pr_url: 'https://example.test/pr/parent' }] },
      cleanup: { removed: [] },
      ...over,
    }
    if (opts.label in table) return typeof table[opts.label] === 'function' ? table[opts.label]() : table[opts.label]
    if (base in table) return typeof table[base] === 'function' ? table[base]() : table[base]
    throw new Error(`unexpected agent ${opts.label}`)
  }
}

async function run(over) {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: responder(over) })
  const result = await workflow.run({ ...globals, args: { spec: slug } })
  return { result, trace, labels: trace.agents.map(({ opts }) => opts.label) }
}

const STOPS = [
  ['needs-context', { status: 'needs-context', orientation: 'guard ceiling hit' }, /needs-context.*guard ceiling hit/],
  ['blocked: x', { status: 'blocked: tool x is missing' }, /blocked.*tool x is missing/],
]

for (const [name, answer, reason] of STOPS) {
  test(`press ${name} is final: no redo, and the reason reaches the curd failure`, async () => {
    const { result, labels } = await run({ [`press:${slug}`]: answer })
    assert.equal(labels.some((l) => /:redo\d+$/.test(l)), false)
    assert.equal(result.curds[0].status, 'failed')
    assert.match(result.curds[0].excluded_reason, /^press: /)
    assert.match(result.curds[0].excluded_reason, reason)
  })

  test(`cure ${name} is final: no redo, and the reason reaches the curd failure`, async () => {
    const { result, labels } = await run({ 'age:barrier': ageWith([finding]), [`cure:${slug}`]: answer })
    assert.equal(labels.some((l) => /:redo\d+$/.test(l)), false)
    assert.equal(labels.includes('re-merge'), false)
    assert.equal(result.curds[0].status, 'failed')
    assert.match(result.curds[0].excluded_reason, /^cure: /)
    assert.match(result.curds[0].excluded_reason, reason)
  })

  test(`corrective ${name} is final: no redo, and the reason reaches the curd failure`, async () => {
    const { result, labels } = await run({ [`taste:${slug}`]: taste('revise'), [`correct:${slug}:r1`]: answer })
    assert.equal(labels.some((l) => /:redo\d+$/.test(l)), false)
    assert.equal(labels.includes(`press:${slug}`), false)
    assert.equal(result.curds[0].status, 'failed')
    assert.match(result.curds[0].excluded_reason, /^taste-correct: /)
    assert.match(result.curds[0].excluded_reason, reason)
  })
}

test('a press status that is neither blocked nor needs-context still redoes', async () => {
  let calls = 0
  const { result, labels } = await run({ [`press:${slug}`]: () => (++calls === 1 ? { status: 'weird' } : pressOk) })
  assert.ok(labels.includes(`press:${slug}:redo1`))
  assert.equal(result.curds[0].status, 'clean')
})

test('press, cure, and corrective prompts state the exact status set', async () => {
  const { trace } = await run({ 'age:barrier': ageWith([finding]), [`cure:${slug}`]: { status: 'ok', committed: false } })
  const corrective = await run({ [`taste:${slug}`]: taste('revise'), [`correct:${slug}:r1`]: { status: 'fixed', committed: false } })
  const promptOf = (label) => [...trace.agents, ...corrective.trace.agents].find(({ opts }) => opts.label === label).prompt
  assert.match(promptOf(`press:${slug}`), /exactly one of ok, partial, or blocked\. Put any reason in orientation\./)
  assert.match(promptOf(`cure:${slug}`), /exactly one of ok, partial, or blocked\. Put any reason in orientation\./)
  assert.match(promptOf(`correct:${slug}:r1`), /exactly one of fixed, partial, or blocked\. Put any reason in summary\./)
})

test('an overall taste halt fails the curd at once with no corrective round', async () => {
  const { result, labels } = await run({ [`taste:${slug}`]: taste('halt', [lens('pass'), lens('halt', 'locked decision broken')]) })
  assert.equal(labels.some((l) => l.startsWith('correct:') || /:redo\d+$/.test(l)), false)
  assert.equal(labels.includes(`press:${slug}`), false)
  assert.equal(result.curds[0].status, 'failed')
  assert.match(result.curds[0].excluded_reason, /^taste: .*locked decision broken/)
})

test('a halt lens under an overall pass fails the curd and never reaches press', async () => {
  const { result, labels } = await run({ [`taste:${slug}`]: taste('pass', [lens('pass'), lens(' HALT ', 'violates the lock')]) })
  assert.equal(labels.some((l) => l.startsWith('correct:')), false)
  assert.equal(labels.includes(`press:${slug}`), false)
  assert.match(result.curds[0].excluded_reason, /^taste: .*violates the lock/)
})

test('a revise lens under an overall pass still forces revise', async () => {
  const { labels } = await run({ [`taste:${slug}`]: taste('pass', [lens('revise', 'rework')]), [`correct:${slug}:r1`]: { status: 'fixed', committed: true, head_sha: sha(3) }, [`taste:${slug}:r1`]: taste('pass') })
  assert.ok(labels.includes(`correct:${slug}:r1`))
})

test('a blocked taste answer is final: no redo, and the cleaned reason fails the curd at taste', async () => {
  const { result, labels } = await run({ [`taste:${slug}`]: { status: 'blocked: taste-loop \u0007 stuck' } })
  assert.equal(labels.filter((l) => l.startsWith('taste:')).length, 1)
  assert.equal(result.curds[0].status, 'failed')
  assert.match(result.curds[0].excluded_reason, /^taste: taste reviewer is blocked: taste-loop stuck$/)
})

test('taste dispatches the taste-tester with no model override and states the verdict set', async () => {
  const { trace } = await run({ [`taste:${slug}`]: taste('revise'), [`correct:${slug}:r1`]: { status: 'fixed', committed: true, head_sha: sha(3) }, [`taste:${slug}:r1`]: taste('pass') })
  const tastes = trace.agents.filter(({ opts }) => opts.label.startsWith('taste:'))
  assert.equal(tastes.length, 2)
  for (const { opts, prompt } of tastes) {
    assert.equal(opts.agentType, 'taste-tester')
    assert.equal(opts.model, undefined)
    assert.match(prompt, /is pass, revise, or halt/)
    assert.equal(/\b(?:round|cycle)\s*\d|\bv\d/i.test(prompt), false)
  }
})
