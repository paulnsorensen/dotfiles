import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test, { after } from 'node:test'
import { fileURLToPath } from 'node:url'
import { takeOverStale } from '../../claude/t3-run/ledger.mjs'

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
    Array.from({ length: 20 }, (_, i) =>
      new Promise((resolve) => {
        const args = ['ledger', 'record', 'r', '--phase', 'p', '--role', 'coder', '--client-request-id', `c${i}`, '--task-id', `t${i}`]
        spawn(shim, args, { cwd }).on('close', resolve)
      }),
    ),
  )
  assert.deepEqual(codes, Array(20).fill(0))
  assert.equal(JSON.parse(readFileSync(file(cwd), 'utf8')).children.length, 20)
})

test('a lock that cannot be taken over times out with exit 1 naming the lock file', () => {
  const cwd = tempRepo()
  cli(cwd, 'init', 'r')
  mkdirSync(`${file(cwd)}.lock`)
  const r = rec(cwd, 'c1', 't1')
  assert.equal(r.status, 1)
  assert.match(r.stderr, /r\.json\.lock/)
})

test('a fresh live lock is waited for past the stale limit, never stolen early', () => {
  const cwd = tempRepo()
  cli(cwd, 'init', 'r')
  const lock = `${file(cwd)}.lock`
  writeFileSync(lock, JSON.stringify({ pid: process.pid, created: Date.now() }))
  const started = Date.now()
  assert.equal(rec(cwd, 'c1', 't1').status, 0)
  assert.ok(Date.now() - started >= 2_500, 'the caller waited until the lock aged out')
})

test('a lock whose pid is dead is taken over', () => {
  const cwd = tempRepo()
  cli(cwd, 'init', 'r')
  const dead = spawnSync(process.execPath, ['-e', '']).pid
  writeFileSync(`${file(cwd)}.lock`, JSON.stringify({ pid: dead, created: Date.now() }))
  assert.equal(rec(cwd, 'c1', 't1').status, 0)
  assert.equal(JSON.parse(readFileSync(file(cwd), 'utf8')).children.length, 1)
  assert.equal(existsSync(`${file(cwd)}.lock`), false)
})

test('a lock older than the stale limit is taken over even when its pid is alive', () => {
  const cwd = tempRepo()
  cli(cwd, 'init', 'r')
  writeFileSync(`${file(cwd)}.lock`, JSON.stringify({ pid: process.pid, created: Date.now() - 31_000 }))
  assert.equal(rec(cwd, 'c1', 't1').status, 0)
})

test('record with a task id already recorded under another client request id exits 1 naming both', () => {
  const cwd = tempRepo()
  cli(cwd, 'init', 'r')
  assert.equal(rec(cwd, 'c1', 't1').status, 0)
  const r = rec(cwd, 'c2', 't1')
  assert.equal(r.status, 1)
  assert.match(r.stderr, /c1/)
  assert.match(r.stderr, /c2/)
  assert.equal(JSON.parse(readFileSync(file(cwd), 'utf8')).children.length, 1)
})

const reserve = (cwd, phase = 'p', role = 'coder') => cli(cwd, 'reserve', 'r', '--phase', phase, '--role', role, '--depth', '1')

test('reserve prints the next id per phase and role without recording a child', () => {
  const cwd = tempRepo()
  cli(cwd, 'init', 'r')
  assert.equal(reserve(cwd).stdout.trim(), 'r/p/coder/1')
  assert.equal(reserve(cwd).stdout.trim(), 'r/p/coder/2')
  assert.equal(reserve(cwd, 'p', 'reviewer').stdout.trim(), 'r/p/reviewer/1')
  assert.equal(reserve(cwd, 'q').stdout.trim(), 'r/q/coder/1')
  assert.equal(JSON.parse(readFileSync(file(cwd), 'utf8')).children.length, 0)
  assert.equal(rec(cwd, 'r/p/coder/7', 't7').status, 0)
  assert.equal(reserve(cwd).stdout.trim(), 'r/p/coder/8')
  assert.equal(reserve(cwd, 'a/b').status, 2)
})

