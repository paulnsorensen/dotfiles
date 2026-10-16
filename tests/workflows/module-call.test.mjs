import assert from 'node:assert/strict'
import test from 'node:test'
import { loadModule } from '../../claude/workflow-prelude/load.mjs'

// The vm context has its own Object prototype, so compare values through JSON.
const plain = (v) => JSON.parse(JSON.stringify(v))

// Loads the call module with a scripted agent. respond(text, opts, n) returns an answer or throws; n counts calls from 1.
function setup(respond, { fixRounds = 2 } = {}) {
  const calls = []
  const logs = []
  const agent = async (text, opts) => {
    calls.push({ text, opts })
    return respond(text, opts, calls.length)
  }
  const mod = loadModule('call', { globals: { PREAMBLE: 'PRE', LIMITS: { fixRounds }, agent, log: (m) => logs.push(m) } })
  return { ...mod, calls, logs, labels: () => calls.map((c) => c.opts.label) }
}

const READ = { label: 'x', phase: 'P', agentType: 'explorer', schema: { type: 'object' } }
const WRITE = { ...READ, agentType: 'coder' }
const ok = () => []
const boom = () => { throw new Error('boom') }

test('unwrapEnvelope returns the innermost wfx envelope and leaves a plain one alone', () => {
  const { unwrapEnvelope } = setup(ok)
  const inner = { ok: true, cmd: 'run-state', data: { value: { a: 1 } } }
  assert.deepEqual(plain(unwrapEnvelope({ ok: true, cmd: 'wfx run-state get', data: inner })), inner)
  assert.deepEqual(plain(unwrapEnvelope({ ok: true, cmd: 'x', data: { ok: true, cmd: 'y', data: inner } })), inner)
  assert.deepEqual(plain(unwrapEnvelope(inner)), inner)
  assert.equal(unwrapEnvelope(null), null)
})

test('wfxCommandOf names the last wfx command in a command line', () => {
  const { wfxCommandOf } = setup(ok)
  assert.equal(wfxCommandOf('wfx preflight --worktree /x'), 'preflight')
  assert.equal(wfxCommandOf("printf '%s' 'a b' | wfx run-state put --landing 1 --key plan"), 'run-state')
  assert.equal(wfxCommandOf('git fetch --quiet origin && wfx restack --repo r'), 'restack')
  assert.equal(wfxCommandOf('sleep 540 && wfx poll --pr 2'), 'poll')
  assert.equal(wfxCommandOf('gh pr list --head x'), '')
  assert.equal(wfxCommandOf('echo nowfx thing'), '')
})

// AC-5
test('typed_readOnlyThrowThenAnswer_retriesOnceAndKeepsTheAnswer', async () => {
  const t = setup((text, opts, n) => (n === 1 ? boom() : { v: 1 }))
  const r = await t.typed('q', READ, ok)
  assert.deepEqual(plain(r), { value: { v: 1 }, errors: [], lost: null, threw: false })
  assert.deepEqual(t.labels(), ['x', 'x:retry1'])
  assert.match(t.logs.join('\n'), /x: agent threw: boom/)
})

test('typed_readOnlyThrowTwice_returnsThrewAfterOneRetry', async () => {
  const t = setup(boom)
  const r = await t.typed('q', READ, ok)
  assert.equal(r.threw, true)
  assert.equal(r.lost, 'threw')
  assert.equal(r.value, null)
  assert.match(r.errors[0].msg, /agent threw: boom/)
  assert.deepEqual(t.labels(), ['x', 'x:retry1'])
})

test('typed_writerThrow_isNotRetried', async () => {
  for (const opts of [WRITE, { ...READ, agentType: 'builder', isolation: 'worktree' }]) {
    const t = setup(boom)
    const r = await t.typed('q', opts, ok)
    assert.equal(r.threw, true, opts.agentType)
    assert.equal(r.lost, 'threw')
    assert.deepEqual(t.labels(), ['x'], opts.agentType)
  }
})

