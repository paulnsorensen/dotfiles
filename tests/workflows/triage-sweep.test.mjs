import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow } from './harness.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/triage-sweep.js')

const item = (number, title) => ({ number, kind: 'issue', title })
const grounded = (entry, verdict) => ({
  ...entry,
  verdict,
  evidence: [{ claim: 'checked', citation: 'file:1' }],
  summary: 'summary',
  recommendation: 'fix now',
})

test('triage-sweep coerces a repo string and verifies only close-worthy verdicts', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'gather') return { items: [
        item(1, 'valid'), item(2, 'needs-info'), item(3, 'stale'), item(4, 'superseded'),
      ] }
      if (opts.label === 'ground:issue#1') return grounded(item(1, 'valid'), 'valid')
      if (opts.label === 'ground:issue#2') return grounded(item(2, 'needs-info'), 'needs-info')
      if (opts.label === 'ground:issue#3') return grounded(item(3, 'stale'), 'stale')
      if (opts.label === 'ground:issue#4') return grounded(item(4, 'superseded'), 'superseded')
      if (opts.label === 'verify:issue#3') return { number: 3, refuted: false, final_verdict: 'stale', note: 'confirmed' }
      if (opts.label === 'verify:issue#4') return { number: 4, refuted: false, final_verdict: 'superseded', note: 'confirmed' }
      if (opts.label === 'route') return { routed: [], summary: 'done' }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: 'owner/name' })

  assert.equal(result.grounded.filter((entry) => entry.verify).length, 2)
  assert.deepEqual(trace.agents.map(({ opts }) => opts.label), [
    'gather', 'ground:issue#1', 'ground:issue#2', 'ground:issue#3', 'ground:issue#4',
    'verify:issue#3', 'verify:issue#4', 'route',
  ])
  assert.equal(trace.agents.some(({ opts }) => opts.label === 'verify:issue#1' || opts.label === 'verify:issue#2'), false)
  assert.match(trace.agents[0].prompt, /Repo: owner\/name\./)
  assert.match(trace.agents[0].prompt, /Scope: both/)
  assert.match(trace.agents[0].prompt, /Limit: 30/)
})

test('triage-sweep defaults absent args to both scopes and a limit of 30', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: () => ({ items: [] }) })

  await workflow.run({ ...globals, args: undefined })

  assert.match(trace.agents[0].prompt, /Scope: both/)
  assert.match(trace.agents[0].prompt, /Limit: 30/)
})

test('triage-sweep drops an item whose Ground agent fails but still completes other items', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'gather') return { items: [item(1, 'broken'), item(2, 'valid')] }
      if (opts.label === 'ground:issue#1') throw new Error('ground agent crashed')
      if (opts.label === 'ground:issue#2') return grounded(item(2, 'valid'), 'valid')
      if (opts.label === 'route') return { routed: [], summary: 'done' }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: 'owner/name' })

  assert.equal(result.items.length, 2)
  assert.equal(result.grounded.length, 1)
  assert.equal(result.grounded[0].item.number, 2)
  assert.equal(trace.agents.some(({ opts }) => opts.label === 'verify:issue#1'), false)
})

test('a crashed verify never lets a close-worthy item look verified, and routes it to needs-human', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'gather') return { items: [item(3, 'stale one'), item(4, 'superseded one')] }
      if (opts.label === 'ground:issue#3') return grounded(item(3, 'stale one'), 'stale')
      if (opts.label === 'ground:issue#4') return grounded(item(4, 'superseded one'), 'superseded')
      if (opts.label === 'verify:issue#3') throw new Error('verify agent crashed')
      if (opts.label === 'verify:issue#4') return { number: 4, refuted: true, final_verdict: 'valid', note: 'found the fix was never merged' }
      if (opts.label === 'route') return { routed: [], summary: 'done' }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: 'owner/name' })

  const crashed = result.grounded.find((g) => g.item.number === 3)
  const refuted = result.grounded.find((g) => g.item.number === 4)

  // A crashed verify must never masquerade as a clean skip (verify:null already means
  // "not close-worthy" elsewhere) — it must be flagged so Route can never close it.
  assert.equal(crashed.verify, null)
  assert.equal(crashed.verifyFailed, true)
  assert.match(trace.logs.join('\n'), /Verify crashed for issue#3/)

  // A verify that ran and refuted the close verdict must surface the refutation, not verifyFailed.
  assert.equal(refuted.verifyFailed, false)
  assert.equal(refuted.verify.refuted, true)
  assert.equal(refuted.verify.final_verdict, 'valid')

  const routePrompt = trace.agents.find(({ opts }) => opts.label === 'route').prompt
  assert.match(routePrompt, /"verifyFailed": true/)
  assert.match(routePrompt, /"refuted": true/)
})

test('triage-sweep accepts object-form args and rejects a repo containing a space', async () => {
  const workflow = await loadWorkflow(path)

  const { globals: goodGlobals, trace: goodTrace } = createRuntime({ respond: () => ({ items: [] }) })
  await workflow.run({ ...goodGlobals, args: { repo: 'owner/name', scope: 'issues', limit: 5 } })
  assert.match(goodTrace.agents[0].prompt, /Repo: owner\/name\./)
  assert.match(goodTrace.agents[0].prompt, /Scope: issues/)
  assert.match(goodTrace.agents[0].prompt, /Limit: 5/)

  const { globals: badGlobals, trace: badTrace } = createRuntime({ respond: () => ({ items: [] }) })
  await workflow.run({ ...badGlobals, args: { repo: 'owner/name; rm -rf /' } })
  assert.match(badTrace.agents[0].prompt, /Repo: the current directory's repo/)
})

test('triage-sweep with scope=issues only asks gh for issues, never PRs', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: () => ({ items: [] }) })

  await workflow.run({ ...globals, args: { scope: 'issues' } })

  assert.match(trace.agents[0].prompt, /gh issue list/)
  assert.doesNotMatch(trace.agents[0].prompt, /gh pr list/)
})
