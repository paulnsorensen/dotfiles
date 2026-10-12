import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const repo = fileURLToPath(new URL('../../', import.meta.url))
const syncScript = join(repo, 'claude/workflow-prelude/sync.mjs')
const sourcePath = join(repo, 'claude/workflow-prelude/prelude.js')
const WORKFLOWS = ['claude/workflows/cheese-factory.js', 'claude/workflows/move-my-cheese.js']
const NAMES = [
  'SCRATCH_PATH_SRC', 'SCRATCH_WORKTREE_RE', 'FULL_SHA_RE', 'floorReached', 'form', 'substance',
  'errorText', 'schemaErrors', 'data', 'prompt', 'redoPrompt', 'repairPrompt',
]
const BEGIN = '// BEGIN shared prelude: test fixture\n'
const END = '// END shared prelude\n'

const run = (...args) => spawnSync(process.execPath, [syncScript, ...args], { encoding: 'utf8' })
const fixture = (files) => {
  const dir = mkdtempSync(join(tmpdir(), 'prelude-'))
  const source = join(dir, 'prelude.js')
  writeFileSync(source, 'const a = 1\n')
  const paths = Object.entries(files).map(([name, text]) => {
    const p = join(dir, name)
    writeFileSync(p, text)
    return p
  })
  return { source, paths }
}
const declaration = (name) => new RegExp(`^(const|function) ${name}\\b`, 'm')

test('sync --check exits 0 on the real workflows', () => {
  const r = run('--check')
  assert.equal(r.status, 0, r.stderr)
})

test('each real workflow block equals the prelude source', () => {
  const source = readFileSync(sourcePath, 'utf8')
  for (const file of WORKFLOWS) {
    const text = readFileSync(join(repo, file), 'utf8')
    const begin = text.indexOf('// BEGIN shared prelude')
    const end = text.indexOf('// END shared prelude')
    assert.ok(begin > 0 && end > begin, file)
    assert.equal(text.slice(text.indexOf('\n', begin) + 1, end), source, file)
  }
})

test('prelude declares exactly the twelve shared names, each with one lead comment, and exports nothing', () => {
  const lines = readFileSync(sourcePath, 'utf8').split('\n')
  assert.equal(lines.some((l) => /^\s*export\b/.test(l)), false)
  const declared = lines.flatMap((l, i) => {
    const m = /^(?:const|function) (\w+)/.exec(l)
    return m ? [{ name: m[1], i }] : []
  })
  assert.deepEqual(declared.map((d) => d.name).sort(), [...NAMES].sort())
  for (const { name, i } of declared) {
    assert.match(lines[i - 1], /^\/\//, `${name} lead comment`)
    assert.doesNotMatch(lines[i - 2] ?? '', /^\/\//, `${name} has one lead comment`)
  }
})

test('each workflow declares every prelude name once, inside the block, after meta', () => {
  for (const file of WORKFLOWS) {
    const text = readFileSync(join(repo, file), 'utf8')
    const begin = text.indexOf('// BEGIN shared prelude')
    const end = text.indexOf('// END shared prelude')
    assert.ok(text.indexOf('export const meta') < begin, file)
    for (const name of NAMES) {
      const all = text.match(new RegExp(declaration(name).source, 'gm')) ?? []
      assert.equal(all.length, 1, `${file} ${name}`)
      const at = text.search(declaration(name))
      assert.ok(at > begin && at < end, `${file} ${name} inside block`)
    }
  }
})

test('cheese-factory has no SHA_RE and move-my-cheese keeps its 7-to-40-hex SHA_RE', () => {
  assert.doesNotMatch(readFileSync(join(repo, WORKFLOWS[0]), 'utf8'), /^const SHA_RE\b/m)
  assert.match(readFileSync(join(repo, WORKFLOWS[1]), 'utf8'), /^const SHA_RE = \/\^\[0-9a-f\]\{7,40\}\$\/i$/m)
})

test('sync writes only between the markers and a second run changes nothing', () => {
  const before = `head line\n${BEGIN}OLD\n${END}tail line\n`
  const { source, paths } = fixture({ 'a.js': before })
  const first = run('--source', source, paths[0])
  assert.equal(first.status, 0, first.stderr)
  const after = readFileSync(paths[0], 'utf8')
  assert.equal(after, `head line\n${BEGIN}const a = 1\n${END}tail line\n`)
  const second = run('--source', source, paths[0])
  assert.equal(second.status, 0)
  assert.equal(second.stdout, '')
  assert.equal(readFileSync(paths[0], 'utf8'), after)
  assert.equal(run('--check', '--source', source, paths[0]).status, 0)
})

test('sync --check exits nonzero and names the file when a block drifted', () => {
  const { source, paths } = fixture({ 'drift.js': `x\n${BEGIN}stale\n${END}y\n` })
  const r = run('--check', '--source', source, paths[0])
  assert.notEqual(r.status, 0)
  assert.ok(r.stderr.includes(paths[0]), r.stderr)
  assert.equal(readFileSync(paths[0], 'utf8'), `x\n${BEGIN}stale\n${END}y\n`)
})

test('sync --check exits nonzero and names the file with zero or duplicate marker pairs', () => {
  const pair = `${BEGIN}const a = 1\n${END}`
  const { source, paths } = fixture({ 'none.js': 'no markers\n', 'twice.js': `${pair}${pair}` })
  for (const p of paths) {
    const r = run('--check', '--source', source, p)
    assert.notEqual(r.status, 0, p)
    assert.ok(r.stderr.includes(p), r.stderr)
    const w = run('--source', source, p)
    assert.notEqual(w.status, 0, p)
  }
})
