// Adversarial press tests: subprocess the real bin/t3-run against temp git repos.
import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test, { after } from 'node:test'
import { fileURLToPath } from 'node:url'

const repo = fileURLToPath(new URL('../../', import.meta.url))
const shim = join(repo, 'bin/t3-run')
const roleMap = JSON.parse(readFileSync(join(repo, 'skills/t3-core/role-map.json'), 'utf8'))
const temps = []
after(() => {
  for (const d of temps) rmSync(d, { recursive: true, force: true })
})
const tmp = (prefix) => {
  const d = realpathSync(mkdtempSync(join(tmpdir(), prefix)))
  temps.push(d)
  return d
}
const tempRepo = () => {
  const dir = tmp('t3-press-')
  spawnSync('git', ['init', '-q'], { cwd: dir })
  return dir
}
const run = (cwd, ...args) => spawnSync(shim, args, { cwd, encoding: 'utf8' })
const led = (cwd, ...args) => run(cwd, 'ledger', ...args)
const rec = (cwd, id, req, task, phase = 'p1') =>
  led(cwd, 'record', id, '--phase', phase, '--role', 'coder', '--client-request-id', req, '--task-id', task)
const ledgerFile = (cwd, id) => join(cwd, '.cheese/t3', `${id}.json`)
const noStack = (r) => assert.doesNotMatch(r.stderr, /node:internal|\.mjs:\d+/)
const put = (dir, name, text) => {
  const f = join(dir, name)
  writeFileSync(f, text)
  return f
}

test('ledger refuses unsafe run ids and writes nothing outside .cheese/t3', () => {
  const cwd = tempRepo()
  for (const id of ['a/b', '../x', '..', 'a..b', '', '.hidden', '-x', '/abs', 'a b']) {
    const r = led(cwd, 'init', id)
    assert.equal(r.status, 2, `id '${id}' should be a usage error: ${r.stderr}`)
  }
  const r = led(cwd, 'init', 'a'.repeat(300))
  assert.notEqual(r.status, 0, 'a 300-char run id must not succeed')
  noStack(r)
  assert.deepEqual(readdirSync(cwd).filter((f) => f !== '.git' && f !== '.cheese'), [], 'nothing written outside .cheese')
  const t3 = join(cwd, '.cheese/t3')
  assert.deepEqual(existsSync(t3) ? readdirSync(t3) : [], [])
})

test('record before init fails with a hint and creates no ledger', () => {
  const cwd = tempRepo()
  const r = rec(cwd, 'r1', 'c1', 't1')
  assert.equal(r.status, 1)
  assert.match(r.stderr, /ledger init/)
  assert.equal(existsSync(ledgerFile(cwd, 'r1')), false)
})

test('complete for an unknown task id exits 1 and leaves the ledger unchanged', () => {
  const cwd = tempRepo()
  led(cwd, 'init', 'r1')
  rec(cwd, 'r1', 'c1', 't1')
  const before = readFileSync(ledgerFile(cwd, 'r1'), 'utf8')
  const r = led(cwd, 'complete', 'r1', '--task-id', 'nope', '--status', 'completed')
  assert.equal(r.status, 1)
  assert.match(r.stderr, /no child with task id 'nope'/)
  assert.equal(readFileSync(ledgerFile(cwd, 'r1'), 'utf8'), before)
})

test('complete rejects a non-terminal status', () => {
  const cwd = tempRepo()
  led(cwd, 'init', 'r1')
  rec(cwd, 'r1', 'c1', 't1')
  assert.equal(led(cwd, 'complete', 'r1', '--task-id', 't1', '--status', 'running').status, 2)
})

