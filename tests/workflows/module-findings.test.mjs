import strict from 'node:assert/strict'
import test from 'node:test'
import { loadModule } from '../../claude/workflow-prelude/load.mjs'
// A module runs in a vm context, so its values have another realm's prototypes. Compare by JSON shape.
const toPlain = (v) => (v === undefined ? v : JSON.parse(JSON.stringify(v)))
const assert = { ...strict, deepEqual: (a, b, m) => strict.deepEqual(toPlain(a), toPlain(b), m) }

const f = loadModule('findings', { globals: {} })
const plain = (v) => JSON.parse(JSON.stringify(v))
const finding = (file, severity = 'medium', extra = {}) => ({ dimension: 'd', severity, file, line: 1, claim: 'c', fix_cost_now: 'moderate', ...extra })

test('findings_needsCure_mediumPlusOrContainedLow', () => {
  assert.equal(f.isMediumPlus(finding('a', 'low')), false)
  assert.equal(f.isMediumPlus(finding('a', 'blocker')), true)
  assert.equal(f.needsCure(finding('a', 'low')), false)
  assert.equal(f.needsCure(finding('a', 'low', { fix_cost_now: 'contained' })), true)
})

test('findings_normalizeFile_stripsDotSlashAndWorktreePrefix', () => {
  assert.equal(f.normalizeFile('./a/b.js'), 'a/b.js')
  assert.equal(f.normalizeFile('/w/tree/a.js', '/w/tree/'), 'a.js')
  assert.equal(f.normalizeFile('/home/u/repo/.claude/worktrees/agent-1/src/x.js'), 'src/x.js')
  assert.equal(f.normalizeFile('/other/a.js'), '/other/a.js')
})

test('findings_routeFindings_firstOwnerGetsItAndOthersShare', () => {
  const result = { has_medium_plus_findings: true, has_cheap_lows: false, findings: [finding('./a.js'), finding('b.js'), finding('c.js', 'low')] }
  const r = f.routeFindings(result, { s1: ['a.js', 'b.js'], s2: ['b.js'] }, ['s1', 's2'])
  assert.deepEqual(plain([...r.bySlug]), [['s1', [finding('a.js'), finding('b.js')]]])
  assert.deepEqual(plain([...r.shared].map(([k, v]) => [k, [...v]])), [['s2', ['s1']]])
  assert.equal(r.sharedFindings.get('s2').length, 1)
  assert.equal(r.unrouted, false)
})

test('findings_routeFindings_unownedNeedingCureIsUnrouted', () => {
  const r = f.routeFindings({ findings: [finding('z.js')] }, { s1: ['a.js'] }, ['s1'])
  assert.equal(r.unrouted, true)
  assert.equal(r.unownedMedium, true)
  const lowOnly = f.routeFindings({ findings: [finding('z.js', 'low')] }, { s1: ['a.js'] }, ['s1'])
  assert.equal(lowOnly.unrouted, false)
  const claimed = f.routeFindings({ has_medium_plus_findings: true, findings: [] }, {}, [])
  assert.equal(claimed.unrouted, true)
})

test('findings_enumErrors_formByDefaultSubstanceOnRequest', () => {
  assert.deepEqual(f.enumErrors('$.x', 'a', ['a', 'b']), [])
  assert.equal(f.enumErrors('$.x', 'z', ['a', 'b'])[0].kind, 'form')
  assert.equal(f.enumErrors('$.x', 'z', ['a', 'b'], (m) => ({ kind: 'substance', msg: m }))[0].kind, 'substance')
})

test('findings_findingErrors_checksSeverityAndFixCost', () => {
  assert.deepEqual(f.findingErrors({ findings: [finding('a')] }), [])
  const errors = f.findingErrors({ findings: [finding('a', 'huge', { fix_cost_now: 'free' })] })
  assert.deepEqual(errors.map((e) => e.kind), ['substance', 'substance'])
  assert.ok(errors[0].msg.startsWith('$.findings[0].severity must be one of'))
})

test('findings_splitBlocked_splitsStatusAndKeepsReason', () => {
  assert.deepEqual(plain(f.splitBlocked({ status: 'Blocked: no repo' })), { status: 'blocked', reason: 'no repo' })
  assert.deepEqual(plain(f.splitBlocked({ status: 'halt: stop', reason: 'kept' })), { status: 'blocked', reason: 'kept' })
  assert.deepEqual(plain(f.splitBlocked({ status: 'ok' })), { status: 'ok' })
  assert.equal(f.splitBlocked(null), null)
})

test('findings_dedupeFindings_dropsRepeatsAndSortsByLocation', () => {
  const a = finding('b.js', 'medium', { line: 9 })
  const b = finding('a.js', 'medium', { line: 20 })
  const c = finding('a.js', 'medium', { line: 3 })
  const out = f.dedupeFindings([a, b, { ...a, severity: 'high' }, c])
  assert.deepEqual(plain(out), plain([c, b, a]))
})

test('findings_cureBatches_chunksEachSlugByCapInMapOrder', () => {
  const by = new Map([['s1', [1, 2, 3, 4, 5]], ['s2', [6]]])
  assert.deepEqual(plain(f.cureBatches(by, 2)), [
    { slug: 's1', findings: [1, 2] }, { slug: 's1', findings: [3, 4] }, { slug: 's1', findings: [5] }, { slug: 's2', findings: [6] },
  ])
  assert.equal(f.cureBatches(by, 0).length, 6)
  assert.deepEqual(f.cureBatches(new Map(), 3), [])
})
