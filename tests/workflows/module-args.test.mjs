import strictAssert from 'node:assert/strict'
// The module runs in its own realm, so deepEqual compares through JSON.
const json = (v) => JSON.parse(JSON.stringify(v))
const assert = { ...strictAssert, deepEqual: (a, e) => strictAssert.deepEqual(json(a), json(e)) }
import test from 'node:test'
import { loadModule } from '../../claude/workflow-prelude/load.mjs'

const { parseArgs } = loadModule('args')
const USAGE = "workflow('x', { slug: 'a-b', n?: 1 })"
const parse = parseArgs({
  usage: USAGE,
  key: 'slug',
  fields: {
    slug: { type: 'string', required: true, pattern: '^[a-z][a-z-]*$' },
    dry: { type: 'boolean', default: false },
    n: { type: 'integer', min: 1, max: 5, clamp: true, default: 2 },
    strict: { type: 'integer', min: 1, max: 5 },
    mode: { type: 'enum', values: ['fast', 'slow'], default: 'fast' },
    refs: { type: 'array', items: 'string', max: 2 },
  },
})

test('parseArgs_bareStringGoesToTheKeyField', () => {
  assert.deepEqual(parse('my-slug').opts, { slug: 'my-slug', dry: false, n: 2, mode: 'fast' })
})

test('parseArgs_jsonStringAndObjectParseTheSame', () => {
  const obj = { slug: 'ab', dry: true, mode: 'slow', refs: ['r'] }
  assert.deepEqual(parse(JSON.stringify(obj)).opts, parse(obj).opts)
  assert.equal(parse(obj).opts.mode, 'slow')
})

test('parseArgs_unknownKeyIsRejectedWithTheExactCallShape', () => {
  const r = parse({ slug: 'ab', extra: 1 })
  assert.equal(r.opts, undefined)
  assert.match(r.error, /unknown key "extra"/)
  assert.ok(r.error.endsWith(`Call shape: ${USAGE}`))
  assert.deepEqual(r.blocked, { status: 'blocked', error: r.error, usage: USAGE })
})

test('parseArgs_typeAndPatternViolationsAreAllReported', () => {
  const r = parse({ slug: 'A1', dry: 'yes', mode: 'mid', refs: [1], strict: 9 })
  assert.match(r.error, /slug does not match/)
  assert.match(r.error, /dry must be a boolean/)
  assert.match(r.error, /mode must be one of fast, slow/)
  assert.match(r.error, /refs must hold only string items/)
  assert.match(r.error, /strict must be an integer from 1 to 5/)
})

test('parseArgs_integerClampsOnlyWhenAsked_andRejectsNonIntegers', () => {
  assert.equal(parse({ slug: 'ab', n: 99 }).opts.n, 5)
  assert.equal(parse({ slug: 'ab', n: -3 }).opts.n, 1)
  assert.match(parse({ slug: 'ab', n: 1.5 }).error, /n must be an integer/)
  assert.match(parse({ slug: 'ab', n: '3' }).error, /n must be an integer/)
})

test('parseArgs_requiredFieldAndArrayLength', () => {
  assert.match(parse({}).error, /slug is required/)
  assert.match(parse({ slug: 'ab', refs: ['a', 'b', 'c'] }).error, /refs holds at most 2 items/)
})

test('parseArgs_badJsonAndNonObjectInputsBlock', () => {
  assert.match(parse('{oops').error, /not valid JSON/)
  assert.match(parse([1]).error, /args must be an object/)
  assert.match(parse(3).error, /args must be an object/)
  assert.match(parse(null).error, /slug is required/)
  const noKey = parseArgs({ usage: 'u', fields: {} })
  assert.match(noKey('text').error, /args must be an object/)
  assert.deepEqual(noKey(undefined).opts, {})
})
