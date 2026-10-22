import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const repo = fileURLToPath(new URL('../../', import.meta.url))
const shim = join(repo, 'bin/t3-run')
const roleMap = JSON.parse(readFileSync(join(repo, 'skills/t3-core/role-map.json'), 'utf8'))
const cli = (...args) => spawnSync(shim, args, { cwd: tmpdir(), encoding: 'utf8' })

test('role prints the map entry for every role, from a directory outside the repo', () => {
  for (const [role, target] of Object.entries(roleMap)) {
    const r = cli('role', role)
    assert.equal(r.status, 0, role)
    assert.deepEqual(JSON.parse(r.stdout), target)
  }
})

test('role advisor prints the gpt-6-astra target', () => {
  const out = JSON.parse(cli('role', 'advisor').stdout)
  assert.equal(out.model, 'gpt-6-astra')
  assert.equal(out.providerInstanceId, 'codex')
})

test('role rejects an unknown role with exit 2 and the known roles', () => {
  const r = cli('role', 'nope')
  assert.equal(r.status, 2)
  assert.match(r.stderr, /unknown role 'nope'/)
  assert.match(r.stderr, /advisor/)
  assert.match(r.stderr, /coder/)
})

test('shim resolves its real path through a symlink and execs claude/t3-run/t3-run.mjs', async () => {
  const { mkdtempSync, symlinkSync, rmSync } = await import('node:fs')
  const dir = mkdtempSync(join(tmpdir(), 't3-link-'))
  try {
    assert.ok(existsSync(join(repo, 'claude/t3-run/t3-run.mjs')))
    symlinkSync(shim, join(dir, 't3-run'))
    const r = spawnSync(join(dir, 't3-run'), ['role', 'coder'], { encoding: 'utf8' })
    assert.equal(r.status, 0)
    assert.equal(JSON.parse(r.stdout).isolation, 'worktree')
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('an unknown command exits 2 with usage', () => {
  const r = cli('bogus')
  assert.equal(r.status, 2)
  assert.match(r.stderr, /Usage: t3-run/)
})
