#!/usr/bin/env node
// Vendors prelude.js into the marked block of each listed workflow.
// Usage: node claude/workflow-prelude/sync.mjs [--check] [--source <file>] [workflow-file ...]
// Without --check, the script writes. With --check, it exits 1 and names each file that differs.
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const repo = resolve(here, '..', '..')
const DEFAULT_FILES = ['claude/workflows/cheese-factory.js', 'claude/workflows/move-my-cheese.js']
const BEGIN = '// BEGIN shared prelude'
const END = '// END shared prelude'

const usage = 'usage: node claude/workflow-prelude/sync.mjs [--check] [--source <file>] [workflow-file ...]'
const fail = (message) => {
  console.error(message)
  process.exit(1)
}

const args = process.argv.slice(2)
const files = []
let check = false
let source = resolve(here, 'prelude.js')
for (let i = 0; i < args.length; i++) {
  const arg = args[i]
  if (arg === '--check') check = true
  else if (arg === '--source') {
    const value = args[++i]
    if (value === undefined || value.startsWith('--')) fail(`--source needs a file\n${usage}`)
    source = resolve(value)
  } else if (arg.startsWith('--')) fail(`unknown flag ${arg}\n${usage}`)
  else files.push(resolve(arg))
}
const targets = files.length ? files : DEFAULT_FILES.map((f) => resolve(repo, f))

// A begin line is the marker alone, or the marker followed by a colon and a note.
const isBegin = (line) => {
  const t = line.trim()
  return t === BEGIN || t.startsWith(`${BEGIN}:`)
}
const isEnd = (line) => line.trim() === END

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

// Check every input before any write, so a bad input leaves all targets unchanged.
for (const file of [source, ...targets]) {
  if (!existsSync(file)) fail(`${file}: file not found`)
}
let block = readFileSync(source, 'utf8')
if (block.split('\n').some((line) => isBegin(line) || isEnd(line))) {
  fail(`${source}: source contains a shared prelude marker line; remove it`)
}
if (block && !block.endsWith('\n')) block += '\n'

const plans = targets.map((file) => {
  const text = readFileSync(file, 'utf8')
  return { file, text, parts: split(text) }
})
let failed = false
for (const { file, parts } of plans) {
  if (parts) continue
  console.error(`${file}: expected exactly one "${BEGIN}" and one "${END}" marker line, in that order`)
  failed = true
}
if (failed) process.exit(1)
for (const { file, text, parts } of plans) {
  const next = parts.head + block + parts.tail
  if (next === text) continue
  if (check) {
    console.error(`${file}: shared prelude block differs from ${source}; run node claude/workflow-prelude/sync.mjs`)
    failed = true
  } else {
    writeFileSync(file, next)
    console.log(`${file}: updated`)
  }
}
process.exit(failed ? 1 : 0)
