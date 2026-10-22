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
    assert.deepEqual(JSON.parse(r.stdout), { role, ...target })
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

const SPEC = {
  reviewer: ['claudeAgent', 'claude-opus-5-5', 'effort', 'high', 'shared'],
  planner: ['claudeAgent', 'claude-opus-5-5', 'effort', 'high', 'shared'],
  'taste-test': ['claudeAgent', 'claude-opus-5-5', 'effort', 'medium', 'shared'],
  'second-reviewer': ['codex', 'gpt-6.1-sol', 'reasoningEffort', 'high', 'shared'],
  advisor: ['codex', 'gpt-6-astra', 'reasoningEffort', 'high', 'shared'],
  coder: ['claudeAgent', 'claude-sonnet-5-5', 'effort', 'medium', 'worktree'],
  press: ['claudeAgent', 'claude-sonnet-5-5', 'effort', 'medium', 'worktree'],
  cure: ['claudeAgent', 'claude-sonnet-5-5', 'effort', 'medium', 'worktree'],
  continuation: ['claudeAgent', 'claude-sonnet-5-5', 'effort', 'medium', 'worktree'],
  explorer: ['claudeAgent', 'claude-sonnet-5-5', 'effort', 'low', 'shared'],
  researcher: ['claudeAgent', 'claude-sonnet-5-5', 'effort', 'medium', 'shared'],
  'gate-runner': ['claudeAgent', 'claude-haiku-5-5', 'effort', 'low', 'shared'],
  runner: ['claudeAgent', 'claude-haiku-5-5', 'effort', 'low', 'shared'],
  recon: ['claudeAgent', 'claude-haiku-5-5', 'effort', 'low', 'shared'],
  'worktree-digest': ['claudeAgent', 'claude-haiku-5-5', 'effort', 'low', 'shared'],
  formatter: ['codex', 'gpt-6-luna', 'reasoningEffort', 'medium', 'shared'],
  verifier: ['codex', 'gpt-6-luna', 'reasoningEffort', 'medium', 'shared'],
}

test('role-map pins provider, model, effort key and value, and isolation for every role', () => {
  assert.deepEqual(Object.keys(roleMap).sort(), Object.keys(SPEC).sort())
  for (const [role, [providerInstanceId, model, key, value, isolation]] of Object.entries(SPEC)) {
    assert.deepEqual(roleMap[role], { providerInstanceId, model, options: { [key]: value }, isolation }, role)
  }
  for (const role of ['formatter', 'verifier']) {
    assert.ok(['medium', 'high', 'xhigh'].includes(roleMap[role].options.reasoningEffort), `${role} Luna effort must be medium or higher`)
  }
})

test('role --depth accepts 0..2 and refuses 3 before launch with exit 1', () => {
  for (const d of ['0', '1', '2']) assert.equal(cli('role', 'coder', '--depth', d).status, 0, d)
  const r = cli('role', 'coder', '--depth', '3')
  assert.equal(r.status, 1)
  assert.match(r.stderr, /depth 3 exceeds the cap of 2/)
  for (const d of ['-1', '1.5', 'x']) assert.equal(cli('role', 'coder', '--depth', d).status, 1, d)
})

const viaType = (type, tier, mode) =>
  cli('role', '--agent-type', type, ...(tier ? ['--tier', tier] : []), ...(mode ? ['--mode', mode] : []))
const roleOf = (r) => JSON.parse(r.stdout).role

test('--agent-type resolves judge by mode, explorer by tier, and prints the resolved role', () => {
  const advise = JSON.parse(viaType('judge', undefined, 'advise').stdout)
  assert.equal(advise.role, 'advisor')
  assert.equal(advise.model, 'gpt-6-astra')
  assert.equal(roleOf(viaType('judge', undefined, 'verify')), 'verifier')
  assert.equal(roleOf(viaType('judge')), 'verifier')
  assert.equal(roleOf(viaType('explorer', 'opus')), 'planner')
  assert.equal(roleOf(viaType('explorer', 'haiku')), 'explorer')
  assert.equal(roleOf(viaType('explorer')), 'explorer')
  assert.equal(roleOf(viaType('Plan')), 'planner')
  assert.equal(roleOf(cli('role', '--agent-type', 'coder', '--depth', '2')), 'coder')
  assert.equal(cli('role', '--agent-type', 'coder', '--depth', '3').status, 1)
})

test('--agent-type rejects an unknown type with exit 2 naming the known types', () => {
  const r = viaType('nope')
  assert.equal(r.status, 2)
  assert.match(r.stderr, /unknown agent type 'nope'/)
  assert.match(r.stderr, /judge/)
  assert.match(r.stderr, /whey-drainer/)
})

test('every agent-type rule names a role that exists in role-map.json', () => {
  const rules = JSON.parse(readFileSync(join(repo, 'skills/t3-core/agent-type-rules.json'), 'utf8'))
  assert.ok(Array.isArray(rules) && rules.length > 0)
  for (const rule of rules) assert.ok(Object.hasOwn(roleMap, rule.role), `${rule.agentType} -> ${rule.role}`)
})

test('every agentType, tier, and Judge mode in the workflow sources resolves to a role', () => {
  const seen = new Set()
  for (const name of ['cheese-factory', 'move-my-cheese', 'brie-ground', 'age-fanout']) {
    const src = readFileSync(join(repo, 'claude/workflows', `${name}.js`), 'utf8')
    const consts = Object.fromEntries([...src.matchAll(/const ([A-Z_]+) = '([^']+)'/g)].map((m) => [m[1], m[2]]))
    for (const line of src.split('\n')) {
      const m = line.match(/agentType: *(?:'([^']+)'|([A-Z_]+))/)
      if (!m) continue
      const type = m[1] ?? consts[m[2]]
      assert.ok(type, `${name}: unresolved agentType ${m[2]}`)
      const model = line.match(/model: *(?:'([a-z]+)'|([A-Z_]+))/)
      const tier = model ? (model[1] ?? consts[model[2]]) : ''
      seen.add(`${type}|${tier}|`)
    }
    for (const m of src.matchAll(/judgePrompt\('([a-z]+)'/g)) seen.add(`judge||${m[1]}`)
  }
  assert.ok([...seen].includes('judge||advise'), 'scan finds the advise judge mode')
  assert.ok([...seen].some((k) => k.startsWith('explorer|')), 'scan finds explorer')
  for (const key of seen) {
    const [type, tier, mode] = key.split('|')
    const r = viaType(type, tier || undefined, mode || undefined)
    assert.equal(r.status, 0, `${key}: ${r.stderr}`)
    assert.ok(Object.hasOwn(roleMap, roleOf(r)), key)
  }
})