test('typed_reviewerWorktreeThrow_retriesBecauseItOnlyHoldsReports', async () => {
  const t = setup(boom)
  await t.typed('q', { ...READ, agentType: 'reviewer', isolation: 'worktree' }, ok)
  assert.deepEqual(t.labels(), ['x', 'x:retry1'])
})

test('typed_throwInsideRedo_countsAsTheSameSingleRetry', async () => {
  const t = setup((text, opts, n) => (n === 1 ? { bad: 1 } : n === 2 ? boom() : { good: 1 }))
  const r = await t.typed('q', READ, (v) => (v.good ? [] : [t.substance('needs facts')]))
  assert.deepEqual(t.labels(), ['x', 'x:redo1', 'x:retry2'])
  assert.deepEqual(plain(r.value), { good: 1 })
})

// AC-6: one test per hook
test('typed_normalizeHook_runsBeforeTheCheckAndShapesTheReturnedValue', async () => {
  const t = setup(() => ({ status: ' OK ' }))
  const seen = []
  const r = await t.typed('q', READ, (v) => { seen.push(v.status); return [] }, { normalize: (v) => ({ ...v, status: v.status.trim().toLowerCase() }) })
  assert.deepEqual(seen, ['ok'])
  assert.equal(r.value.status, 'ok')
  const plainRun = await setup(() => ({ status: ' OK ' })).typed('q', READ, ok)
  assert.equal(plainRun.value.status, ' OK ', 'no hook leaves the value alone')
})

test('typed_expandShasHook_runsOnceAfterAFailedCheckAndTheExpandedValueIsRechecked', async () => {
  const t = setup(() => ({ sha: 'abc1234' }))
  const full = 'a'.repeat(40)
  const expandCalls = []
  const r = await t.typed('q', READ, (v) => (v.sha.length === 40 ? [] : [t.form('sha must be full')]), {
    expandShas: async (value, opts) => { expandCalls.push({ value: plain(value), label: opts.label }); return { ...value, sha: full } },
  })
  assert.deepEqual(expandCalls, [{ value: { sha: 'abc1234' }, label: 'x' }])
  assert.equal(r.value.sha, full)
  assert.equal(t.calls.length, 1, 'the expansion replaced a repair call')
})

test('typed_expandShasHook_isSkippedWhenTheCheckPassesOrTheHookReturnsNull', async () => {
  const passing = setup(() => ({ sha: 'abc1234' }))
  let called = 0
  await passing.typed('q', READ, ok, { expandShas: async () => { called++; return null } })
  assert.equal(called, 0)
  const failing = setup(() => ({ sha: 'abc1234' }))
  const r = await failing.typed('q', READ, () => [failing.form('bad')], { expandShas: async () => { called++; return null } })
  assert.equal(called, 1, 'runs once even though the repair rounds fail again')
  assert.equal(r.value, null)
})

test('typed_onWorktreeHook_runsForIsolatedCallsOnlyWithTheNormalizedValue', async () => {
  const seen = []
  const hooks = { normalize: (v) => ({ ...v, n: 1 }), onWorktree: (value, opts) => seen.push({ value: plain(value), label: opts.label }) }
  const iso = setup(() => ({ worktree_path: '/w' }))
  await iso.typed('q', { ...WRITE, isolation: 'worktree' }, ok, hooks)
  assert.deepEqual(seen, [{ value: { worktree_path: '/w', n: 1 }, label: 'x' }])
  const plainCall = setup(() => ({ worktree_path: '/w' }))
  await plainCall.typed('q', READ, ok, hooks)
  assert.equal(seen.length, 1, 'a call without isolation records nothing')
})

test('typed_onWorktreeHook_runsForEveryAnswerSoARejectedAttemptIsStillRecorded', async () => {
  const seen = []
  const t = setup((text, opts, n) => ({ worktree_path: `/w${n}`, ok: n === 2 }))
  await t.typed('q', { ...READ, isolation: 'worktree', agentType: 'reviewer' }, (v) => (v.ok ? [] : [t.substance('redo')]), { onWorktree: (v) => seen.push(v.worktree_path) })
  assert.deepEqual(seen, ['/w1', '/w2'])
})

