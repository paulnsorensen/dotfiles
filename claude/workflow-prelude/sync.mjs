#!/usr/bin/env node
// Vendors prelude.js into the marked block of each listed workflow.
// Also vendors gates.js into the shared gates block of cheese-factory.js, and of no other workflow.
// Usage: node claude/workflow-prelude/sync.mjs [--check] [--source <file>] [--gates-source <file>] [workflow-file ...]
// Without --check, the script writes. With --check, it exits 1 and names each file that differs.
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { basename, dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const repo = resolve(here, '..', '..')
const DEFAULT_FILES = ['claude/workflows/cheese-board.js', 'claude/workflows/cheese-factory.js', 'claude/workflows/move-my-cheese.js']
const GATES_FILE = 'cheese-factory.js'

const usage = 'usage: node claude/workflow-prelude/sync.mjs [--check] [--source <file>] [--gates-source <file>] [workflow-file ...]'
const fail = (message) => {
  console.error(message)
  process.exit(1)
}

const args = process.argv.slice(2)
const files = []
let check = false
let source = resolve(here, 'prelude.js')
let gatesSource = resolve(here, 'gates.js')
for (let i = 0; i < args.length; i++) {
  const arg = args[i]
  if (arg === '--check') check = true
  else if (arg === '--source' || arg === '--gates-source') {
    const value = args[++i]
    if (value === undefined || value.startsWith('--')) fail(`${arg} needs a file\n${usage}`)
    if (arg === '--source') source = resolve(value)
    else gatesSource = resolve(value)
  } else if (arg.startsWith('--')) fail(`unknown flag ${arg}\n${usage}`)
  else files.push(resolve(arg))
}
const targets = files.length ? files : DEFAULT_FILES.map((f) => resolve(repo, f))

// A marker line is exact. Only a trailing carriage return is ignored, so an indented marker is not a marker.
// A begin line is the marker alone, or the marker followed by a colon and a note.
const bare = (line) => line.replace(/\r$/, '')

const makeBlock = (name, blockSource, blockFiles) => {
  const BEGIN = `// BEGIN shared ${name}`
  const END = `// END shared ${name}`
  const isBegin = (line) => {
    const t = bare(line)
    return t === BEGIN || t.startsWith(`${BEGIN}:`)
  }
  const isEnd = (line) => bare(line) === END
  // Returns { head, tail } where head ends after the begin line and tail starts at the end marker, or null.
  const split = (text) => {
    const lines = text.split('\n')
    const begins = []
    const ends = []
    lines.forEach((line, i) => {
      if (isBegin(line)) begins.push(i)
      if (isEnd(line)) ends.push(i)
    })
    if (begins.length !== 1 || ends.length !== 1 || ends[0] <= begins[0]) return null
    return {
      head: lines.slice(0, begins[0] + 1).join('\n') + '\n',
      tail: lines.slice(ends[0]).join('\n'),
    }
  }
  return { name, BEGIN, END, source: blockSource, files: blockFiles, isBegin, isEnd, split }
}

const allBlocks = [
  makeBlock('prelude', source, targets),
  makeBlock('gates', gatesSource, targets.filter((f) => basename(f) === GATES_FILE)),
]
const blocks = allBlocks.filter((b) => b.files.length)

// Check every input before any write, so a bad input leaves all targets unchanged.
for (const file of new Set([...blocks.map((b) => b.source), ...targets])) {
  if (!existsSync(file)) fail(`${file}: file not found`)
}
for (const b of blocks) {
  b.text = readFileSync(b.source, 'utf8')
  const lines = b.text.split('\n')
  const other = allBlocks.find((o) => lines.some((line) => o.isBegin(line) || o.isEnd(line)))
  if (other) fail(`${b.source}: source contains a shared ${other.name} marker line; remove it`)
  if (b.text && !b.text.endsWith('\n')) b.text += '\n'
}

const originals = new Map(targets.map((file) => [file, readFileSync(file, 'utf8')]))
let failed = false
for (const b of blocks) {
  for (const file of b.files) {
    if (b.split(originals.get(file))) continue
    console.error(`${file}: expected exactly one "${b.BEGIN}" and one "${b.END}" marker line, in that order`)
    failed = true
  }
}
if (failed) process.exit(1)
for (const file of targets) {
  const original = originals.get(file)
  let next = original
  for (const b of blocks) {
    if (!b.files.includes(file)) continue
    const parts = b.split(next)
    const updated = parts.head + b.text + parts.tail
    if (check && updated !== next) {
      console.error(`${file}: shared ${b.name} block differs from ${b.source}; run node claude/workflow-prelude/sync.mjs`)
      failed = true
    }
    next = updated
  }
  if (check || next === original) continue
  writeFileSync(file, next)
  console.log(`${file}: updated`)
}
process.exit(failed ? 1 : 0)
