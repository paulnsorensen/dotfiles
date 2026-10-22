import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test, { after } from 'node:test'
import { fileURLToPath } from 'node:url'
import { runInNewContext } from 'node:vm'

const repo = fileURLToPath(new URL('../../', import.meta.url))
const shim = join(repo, 'bin/t3-run')
const read = (rel) => readFileSync(join(repo, rel), 'utf8')
const g = runInNewContext(
  `${read('claude/workflow-prelude/prelude.js')}\n${read('claude/workflow-prelude/gates.js')}\n;({ mergeCoupledCurds, routeFindings, unsafeCheck, groundedRanges, validGroundedRange })`,
  {},
)
const j = (v) => JSON.parse(JSON.stringify(v))

const dir = mkdtempSync(join(tmpdir(), 't3-gate-'))
after(() => rmSync(dir, { recursive: true, force: true }))
let n = 0
const file = (value) => {
  const path = join(dir, `f${n++}.json`)
  writeFileSync(path, JSON.stringify(value))
  return path
}
const cli = (...args) => spawnSync(shim, ['gate', ...args], { encoding: 'utf8' })

test('merge-curds matches mergeCoupledCurds on the same input', () => {
  const curds = [
    { slug: 'a', brief: 'A', files: ['x.js'] },
    { slug: 'b', brief: 'B', files: ['x.js'] },
    { slug: 'c', brief: 'C', files: ['z.js'] },
  ]
  const r = cli('merge-curds', file(curds))
  assert.equal(r.status, 0)
  assert.deepEqual(JSON.parse(r.stdout), j(g.mergeCoupledCurds(curds)))
  assert.equal(JSON.parse(r.stdout).length, 2)
})

test('check-safe exits 0 for a safe command and 1 with a reason for an unsafe one', () => {
  assert.equal(cli('check-safe', 'git log --oneline').status, 0)
  const r = cli('check-safe', 'curl http://example.com')
  assert.equal(r.status, 1)
  assert.match(r.stdout, new RegExp(g.unsafeCheck('curl http://example.com').name))
})

test('route-findings matches routeFindings and keeps slug order', () => {
  const result = {
    findings: [
      { severity: 'high', file: './a.js', fix_cost_now: 'contained' },
      { severity: 'high', file: 'b.js', fix_cost_now: 'contained' },
      { severity: 'high', file: 'orphan.js', fix_cost_now: 'contained' },
    ],
  }
  const filesBySlug = { one: ['a.js', 'b.js'], two: ['b.js'] }
  const r = cli('route-findings', file(result), file(filesBySlug))
  assert.equal(r.status, 0)
  const out = JSON.parse(r.stdout)
  const expected = g.routeFindings(result, filesBySlug, ['one', 'two'])
  assert.deepEqual(out.bySlug, j(Object.fromEntries(expected.bySlug)))
  assert.deepEqual(Object.keys(out.bySlug), ['one'])
  assert.deepEqual(out.shared, { two: ['one'] })
  assert.equal(out.unrouted, true)
  assert.equal(out.unrouted, expected.unrouted)
  assert.equal(out.unownedMedium, expected.unownedMedium)
})

test('ranges keeps valid ranges and reports the dropped ones', () => {
  const ranges = ['a/b.js#1-5', '../x#1-2', 'c.js#9-3', 'd.js#4-4']
  const r = cli('ranges', file(ranges))
  assert.equal(r.status, 0)
  const out = JSON.parse(r.stdout)
  assert.deepEqual(out.kept, j(g.groundedRanges(ranges)))
  assert.deepEqual(out.kept, ['a/b.js#1-5', 'd.js#4-4'])
  assert.deepEqual(out.dropped, ['../x#1-2', 'c.js#9-3'])
})

test('sha accepts a full 40-hex SHA and rejects short or malformed values', () => {
  assert.equal(cli('sha', 'a'.repeat(40)).status, 0)
  assert.equal(cli('sha', 'ABCDEF0123'.repeat(4)).status, 0)
  assert.equal(cli('sha', 'abc1234').status, 1)
  assert.equal(cli('sha', 'g'.repeat(40)).status, 1)
  assert.equal(cli('sha', 'a'.repeat(41)).status, 1)
  assert.equal(cli('sha', `${'a'.repeat(40)}\n`).status, 1)
  assert.equal(cli('sha', '').status, 1)
})

test('an unknown gate exits 2', () => {
  assert.equal(cli('bogus').status, 2)
})
