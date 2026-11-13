import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test, { after } from 'node:test'
import { fileURLToPath } from 'node:url'

const repo = fileURLToPath(new URL('../../', import.meta.url))
const shim = join(repo, 'bin/t3-run')
const dir = mkdtempSync(join(tmpdir(), 't3-validate-'))
after(() => rmSync(dir, { recursive: true, force: true }))

let n = 0
const validate = (role, content) => {
  const file = join(dir, `r${n++}.json`)
  writeFileSync(file, typeof content === 'string' ? content : JSON.stringify(content))
  const r = spawnSync(shim, ['validate', role, file], { encoding: 'utf8' })
  return { status: r.status, reasons: r.stdout.split('\n').filter(Boolean) }
}
const SHA = 'a'.repeat(40)

test('the S-4 fabricated object is rejected for a cheap role', () => {
  const out = validate('formatter', { start: null, end: null, pwd: '', branch: '', head: '' })
  assert.equal(out.status, 1)
  assert.match(out.reasons[0], /empty result/)
})

test('an object of empty arrays and objects is rejected', () => {
  assert.equal(validate('verifier', { a: [], b: {}, c: null }).status, 1)
})

test('a non-empty status passes for a cheap role', () => {
  assert.equal(validate('gate-runner', { status: 'ok', extra: null }).status, 0)
})

test('a cheap role without a status string fails', () => {
  assert.equal(validate('runner', { note: 'x' }).status, 1)
  assert.equal(validate('runner', { status: 3 }).status, 1)
})

test('input that is not exactly one JSON object fails', () => {
  assert.equal(validate('runner', '[1]').status, 1)
  assert.equal(validate('runner', '{"status":"ok"} {"status":"ok"}').status, 1)
  assert.equal(validate('runner', 'not json').status, 1)
})

test('a write role needs status, branch, and a full head_sha', () => {
  assert.equal(validate('coder', { status: 'ok', branch: 'b', head_sha: SHA }).status, 0)
  const bad = validate('cure', { status: 'ok', head_sha: 'abc1234' })
  assert.equal(bad.status, 1)
  assert.equal(bad.reasons.length, 2)
  assert.ok(bad.reasons.some((r) => /branch/.test(r)))
  assert.ok(bad.reasons.some((r) => /head_sha/.test(r)))
})

test('every write role is checked, and a reviewer needs only status', () => {
  for (const role of ['coder', 'press', 'cure', 'continuation']) {
    assert.equal(validate(role, { status: 'ok' }).status, 1, role)
  }
  assert.equal(validate('reviewer', { status: 'ok' }).status, 0)
})

test('an unknown role exits 2', () => {
  const file = join(dir, 'u.json')
  writeFileSync(file, '{"status":"ok"}')
  assert.equal(spawnSync(shim, ['validate', 'nope', file], { encoding: 'utf8' }).status, 2)
})
