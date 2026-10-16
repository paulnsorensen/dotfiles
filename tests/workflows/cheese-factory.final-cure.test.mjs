// Final-cure tests: the producer redoes a review that omits an outcome key or whose repair rewrites an outcome, and a run with no plated curd is partial.
import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime } from './harness.mjs'
import { loadWorkflow } from './cheese-factory.fixtures.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/cheese-factory.js')

const sha = (n) => n.toString(16).padStart(40, '0')
const BASE_SHA = sha(0xba5e)
const HEAD = sha(0x1ead)
const NEW_HEAD = sha(0x2ead)
const CURE_SHA = sha(0xc0de)
const SCRATCH = (name) => `/repo/.claude/worktrees/${name}`

const finding = { dimension: 'correctness', severity: 'medium', fix_cost_now: 'n/a', file: 'src/parent.js', line: 1, claim: 'c', why_it_matters: 'm', fix_direction: 'f' }
const review = (extra = {}) => ({ status: 'ok', artifact: '.cheese/age/x.md', has_medium_plus_findings: false, findings: [], reviewed_slugs: ['parent'], ...extra })
const integrated = (head = HEAD, worktree = 'integ') => ({ worktree_path: SCRATCH(worktree), merged: ['parent'], conflicted: [], head, files_by_slug: { parent: ['src/parent.js'] }, files_changed: 5, lines_changed: 50 })
const tasteOk = { verdict: 'pass', lenses: [{ lens: 'drift', verdict: 'pass', note: '' }], issues: [], recommendation: 'pass' }
const approve = { verdict: 'approve', concerns: [], guidance: '' }

const defaults = {
  resolve: { mode: 'resolved', base_sha: BASE_SHA, spec_path: '/specs/parent.md', spec_text: 'spec body', curd_count: { slug: 'parent', candidate_curds: 1, blast_radius: 'medium' } },
  ground: { decisions: [], prior_research: [], research_questions: [] },
  'advise:plan': approve,
  'advise:done': approve,
  'cook:parent': { status: 'ok', head_sha: sha(1), worktree_path: SCRATCH('cook'), artifact: '.cheese/cook/parent.md', orientation: 'done' },
  'taste:parent': tasteOk,
  'press:parent': { status: 'ok', head_sha: sha(2), artifact: '.cheese/press/parent.md', orientation: 'ok' },
  integrate: integrated(),
  'age:barrier': review(),
  'cure:parent': { status: 'ok', committed: true, head_sha: CURE_SHA, artifact: '.cheese/cure/x.md' },
  're-merge': integrated(NEW_HEAD, 'remerge'),
  plate: { results: [{ slug: 'parent', status: 'ok', pr_url: 'https://example.test/pr' }] },
  cleanup: { removed: [] },
}

async function run(over = {}) {
  const table = { ...defaults, ...over }
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: (call) => {
      const key = [call.opts.label, call.opts.label.replace(/:(?:redo|repair)\d+$/, '')].find((k) => Object.hasOwn(table, k))
      if (key === undefined) throw new Error(`unexpected agent ${call.opts.label}`)
      const entry = table[key]
      return typeof entry === 'function' ? entry(call) : entry
    },
  })
  const result = await workflow.run({ ...globals, args: { spec: 'parent' } })
  return { result, labels: trace.agents.map(({ opts }) => opts.label) }
}

const starting = (labels, prefix) => labels.filter((l) => l.startsWith(prefix))

// ---- finding 1: a missing outcome key is substance ----

for (const missing of ['has_medium_plus_findings', 'findings']) {
  test(`checkAge_okAnswerMissing_${missing}_redoesTheReviewWithoutFormatterRepair`, async () => {
    const { labels } = await run({
      'age:barrier': (call) => {
        if (!/:redo1$/.test(call.opts.label)) { const v = review(); delete v[missing]; return v }
        return review()
      },
    })

    assert.ok(labels.includes('age:barrier:redo1'), 'the reviewer must redo')
    assert.equal(labels.includes('age:barrier:repair1'), false, 'a formatter must not invent the outcome')
  })
}

test('checkAge_validAnswer_passesWithoutRedoOrRepair', async () => {
  const { labels, result } = await run()

  assert.deepEqual(starting(labels, 'age:barrier'), ['age:barrier'])
  assert.equal(result.curds[0].status, 'clean')
})

for (const missing of ['verdict', 'lenses']) {
  test(`checkTaste_missing_${missing}_redoesTheReviewWithoutFormatterRepair`, async () => {
    const { labels } = await run({
      'taste:parent': (call) => {
        if (!/:redo1$/.test(call.opts.label)) { const v = { ...tasteOk }; delete v[missing]; return v }
        return tasteOk
      },
    })

    assert.ok(labels.includes('taste:parent:redo1'))
    assert.equal(labels.includes('taste:parent:repair1'), false)
  })
}

