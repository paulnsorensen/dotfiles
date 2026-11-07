// ledger <sub> <run> ...: the run ledger at .cheese/t3/<run>.json under the git top-level of the cwd.
import { execFileSync } from 'node:child_process'
import { closeSync, existsSync, mkdirSync, openSync, readFileSync, renameSync, rmSync, statSync, writeFileSync, writeSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { childDepth, parseFlags, print, usage } from './util.mjs'

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

const LOCK_STALE_MS = 3_000
const LOCK_WAIT_MS = 10
// The wait outlasts the stale limit, so a waiting caller always recovers a crashed holder's lock.
const LOCK_TRIES = Math.ceil((LOCK_STALE_MS * 2) / LOCK_WAIT_MS)

const pidAlive = (pid) => {
  try {
    process.kill(pid, 0)
    return true
  } catch (error) {
    return error.code === 'EPERM'
  }
}

// A file is stale when its owner pid is dead or it is older than the stale limit. A file with no readable body ages by mtime.
function staleBody(file) {
  let body
  try {
    body = readFileSync(file, 'utf8')
  } catch {
    return null
  }
  let info = null
  try {
    info = JSON.parse(body)
  } catch {}
  const created = Number.isFinite(info?.created) ? info.created : statSync(file, { throwIfNoEntry: false })?.mtimeMs
  if (created === undefined) return null
  const dead = Number.isInteger(info?.pid) && !pidAlive(info.pid)
  return dead || Date.now() - created > LOCK_STALE_MS ? body : null
}

// Removes a stale lock. An exclusive `.break` file admits one taker at a time. The taker re-checks that the lock body
// is still the stale body it saw, and never removes a lock whose body changed. A stale `.break` file is cleared first.
export function takeOverStale(lock, hooks = {}) {
  const brk = `${lock}.break`
  const body = staleBody(lock)
  if (body === null) return
  try {
    closeSync(openSync(brk, 'wx'))
  } catch (error) {
    if (error.code === 'EEXIST' && staleBody(brk) !== null) rmSync(brk, { force: true })
    return
  }
  try {
    hooks.afterBreak?.()
    if (staleBody(lock) === body) rmSync(lock, { force: true })
  } finally {
    rmSync(brk, { force: true })
  }
}

// Holds an exclusive lock file around one read-modify-write.
function withLock(run, fn) {
  const lock = `${ledgerPath(run)}.lock`
  mkdirSync(dirname(lock), { recursive: true })
  const mine = JSON.stringify({ pid: process.pid, created: Date.now(), nonce: Math.random() })
  let acquired = false
  for (let i = 0; i < LOCK_TRIES && !acquired; i++) {
    try {
      const fd = openSync(lock, 'wx')
      writeSync(fd, mine)
      closeSync(fd)
      acquired = true
    } catch (error) {
      if (error.code !== 'EEXIST') throw error
      takeOverStale(lock)
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, LOCK_WAIT_MS)
    }
  }
  if (!acquired) throw Object.assign(new Error(`cannot take ledger lock ${lock}; remove it if no other t3-run runs`), { exitCode: 1 })
  try {
    return fn()
  } finally {
    try {
      if (readFileSync(lock, 'utf8') === mine) rmSync(lock, { force: true })
    } catch {}
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
        const sameTask = ledger.children.find((c) => c.taskId === flags['task-id'])
        if (sameTask) {
          throw Object.assign(new Error(`task id '${sameTask.taskId}' already recorded under client request id '${sameTask.clientRequestId}', not '${flags['client-request-id']}'`), { exitCode: 1 })
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
    case 'reserve': {
      const { flags } = parseFlags(rest, ['phase', 'role', 'depth'])
      required(flags, ['phase', 'role'])
      childDepth(flags.depth)
      for (const name of ['phase', 'role']) if (flags[name].includes('/')) throw usage(`--${name} must not contain '/'`)
      const prefix = `${run}/${flags.phase}/${flags.role}/`
      return withLock(run, () => {
        const ledger = load(run)
        const reserved = Array.isArray(ledger.reserved) ? ledger.reserved : []
        const used = [...ledger.children.map((c) => c.clientRequestId), ...reserved]
        const highest = used.reduce((max, id) => {
          const tail = typeof id === 'string' && id.startsWith(prefix) ? id.slice(prefix.length) : ''
          return /^[0-9]+$/.test(tail) ? Math.max(max, Number(tail)) : max
        }, 0)
        const id = `${prefix}${highest + 1}`
        ledger.reserved = [...reserved, id]
        save(run, ledger)
        process.stdout.write(`${id}\n`)
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
      throw usage('ledger needs a subcommand: init, record, reserve, complete, status, barrier')
  }
}
