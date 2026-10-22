// ledger <sub> <run> ...: the run ledger at .cheese/t3/<run>.json under the git top-level of the cwd.
import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
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
  return JSON.parse(readFileSync(file, 'utf8'))
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
      if (existsSync(ledgerPath(run))) return 0
      save(run, { run, skill: flags.skill ?? null, createdAt: new Date().toISOString(), children: [] })
      return 0
    }
    case 'record': {
      const { flags } = parseFlags(rest, ['phase', 'role', 'client-request-id', 'task-id', 'depth'])
      required(flags, ['phase', 'role', 'client-request-id', 'task-id'])
      const depth = flags.depth === undefined ? 1 : Number(flags.depth)
      if (!Number.isInteger(depth) || depth < 0) throw usage('--depth must be a non-negative integer')
      const ledger = load(run)
      if (ledger.children.some((c) => c.clientRequestId === flags['client-request-id'])) return 0
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
    }
    case 'complete': {
      const { flags } = parseFlags(rest, ['task-id', 'status', 'head-sha', 'result-file'])
      required(flags, ['task-id', 'status'])
      if (!TERMINAL.has(flags.status)) throw usage(`--status must be one of: ${[...TERMINAL].join(', ')}`)
      const ledger = load(run)
      const child = ledger.children.find((c) => c.taskId === flags['task-id'])
      if (!child) throw Object.assign(new Error(`no child with task id '${flags['task-id']}'`), { exitCode: 1 })
      Object.assign(child, { status: flags.status, completedAt: new Date().toISOString() })
      if (flags['head-sha']) child.headSha = flags['head-sha']
      if (flags['result-file']) child.resultFile = flags['result-file']
      save(run, ledger)
      return 0
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