test('typed_nullIsFinalHook_stopsAtOnceOnANullAnswerWithLostMissing', async () => {
  const final = setup(() => null)
  const r = await final.typed('q', WRITE, ok, { nullIsFinal: true })
  assert.deepEqual(plain({ value: r.value, lost: r.lost, threw: r.threw }), { value: null, lost: 'missing', threw: false })
  assert.equal(final.calls.length, 1, 'no redo of a writer')
  const open = setup(() => null)
  const o = await open.typed('q', WRITE, ok)
  assert.equal(o.lost, 'missing')
  assert.deepEqual(open.labels(), ['x', 'x:redo1', 'x:redo2'])
})

test('typed_nullIsFinalHook_stillRedoesAnInvalidValueAndSkipsExpansion', async () => {
  let expanded = 0
  const t = setup((text, opts, n) => (n === 1 ? { bad: 1 } : { good: 1 }))
  const r = await t.typed('q', WRITE, (v) => (v.good ? [] : [t.substance('no')]), { nullIsFinal: true, expandShas: async () => { expanded++; return null } })
  assert.deepEqual(t.labels(), ['x', 'x:redo1'])
  assert.equal(expanded, 0)
  assert.deepEqual(plain(r.value), { good: 1 })
})

test('typed_noRedoHook_endsOnASubstanceErrorButStillRepairsForm', async () => {
  const t = setup(() => ({ bad: 1 }))
  const r = await t.typed('q', WRITE, () => [t.substance('no')], { noRedo: true })
  assert.equal(r.value, null)
  assert.equal(t.calls.length, 1, 'no redo after a substance error')
  const lost = setup(() => null)
  const l = await lost.typed('q', WRITE, ok, { noRedo: true })
  assert.equal(l.lost, 'missing')
  assert.equal(lost.calls.length, 1)
  const fixed = setup((text, opts, n) => (n === 1 ? { bad: 1 } : { good: 1 }))
  const f = await fixed.typed('q', WRITE, (v) => (v.good ? [] : [t.form('shape')]), { noRedo: true })
  assert.deepEqual(plain(f.value), { good: 1 })
  assert.deepEqual(fixed.labels(), ['x', 'x:repair1'])
})

test('typed_retryOnThrowHook_predicateOrFlagReplacesTheReadOnlyRule', async () => {
  const never = setup(boom)
  await never.typed('q', READ, ok, { retryOnThrow: () => false })
  assert.deepEqual(never.labels(), ['x'])
  const writer = setup(boom)
  const w = await writer.typed('q', WRITE, ok, { retryOnThrow: (opts) => opts.agentType === 'coder' })
  assert.deepEqual(writer.labels(), ['x', 'x:retry1'])
  assert.equal(w.threw, true)
  const flagOff = setup(boom)
  await flagOff.typed('q', READ, ok, { retryOnThrow: false })
  assert.deepEqual(flagOff.labels(), ['x'])
  const flagOn = setup(boom)
  await flagOn.typed('q', WRITE, ok, { retryOnThrow: true })
  assert.deepEqual(flagOn.labels(), ['x', 'x:retry1'])
})

test('typed_driftOfHook_turnsAFormatterRepairThatChangesADecisionIntoAProducerRedo', async () => {
  const t = setup((text, opts, n) => (n === 1 ? { verdict: 'revise', note: 'x ' } : n === 2 ? { verdict: 'approve', note: 'x' } : { verdict: 'revise', note: 'x' }))
  const drift = (before, after) => (before.verdict !== after.verdict ? 'verdict' : null)
  const r = await t.typed('q', READ, (v) => (v.note.endsWith(' ') ? [t.form('trim note')] : []), { driftOf: drift })
  assert.deepEqual(t.labels(), ['x', 'x:repair1', 'x:redo2'])
  assert.match(t.calls[2].text, /a formatter repair changed verdict/)
  assert.match(t.calls[2].text, /trim note/)
  assert.deepEqual(plain(r.value), { verdict: 'revise', note: 'x' })
  const free = setup((text, opts, n) => (n === 1 ? { verdict: 'revise', note: 'x ' } : { verdict: 'approve', note: 'x' }))
  const f = await free.typed('q', READ, (v) => (v.note.endsWith(' ') ? [free.form('trim note')] : []))
  assert.equal(f.value.verdict, 'approve', 'without the hook a repair that changes a decision is accepted')
})

