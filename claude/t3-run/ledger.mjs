// ledger <sub> <run> ...: the run ledger at .cheese/t3/<run>.json under the git top-level of the cwd.
import { execFileSync } from 'node:child_process'
import { closeSync, existsSync, mkdirSync, openSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { parseFlags, print, usage } from './util.mjs'

const TERMINAL = new Set(['completed', 'failed', 'cancelled', 'blocked'])
const SAFE_RUN_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/

function repoRoot() {
  try {
    return execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim()
  } catch {
    return process.cwd()
  }
}

function ledgerPath(run) {
  if (!run || !SAFE_RUN_RE.test(run) || run.includes('..')) throw usage(`unsafe run id '${run ?? ''}': use letters, digits, '.', '_', '-' and no '..'`)
  return join(repoRoot(), '.cheese', 't3', `${run}.json`)
}

function load(run) {
  const file = ledgerPath(run)
  if (!existsSync(file)) throw Object.assign(new Error(`no ledger for run '${run}'; run 'ledger init' first`), { exitCode: 1 })
  try {
    const ledger = JSON.parse(readFileSync(file, 'utf8'))
    if (!Array.isArray(ledger?.children)) throw new Error('no children array')
    return ledger
  } catch (error) {
    throw Object.assign(new Error(`corrupt ledger ${file}: ${error.message}`), { exitCode: 1 })
  }
}

const LOCK_TRIES = 500
const LOCK_WAIT_MS = 10

// Holds an exclusive lock file around one read-modify-write.
function withLock(run, fn) {
  const lock = `${ledgerPath(run)}.lock`
  mkdirSync(dirname(lock), { recursive: true })
  let acquired = false
  for (let i = 0; i < LOCK_TRIES && !acquired; i++) {
    try {
      closeSync(openSync(lock, 'wx'))
      acquired = true
    } catch (error) {
      if (error.code !== 'EEXIST') throw error
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, LOCK_WAIT_MS)
    }
  }
  if (!acquired) throw Object.assign(new Error(`cannot take ledger lock ${lock}; remove it if no other t3-run runs`), { exitCode: 1 })
  try {
    return fn()
  } finally {
    rmSync(lock, { force: true })
  }
}

function save(run, ledger) {
  const file = ledgerPath(run)
  mkdirSync(dirname(file), { recursive: true })
  const temp = `${file}.${process.pid}.tmp`
  writeFileSync(temp, `${JSON.stringify(ledger, null, 2)}\n`)
  renameSync(temp, file)
}

const required = (flags, names) => {
  for (const name of names) if (!flags[name]) throw usage(`missing --${name}`)
}

export function runLedger([sub, run, ...rest]) {
  switch (sub) {
    case 'init': {
      const { flags } = parseFlags(rest, ['skill'])
      return withLock(run, () => {
        if (existsSync(ledgerPath(run))) return 0
        save(run, { run, skill: flags.skill ?? null, createdAt: new Date().toISOString(), children: [] })
        return 0
      })
    }
    case 'record': {
      const { flags } = parseFlags(rest, ['phase', 'role', 'client-request-id', 'task-id', 'depth'])
      required(flags, ['phase', 'role', 'client-request-id', 'task-id'])
      const depth = flags.depth === undefined ? 1 : Number(flags.depth)
      if (!Number.isInteger(depth) || depth < 0 || depth > 2) throw usage('--depth must be an integer from 0 to 2')
      return withLock(run, () => {
        const ledger = load(run)
        const prior = ledger.children.find((c) => c.clientRequestId === flags['client-request-id'])
        if (prior) {
          if (prior.taskId === flags['task-id']) return 0
          throw Object.assign(new Error(`client request id '${prior.clientRequestId}' already maps to task '${prior.taskId}', not '${flags['task-id']}'`), { exitCode: 1 })
        }
        ledger.children.push({
          clientRequestId: flags['client-request-id'],
          taskId: flags['task-id'],
          phase: flags.phase,
          role: flags.role,
          depth,
          status: 'running',
          recordedAt: new Date().toISOString(),
        })
        save(run, ledger)
        return 0
      })
    }
    case 'complete': {
      const { flags } = parseFlags(rest, ['task-id', 'status', 'head-sha', 'result-file'])
      required(flags, ['task-id', 'status'])
      if (!TERMINAL.has(flags.status)) throw usage(`--status must be one of: ${[...TERMINAL].join(', ')}`)
      return withLock(run, () => {
        const ledger = load(run)
        const child = ledger.children.find((c) => c.taskId === flags['task-id'])
        if (!child) throw Object.assign(new Error(`no child with task id '${flags['task-id']}'`), { exitCode: 1 })
        Object.assign(child, { status: flags.status, completedAt: new Date().toISOString() })
        if (flags['head-sha']) child.headSha = flags['head-sha']
        if (flags['result-file']) child.resultFile = flags['result-file']
        save(run, ledger)
        return 0
      })
    }
    case 'status':
      print(load(run).children.filter((c) => !TERMINAL.has(c.status)))
      return 0
    case 'barrier': {
      const phase = rest[0]
      if (!phase) throw usage('barrier needs <phase>')
      const children = load(run).children.filter((c) => c.phase === phase)
      if (!children.length) {
        process.stderr.write(`no children recorded for phase '${phase}'\n`)
        return 1
      }
      const pending = children.filter((c) => !TERMINAL.has(c.status))
      if (!pending.length) return 0
      process.stdout.write(`${pending.map((c) => c.taskId).join('\n')}\n`)
      return 1
    }
    default:
      throw usage('ledger needs a subcommand: init, record, complete, status, barrier')
  }
}
