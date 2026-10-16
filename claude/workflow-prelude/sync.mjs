#!/usr/bin/env node
// Vendors each prelude module into the marked blocks of the workflow scripts.
// Usage: node claude/workflow-prelude/sync.mjs [--check] [--modules-dir <dir>] [workflow-file ...]
// Without file arguments, the targets are the claude/workflows/*.js files that hold a BEGIN module marker.
// A block is the line pair "// BEGIN module <name>" and "// END module <name>". Its body is the module file text.
// Without --check, the script writes. With --check, it exits 1 and names each target and module that differs.
import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { MODULES_DIR, listModules, readHeader, readModule } from './load.mjs'

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..')
const WORKFLOWS_DIR = join(repo, 'claude', 'workflows')
const BEGIN = /^\/\/ BEGIN module (\S+)$/
const END = /^\/\/ END module (\S+)$/

const usage = 'usage: node claude/workflow-prelude/sync.mjs [--check] [--modules-dir <dir>] [workflow-file ...]'
const fail = (message) => {
  console.error(message)
  process.exit(1)
}

const args = process.argv.slice(2)
const files = []
let check = false
let modulesDir = MODULES_DIR
for (let i = 0; i < args.length; i++) {
  const arg = args[i]
  if (arg === '--check') check = true
  else if (arg === '--modules-dir') {
    const value = args[++i]
    if (value === undefined || value.startsWith('--')) fail(`--modules-dir needs a directory\n${usage}`)
    modulesDir = resolve(value)
  }
  else if (arg.startsWith('--')) fail(`unknown flag ${arg}\n${usage}`)
  else files.push(resolve(arg))
}

// A marker line is exact. Only a trailing carriage return is ignored, so an indented marker is not a marker.
const bare = (line) => line.replace(/\r$/, '')

const targets = files.length
  ? files
  : readdirSync(WORKFLOWS_DIR)
      .filter((f) => f.endsWith('.js'))
      .map((f) => join(WORKFLOWS_DIR, f))
      .filter((f) => readFileSync(f, 'utf8').split('\n').some((l) => BEGIN.test(bare(l))))
if (!targets.length) fail('no target has a "// BEGIN module <name>" marker')
for (const file of targets) if (!existsSync(file)) fail(`${file}: file not found`)

const known = new Set(listModules(modulesDir))
const sources = new Map()
const problems = []
for (const name of known) {
  const src = readModule(name, modulesDir)
  try {
    const header = readHeader(src)
    if (header.name !== name) throw new Error(`header names module ${header.name}`)
    if (!src.endsWith('\n')) throw new Error('file must end with a newline')
    if (src.split('\n').some((l) => BEGIN.test(bare(l)) || END.test(bare(l)))) throw new Error('file holds a module marker line')
    sources.set(name, { src, header })
  } catch (e) {
    problems.push(`module ${name}: ${e.message}`)
  }
}

// Returns { lines, blocks } for one target, or pushes problems. A block is { name, begin, end } as line indexes.
function scan(file, text) {
  const lines = text.split('\n')
  const blocks = []
  let open = null
  lines.forEach((raw, i) => {
    const line = bare(raw)
    const b = BEGIN.exec(line)
    const e = END.exec(line)
    if (b) {
      if (open) problems.push(`${file}: BEGIN module ${b[1]} (line ${i + 1}) starts inside the open block ${open.name}`)
      else open = { name: b[1], begin: i }
    } else if (e) {
      if (open && open.name === e[1]) {
        blocks.push({ name: open.name, begin: open.begin, end: i })
        open = null
      } else problems.push(`${file}: END module ${e[1]} (line ${i + 1}) has no matching BEGIN module ${e[1]}`)
    }
  })
  if (open) problems.push(`${file}: BEGIN module ${open.name} (line ${open.begin + 1}) has no END module ${open.name}`)
  const seen = new Set()
  for (const { name } of blocks) {
    if (seen.has(name)) problems.push(`${file}: module ${name} is marked more than once`)
    seen.add(name)
    if (!known.has(name)) problems.push(`${file}: unknown module ${name}`)
  }
  if (!blocks.length) problems.push(`${file}: expected at least one "// BEGIN module <name>" and "// END module <name>" pair`)
  for (const { name } of blocks) {
    for (const need of sources.get(name)?.header.requires ?? []) {
      if (!seen.has(need)) problems.push(`${file}: module ${name} requires module ${need}, which the target does not mark`)
    }
  }
  return { lines, blocks }
}

const plans = targets.map((file) => {
  const text = readFileSync(file, 'utf8')
  return { file, text, ...scan(file, text) }
})
// Check every input before any write, so a bad input leaves all targets unchanged.
if (problems.length) fail(problems.join('\n'))

let failed = false
for (const { file, text, lines, blocks } of plans) {
  const out = []
  const drifted = []
  let cursor = 0
  for (const { name, begin, end } of blocks) {
    const body = sources.get(name).src.split('\n').slice(0, -1)
    out.push(...lines.slice(cursor, begin + 1), ...body)
    if (lines.slice(begin + 1, end).join('\n') !== body.join('\n')) drifted.push(name)
    cursor = end
  }
  out.push(...lines.slice(cursor))
  const next = out.join('\n')
  if (next === text) continue
  if (check) {
    console.error(`${file}: module block${drifted.length === 1 ? '' : 's'} ${drifted.join(', ')} differ${drifted.length === 1 ? 's' : ''} from ${modulesDir}; run node claude/workflow-prelude/sync.mjs`)
    failed = true
  } else {
    writeFileSync(file, next)
    console.log(`${file}: updated`)
  }
}
process.exit(failed ? 1 : 0)
