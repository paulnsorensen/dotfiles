import strictAssert from 'node:assert/strict'
// The module runs in its own realm, so deepEqual compares through JSON.
const assert = { ...strictAssert, deepEqual: (a, e, msg) => strictAssert.deepEqual(JSON.parse(JSON.stringify(a)), e, msg) }
import test from 'node:test'
import { loadModule } from '../../claude/workflow-prelude/load.mjs'

const m = loadModule('checkpoint')

test('stable_sortsKeysSoEqualValuesGiveEqualText', () => {
  assert.equal(m.stable({ b: 1, a: [2, { d: 1, c: 2 }] }), m.stable({ a: [2, { c: 2, d: 1 }], b: 1 }))
  assert.notEqual(m.stable({ a: 1 }), m.stable({ a: 2 }))
})

test('digestOf_is16HexAndDetectsAnEdit', () => {
  const d = m.digestOf({ a: [1, 2] })
  assert.match(d, /^[0-9a-f]{16}$/)
  assert.equal(m.digestOf({ a: [1, 2] }), d)
  assert.notEqual(m.digestOf({ a: [1, 3] }), d)
})

test('matchAnswers_acceptsIdTextAndNumberAndRejectsBadKeys', () => {
  const qs = [{ id: 'Q1', question: 'first?' }, { id: 'Q2', question: 'second?' }]
  const ok = m.matchAnswers(qs, { Q1: ' yes ', 'second?': 'no' })
  assert.deepEqual(ok.errors, [])
  assert.deepEqual(ok.answers.map((a) => a.answer), ['yes', 'no'])
  assert.equal(m.matchAnswers(qs, { 2: 'x' }).answers[0].id, 'Q2')
  assert.match(m.matchAnswers(qs, { 9: 'x' }).errors[0], /names no open question/)
  assert.match(m.matchAnswers(qs, { Q1: 'a', 1: 'b' }).errors[0], /two answers/)
  assert.match(m.matchAnswers(qs, []).errors[0], /must be an object/)
  assert.match(m.matchAnswers(qs, {}).errors[0], /holds no answer/)
})

test('isObject_rejectsNullArrayAndPrimitives', () => {
  assert.equal(m.isObject({}), true)
  for (const v of [null, [], 'x', 1, undefined]) assert.equal(m.isObject(v), false, String(v))
})

test('plain_deepCopiesAndDropsUndefined', () => {
  const src = { a: { b: 1 }, c: undefined }
  const copy = m.plain(src)
  assert.deepEqual(copy, { a: { b: 1 } })
  copy.a.b = 2
  assert.equal(src.a.b, 1)
})

test('stateShapeErrors_reportsEachBadFieldWithItsPrefix', () => {
  const shape = { items: 'array', meta: 'object', n: { type: 'integer', min: 1 }, used: { type: 'integer', min: 0, max: 2 }, focus: 'string?', ok: 'boolean' }
  assert.deepEqual(m.stateShapeErrors({ items: [], meta: {}, n: 1, used: 2, focus: null, ok: true }, shape), [])
  const errors = m.stateShapeErrors({ items: {}, meta: [], n: 0, used: 3, focus: 4, ok: 'y' }, shape)
  assert.deepEqual(errors, [
    'args.state.items must be an array',
    'args.state.meta must be an object',
    'args.state.n must be an integer of at least 1',
    'args.state.used must be an integer from 0 to 2',
    'args.state.focus must be a string or null',
    'args.state.ok must be a boolean',
  ])
  assert.deepEqual(m.stateShapeErrors(null, shape, 'args.plan'), ['args.plan must be an object'])
  assert.deepEqual(m.stateShapeErrors({}, { x: 'weird' }), ['args.state.x has the unknown shape type weird'])
})

test('askCheckpoint_withQuestions_carriesStateAndADigestThatBindsStamp', () => {
  const q = [{ id: 'Q1', question: 'a?', options: [] }]
  const r = m.askCheckpoint('spec', q, { keep: 1 }, { stamp: 'S', usage: 'U', extra: { note: 'n' } })
  assert.equal(r.status, 'needs-input')
  assert.equal(r.checkpoint, 'spec')
  assert.deepEqual(r.state, { keep: 1, checkpoint: 'spec', questions: q })
  assert.equal(r.digest, m.digestOf({ stamp: 'S', checkpoint: 'spec', state: r.state }))
  assert.notEqual(r.digest, m.askCheckpoint('spec', q, { keep: 1 }, { stamp: 'T' }).digest)
  assert.equal(r.usage, 'U')
  assert.equal(r.note, 'n')
})

test('askCheckpoint_withNoQuestion_carriesNoStateOrDigest', () => {
  const r = m.askCheckpoint('done', [], {}, { stamp: 'S', usage: 'U' })
  assert.equal('state' in r, false)
  assert.equal('digest' in r, false)
  assert.deepEqual(r.questions, [])
})

test('needsInputResult_putsFieldsBeforeUsage', () => {
  const r = m.needsInputResult(['q'], { digest: 'd', landing: 1 }, 'use it')
  assert.deepEqual(Object.keys(r), ['status', 'questions', 'digest', 'landing', 'usage'])
  assert.equal(r.status, 'needs-input')
  assert.equal(r.usage, 'use it')
})

test('approveError_andDigestError_checkTheDigestOfThePlan', () => {
  const plan = { inputs: [1, 2] }
  const digest = m.digestOf(plan)
  assert.equal(m.approveError(digest), '')
  assert.match(m.approveError(''), /args\.plan needs args\.approve/)
  assert.equal(m.digestError(plan, digest), '')
  assert.match(m.digestError({ inputs: [1] }, digest), /does not match the digest of args\.plan/)
})

test('approveUsage_defaultReproducesTheMoveMyCheeseText', () => {
  assert.equal(
    m.approveUsage(),
    'To execute, re-run with { prs: landing.inputs, plan: landing, approve: digest }. Add land:true to merge. To change the plan first, re-run with the same fields and revise: "<change>".',
  )
  assert.equal(m.approveUsage({ fields: 'a: 1', land: false, revise: false }), 'To execute, re-run with { a: 1 }.')
})
