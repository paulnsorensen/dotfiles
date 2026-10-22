import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test, { after } from 'node:test'
import { fileURLToPath } from 'node:url'

const shim = join(fileURLToPath(new URL('../../', import.meta.url)), 'bin/t3-run')
const temps = []
after(() => {
  for (const d of temps) rmSync(d, { recursive: true, force: true })
})

const tempRepo = () => {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), 't3-lock-')))
  temps.push(dir)
  spawnSync('git', ['init', '-q'], { cwd: dir })
  return dir
}
const cli = (cwd, ...args) => spawnSync(shim, ['ledger', ...args], { cwd, encoding: 'utf8' })
const rec = (cwd, id, task, ...extra) =>
  cli(cwd, 'record', 'r', '--phase', 'p', '--role', 'coder', '--client-request-id', id, '--task-id', task, ...extra)
const file = (cwd) => join(cwd, '.cheese/t3/r.json')

test('parallel record calls all land', async () => {
  const cwd = tempRepo()
  cli(cwd, 'init', 'r')
  const codes = await Promise.all(
    Array.from({ length: 12 }, (_, i) =>
      new Promise((resolve) => {
        const args = ['ledger', 'record', 'r', '--phase', 'p', '--role', 'coder', '--client-request-id', `c${i}`, '--task-id', `t${i}`]
        spawn(shim, args, { cwd }).on('close', resolve)
      }),
    ),
  )
  assert.deepEqual(codes, Array(12).fill(0))
  assert.equal(JSON.parse(readFileSync(file(cwd), 'utf8')).children.length, 12)
})

test('a held lock times out with exit 1 naming the lock file', () => {
  const cwd = tempRepo()
  cli(cwd, 'init', 'r')
  writeFileSync(`${file(cwd)}.lock`, '')
  const r = rec(cwd, 'c1', 't1')
  assert.equal(r.status, 1)
  assert.match(r.stderr, /r\.json\.lock/)
})

test('same client request id with a different task id is a conflict', () => {
  const cwd = tempRepo()
  cli(cwd, 'init', 'r')
  assert.equal(rec(cwd, 'c1', 't1').status, 0)
  assert.equal(rec(cwd, 'c1', 't1').status, 0)
  const r = rec(cwd, 'c1', 't2')
  assert.equal(r.status, 1)
  assert.match(r.stderr, /t1/)
  assert.match(r.stderr, /t2/)
})

test('record rejects depth above 2, negatives, and non-integers', () => {
  const cwd = tempRepo()
  cli(cwd, 'init', 'r')
  for (const depth of ['3', '-1', '1.5', 'x']) assert.equal(rec(cwd, `c${depth}`, `t${depth}`, '--depth', depth).status, 2, depth)
  assert.equal(rec(cwd, 'ok', 'tok', '--depth', '2').status, 0)
})

test('every subcommand reports a corrupt ledger by path and keeps the file', () => {
  const cwd = tempRepo()
  cli(cwd, 'init', 'r')
  const bad = '{not json'
  const calls = [
    ['record', 'r', '--phase', 'p', '--role', 'coder', '--client-request-id', 'c', '--task-id', 't'],
    ['complete', 'r', '--task-id', 't', '--status', 'completed'],
    ['status', 'r'],
    ['barrier', 'r', 'p'],
  ]
  for (const args of calls) {
    writeFileSync(file(cwd), bad)
    const r = cli(cwd, ...args)
    assert.equal(r.status, 1, args[0])
    assert.match(r.stderr, /^t3-run: corrupt ledger .*r\.json/, args[0])
    assert.doesNotMatch(r.stderr, /SyntaxError|\n\s+at /, args[0])
    assert.equal(readFileSync(file(cwd), 'utf8'), bad, args[0])
  }
})