for (const missing of ['has_medium_plus_findings', 'findings', 'reviewed_slugs']) {
  test(`checkReage_okAnswerMissing_${missing}_redoesTheReviewWithoutFormatterRepair`, async () => {
    const { labels } = await run({
      'age:barrier': review({ has_medium_plus_findings: true, findings: [finding] }),
      'age:reage': (call) => {
        const v = review({ mode: 'incremental' })
        if (!/:redo1$/.test(call.opts.label)) delete v[missing]
        return v
      },
    })

    assert.ok(labels.includes('age:reage:redo1'))
    assert.equal(labels.includes('age:reage:repair1'), false)
  })
}

// Control: a taste answer that omits only issues keeps its form classification, so the formatter repairs it.
test('checkTaste_missingIssues_stillUsesFormatterRepairAndNoRedo', async () => {
  const { labels } = await run({
    'taste:parent': (call) => {
      const { issues, ...rest } = tasteOk
      return /:repair1$/.test(call.opts.label) ? tasteOk : rest
    },
  })

  assert.ok(labels.includes('taste:parent:repair1'))
  assert.equal(labels.includes('taste:parent:redo1'), false)
})

// A formatter repair that rewrites a decision field changes the review, so the reviewer redoes the call.
test('checkTaste_repairChangesLensVerdict_redoesTheReview', async () => {
  const revise = { ...tasteOk, lenses: [{ lens: 'drift', verdict: 'revise', note: 'n' }] }
  const { labels } = await run({
    'taste:parent': (call) => {
      const { issues, ...rest } = tasteOk
      if (/:repair1$/.test(call.opts.label)) return revise
      return /:redo2$/.test(call.opts.label) ? tasteOk : rest
    },
  })

  assert.ok(labels.includes('taste:parent:repair1'))
  assert.ok(labels.includes('taste:parent:redo2'), 'a rewritten lens verdict must make the reviewer redo')
})

// The redo after a drifting repair must still carry the original form errors, or the producer cannot fix them.
test('checkTaste_repairDrifts_redoPromptKeepsOriginalErrorsAndProducerFixes', async () => {
  const revise = { ...tasteOk, lenses: [{ lens: 'drift', verdict: 'revise', note: 'n' }] }
  const prompts = []
  const { labels } = await run({
    'taste:parent': (call) => {
      const { issues, ...rest } = tasteOk
      if (/:repair1$/.test(call.opts.label)) return revise
      if (/:redo2$/.test(call.opts.label)) { prompts.push(call.prompt); return tasteOk }
      return rest
    },
  })

  assert.equal(prompts.length, 1)
  assert.match(prompts[0], /\$\.issues is required/)
  assert.match(prompts[0], /fix the original errors yourself/)
  assert.equal(labels.includes('taste:parent:redo3'), false, 'the fixed redo must pass')
})

// The producer may write "Pass" and omit issues; the repair writes "pass". Case alone is not a decision change.
test('checkTaste_lensVerdictCaseDiffers_repairIsNotDrift', async () => {
  const { labels, result } = await run({
    'taste:parent': (call) => {
      if (/:repair1$/.test(call.opts.label)) return tasteOk
      const { issues, ...rest } = tasteOk
      return { ...rest, lenses: [{ lens: 'drift', verdict: 'Pass', note: '' }] }
    },
  })

  assert.ok(labels.includes('taste:parent:repair1'))
  assert.equal(labels.some((l) => /:redo\d+$/.test(l) && l.startsWith('taste:parent')), false)
  assert.equal(result.curds[0].status, 'clean')
})

// The age shapes have no form-only error that the runtime schema lets through, so this test drives the shared list rule through the taste lenses.
test('checkTaste_repairDropsLens_redoesTheReview', async () => {
  const two = { ...tasteOk, lenses: [{ lens: 'drift', verdict: 'pass', note: '' }, { lens: 'scope', verdict: 'pass', note: '' }] }
  const { labels } = await run({
    'taste:parent': (call) => {
      const { issues, ...rest } = two
      if (/:repair1$/.test(call.opts.label)) return { ...two, lenses: [two.lenses[0]] }
      return /:redo2$/.test(call.opts.label) ? two : rest
    },
  })

  assert.ok(labels.includes('taste:parent:repair1'))
  assert.ok(labels.includes('taste:parent:redo2'), 'a dropped lens must make the reviewer redo')
})

// ---- finding 2: top-level status ----

test('report_everyCookFails_statusIsPartial', async () => {
  const { result, labels } = await run({ 'cook:parent': { status: 'blocked', reason: 'cannot start' } })

  assert.equal(result.curds[0].status, 'failed')
  assert.equal(labels.includes('plate'), false)
  assert.equal(result.status, 'partial')
})

test('report_oneDirtyCurd_statusIsPartial', async () => {
  const { result } = await run({
    'age:barrier': review({ has_medium_plus_findings: true, findings: [finding] }),
    'cure:parent': { status: 'blocked', reason: 'no fix' },
    'age:reage': review({ mode: 'incremental' }),
  })

  assert.notEqual(result.curds[0].status, 'clean')
  assert.equal(result.status, 'partial')
})

test('report_allCurdsCleanAndPlated_statusIsOk', async () => {
  const { result } = await run()

  assert.equal(result.curds[0].status, 'clean')
  assert.equal(result.status, 'ok')
})
