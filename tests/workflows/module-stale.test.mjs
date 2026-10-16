import strict from 'node:assert/strict'
import test from 'node:test'
import { loadModule } from '../../claude/workflow-prelude/load.mjs'
// A module runs in a vm context, so its values have another realm's prototypes. Compare by JSON shape.
const toPlain = (v) => (v === undefined ? v : JSON.parse(JSON.stringify(v)))
const assert = { ...strict, deepEqual: (a, b, m) => strict.deepEqual(toPlain(a), toPlain(b), m) }

const s = loadModule('stale', { globals: {} })
const plain = (v) => JSON.parse(JSON.stringify(v))
const snapshot = { base: 'b1', heads: { 11: 'h11', 12: 'h12' }, files: ['src/a.js', 'src/b.js'] }
const live = (over = {}) => ({ base: 'b1', heads: { 11: 'h11', 12: 'h12' }, ...over })
const verdictOf = (l, changed) => plain(s.staleVerdict(snapshot, l, changed))

// AC-8
test('staleVerdict_nothingMoved_isFresh', () => {
  assert.deepEqual(verdictOf(live(), []), { verdict: 'fresh', reasons: [] })
  assert.equal(verdictOf(live(), null).verdict, 'fresh')
})

test('staleVerdict_baseMovedWithoutFileOverlap_isRebase', () => {
  const r = verdictOf(live({ base: 'b2' }), ['docs/x.md'])
  assert.equal(r.verdict, 'rebase')
  assert.equal(r.reasons.length, 1)
  assert.ok(r.reasons[0].includes('b1') && r.reasons[0].includes('b2'))
})

test('staleVerdict_headMoved_isReplan', () => {
  const r = verdictOf(live({ heads: { 11: 'h11', 12: 'new' } }), [])
  assert.equal(r.verdict, 'replan')
  assert.ok(r.reasons[0].includes('#12') && r.reasons[0].includes('new'))
})

test('staleVerdict_prSetChanged_isReplan', () => {
  assert.equal(verdictOf(live({ heads: { 11: 'h11' } }), []).verdict, 'replan')
  assert.equal(verdictOf(live({ heads: { 11: 'h11', 12: 'h12', 13: 'h13' } }), []).verdict, 'replan')
})

test('staleVerdict_baseMovedOverPlanFiles_isReplan', () => {
  const r = verdictOf(live({ base: 'b2' }), ['src/b.js', 'docs/x.md'])
  assert.equal(r.verdict, 'replan')
  assert.ok(r.reasons[0].includes('src/b.js') && !r.reasons[0].includes('docs/x.md'))
})

test('staleVerdict_baseMovedWithUnknownFiles_isReplan', () => {
  for (const unknown of [null, undefined]) {
    const r = verdictOf(live({ base: 'b2' }), unknown)
    assert.equal(r.verdict, 'replan')
    assert.ok(r.reasons[0].includes('unknown'))
  }
})

test('staleVerdict_headMovedWinsOverMovedBase', () => {
  const r = verdictOf(live({ base: 'b2', heads: { 11: 'x', 12: 'h12' } }), [])
  assert.equal(r.verdict, 'replan')
  assert.ok(r.reasons.every((x) => !x.includes('base moved')))
})

test('stale_shaRes_acceptTheirLengthsOnly', () => {
  assert.ok(s.SHA_RE.test('abc1234') && s.SHA_RE.test('a'.repeat(40)))
  assert.equal(s.SHA_RE.test('abc123'), false)
  assert.equal(s.SHA_RE.test('a'.repeat(41)), false)
  assert.ok(s.SHORT_SHA_RE.test('abc1234') && !s.SHORT_SHA_RE.test('a'.repeat(17)))
  assert.ok(s.DIGEST_RE.test('0123456789abcdef') && !s.DIGEST_RE.test('0123456789ABCDEF'))
})

test('stale_shaErrors_substanceUnlessFullSha', () => {
  assert.deepEqual(s.shaErrors('$.head', 'a'.repeat(40)), [])
  assert.deepEqual(plain(s.shaErrors('$.head', 'abc1234')), [{ kind: 'substance', msg: '$.head must be a 40-hex commit SHA' }])
  assert.equal(s.shaErrors('$.head', 5).length, 1)
})

test('stale_stampedBy_needsDigestAndCurrentHead', () => {
  const p = { landing_digest: 'd', landing_head: 'h', head_sha: 'h' }
  assert.equal(s.stampedBy(p, 'd'), true)
  assert.equal(s.stampedBy(p, 'x'), false)
  assert.equal(s.stampedBy({ ...p, head_sha: 'z' }, 'd'), false)
})

test('stale_markersOf_wellFormedMarkersOnly', () => {
  const sha = 'a'.repeat(40)
  const good = s.markersOf({ aged_sha: ` ${sha} `, aged_patch: sha, aged_dirty: true, landing_digest: '0123456789abcdef', landing_head: sha })
  assert.deepEqual(plain(good), { aged_sha: sha, aged_patch: sha, aged_dirty: true, landing_digest: '0123456789abcdef', landing_head: sha })
  const bad = s.markersOf({ aged_sha: sha, aged_patch: 'short', aged_dirty: true, landing_digest: 'nope', landing_head: sha })
  assert.deepEqual(plain(bad), { aged_sha: '', aged_patch: '', aged_dirty: false, landing_digest: '', landing_head: '' })
})
