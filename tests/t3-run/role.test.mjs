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
    const r = cli('role', role, '--depth', '1')
    assert.equal(r.status, 0, role)
    assert.deepEqual(JSON.parse(r.stdout), { role, ...target })
  }
})

test('role advisor prints the gpt-6-astra target', () => {
  const out = JSON.parse(cli('role', 'advisor', '--depth', '1').stdout)
  assert.equal(out.model, 'gpt-6-astra')
  assert.equal(out.providerInstanceId, 'codex')
})

test('role rejects an unknown role with exit 2 and the known roles', () => {
  const r = cli('role', 'nope', '--depth', '1')
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
    const r = spawnSync(join(dir, 't3-run'), ['role', 'coder', '--depth', '1'], { encoding: 'utf8' })
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

test('role --depth is the child depth: 1 and 2 pass, 3 exits 1, missing and non-integer exit 2', () => {
  for (const d of ['1', '2']) assert.equal(cli('role', 'coder', '--depth', d).status, 0, d)
  const over = cli('role', 'coder', '--depth', '3')
  assert.equal(over.status, 1)
  assert.match(over.stderr, /child depth 3 exceeds the cap of 2/)
  assert.equal(cli('role', 'coder', '--depth', '9').status, 1)
  assert.equal(cli('role', 'coder').status, 2)
  assert.equal(cli('role', '--agent-type', 'coder').status, 2)
  for (const d of ['abc', '0', '-1', '1.5']) {
    const r = cli('role', 'coder', '--depth', d)
    assert.equal(r.status, 2, d)
    assert.doesNotMatch(r.stderr, /exceeds the cap/, d)
  }
})

const viaType = (type, tier, mode) =>
  cli('role', '--agent-type', type, ...(tier ? ['--tier', tier] : []), ...(mode ? ['--mode', mode] : []), '--depth', '1')
const roleOf = (r) => JSON.parse(r.stdout).role

test('--agent-type resolves judge by mode and tier, explorer by tier, and prints the resolved role', () => {
  const advise = JSON.parse(viaType('judge', 'opus', 'advise').stdout)
  assert.equal(advise.role, 'advisor')
  assert.equal(advise.model, 'gpt-6-astra')
  assert.equal(advise.options.reasoningEffort, 'high')
  assert.equal(roleOf(viaType('judge', undefined, 'advise')), 'advisor')
  assert.equal(roleOf(viaType('judge', 'opus')), 'advisor')
  assert.equal(roleOf(viaType('judge', 'sonnet', 'verify')), 'gate-runner')
  assert.equal(roleOf(viaType('judge', undefined, 'verify')), 'gate-runner')
  assert.equal(roleOf(viaType('judge')), 'gate-runner')
  assert.equal(roleOf(viaType('explorer', 'opus')), 'planner')
  assert.equal(roleOf(viaType('explorer', 'haiku')), 'explorer')
  assert.equal(roleOf(viaType('explorer')), 'explorer')
  assert.equal(roleOf(viaType('Plan')), 'planner')
  for (const alias of ['general-purpose', 'generalist', 'general']) assert.equal(roleOf(viaType(alias)), 'explorer', alias)
  assert.equal(roleOf(cli('role', '--agent-type', 'coder', '--depth', '2')), 'coder')
  assert.equal(cli('role', '--agent-type', 'coder', '--depth', '3').status, 1)
})

test('--agent-type rejects a misspelt tier or mode with exit 2 naming the accepted values', () => {
  const mode = viaType('judge', undefined, 'advize')
  assert.equal(mode.status, 2)
  assert.match(mode.stderr, /unknown mode 'advize'/)
  assert.match(mode.stderr, /advise, verify/)
  assert.equal(viaType('coder', undefined, 'advise').status, 2)
  const tier = viaType('explorer', 'opsu')
  assert.equal(tier.status, 2)
  assert.match(tier.stderr, /unknown tier 'opsu'/)
  assert.match(tier.stderr, /opus, sonnet, haiku/)
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

// Returns the text of the object literal that holds the key at `index`.
function enclosingLiteral(src, index) {
  let depth = 0
  let start = index
  while (start > 0) {
    start--
    if (src[start] === '}') depth++
    else if (src[start] === '{' && depth-- === 0) break
  }
  depth = 0
  let end = start
  for (; end < src.length; end++) {
    if (src[end] === '{') depth++
    else if (src[end] === '}' && --depth === 0) break
  }
  return src.slice(start, end + 1)
}

const WORKFLOWS = ['cheese-factory', 'move-my-cheese', 'brie-ground', 'age-fanout', 'cheese-board']
const CONST_RE = /(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(['"])([^'"]+)\2/g
const VALUE_RE = /(?:(['"])([^'"]+)\1|([A-Za-z_$][\w$]*))/

test('every agentType, tier, and Judge mode in the workflow sources resolves to the expected role', () => {
  const seen = new Map()
  for (const name of WORKFLOWS) {
    const src = readFileSync(join(repo, 'claude/workflows', `${name}.js`), 'utf8')
    const consts = Object.fromEntries([...src.matchAll(CONST_RE)].map((m) => [m[1], m[3]]))
    const valueOf = (m) => (m[2] ?? consts[m[3]])
    const keys = [...src.matchAll(/(?<![.\w$])agentType\b(?=\s*[:,}])/g)]
    let resolved = 0
    for (const key of keys) {
      const literal = enclosingLiteral(src, key.index)
      const typeMatch = literal.match(new RegExp(`(?<![.\\w$])agentType\\s*:\\s*${VALUE_RE.source}`))
      const type = typeMatch && valueOf(typeMatch)
      assert.ok(type, `${name}: unresolved agentType near ${src.slice(key.index, key.index + 40)}`)
      const modelMatch = literal.match(new RegExp(`(?<![.\\w$])model\\s*:\\s*${VALUE_RE.source}`))
      const tier = (modelMatch && valueOf(modelMatch)) ?? ''
      seen.set(`${type}|${tier}|`, name)
      resolved++
    }
    assert.equal(resolved, keys.length, `${name}: every agentType key resolves`)
    for (const m of src.matchAll(/judgePrompt\(\s*(['"])([a-z]+)\1/g)) seen.set(`judge||${m[2]}`, name)
  }
  const keys = [...seen.keys()]
  for (const expected of ['judge||advise', 'judge||verify', 'judge|opus|', 'judge|sonnet|', 'coder|sonnet|']) {
    assert.ok(keys.includes(expected), `scan finds ${expected}`)
  }
  assert.ok(keys.some((k) => k.startsWith('explorer|')), 'scan finds explorer')
  const expectedRole = { 'judge||advise': 'advisor', 'judge||verify': 'gate-runner', 'judge|opus|': 'advisor', 'judge|sonnet|': 'gate-runner', 'explorer|opus|': 'planner' }
  for (const key of keys) {
    const [type, tier, mode] = key.split('|')
    const r = viaType(type, tier || undefined, mode || undefined)
    assert.equal(r.status, 0, `${key}: ${r.stderr}`)
    assert.ok(Object.hasOwn(roleMap, roleOf(r)), key)
    if (expectedRole[key]) assert.equal(roleOf(r), expectedRole[key], key)
  }
  const advisor = JSON.parse(viaType('judge', 'opus', 'advise').stdout)
  assert.deepEqual([advisor.model, advisor.options.reasoningEffort], ['gpt-6-astra', 'high'])
})
