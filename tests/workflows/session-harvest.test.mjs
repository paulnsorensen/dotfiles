import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow } from './harness.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/session-harvest.js')
const SINCE = '2026-07-01T00:00:00Z'

const emptySweep = () => ({ candidates: [], scanned_count: 0 })

function respondSweep({ scripts = emptySweep(), worktrees = emptySweep(), handoffs = emptySweep() } = {}) {
  return ({ opts }) => {
    if (opts.label === 'scripts') return scripts
    if (opts.label === 'worktrees') return worktrees
    if (opts.label === 'handoffs') return handoffs
    throw new Error(`unexpected agent ${opts.label}`)
  }
}

test('session-harvest rejects a missing sinceIso without dispatching any agent', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: () => { throw new Error('agent should not be called') } })

  const result = await workflow.run({ ...globals, args: {} })

  assert.equal(typeof result.error, 'string')
  assert.equal(trace.agents.length, 0)
})

test('session-harvest filters out an already_saved workflow candidate before verify', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: (call) => {
      const { opts } = call
      if (opts.label === 'scripts') {
        return {
          candidates: [
            { name: 'kept-flow', path: 'a.js', occurrences: 2, already_saved: false, why: 'new' },
            { name: 'old-flow', path: 'b.js', occurrences: 3, already_saved: true, why: 'already promoted' },
          ],
          scanned_count: 2,
        }
      }
      if (opts.label === 'worktrees') return emptySweep()
      if (opts.label === 'handoffs') return emptySweep()
      if (opts.label === 'verify:workflow:kept-flow') return { still_relevant: true, evidence: 'checked', reason: 'ok' }
      if (opts.label === 'report') return { rows: [], summary: 'done' }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { sinceIso: SINCE } })

  assert.equal(result.candidates_found, 1)
  assert.equal(trace.agents.some(({ opts }) => opts.label === 'verify:workflow:old-flow'), false)
  assert.equal(trace.agents.some(({ opts }) => opts.label === 'verify:workflow:kept-flow'), true)
})

test('session-harvest aligns verdicts by index and filters out a still_relevant=false candidate', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: respondSweepWithVerify(),
  })

  const result = await workflow.run({ ...globals, args: { sinceIso: SINCE } })

  assert.equal(result.candidates_found, 2)
  assert.equal(result.verified_relevant, 1)
  assert.equal(result.rows.length, 1)
  assert.equal(result.rows[0].candidate, 'kept')

  function respondSweepWithVerify() {
    return ({ opts }) => {
      if (opts.label === 'scripts') {
        return {
          candidates: [
            { name: 'stale', path: 'a.js', occurrences: 2, already_saved: false, why: '' },
            { name: 'live', path: 'b.js', occurrences: 2, already_saved: false, why: '' },
          ],
          scanned_count: 2,
        }
      }
      if (opts.label === 'worktrees') return emptySweep()
      if (opts.label === 'handoffs') return emptySweep()
      if (opts.label === 'verify:workflow:stale') return { still_relevant: false, evidence: 'already promoted', reason: 'gone' }
      if (opts.label === 'verify:workflow:live') return { still_relevant: true, evidence: 'still missing', reason: 'ok' }
      if (opts.label === 'report') return { rows: [{ candidate: 'kept', kind: 'workflow', where: 'b.js', why_it_matters: 'x', suggested_action: 'y' }], summary: 'done' }
      throw new Error(`unexpected agent ${opts.label}`)
    }
  }
})

test('session-harvest short-circuits with an empty report when the sweep finds nothing', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: respondSweep() })

  const result = await workflow.run({ ...globals, args: { sinceIso: SINCE } })

  assert.equal(result.candidates_found, 0)
  assert.equal(result.verified_relevant, 0)
  assert.equal(result.rows.length, 0)
  assert.equal(trace.agents.some(({ opts }) => opts.phase === 'Verify' || opts.phase === 'Report'), false)
})

test('session-harvest short-circuits with an empty report when every candidate is rejected by verify', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'scripts') return { candidates: [{ name: 'gone', path: 'a.js', occurrences: 2, already_saved: false, why: '' }], scanned_count: 1 }
      if (opts.label === 'worktrees') return emptySweep()
      if (opts.label === 'handoffs') return emptySweep()
      if (opts.label === 'verify:workflow:gone') return { still_relevant: false, evidence: 'promoted since', reason: 'done' }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { sinceIso: SINCE } })

  assert.equal(result.candidates_found, 1)
  assert.equal(result.verified_relevant, 0)
  assert.equal(result.rows.length, 0)
  assert.equal(trace.agents.some(({ opts }) => opts.label === 'report'), false)
})

test('session-harvest caps candidates at MAX_CANDIDATES before the verify pipeline and logs the truncation', async () => {
  const workflow = await loadWorkflow(path)
  const scripts = {
    candidates: Array.from({ length: 60 }, (_, i) => ({ name: `flow-${i}`, path: `${i}.js`, occurrences: 2, already_saved: false, why: '' })),
    scanned_count: 60,
  }
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'scripts') return scripts
      if (opts.label === 'worktrees') return emptySweep()
      if (opts.label === 'handoffs') return emptySweep()
      if (opts.label.startsWith('verify:')) return { still_relevant: true, evidence: 'checked', reason: 'ok' }
      if (opts.label === 'report') return { rows: [], summary: 'done' }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { sinceIso: SINCE } })

  const verifyCalls = trace.agents.filter(({ opts }) => opts.label.startsWith('verify:'))
  assert.equal(verifyCalls.length, 50)
  assert.equal(result.candidates_found, 50)
  assert.match(trace.logs.join('\n'), /60 candidate\(s\) exceeds max 50; truncating before verify\./)
})

test('session-harvest rejects a devRoot with shell metacharacters and falls back to the default', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: respondSweep() })

  const result = await workflow.run({ ...globals, args: { sinceIso: SINCE, devRoot: '~/Dev; rm -rf /' } })

  assert.equal(result.devRoot, '~/Dev')
  assert.match(trace.logs.join('\n'), /devRoot .* contains unsafe characters; falling back to ~\/Dev\./)
})

test('session-harvest rejects a malformed sinceIso without dispatching any agent', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: () => { throw new Error('agent should not be called') } })

  const result = await workflow.run({ ...globals, args: { sinceIso: 'not-a-date' } })

  assert.equal(typeof result.error, 'string')
  assert.equal(trace.agents.length, 0)
  assert.match(trace.logs.join('\n'), /does not look like an ISO-8601 timestamp/)
})