test('REAL BUG: two parallel complete calls both land (lost update in read-modify-write)', async () => {
  const cwd = tempRepo()
  led(cwd, 'init', 'r1')
  const ids = Array.from({ length: 8 }, (_, i) => `t${i}`)
  for (const id of ids) rec(cwd, 'r1', `c-${id}`, id)
  const codes = await Promise.all(
    ids.map(
      (id) =>
        new Promise((resolve) => {
          const p = spawn(shim, ['ledger', 'complete', 'r1', '--task-id', id, '--status', 'completed'], { cwd })
          p.on('close', resolve)
        }),
    ),
  )
  assert.deepEqual(codes, ids.map(() => 0))
  const children = JSON.parse(readFileSync(ledgerFile(cwd, 'r1'), 'utf8')).children
  assert.deepEqual(
    children.filter((c) => c.status !== 'completed').map((c) => c.taskId),
    [],
    'every parallel complete must land',
  )
})

test('barrier on an unknown phase or a phase with no children exits 1', () => {
  const cwd = tempRepo()
  led(cwd, 'init', 'r1')
  assert.equal(led(cwd, 'barrier', 'r1', 'ghost').status, 1)
  rec(cwd, 'r1', 'c1', 't1', 'p1')
  assert.equal(led(cwd, 'barrier', 'r1', 'ghost').status, 1)
  assert.equal(led(cwd, 'barrier', 'r1', 'p1').status, 1, 'running child blocks')
  assert.equal(led(cwd, 'barrier', 'r1').status, 2, 'missing phase is a usage error')
})

test('status is an empty list once every child is terminal', () => {
  const cwd = tempRepo()
  led(cwd, 'init', 'r1')
  rec(cwd, 'r1', 'c1', 't1')
  rec(cwd, 'r1', 'c2', 't2')
  assert.equal(JSON.parse(led(cwd, 'status', 'r1').stdout).length, 2)
  for (const [t, s] of [['t1', 'failed'], ['t2', 'cancelled']]) led(cwd, 'complete', 'r1', '--task-id', t, '--status', s)
  const r = led(cwd, 'status', 'r1')
  assert.deepEqual(JSON.parse(r.stdout), [])
  assert.equal(led(cwd, 'barrier', 'r1', 'p1').status, 0)
})

test('record is idempotent on the same clientRequestId and task', () => {
  const cwd = tempRepo()
  led(cwd, 'init', 'r1')
  rec(cwd, 'r1', 'c1', 't1')
  assert.equal(rec(cwd, 'r1', 'c1', 't1').status, 0)
  assert.equal(JSON.parse(readFileSync(ledgerFile(cwd, 'r1'), 'utf8')).children.length, 1)
})

test('REAL BUG: duplicate clientRequestId with a different taskId is silently dropped', () => {
  const cwd = tempRepo()
  led(cwd, 'init', 'r1')
  rec(cwd, 'r1', 'c1', 't1')
  const r = rec(cwd, 'r1', 'c1', 't2')
  const children = JSON.parse(readFileSync(ledgerFile(cwd, 'r1'), 'utf8')).children
  assert.ok(r.status !== 0 || children.some((c) => c.taskId === 't2'), 'a conflicting record must fail or be stored, not exit 0 and vanish')
})

test('record rejects bad depth', () => {
  const cwd = tempRepo()
  led(cwd, 'init', 'r1')
  for (const d of ['-1', 'x', '1.5']) {
    const r = led(cwd, 'record', 'r1', '--phase', 'p', '--role', 'coder', '--client-request-id', 'c', '--task-id', 't', '--depth', d)
    assert.equal(r.status, 2, `depth ${d}`)
  }
})

test('corrupted ledger JSON gives a clear error and is not overwritten', () => {
  const cwd = tempRepo()
  led(cwd, 'init', 'r1')
  const file = ledgerFile(cwd, 'r1')
  writeFileSync(file, '{"run": "r1", "children": [')
  for (const args of [['status', 'r1'], ['barrier', 'r1', 'p1'], ['complete', 'r1', '--task-id', 't', '--status', 'failed']]) {
    const r = led(cwd, ...args)
    assert.notEqual(r.status, 0, args[0])
    assert.match(r.stderr, /^t3-run: /)
    assert.match(r.stderr, /r1|JSON/i, 'error should name the ledger or JSON')
    noStack(r)
  }
  const r = rec(cwd, 'r1', 'c', 't')
  assert.notEqual(r.status, 0)
  assert.equal(readFileSync(file, 'utf8'), '{"run": "r1", "children": [')
  assert.equal(led(cwd, 'init', 'r1').status, 0, 'init sees an existing file and leaves it')
  assert.equal(readFileSync(file, 'utf8'), '{"run": "r1", "children": [')
})

