import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow } from './harness.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/move-my-cheese.js')

// ---- fixture builders (match each phase agent's response schema) ----

function reconPr(number, overrides = {}) {
  return {
    number,
    title: `pr ${number}`,
    branch: `feat/pr-${number}`,
    base: 'main',
    state: 'OPEN',
    is_draft: false,
    merge_state: 'CLEAN',
    ci: 'pass',
    failing_run_ids: [],
    head_sha: `head-${number}`,
    aged_sha: '',
    aged_patch: '',
    unresolved_threads: 0,
    url: `https://example.test/pr/${number}`,
    ...overrides,
  }
}

function rescue(number, overrides = {}) {
  return {
    status: 'ok',
    worktree_path: `/tmp/worktrees/pr-${number}`,
    restacked: true,
    melted: false,
    fixes: [],
    infra_flake_run_ids: [],
    committed: true,
    ...overrides,
  }
}

function age(number, hasMediumPlus, overrides = {}) {
  return {
    status: 'ok',
    mode: 'full',
    scope: 'origin/main...HEAD',
    slug: `pr-${number}`,
    artifact: `.cheese/age/pr-${number}.md`,
    worktree_path: `/tmp/worktrees/pr-${number}`,
    has_medium_plus_findings: hasMediumPlus,
    ...overrides,
  }
}

function cure(committed = true) {
  return { status: 'ok', artifact: '.cheese/cure/pr.md', committed }
}

function finalize(number, overrides = {}) {
  return { pushed: true, head_sha: `new-head-${number}`, marker_updated: true, reruns_triggered: [], ...overrides }
}

test('no prs arg returns discover candidates and dispatches no chain agent', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'discover') return { prs: [{ number: 59, title: 'a', branch: 'feat/a', updated_at: '2026-01-01' }] }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: {} })

  assert.equal(result.candidates.length, 1)
  assert.equal(result.candidates[0].number, 59)
  assert.equal(trace.agents.length, 1)
})

test('invalid prs arg fails loud with no agent dispatch', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: () => { throw new Error('no agent expected') } })

  const result = await workflow.run({ ...globals, args: { prs: [59, -2] } })

  assert.match(result.error, /Invalid PR number/)
  assert.equal(trace.agents.length, 0)
})

test('prs as a string is parsed into numbers', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'recon') return { prs: [reconPr(59, { aged_sha: 'head-59', aged_patch: 'p' }), reconPr(60, { aged_sha: 'head-60', aged_patch: 'p' })] }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: '59, 60' })

  assert.equal(trace.agents.length, 1)
  assert.equal(result.summary.fresh, 2)
})

test('fresh PR (CI green, clean, head already aged) skips the whole chain', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'recon') return { prs: [reconPr(59, { aged_sha: 'head-59', aged_patch: 'abc' })] }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { prs: [59] } })

  assert.equal(trace.agents.length, 1)
  assert.equal(result.results[0].status, 'fresh')
})

test('draft, closed, and blocked PRs are skipped with reasons', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'recon') {
        return {
          prs: [
            reconPr(1, { is_draft: true }),
            reconPr(2, { state: 'MERGED' }),
            reconPr(3, { merge_state: 'BLOCKED' }),
          ],
        }
      }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { prs: [1, 2, 3] } })

  assert.equal(trace.agents.length, 1)
  assert.equal(result.summary.skipped, 3)
  assert.match(result.results.find((r) => r.number === 1).reason, /draft/)
  assert.match(result.results.find((r) => r.number === 2).reason, /MERGED/)
  assert.match(result.results.find((r) => r.number === 3).reason, /BLOCKED/)
})

test('dirty+failing PR runs rescue -> age -> finalize and lands clean', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'recon') return { prs: [reconPr(59, { merge_state: 'DIRTY', ci: 'fail', failing_run_ids: [7] })] }
      if (opts.label === 'rescue:59') return rescue(59, { melted: true, fixes: ['fixed assertion'], infra_flake_run_ids: [7] })
      if (opts.label === 'age:59') return age(59, false)
      if (opts.label === 'finalize:59') return finalize(59, { reruns_triggered: [7] })
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { prs: [59] } })

  const r = result.results[0]
  assert.equal(r.status, 'clean')
  assert.equal(r.restacked, true)
  assert.equal(r.melted, true)
  assert.equal(r.pushed, true)
  assert.deepEqual(r.ci_reruns, [7])
  assert.equal(trace.agents.some(({ opts }) => opts.label === 'cure:59'), false)
  // rescue agent runs worktree-isolated; age reuses its worktree (no isolation)
  const rescueCall = trace.agents.find(({ opts }) => opts.label === 'rescue:59')
  assert.equal(rescueCall.opts.isolation, 'worktree')
  const ageCall = trace.agents.find(({ opts }) => opts.label === 'age:59')
  assert.equal(ageCall.opts.isolation, undefined)
})

