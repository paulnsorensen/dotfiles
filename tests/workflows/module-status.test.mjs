import strictAssert from 'node:assert/strict'
// The module runs in its own realm, so deepEqual compares through JSON.
const assert = { ...strictAssert, deepEqual: (a, e, msg) => strictAssert.deepEqual(JSON.parse(JSON.stringify(a)), e, msg) }
import test from 'node:test'
import { loadModule } from '../../claude/workflow-prelude/load.mjs'

const logs = []
const m = loadModule('status', { globals: { log: (s) => logs.push(s) } })

test('status_tableHoldsTheKnownStatuses', () => {
  assert.deepEqual({ ...m.STATUS }, { ok: 'ok', partial: 'partial', blocked: 'blocked', needsInput: 'needs-input', needsApproval: 'needs-approval' })
  assert.equal(Object.isFrozen(m.STATUS), true)
})

test('finish_mergesBaseThenStatusThenExtra', () => {
  const base = { items: [], gaps: ['g'], status: 'stale' }
  assert.deepEqual(m.finish('blocked', { reason: 'r' }, base), { items: [], gaps: ['g'], status: 'blocked', reason: 'r' })
  assert.deepEqual(m.finish('ok'), { status: 'ok' })
  assert.deepEqual(m.finish('ok', { items: [1] }, base).items, [1])
})

test('blockedResult_usesTheReasonKey', () => {
  const r = m.blockedResult('no budget', { hint: 1 }, { gaps: [] })
  assert.deepEqual(r, { gaps: [], status: 'blocked', reason: 'no budget', hint: 1 })
  assert.equal('error' in r, false)
})

test('gapField_isPureAndEmptyWithoutGaps', () => {
  assert.deepEqual(m.gapField([]), {})
  assert.deepEqual(m.gapField(['a']), { gaps: ['a'] })
})

test('report_logsTheNoteAndAlwaysReturnsANoteString', () => {
  logs.length = 0
  assert.deepEqual(m.report('ok', 'done', { digest: 'd' }), { status: 'ok', note: 'done', digest: 'd' })
  assert.deepEqual(logs, ['done'])
  assert.deepEqual(m.report('ok', ''), { status: 'ok', note: '' })
  assert.deepEqual(logs, ['done'])
})

test('donePayload_dropsUndefinedAndLetsExtraWin', () => {
  assert.deepEqual(m.donePayload({ a: 1, b: undefined, c: 0 }, { c: 2, d: undefined, e: null }), { a: 1, c: 2, e: null })
})

test('runStatus_isOkOnlyWhenProducedCleanAndUnstopped', () => {
  const clean = [{ status: 'clean' }]
  assert.equal(m.runStatus({ produced: 1, rows: clean }), 'ok')
  assert.equal(m.runStatus({ produced: 1, rows: clean, stopped: 'budget' }), 'partial')
  assert.equal(m.runStatus({ produced: 1, rows: clean, gaps: ['g'] }), 'partial')
  assert.equal(m.runStatus({ produced: 0, rows: clean }), 'partial')
  assert.equal(m.runStatus({ produced: 1, rows: [{ status: 'dirty' }] }), 'partial')
  assert.equal(m.runStatus(), 'partial')
})

test('countStatuses_seedsCleanDirtyFailedAndCountsOthers', () => {
  assert.deepEqual(m.countStatuses([{ status: 'clean' }, { status: 'clean' }, { status: 'weird' }]), { clean: 2, dirty: 0, failed: 0, weird: 1 })
  assert.deepEqual(m.countStatuses([{ status: 'a' }], {}), { a: 1 })
})
