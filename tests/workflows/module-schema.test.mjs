import strict from 'node:assert/strict'
import test from 'node:test'
import { loadModule } from '../../claude/workflow-prelude/load.mjs'
// A module runs in a vm context, so its values have another realm's prototypes. Compare by JSON shape.
const toPlain = (v) => (v === undefined ? v : JSON.parse(JSON.stringify(v)))
const assert = { ...strict, deepEqual: (a, b, m) => strict.deepEqual(toPlain(a), toPlain(b), m) }

const m = loadModule('schema', { globals: {} })

test('schema_builders_produceTheJsonSchemaShapes', () => {
  assert.deepEqual(m.str, { type: 'string' })
  assert.deepEqual(m.int, { type: 'integer' })
  assert.deepEqual(m.bool, { type: 'boolean' })
  assert.deepEqual(m.strs, { type: 'array', items: { type: 'string' } })
  assert.deepEqual(m.ints, { type: 'array', items: { type: 'integer' } })
  assert.deepEqual(m.text('why'), { type: 'string', description: 'why' })
  assert.deepEqual(m.oneOf(['a', 'b']), { type: 'string', enum: ['a', 'b'] })
  assert.deepEqual(m.list(m.int), { type: 'array', items: { type: 'integer' } })
})

test('schema_obj_requiresEveryProperty', () => {
  const o = m.obj({ a: m.str, b: m.list(m.int) })
  assert.equal(o.type, 'object')
  assert.deepEqual(o.required, ['a', 'b'])
  assert.deepEqual(Object.keys(o.properties), ['a', 'b'])
})

test('schema_enums_holdTheSharedClosedSets', () => {
  assert.deepEqual(m.CHECK_KINDS, ['command', 'test', 'inspection', 'ci'])
  assert.deepEqual(m.ADVICE_VERDICTS, ['approve', 'revise', 'stop'])
  assert.deepEqual(m.FIX_STATUSES, ['fixed', 'partial', 'blocked'])
  assert.deepEqual(m.PHASE_STATUSES, ['ok', 'partial', 'blocked'])
  assert.deepEqual(m.FINDING_SEVERITIES, ['blocker', 'high', 'medium', 'low'])
  assert.deepEqual(m.FIX_COSTS, ['contained', 'moderate', 'sprawling', 'n/a'])
})