// Round limits and lost
test('typed_formErrors_goToAHaikuFormatterAndStopAtFixRounds', async () => {
  const t = setup(() => ({ v: 1 }))
  const r = await t.typed('q', READ, () => [t.form('shape')])
  assert.deepEqual(t.labels(), ['x', 'x:repair1', 'x:repair2'])
  for (const c of t.calls.slice(1)) {
    assert.equal(c.opts.agentType, 'formatter')
    assert.equal(c.opts.model, 'haiku')
    assert.equal(c.opts.effort, 'low')
    assert.deepEqual(plain(c.opts.schema), { type: 'object' })
  }
  assert.deepEqual(plain({ value: r.value, lost: r.lost, threw: r.threw }), { value: null, lost: null, threw: false })
  assert.equal(r.errors[0].msg, 'shape')
})

test('typed_substanceErrors_redoTheOriginalCallWithTheErrorsAndStopAtFixRounds', async () => {
  const t = setup(() => ({ v: 1 }))
  const r = await t.typed('question', { ...READ, model: 'opus' }, () => [t.substance('wrong')])
  assert.deepEqual(t.labels(), ['x', 'x:redo1', 'x:redo2'])
  assert.equal(t.calls[1].opts.model, 'opus', 'a redo keeps the original options')
  assert.ok(t.calls[1].text.startsWith('question'), 'a redo extends the original prompt')
  assert.match(t.calls[1].text, /wrong/)
  assert.equal(r.value, null)
  assert.equal(r.lost, null)
})

test('typed_mixedErrors_redoInsteadOfRepair', async () => {
  const t = setup(() => ({ v: 1 }))
  await t.typed('q', READ, () => [t.form('a'), t.substance('b')])
  assert.deepEqual(t.labels(), ['x', 'x:redo1', 'x:redo2'])
})

test('typed_fixRoundsOne_allowsOneFixCall', async () => {
  const t = setup(() => ({ v: 1 }), { fixRounds: 1 })
  await t.typed('q', READ, () => [t.substance('b')])
  assert.deepEqual(t.labels(), ['x', 'x:redo1'])
})

test('typed_validOnTheFirstCall_makesOneCallAndReportsNoLoss', async () => {
  const t = setup(() => ({ v: 1 }))
  const r = await t.typed('q', READ, ok)
  assert.deepEqual(plain(r), { value: { v: 1 }, errors: [], lost: null, threw: false })
  assert.equal(t.calls.length, 1)
})

test('typed_nullAnswerThatBecomesValidAfterARedo_succeeds', async () => {
  const t = setup((text, opts, n) => (n === 1 ? null : { v: 1 }))
  const r = await t.typed('q', READ, ok)
  assert.deepEqual(t.labels(), ['x', 'x:redo1'])
  assert.equal(r.lost, null)
  assert.deepEqual(plain(r.value), { v: 1 })
})

test('isWriter_coderOrIsolatedNonReviewer_isTheOnlyWriter', () => {
  const { isWriter } = setup(ok)
  assert.equal(isWriter({ agentType: 'coder' }), true)
  assert.equal(isWriter({ agentType: 'builder', isolation: 'worktree' }), true)
  assert.equal(isWriter({ agentType: 'reviewer', isolation: 'worktree' }), false)
  assert.equal(isWriter({ agentType: 'explorer' }), false)
})
