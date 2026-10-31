// validate <role> <result-file>: check one child result before the parent uses it.
import { readFileSync } from 'node:fs'
import { loadGates } from './gate.mjs'
import { loadRoleMap } from './role.mjs'
import { usage } from './util.mjs'

const isEmpty = (v) => v === null || v === '' || (Array.isArray(v) && v.length === 0) || (typeof v === 'object' && v !== null && !Array.isArray(v) && Object.keys(v).length === 0)
const isObject = (v) => typeof v === 'object' && v !== null && !Array.isArray(v)
const nonEmptyString = (v) => typeof v === 'string' && v.trim() !== ''

export function validateResult(role, text) {
  const map = loadRoleMap()
  if (!Object.hasOwn(map, role)) throw usage(`unknown role '${role}'. Known roles: ${Object.keys(map).join(', ')}`)
  let value
  try {
    value = JSON.parse(text)
  } catch (error) {
    return [`not one JSON object: ${error.message}`]
  }
  if (!isObject(value)) return ['not one JSON object: the value is not an object']
  const entries = Object.values(value)
  if (entries.every(isEmpty)) return ['empty result: every value is null, "", [], or {}']
  const reasons = []
  if (map[role].isolation === 'worktree') {
    for (const key of ['status', 'branch']) if (!nonEmptyString(value[key])) reasons.push(`${key} must be a non-empty string`)
    if (typeof value.head_sha !== 'string' || !loadGates().FULL_SHA_RE.test(value.head_sha)) reasons.push('head_sha must be a full 40-hex SHA')
  } else if (!nonEmptyString(value.status)) reasons.push('status must be a non-empty string')
  return reasons
}

export function runValidate(args) {
  if (args.length !== 2) throw usage('validate needs <role> <result-file>')
  let text
  try {
    text = readFileSync(args[1], 'utf8')
  } catch (error) {
    throw usage(`cannot read ${args[1]}: ${error.message}`)
  }
  const reasons = validateResult(args[0], text)
  if (!reasons.length) return 0
  process.stdout.write(`${reasons.join('\n')}\n`)
  return 1
}
