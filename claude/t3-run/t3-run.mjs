#!/usr/bin/env node
// t3-run: role targets, run ledger, result validation, and gate helpers for the t3-* skills.
import { runGate } from './gate.mjs'
import { runLedger } from './ledger.mjs'
import { runRole } from './role.mjs'
import { runValidate } from './validate.mjs'

const USAGE = `Usage: t3-run <command> [args]
  role <role> [--depth <n>]
  role --agent-type <type> [--tier <tier>] [--mode <mode>] [--depth <n>]
  ledger init <run> [--skill <name>]
  ledger record <run> --phase <p> --role <r> --client-request-id <id> --task-id <id> [--depth <n>]
  ledger reserve <run> --phase <p> --role <r>
  ledger complete <run> --task-id <id> --status <s> [--head-sha <sha>] [--result-file <f>]
  ledger status <run>
  ledger barrier <run> <phase>
  validate <role> <result-file>
  gate merge-curds <curds.json>
  gate check-safe <command-string>
  gate route-findings <findings.json> <files_by_slug.json>
  gate ranges <ranges.json>
  gate sha <sha>
`

const commands = { role: runRole, ledger: runLedger, validate: runValidate, gate: runGate }

const [command, ...args] = process.argv.slice(2)
const run = commands[command]
if (!run) {
  process.stderr.write(USAGE)
  process.exit(command === '--help' || command === '-h' ? 0 : 2)
}

try {
  process.exitCode = run(args) ?? 0
} catch (error) {
  process.stderr.write(`t3-run: ${error.message}\n`)
  process.exitCode = error.exitCode ?? 1
}
