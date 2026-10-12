import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const syncScript = fileURLToPath(new URL('../../claude/workflow-prelude/sync.mjs', import.meta.url))
const run = (...args) => spawnSync(process.execPath, [syncScript, ...args], { encoding: 'utf8' })
const dir = () => mkdtempSync(join(tmpdir(), 'prelude-def-'))
const put = (d, name, text) => {
  const p = join(d, name)
  writeFileSync(p, text)
  return p
}
const BEGIN = '// BEGIN shared prelude: x\n'
const END = '// END shared prelude\n'

test('sync_sourceWithoutTrailingNewline_keepsEndMarkerOnItsOwnLine', () => {
  const d = dir()
  const src = put(d, 'p.js', 'const a = 1')
  const f = put(d, 'w.js', `${BEGIN}old\n${END}`)
  run('--source', src, f)
  assert.match(readFileSync(f, 'utf8'), /^\/\/ END shared prelude$/m, 'END marker fused onto the last source line')
  assert.equal(run('--check', '--source', src, f).status, 0, 'sync output must pass its own --check')
})

test('sync_sourceContainingEndMarker_isRefusedInsteadOfCorruptingTarget', () => {
  const d = dir()
  const src = put(d, 'p.js', `const a = 1\n${END}`)
  const text = `${BEGIN}old\n${END}`
  const f = put(d, 'w.js', text)
  const r = run('--source', src, f)
  assert.notEqual(r.status, 0, 'writes a block that breaks the target on the next run')
  assert.equal(readFileSync(f, 'utf8'), text)
})

test('sync_sourceFlagWithoutValue_failsWithMessageNotStackTrace', () => {
  const f = put(dir(), 'w.js', `${BEGIN}x\n${END}`)
  const r = run(f, '--source')
  assert.notEqual(r.status, 0)
  assert.doesNotMatch(r.stderr, /TypeError|\n\s+at /)
})

test('sync_unknownFlag_isRejectedInsteadOfRewriting', () => {
  const d = dir()
  const src = put(d, 'p.js', 'const a = 1\n')
  const text = `${BEGIN}x\n${END}`
  const f = put(d, 'w.js', text)
  const r = run('--chekc', '--source', src, f)
  assert.notEqual(r.status, 0, 'a typo of --check silently rewrites the file')
  assert.equal(readFileSync(f, 'utf8'), text)
})

test('sync_missingLaterTarget_writesNoEarlierTarget', () => {
  const d = dir()
  const src = put(d, 'p.js', 'const a = 1\n')
  const text = `${BEGIN}old\n${END}`
  const f = put(d, 'w.js', text)
  const r = run('--source', src, f, join(d, 'missing.js'))
  assert.notEqual(r.status, 0)
  assert.equal(readFileSync(f, 'utf8'), text)
})

test('sync_laterTargetWithoutMarkers_writesNoEarlierTarget', () => {
  const d = dir()
  const src = put(d, 'p.js', 'const a = 1\n')
  const text = `${BEGIN}old\n${END}`
  const f = put(d, 'w.js', text)
  const bad = put(d, 'bad.js', 'no markers\n')
  const r = run('--source', src, f, bad)
  assert.notEqual(r.status, 0)
  assert.equal(readFileSync(f, 'utf8'), text)
})

test('sync_markerAsPrefixOfLongerLine_isNotAMarker', () => {
  const d = dir()
  const src = put(d, 'p.js', 'const a = 1\n')
  const f = put(d, 'w.js', `${BEGIN}old\n// END shared prelude and more\n${END}`)
  const r = run('--source', src, f)
  assert.equal(r.status, 0)
  assert.equal(readFileSync(f, 'utf8'), `${BEGIN}const a = 1\n${END}`)
})
