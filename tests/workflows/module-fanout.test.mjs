import strictAssert from 'node:assert/strict'
// The module runs in its own realm, so deepEqual compares through JSON.
const assert = { ...strictAssert, deepEqual: (a, e, msg) => strictAssert.deepEqual(JSON.parse(JSON.stringify(a)), e, msg) }
import test from 'node:test'
import { loadModule } from '../../claude/workflow-prelude/load.mjs'

const load = (globals = {}) => loadModule('fanout', { globals })

test('errorMessage_usesMessageOrText', () => {
  const { errorMessage } = load()
  assert.equal(errorMessage(new Error('boom')), 'boom')
  assert.equal(errorMessage('plain'), 'plain')
  assert.equal(errorMessage(null), 'null')
})

test('safeAgent_wrapsValueNullAndThrow', async () => {
  const results = [{ a: 1 }, null, new Error('bad')]
  const { safeAgent } = load({ agent: async () => { const r = results.shift(); if (r instanceof Error) throw r; return r } })
  assert.deepEqual(await safeAgent('p', { label: 'x' }), { ok: true, value: { a: 1 } })
  assert.deepEqual(await safeAgent('p', { label: 'x' }), { ok: false, error: 'agent x returned no result' })
  assert.deepEqual(await safeAgent('p'), { ok: false, error: 'bad' })
})

test('runBounded_keepsOrderAndNeverExceedsTheLimit', async () => {
  const { runBounded } = load()
  let live = 0
  let peak = 0
  const out = await runBounded([5, 1, 4, 2, 3, 0], async (n, i) => {
    live++
    peak = Math.max(peak, live)
    await new Promise((r) => setTimeout(r, n))
    live--
    return `${i}:${n}`
  }, 2)
  assert.deepEqual(out, ['0:5', '1:1', '2:4', '3:2', '4:3', '5:0'])
  assert.equal(peak, 2)
})

test('runBounded_defaultLimitIs4AndEmptyInputWorks', async () => {
  const { runBounded } = load()
  let live = 0
  let peak = 0
  await runBounded(Array.from({ length: 10 }, (_, i) => i), async () => {
    live++
    peak = Math.max(peak, live)
    await new Promise((r) => setTimeout(r, 2))
    live--
  })
  assert.equal(peak, 4)
  assert.deepEqual(await runBounded([], async () => 1), [])
})

test('chunk_splitsIntoGroupsOfAtMostSize', () => {
  const { chunk } = load()
  assert.deepEqual(chunk([1, 2, 3, 4, 5], 2), [[1, 2], [3, 4], [5]])
  assert.deepEqual(chunk([], 3), [])
})

test('dedupe_keepsFirstPerKeyAndReturnsTheDropped', () => {
  const { dedupe } = load()
  const r = dedupe([{ k: 'a', n: 1 }, { k: 'b', n: 2 }, { k: 'a', n: 3 }], (x) => x.k)
  assert.deepEqual(r.kept.map((x) => x.n), [1, 2])
  assert.deepEqual(r.dropped.map((x) => x.n), [3])
})

test('capList_keepsTheFirstMaxAndReturnsTheRest', () => {
  const { capList } = load()
  assert.deepEqual(capList([1, 2, 3, 4], 2), { kept: [1, 2], dropped: [3, 4] })
  assert.deepEqual(capList([1], 5), { kept: [1], dropped: [] })
})

test('withRedo_redoesOnceWithRedoLabelThenGivesNull', async () => {
  const seen = []
  const logs = []
  const { withRedo } = load({ agent: async (p, o) => { seen.push(o.label); return seen.length === 2 ? { ok: 1 } : null }, log: (m) => logs.push(m) })
  assert.deepEqual(await withRedo('p', { label: 'stage' }), { ok: 1 })
  assert.deepEqual(seen, ['stage', 'stage:redo1'])
  assert.match(logs[0], /stage: no result; redoing once/)
  const none = []
  const { withRedo: w2 } = load({ agent: async (p, o) => { none.push(o.label); return null }, log: () => {} })
  assert.equal(await w2('p', { label: 's' }, 2), null)
  assert.deepEqual(none, ['s', 's:redo1', 's:redo2'])
})
