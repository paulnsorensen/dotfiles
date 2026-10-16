// Loads one workflow-prelude module for tests and tools. It needs no Workflow runtime.
// A module file is a plain script fragment. Line 1 is its header: // module: <name>; provides: a, b; requires: x, y
import { readdirSync, readFileSync } from 'node:fs'
import { basename, dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createContext, runInContext } from 'node:vm'

export const MODULES_DIR = resolve(dirname(fileURLToPath(import.meta.url)), 'modules')

const HEADER = /^\/\/ module: ([A-Za-z][\w-]*); provides: (.+); requires: (.+)$/
const names = (list) => (list.trim() === 'none' ? [] : list.split(',').map((n) => n.trim()))

// Names of every module file in dir, sorted. Tests pass a temp dir.
export const listModules = (dir = MODULES_DIR) =>
  readdirSync(dir).filter((f) => f.endsWith('.js')).map((f) => basename(f, '.js')).sort()

// Parses line 1 of a module source into { name, provides, requires }. Throws when the header is malformed.
export function readHeader(src) {
  const m = HEADER.exec(src.split('\n', 1)[0].replace(/\r$/, ''))
  if (!m) throw new Error('module header must be: // module: <name>; provides: a, b; requires: x, y (or requires: none)')
  const provides = names(m[2])
  const requires = names(m[3])
  if (!provides.length || [...provides, ...requires].some((n) => !/^[A-Za-z_$][\w$]*$|^[A-Za-z][\w-]*$/.test(n))) {
    throw new Error(`module header lists a bad name: ${m[0]}`)
  }
  return { name: m[1], provides, requires }
}

export const readModule = (name, dir = MODULES_DIR) => readFileSync(join(dir, `${name}.js`), 'utf8')

// Returns the module and its transitive requirements in dependency order.
function closure(name, dir) {
  const order = []
  const state = new Map()
  const visit = (n, from) => {
    if (state.get(n) === 'done') return
    if (state.get(n) === 'active') throw new Error(`module ${n} requires itself through ${from}`)
    if (!listModules(dir).includes(n)) throw new Error(`unknown module ${n}${from ? ` (required by ${from})` : ''}`)
    state.set(n, 'active')
    const src = readModule(n, dir)
    const header = readHeader(src)
    if (header.name !== n) throw new Error(`module file ${n}.js declares name ${header.name}`)
    for (const r of header.requires) visit(r, n)
    state.set(n, 'done')
    order.push({ header, src })
  }
  visit(name, '')
  return order
}

// Evaluates the module and its requirements in one vm context seeded with globals. Returns every provided name.
export function loadModule(name, { globals = {}, dir = MODULES_DIR } = {}) {
  const order = closure(name, dir)
  const { provides } = order[order.length - 1].header
  const script = `${order.map((o) => o.src).join('\n')}\n;({ ${provides.join(', ')} })`
  return runInContext(script, createContext({ ...globals }), { filename: `${name}.js` })
}