test('ledger from a subdirectory writes to the repo top-level only', () => {
  const cwd = tempRepo()
  const sub = join(cwd, 'a/b')
  mkdirSync(sub, { recursive: true })
  assert.equal(led(sub, 'init', 'r1').status, 0)
  assert.equal(existsSync(ledgerFile(cwd, 'r1')), true)
  assert.equal(existsSync(join(sub, '.cheese')), false)
})

test('ledger outside any git repo falls back to the cwd', () => {
  const dir = tmp('t3-nogit-')
  const r = led(dir, 'init', 'r1')
  assert.equal(r.status, 0, r.stderr)
  assert.equal(existsSync(ledgerFile(dir, 'r1')), true)
})

test('every role in role-map.json round-trips through role', () => {
  for (const [name, def] of Object.entries(roleMap)) {
    const r = run(repo, 'role', name)
    assert.equal(r.status, 0, `${name}: ${r.stderr}`)
    assert.deepEqual(JSON.parse(r.stdout), {
      providerInstanceId: def.providerInstanceId,
      model: def.model,
      options: def.options,
      isolation: def.isolation,
    })
  }
})

test('role rejects unknown, prototype-key, and wrong-arity input with exit 2', () => {
  for (const args of [['nope'], ['__proto__'], ['constructor'], ['toString'], [], ['coder', 'extra']]) {
    const r = run(repo, 'role', ...args)
    assert.equal(r.status, 2, JSON.stringify(args))
    noStack(r)
  }
})

test('role output options are fresh per call and do not mutate the role map file', () => {
  const before = readFileSync(join(repo, 'skills/t3-core/role-map.json'), 'utf8')
  const a = JSON.parse(run(repo, 'role', 'coder').stdout)
  a.options.poison = true
  assert.equal(JSON.parse(run(repo, 'role', 'coder').stdout).options.poison, undefined)
  assert.equal(readFileSync(join(repo, 'skills/t3-core/role-map.json'), 'utf8'), before)
})

const SHA = 'a'.repeat(40)
const validate = (role, text) => {
  const dir = tmp('t3-val-')
  return run(dir, 'validate', role, put(dir, 'r.json', text))
}

test('validate rejects non-JSON, arrays, two objects, and nested-empty objects', () => {
  for (const text of ['not json', '', '[1]', '[]', '{"status":"ok"}{"status":"ok"}', '{"a":{}}', '{"a":[],"b":"","c":null}', '"str"', '42', 'null']) {
    const r = validate('explorer', text)
    assert.equal(r.status, 1, `${text} -> ${r.stdout}${r.stderr}`)
    assert.ok(r.stdout.length > 0)
  }
})

test('validate: empty or blank status fails for shared and worktree roles', () => {
  assert.equal(validate('explorer', '{"status":""}').status, 1)
  assert.equal(validate('explorer', '{"status":"   ","x":1}').status, 1)
  assert.equal(validate('explorer', '{"status":"ok"}').status, 0)
  assert.equal(validate('coder', JSON.stringify({ status: '', branch: 'b', head_sha: SHA })).status, 1)
})

test('validate: write roles need a full sha and a branch', () => {
  const ok = { status: 'ok', branch: 'b', head_sha: SHA }
  assert.equal(validate('coder', JSON.stringify(ok)).status, 0)
  assert.equal(validate('press', JSON.stringify({ ...ok, head_sha: SHA.toUpperCase() })).status, 0)
  for (const bad of [{ ...ok, head_sha: 'abc1234' }, { ...ok, head_sha: SHA + 'a' }, { ...ok, head_sha: 'g'.repeat(40) }, { ...ok, head_sha: 5 }, { status: 'ok', head_sha: SHA }, { ...ok, branch: '' }]) {
    const r = validate('coder', JSON.stringify(bad))
    assert.equal(r.status, 1, JSON.stringify(bad))
  }
})

