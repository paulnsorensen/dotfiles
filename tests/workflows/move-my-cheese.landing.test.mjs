// move-my-cheese landing hop (AC-22): { prs, landing, approve } reads the saved plan and runs no planner or advisor.
import assert from 'node:assert/strict'
import test from 'node:test'

import { approve, builtConsolidation, envelope, failure, plain, run } from './move-my-cheese.fixtures.mjs'

const HEX16 = /^[0-9a-f]{16}$/

async function planned() {
  const { first, args } = await approve(builtConsolidation())
  return { first, args, landing: plain(first.result.landing) }
}

test('needs-approval saves the landing and returns its id next to the landing object', async () => {
  const { first, landing } = await planned()
  assert.equal(first.result.status, 'needs-approval')
  assert.match(first.result.landing_id, HEX16)
  assert.deepEqual(plain(first.result.landing), landing)
  assert.ok(first.wfxLabels.includes('state:put'))
  const put = first.call('state:put').prompt
  assert.ok(put.includes(`wfx run-state put --landing ${first.result.landing_id} --key plan`))
  assert.ok(put.includes('printf'))
  assert.match(first.result.usage, /landing: landing_id/)
  assert.match(first.result.usage, /plan: landing/)
})

test('a failed save leaves landing_id empty and keeps the landing object', async () => {
  const { first } = await approve(builtConsolidation([['state:put', failure('run-state', 'io-error', 'disk full')]]))
  assert.equal(first.result.status, 'needs-approval')
  assert.equal(first.result.landing_id, '')
  assert.ok(first.result.landing.plan)
})

test('the landing hop reads the saved plan and runs no planner or advisor', async () => {
  const { first, landing } = await planned()
  const hop = await run(
    { prs: [1, 2], landing: first.result.landing_id, approve: first.result.digest },
    builtConsolidation([['state:get', envelope('run-state', { value: landing })]]),
  )
  assert.notEqual(hop.result.status, 'blocked')
  assert.ok(hop.wfxLabels.includes('state:get'))
  assert.ok(hop.call('state:get').prompt.includes(`wfx run-state get --landing ${first.result.landing_id} --key plan`))
  assert.equal(hop.labels.some((l) => l.startsWith('plan') || l.startsWith('advise:plan') || l.startsWith('survey') || l.startsWith('tensions')), false)
  assert.equal(hop.labels.some((l) => l.startsWith('target:')), true)
})

// Live run 2026-10-16: the haiku runner wrapped the printed envelope in an envelope of its own, so data.value was absent.
test('the landing hop unwraps an envelope that the runner nested inside its own', async () => {
  const { first, landing } = await planned()
  const nested = { ok: true, cmd: `wfx run-state get --landing ${first.result.landing_id} --key plan`, data: envelope('run-state', { landing: first.result.landing_id, key: 'plan', value: landing }) }
  const hop = await run(
    { prs: [1, 2], landing: first.result.landing_id, approve: first.result.digest },
    builtConsolidation([['state:get', nested]]),
  )
  assert.notEqual(hop.result.status, 'blocked', JSON.stringify(hop.result))
  assert.equal(hop.labels.some((l) => l.startsWith('target:')), true)
})

test('the long form with the plan object still works and reads no saved state', async () => {
  const { args } = await planned()
  const hop = await run(args, builtConsolidation())
  assert.notEqual(hop.result.status, 'blocked')
  assert.equal(hop.wfxLabels.includes('state:get'), false)
})

test('a saved plan whose digest differs from approve is refused', async () => {
  const { first, landing } = await planned()
  const edited = { ...landing, plan: { ...landing.plan, summary: 'edited' } }
  const hop = await run(
    { prs: [1, 2], landing: first.result.landing_id, approve: first.result.digest },
    builtConsolidation([['state:get', envelope('run-state', { value: edited })]]),
  )
  assert.equal(hop.result.status, 'blocked')
  assert.match(hop.result.error, /the saved plan/)
  assert.equal(hop.labels.some((l) => l.startsWith('target:')), false)
})

test('a saved plan under another landing id is refused', async () => {
  const { first, landing } = await planned()
  const hop = await run(
    { prs: [1, 2], landing: '0123456789abcdef', approve: first.result.digest },
    builtConsolidation([['state:get', envelope('run-state', { value: landing })]]),
  )
  assert.equal(hop.result.status, 'blocked')
  assert.match(hop.result.error, /does not match args\.landing/)
})

test('a missing saved plan blocks with the state error', async () => {
  const { first } = await planned()
  const hop = await run(
    { prs: [1, 2], landing: first.result.landing_id, approve: first.result.digest },
    builtConsolidation([['state:get', failure('run-state', 'not-found', 'no such key')]]),
  )
  assert.equal(hop.result.status, 'blocked')
  assert.match(hop.result.error, /no such key/)
})

test('a landing id that is not 16 hex digits, or that comes with a plan, blocks before any agent', async () => {
  const { first, args } = await planned()
  const bad = await run({ prs: [1, 2], landing: 'nope', approve: first.result.digest }, [])
  assert.equal(bad.result.status, 'blocked')
  assert.equal(bad.raw.agents.length, 0)
  const both = await run({ ...args, landing: first.result.landing_id }, [])
  assert.equal(both.result.status, 'blocked')
  assert.equal(both.raw.agents.length, 0)
})
