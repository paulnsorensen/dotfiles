import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test, { after } from 'node:test'
import { fileURLToPath } from 'node:url'

const repo = fileURLToPath(new URL('../../', import.meta.url))
const shim = join(repo, 'bin/t3-run')
const temps = []
after(() => {
  for (const d of temps) rmSync(d, { recursive: true, force: true })
})

const tempRepo = () => {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), 't3-ledger-')))
  temps.push(dir)
  spawnSync('git', ['init', '-q'], { cwd: dir })
  return dir
}
const cli = (cwd, ...args) => spawnSync(shim, ['ledger', ...args], { cwd, encoding: 'utf8' })
const rec = (cwd, run, phase, id, task, role = 'coder') =>
  cli(cwd, 'record', run, '--phase', phase, '--role', role, '--client-request-id', id, '--task-id', task)
const ledgerFile = (cwd, run) => join(cwd, '.cheese/t3', `${run}.json`)

test('init writes the ledger under the git top-level, even from a subdirectory', () => {
  const cwd = tempRepo()
  const sub = join(cwd, 'deep/er')
  mkdirSync(sub, { recursive: true })
  assert.equal(cli(sub, 'init', 'run-1', '--skill', 't3-cook').status, 0)
  const ledger = JSON.parse(readFileSync(ledgerFile(cwd, 'run-1'), 'utf8'))
  assert.equal(ledger.skill, 't3-cook')
  assert.deepEqual(ledger.children, [])
  assert.deepEqual(readdirSync(join(cwd, '.cheese/t3')), ['run-1.json'])
})

test('ledger falls back to the cwd outside a git repo', () => {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), 't3-nogit-')))
  temps.push(dir)
  assert.equal(cli(dir, 'init', 'r').status, 0)
  assert.ok(existsSync(ledgerFile(dir, 'r')))
})

test('an unsafe run id is rejected with exit 2', () => {
  const cwd = tempRepo()
  for (const bad of ['../x', 'a/b', '..', 'a..b', '.hidden', '']) {
    assert.equal(cli(cwd, 'init', bad).status, 2, JSON.stringify(bad))
  }
  assert.ok(!existsSync(join(cwd, '.cheese')))
})

test('record is idempotent per clientRequestId and a new id is a new child', () => {
  const cwd = tempRepo()
  cli(cwd, 'init', 'r')
  assert.equal(rec(cwd, 'r', 'build', 'r/build/coder/1', 't1').status, 0)
  assert.equal(rec(cwd, 'r', 'build', 'r/build/coder/1', 't1').status, 0)
  assert.equal(JSON.parse(readFileSync(ledgerFile(cwd, 'r'), 'utf8')).children.length, 1)
  rec(cwd, 'r', 'build', 'r/build/coder/2', 't2')
  assert.equal(JSON.parse(readFileSync(ledgerFile(cwd, 'r'), 'utf8')).children.length, 2)
})

test('record stores the depth and defaults it to 1', () => {
  const cwd = tempRepo()
  cli(cwd, 'init', 'r')
  rec(cwd, 'r', 'p', 'c1', 't1')
  cli(cwd, 'record', 'r', '--phase', 'p', '--role', 'coder', '--client-request-id', 'c2', '--task-id', 't2', '--depth', '2')
  const [a, b] = JSON.parse(readFileSync(ledgerFile(cwd, 'r'), 'utf8')).children
  assert.deepEqual([a.depth, b.depth], [1, 2])
})

test('status lists only non-terminal children, so resume skips finished work', () => {
  const cwd = tempRepo()
  cli(cwd, 'init', 'r')
  rec(cwd, 'r', 'p', 'c1', 't1')
  rec(cwd, 'r', 'p', 'c2', 't2')
  rec(cwd, 'r', 'p', 'c3', 't3')
  cli(cwd, 'complete', 'r', '--task-id', 't1', '--status', 'completed', '--head-sha', 'a'.repeat(40), '--result-file', 'out.json')
  cli(cwd, 'complete', 'r', '--task-id', 't3', '--status', 'failed')
  const r = cli(cwd, 'status', 'r')
  assert.equal(r.status, 0)
  assert.deepEqual(JSON.parse(r.stdout).map((c) => c.taskId), ['t2'])
  const done = JSON.parse(readFileSync(ledgerFile(cwd, 'r'), 'utf8')).children[0]
  assert.equal(done.headSha, 'a'.repeat(40))
  assert.equal(done.resultFile, 'out.json')
})

test('complete rejects a non-terminal status and an unknown task id', () => {
  const cwd = tempRepo()
  cli(cwd, 'init', 'r')
  rec(cwd, 'r', 'p', 'c1', 't1')
  assert.equal(cli(cwd, 'complete', 'r', '--task-id', 't1', '--status', 'running').status, 2)
  assert.equal(cli(cwd, 'complete', 'r', '--task-id', 'zz', '--status', 'completed').status, 1)
})

test('barrier passes only when the phase has children and all are terminal', () => {
  const cwd = tempRepo()
  cli(cwd, 'init', 'r')
  assert.equal(cli(cwd, 'barrier', 'r', 'p').status, 1)
  rec(cwd, 'r', 'p', 'c1', 't1')
  rec(cwd, 'r', 'p', 'c2', 't2')
  rec(cwd, 'r', 'other', 'c3', 't3')
  cli(cwd, 'complete', 'r', '--task-id', 't1', '--status', 'completed')
  const pending = cli(cwd, 'barrier', 'r', 'p')
  assert.equal(pending.status, 1)
  assert.deepEqual(pending.stdout.split('\n').filter(Boolean), ['t2'])
  cli(cwd, 'complete', 'r', '--task-id', 't2', '--status', 'blocked')
  assert.equal(cli(cwd, 'barrier', 'r', 'p').status, 0)
  assert.equal(cli(cwd, 'barrier', 'r', 'other').status, 1)
})

test('a missing ledger exits 1 and leaves no temp files', () => {
  const cwd = tempRepo()
  assert.equal(cli(cwd, 'status', 'nope').status, 1)
  cli(cwd, 'init', 'r')
  rec(cwd, 'r', 'p', 'c1', 't1')
  assert.deepEqual(readdirSync(join(cwd, '.cheese/t3')), ['r.json'])
})
