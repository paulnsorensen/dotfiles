// Shared helpers: clone location, JSON file reads, and usage errors.
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

export const CLONE = fileURLToPath(new URL('../../', import.meta.url))

// A usage error exits 2; a domain failure exits 1.
export function usage(message) {
  return Object.assign(new Error(message), { exitCode: 2 })
}

export const readJson = (file) => {
  try {
    return JSON.parse(readFileSync(file, 'utf8'))
  } catch (error) {
    throw usage(`cannot read JSON from ${file}: ${error.message}`)
  }
}

export const print = (value) => process.stdout.write(`${JSON.stringify(value)}\n`)

// Parses `--name value` pairs. Returns { positional, flags }.
export function parseFlags(args, allowed) {
  const positional = []
  const flags = {}
  for (let i = 0; i < args.length; i++) {
    if (!args[i].startsWith('--')) {
      positional.push(args[i])
      continue
    }
    const name = args[i].slice(2)
    if (!allowed.includes(name)) throw usage(`unknown option --${name}`)
    if (i + 1 >= args.length) throw usage(`option --${name} needs a value`)
    flags[name] = args[++i]
  }
  return { positional, flags }
}

export const MAX_CHILD_DEPTH = 2

// Validates --depth, the depth of the child that the caller launches (1..2).
export function childDepth(value) {
  if (value === undefined) throw usage('missing --depth (the depth of the child to launch: 1 or 2)')
  if (!/^[0-9]+$/.test(value)) throw usage(`--depth must be an integer from 1 to ${MAX_CHILD_DEPTH}, got '${value}'`)
  const depth = Number(value)
  if (depth > MAX_CHILD_DEPTH) throw Object.assign(new Error(`child depth ${depth} exceeds the cap of ${MAX_CHILD_DEPTH}`), { exitCode: 1 })
  if (depth < 1) throw usage(`--depth must be an integer from 1 to ${MAX_CHILD_DEPTH}, got '${value}'`)
  return depth
}
