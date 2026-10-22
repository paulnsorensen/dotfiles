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