test('parallel reserve calls return distinct ids', async () => {
  const cwd = tempRepo()
  cli(cwd, 'init', 'r')
  const outs = await Promise.all(
    Array.from({ length: 10 }, () =>
      new Promise((resolve) => {
        let out = ''
        const p = spawn(shim, ['ledger', 'reserve', 'r', '--phase', 'p', '--role', 'coder', '--depth', '1'], { cwd })
        p.stdout.on('data', (d) => (out += d))
        p.on('close', (code) => resolve({ code, id: out.trim() }))
      }),
    ),
  )
  assert.deepEqual(outs.map((o) => o.code), Array(10).fill(0))
  assert.equal(new Set(outs.map((o) => o.id)).size, 10)
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

test('reserve needs --depth 1..2: 3 exits 1, missing and non-integer exit 2', () => {
  const cwd = tempRepo()
  cli(cwd, 'init', 'r')
  const base = ['reserve', 'r', '--phase', 'p', '--role', 'coder']
  assert.equal(cli(cwd, ...base, '--depth', '1').status, 0)
  assert.equal(cli(cwd, ...base, '--depth', '2').status, 0)
  const over = cli(cwd, ...base, '--depth', '3')
  assert.equal(over.status, 1)
  assert.match(over.stderr, /child depth 3 exceeds the cap of 2/)
  assert.equal(cli(cwd, ...base).status, 2)
  for (const d of ['abc', '0', '-1', '1.5']) {
    const r = cli(cwd, ...base, '--depth', d)
    assert.equal(r.status, 2, d)
    assert.doesNotMatch(r.stderr, /exceeds the cap/, d)
  }
})

const stale = (cwd) => {
  const lock = `${file(cwd)}.lock`
  writeFileSync(lock, JSON.stringify({ pid: process.pid, created: Date.now() - 60_000 }))
  return lock
}

test('takeover: contenders that lose the break file leave the stale lock to the winner', () => {
  const cwd = tempRepo()
  cli(cwd, 'init', 'r')
  const lock = stale(cwd)
  let seen = 0
  takeOverStale(lock, {
    afterBreak: () => {
      takeOverStale(lock)
      takeOverStale(lock)
      seen = existsSync(lock) ? 1 : 0
    },
  })
  assert.equal(seen, 1, 'two rival takers did not remove the lock while the first held the break file')
  assert.equal(existsSync(lock), false)
  assert.equal(existsSync(`${lock}.break`), false)
})

test('takeover: a lock replaced after the stale read is never removed', () => {
  const cwd = tempRepo()
  cli(cwd, 'init', 'r')
  const lock = stale(cwd)
  const fresh = JSON.stringify({ pid: process.pid, created: Date.now() })
  takeOverStale(lock, { afterBreak: () => writeFileSync(lock, fresh) })
  assert.equal(readFileSync(lock, 'utf8'), fresh)
  assert.equal(existsSync(`${lock}.break`), false)
})

test('takeover: a crashed taker leaves a stale break file that a later taker clears', () => {
  const cwd = tempRepo()
  cli(cwd, 'init', 'r')
  const lock = stale(cwd)
  writeFileSync(`${lock}.break`, JSON.stringify({ pid: process.pid, created: Date.now() - 60_000 }))
  takeOverStale(lock)
  takeOverStale(lock)
  assert.equal(existsSync(lock), false)
})

test('three processes over one stale lock lose no update', async () => {
  const cwd = tempRepo()
  cli(cwd, 'init', 'r')
  stale(cwd)
  const codes = await Promise.all(
    Array.from({ length: 3 }, (_, i) =>
      new Promise((resolve) => {
        const args = ['ledger', 'record', 'r', '--phase', 'p', '--role', 'coder', '--client-request-id', `c${i}`, '--task-id', `t${i}`]
        spawn(shim, args, { cwd }).on('close', resolve)
      }),
    ),
  )
  assert.deepEqual(codes, [0, 0, 0])
  assert.equal(JSON.parse(readFileSync(file(cwd), 'utf8')).children.length, 3)
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
