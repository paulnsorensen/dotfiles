import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test, { after } from 'node:test'
import { fileURLToPath } from 'node:url'
import { runInNewContext } from 'node:vm'

const repo = fileURLToPath(new URL('../../', import.meta.url))
const syncScript = join(repo, 'claude/workflow-prelude/sync.mjs')
const read = (rel) => readFileSync(join(repo, rel), 'utf8')
const NAMES = ['validGroundedRange', 'groundedRanges', 'mergeCoupledCurds', 'routeFindings', 'unsafeCheck', 'commandHit']

const gatesSource = read('claude/workflow-prelude/gates.js')
const g = runInNewContext(`${read('claude/workflow-prelude/prelude.js')}\n${gatesSource}\n;({ ${NAMES.join(', ')} })`, {})

// Values from the vm context have another realm's prototypes; compare them as plain JSON.
const j = (v) => JSON.parse(JSON.stringify(v))

const roots = []
after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

test('gates.js is a plain script that defines every exported name and has no import or export', () => {
  assert.doesNotMatch(gatesSource, /^\s*(import|export)\b/m)
  for (const name of NAMES) assert.equal(typeof g[name], 'function', name)
})

test('mergeCoupledCurds merges curds that share a file', () => {
  const out = g.mergeCoupledCurds([
    { slug: 'a', brief: 'A', files: ['x.js'] },
    { slug: 'b', brief: 'B', files: ['x.js', 'y.js'] },
    { slug: 'c', brief: 'C', files: ['z.js'] },
  ])
  assert.equal(out.length, 2)
  assert.deepEqual(j(out[0].merged_from), ['a', 'b'])
  assert.deepEqual(j(out[0].files).sort(), ['x.js', 'y.js'])
  assert.equal(out[0].brief, 'A\n\nB')
  assert.equal(out[1].slug, 'c')
  assert.equal(out[1].merged_from, undefined)
})

test('mergeCoupledCurds merges through depends_on, transitively', () => {
  const out = g.mergeCoupledCurds([
    { slug: 'a', brief: 'A', files: ['a.js'] },
    { slug: 'b', brief: 'B', files: ['b.js'], depends_on: ['a'] },
    { slug: 'c', brief: 'C', files: ['c.js'], depends_on: ['b'] },
    { slug: 'd', brief: 'D', files: ['d.js'] },
  ])
  assert.equal(out.length, 2)
  assert.deepEqual(j(out[0].merged_from), ['a', 'b', 'c'])
  assert.equal(out[1].slug, 'd')
})

test('groundedRanges keeps valid and one-line ranges and drops invalid ones', () => {
  const valid = ['src/a.js#1-5', 'src/b.js#7-7']
  const invalid = ['src/a.js#5-1', '/abs/a.js#1-2', '../a.js#1-2', 'a.js#0-3', 'a.js', ' a.js#1-2', 42]
  assert.deepEqual(j(g.groundedRanges([...valid, ...invalid])), valid)
  assert.deepEqual(j(g.groundedRanges('nope')), [])
  assert.equal(g.validGroundedRange('src/b.js#7-7'), true)
})

test('routeFindings routes a finding to its first owner and records the other owners as shared', () => {
  const result = { findings: [{ severity: 'high', file: './a.js' }] }
  const out = g.routeFindings(result, { one: ['a.js'], two: ['a.js'] }, ['one', 'two'], null)
  assert.deepEqual(j(out.bySlug.get('one')), [{ severity: 'high', file: 'a.js' }])
  assert.deepEqual(j([...out.shared.get('two')]), ['one'])
  assert.equal(out.sharedFindings.get('two').length, 1)
  assert.equal(out.unrouted, false)
})

test('routeFindings marks unrouted when a cure-needing finding has no owner, and ignores an unowned plain low', () => {
  const owned = { one: ['a.js'] }
  const unowned = g.routeFindings({ findings: [{ severity: 'medium', file: 'zzz.js' }] }, owned, ['one'], null)
  assert.equal(unowned.unrouted, true)
  assert.equal(unowned.unownedMedium, true)
  const low = g.routeFindings({ findings: [{ severity: 'low', file: 'zzz.js', fix_cost_now: 'large' }] }, owned, ['one'], null)
  assert.equal(low.unrouted, false)
})

test('routeFindings strips the worktree prefix before it matches owners', () => {
  const wt = '/tmp/repo/.claude/worktrees/agent-1'
  const out = g.routeFindings({ findings: [{ severity: 'high', file: `${wt}/a.js` }] }, { one: ['a.js'] }, ['one'], wt)
  assert.equal(out.bySlug.get('one')[0].file, 'a.js')
})

test('unsafeCheck rejects an unsafe command and accepts a safe one', () => {
  const curl = g.unsafeCheck('curl https://example.com')
  assert.equal(curl.name, 'command not on the read-only allowlist')
  assert.equal(curl.text, 'curl')
  assert.equal(g.unsafeCheck('echo hi > out.txt').name, 'output redirection to a file')
  assert.equal(g.unsafeCheck('git commit -m x').name, 'git mutation')
  assert.equal(g.unsafeCheck('node --test tests/workflows/'), null)
  assert.equal(g.unsafeCheck('test -e a.js && git status'), null)
})

test('commandHit classifies one simple command', () => {
  const rm = g.commandHit(['rm', '-rf', 'x'])
  assert.equal(rm.name, 'command not on the read-only allowlist')
  assert.equal(rm.text, 'rm')
  assert.equal(g.commandHit(['ls', '-l']), null)
})

test('the cheese-factory gates block equals gates.js, and no other workflow has gates markers', () => {
  const text = read('claude/workflows/cheese-factory.js')
  const begin = text.indexOf('// BEGIN shared gates')
  const end = text.indexOf('// END shared gates')
  assert.ok(begin > 0 && end > begin)
  assert.equal(text.slice(text.indexOf('\n', begin) + 1, end), gatesSource)
  for (const f of ['cheese-board', 'move-my-cheese']) assert.doesNotMatch(read(`claude/workflows/${f}.js`), /shared gates/)
  for (const name of NAMES.filter((n) => n !== 'validGroundedRange')) {
    assert.doesNotMatch(text.slice(0, begin) + text.slice(end), new RegExp(`^(const|function) ${name}\\b`, 'm'), name)
  }
})

test('sync --check exits 1 and names the file when the pasted gates block drifted', () => {
  const d = mkdtempSync(join(tmpdir(), 'gates-'))
  roots.push(d)
  const f = join(d, 'cheese-factory.js')
  writeFileSync(f, read('claude/workflows/cheese-factory.js'))
  const ok = spawnSync(process.execPath, [syncScript, '--check', f], { encoding: 'utf8' })
  assert.equal(ok.status, 0, ok.stderr)
  const drifted = readFileSync(f, 'utf8').replace('// END shared gates', 'const drift = 1\n// END shared gates')
  writeFileSync(f, drifted)
  const r = spawnSync(process.execPath, [syncScript, '--check', f], { encoding: 'utf8' })
  assert.equal(r.status, 1)
  assert.ok(r.stderr.includes(f) && r.stderr.includes('gates'), r.stderr)
  assert.equal(readFileSync(f, 'utf8'), drifted)
})
