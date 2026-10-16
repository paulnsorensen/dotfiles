import assert from 'node:assert/strict'
import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import { MODULES_DIR, listModules, readHeader } from '../../claude/workflow-prelude/load.mjs'

const repo = fileURLToPath(new URL('../../', import.meta.url))

// These scripts still hold local copies of module names.
// The integrator removes each entry after its curd merges and adopts the modules.
const PENDING_ADOPTION = ['claude/workflows/move-my-cheese.js']

const BEGIN = /^\/\/ BEGIN module (\S+)$/
const END = /^\/\/ END module (\S+)$/
const DECLARATION = /^(?:export\s+)?(?:async\s+function|function|const|let)\s*\*?\s*([A-Za-z_$][\w$]*)/
const DESTRUCTURED = /^(?:const|let)\s*[{[]([^}\]=]*)[}\]]\s*=/

// Every name that some module provides, mapped to the module.
const provided = () => {
  const names = new Map()
  for (const m of listModules()) {
    const src = readFileSync(join(MODULES_DIR, `${m}.js`), 'utf8')
    for (const name of readHeader(src).provides) names.set(name, m)
  }
  return names
}

// Returns { name, line, module } for each top-level declaration outside module blocks whose name a module provides.
export function duplicatesIn(text, names = provided()) {
  const found = []
  let inside = false
  text.split('\n').forEach((raw, i) => {
    const line = raw.replace(/\r$/, '')
    if (BEGIN.test(line)) inside = true
    else if (END.test(line)) inside = false
    else if (!inside) {
      const declared = DECLARATION.exec(line)?.[1]
      const pulled = DESTRUCTURED.exec(line)?.[1].split(',').map((p) => p.split(':').pop().trim()).filter(Boolean) ?? []
      for (const name of [declared, ...pulled]) {
        if (name && names.has(name)) found.push({ name, line: i + 1, module: names.get(name) })
      }
    }
  })
  return found
}

const scripts = readdirSync(join(repo, 'claude/workflows'))
  .filter((f) => f.endsWith('.js'))
  .map((f) => `claude/workflows/${f}`)

for (const rel of scripts) {
  const pending = PENDING_ADOPTION.includes(rel)
  test(`${rel} declares no module-provided name outside its module blocks${pending ? ' (pending adoption)' : ''}`, { skip: pending && 'pending adoption' }, () => {
    const dups = duplicatesIn(readFileSync(join(repo, rel), 'utf8'))
    assert.deepEqual(dups.map((d) => `${d.name}:${d.line} (module ${d.module})`), [])
  })
}

test('PENDING_ADOPTION names real scripts', () => {
  for (const rel of PENDING_ADOPTION) assert.ok(scripts.includes(rel), `${rel} is not a workflow script`)
})

test('the scanner flags a duplicate outside a module block', () => {
  const text = [
    'const LIMITS = {}',
    '// BEGIN module fanout',
    'const chunk = (a) => a',
    '// END module fanout',
    'const dedupe = (a) => a',
    'async function safeAgent() {}',
    'function errorMessage() {}',
    'const { floorReached, other } = x',
    'const mine = 1',
  ].join('\n')
  const found = duplicatesIn(text, new Map([['chunk', 'fanout'], ['dedupe', 'fanout'], ['safeAgent', 'fanout'], ['errorMessage', 'fanout'], ['floorReached', 'budget']]))
  assert.deepEqual(found.map((d) => d.name), ['dedupe', 'safeAgent', 'errorMessage', 'floorReached'])
})

test('the scanner passes a script with no duplicate', () => {
  assert.deepEqual(duplicatesIn('const mine = 1\nfunction local() {}', new Map([['chunk', 'fanout']])), [])
})