test('no-rescue-needed PR goes straight to age in its own worktree', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'recon') return { prs: [reconPr(60, { aged_sha: 'old-sha', aged_patch: 'oldpatch' })] }
      if (opts.label === 'age:60') return age(60, false, { mode: 'incremental', scope: 'old-sha..HEAD' })
      if (opts.label === 'finalize:60') return finalize(60)
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { prs: [60] } })

  assert.equal(trace.agents.some(({ opts }) => opts.label === 'rescue:60'), false)
  const ageCall = trace.agents.find(({ opts }) => opts.label === 'age:60')
  assert.equal(ageCall.opts.isolation, 'worktree')
  assert.equal(result.results[0].status, 'clean')
  assert.equal(result.results[0].age_mode, 'incremental')
})

test('age skipped-unchanged runs no cure and still finalizes the marker', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'recon') return { prs: [reconPr(61, { merge_state: 'BEHIND', aged_sha: 'old', aged_patch: 'same' })] }
      if (opts.label === 'rescue:61') return rescue(61)
      if (opts.label === 'age:61') return age(61, false, { mode: 'skipped-unchanged', scope: '', slug: '', artifact: '', worktree_path: '/tmp/worktrees/pr-61' })
      if (opts.label === 'finalize:61') return finalize(61)
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { prs: [61] } })

  assert.equal(trace.agents.some(({ opts }) => opts.label === 'cure:61'), false)
  assert.equal(result.results[0].status, 'clean')
  assert.equal(result.results[0].age_mode, 'skipped-unchanged')
  assert.equal(result.results[0].marker_updated, true)
})

test('medium+ findings trigger cure then re-age; clean re-age lands clean', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'recon') return { prs: [reconPr(62, { ci: 'fail' })] }
      if (opts.label === 'rescue:62') return rescue(62)
      if (opts.label === 'age:62') return age(62, true)
      if (opts.label === 'cure:62') return cure(true)
      if (opts.label === 'reage:62') return age(62, false, { mode: 'incremental' })
      if (opts.label === 'finalize:62') return finalize(62)
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { prs: [62] } })

  assert.equal(result.results[0].status, 'clean')
  assert.equal(result.results[0].cured, true)
  assert.equal(trace.agents.some(({ opts }) => opts.label === 'reage:62'), true)
})

test('re-age still medium+ marks the PR dirty but finalize still pushes', async () => {
  const workflow = await loadWorkflow(path)
  const { globals } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'recon') return { prs: [reconPr(63, { ci: 'fail' })] }
      if (opts.label === 'rescue:63') return rescue(63)
      if (opts.label === 'age:63') return age(63, true)
      if (opts.label === 'cure:63') return cure(true)
      if (opts.label === 'reage:63') return age(63, true, { mode: 'incremental' })
      if (opts.label === 'finalize:63') return finalize(63)
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { prs: [63] } })

  assert.equal(result.results[0].status, 'dirty')
  assert.equal(result.results[0].pushed, true)
})

test('uncommitted cure keeps the age verdict: dirty, no re-age', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'recon') return { prs: [reconPr(64, { ci: 'fail' })] }
      if (opts.label === 'rescue:64') return rescue(64)
      if (opts.label === 'age:64') return age(64, true)
      if (opts.label === 'cure:64') return cure(false)
      if (opts.label === 'finalize:64') return finalize(64)
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { prs: [64] } })

  assert.equal(trace.agents.some(({ opts }) => opts.label === 'reage:64'), false)
  assert.equal(result.results[0].status, 'dirty')
})

test('blocked rescue fails the PR and skips age + finalize', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'recon') return { prs: [reconPr(65, { merge_state: 'DIRTY' })] }
      if (opts.label === 'rescue:65') return rescue(65, { status: 'blocked' })
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { prs: [65] } })

  assert.equal(trace.agents.some(({ opts }) => opts.label === 'age:65'), false)
  assert.equal(trace.agents.some(({ opts }) => opts.label === 'finalize:65'), false)
  assert.equal(result.results[0].status, 'failed')
  assert.match(result.results[0].reason, /rescue/)
})

test('recon missing a requested PR reports it failed without dispatching a chain', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'recon') return { prs: [reconPr(66, { aged_sha: 'head-66' })] }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { prs: [66, 999] } })

  assert.equal(trace.agents.length, 1)
  const missing = result.results.find((r) => r.number === 999)
  assert.equal(missing.status, 'failed')
})

test('unresolved review threads are surfaced in the log for /affinage', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'recon') return { prs: [reconPr(67, { ci: 'fail', unresolved_threads: 3 })] }
      if (opts.label === 'rescue:67') return rescue(67)
      if (opts.label === 'age:67') return age(67, false)
      if (opts.label === 'finalize:67') return finalize(67)
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { prs: [67] } })

  assert.equal(result.results[0].unresolved_threads, 3)
  assert.equal(trace.logs.some((l) => l.includes('/affinage')), true)
})
