#!/usr/bin/env node
// Vendors prelude.js into the marked block of each listed workflow.
// Usage: node claude/workflow-prelude/sync.mjs [--check] [--source <file>] [workflow-file ...]
// Without --check, the script writes. With --check, it exits 1 and names each file that differs.
import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const repo = resolve(here, '..', '..')
const DEFAULT_FILES = ['claude/workflows/cheese-factory.js', 'claude/workflows/move-my-cheese.js']
const BEGIN = '// BEGIN shared prelude'
const END = '// END shared prelude'

const args = process.argv.slice(2)
const check = args.includes('--check')
const sourceAt = args.indexOf('--source')
const source = sourceAt === -1 ? resolve(here, 'prelude.js') : resolve(args[sourceAt + 1])
const files = args
  .filter((a, i) => !a.startsWith('--') && (sourceAt === -1 || i !== sourceAt + 1))
  .map((f) => resolve(f))
const targets = files.length ? files : DEFAULT_FILES.map((f) => resolve(repo, f))

const lineStarts = (text, marker) => {
  const found = []
  let at = 0
  for (;;) {
    at = text.indexOf(marker, at)
    if (at === -1) return found
    if (at === 0 || text[at - 1] === '\n') found.push(at)
    at += marker.length
  }
}

// Returns { head, tail } where head ends after the begin line and tail starts at the end marker, or null.
const split = (text) => {
  const begins = lineStarts(text, BEGIN)
  const ends = lineStarts(text, END)
  if (begins.length !== 1 || ends.length !== 1 || ends[0] < begins[0]) return null
  const beginLineEnd = text.indexOf('\n', begins[0])
  if (beginLineEnd === -1 || beginLineEnd >= ends[0]) return null
  return { head: text.slice(0, beginLineEnd + 1), tail: text.slice(ends[0]) }
}

const block = readFileSync(source, 'utf8')
let failed = false
for (const file of targets) {
  const text = readFileSync(file, 'utf8')
  const parts = split(text)
  if (!parts) {
    console.error(`${file}: expected exactly one "${BEGIN}" and one "${END}" marker line, in that order`)
    failed = true
    continue
  }
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