test('validate: unknown role and wrong arity are usage errors; missing file is usage error', () => {
  assert.equal(validate('nope', '{"status":"ok"}').status, 2)
  assert.equal(validate('__proto__', '{"status":"ok"}').status, 2)
  assert.equal(run(repo, 'validate', 'coder').status, 2)
  const r = run(repo, 'validate', 'coder', '/nonexistent/x.json')
  assert.equal(r.status, 2)
  noStack(r)
})

test('gate check-safe flags wrapper bypasses and passes a safe command', () => {
  const bad = [
    'env -S "git push --force"',
    'timeout --signal=KILL 5 git push --force',
    'doas -u root git push --force',
    'stdbuf -o0 git push --force',
    'git push --force',
  ]
  for (const cmd of bad) {
    const r = run(repo, 'gate', 'check-safe', cmd)
    assert.equal(r.status, 1, `${cmd} -> ${r.stdout}${r.stderr}`)
    assert.match(r.stdout, /^unsafe: /)
  }
  assert.equal(run(repo, 'gate', 'check-safe', 'ls -la').status, 0)
  assert.equal(run(repo, 'gate', 'check-safe').status, 2)
})

test('gate sha accepts uppercase and rejects short, long, and non-hex', () => {
  assert.equal(run(repo, 'gate', 'sha', SHA).status, 0)
  assert.equal(run(repo, 'gate', 'sha', SHA.toUpperCase()).status, 0)
  for (const s of ['', 'abc', SHA + 'a', 'z'.repeat(40), SHA + '\n']) assert.equal(run(repo, 'gate', 'sha', s).status, 1, JSON.stringify(s))
})

test('gate JSON inputs: malformed or wrong-shaped files fail with a message, not a stack', () => {
  const dir = tmp('t3-gj-')
  const bad = put(dir, 'bad.json', '{oops')
  const obj = put(dir, 'obj.json', '{}')
  const nul = put(dir, 'null.json', 'null')
  const missing = join(dir, 'missing.json')
  const cases = [
    ['merge-curds', bad], ['merge-curds', obj], ['merge-curds', missing],
    ['ranges', bad], ['ranges', obj],
    ['route-findings', bad, obj], ['route-findings', obj, obj], ['route-findings', nul, obj], ['route-findings', bad], ['route-findings', put(dir, 'f.json', '[]'), nul],
  ]
  for (const args of cases) {
    const r = run(repo, 'gate', ...args)
    assert.notEqual(r.status, 0, JSON.stringify(args))
    assert.match(r.stderr, /^t3-run: /, JSON.stringify(args))
    noStack(r)
  }
  assert.equal(run(repo, 'gate', 'nope').status, 2)
  assert.equal(run(repo, 'gate').status, 2)
})

test('route-findings with an empty findings array exits 0 and routes nothing', () => {
  const dir = tmp('t3-rf-')
  const r = run(repo, 'gate', 'route-findings', put(dir, 'f.json', '[]'), put(dir, 's.json', '{}'))
  assert.equal(r.status, 0, r.stderr)
  assert.deepEqual(JSON.parse(r.stdout).bySlug, {})
})

test('bin/t3-run works through a symlink in another directory', () => {
  const dir = tmp('t3-link-')
  const link = join(dir, 'tr')
  symlinkSync(shim, link)
  const r = spawnSync(link, ['role', 'coder'], { cwd: dir, encoding: 'utf8' })
  assert.equal(r.status, 0, r.stderr)
  assert.equal(JSON.parse(r.stdout).isolation, 'worktree')
  const nested = join(dir, 'x')
  mkdirSync(nested)
  symlinkSync(link, join(nested, 'tr2'))
  assert.equal(spawnSync(join(nested, 'tr2'), ['gate', 'sha', SHA], { cwd: dir }).status, 0)
})

test('unknown command prints usage and exits 2; --help exits 0', () => {
  assert.equal(run(repo, 'bogus').status, 2)
  assert.equal(run(repo).status, 2)
  assert.equal(run(repo, '--help').status, 0)
})
