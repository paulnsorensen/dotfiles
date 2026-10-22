// role <role> | --agent-type <type>: print the dispatch target for one role from skills/t3-core/role-map.json.
import { join } from 'node:path'
import { CLONE, parseFlags, print, readJson, usage } from './util.mjs'

export const loadRoleMap = () => readJson(join(CLONE, 'skills/t3-core/role-map.json'))
export const loadAgentTypeRules = () => readJson(join(CLONE, 'skills/t3-core/agent-type-rules.json'))

const MAX_DEPTH = 2

// First matching rule wins. A rule field that is absent matches any value.
function resolveAgentType(type, tier, mode) {
  const rules = loadAgentTypeRules()
  const known = [...new Set(rules.map((r) => r.agentType))]
  if (!known.includes(type)) throw usage(`unknown agent type '${type}'. Known types: ${known.join(', ')}`)
  const rule = rules.find((r) => r.agentType === type && (r.tier === undefined || r.tier === tier) && (r.mode === undefined || r.mode === mode))
  if (!rule) throw usage(`no rule for agent type '${type}' with tier '${tier ?? ''}' and mode '${mode ?? ''}'`)
  return rule.role
}

export function runRole(args) {
  const { positional, flags } = parseFlags(args, ['agent-type', 'tier', 'mode', 'depth'])
  if (flags.depth !== undefined) {
    const depth = Number(flags.depth)
    if (!/^[0-9]+$/.test(flags.depth) || !Number.isInteger(depth) || depth < 0 || depth > MAX_DEPTH) {
      throw Object.assign(new Error(`depth ${flags.depth} exceeds the cap of ${MAX_DEPTH}`), { exitCode: 1 })
    }
  }
  const map = loadRoleMap()
  let role
  if (flags['agent-type'] !== undefined) {
    if (positional.length) throw usage('role takes either a role name or --agent-type, not both')
    role = resolveAgentType(flags['agent-type'], flags.tier, flags.mode)
  } else {
    if (flags.tier !== undefined || flags.mode !== undefined) throw usage('--tier and --mode need --agent-type')
    if (positional.length !== 1) throw usage('role needs exactly one role name')
    role = positional[0]
  }
  if (!Object.hasOwn(map, role)) throw usage(`unknown role '${role}'. Known roles: ${Object.keys(map).join(', ')}`)
  const { providerInstanceId, model, options, isolation } = map[role]
  print({ role, providerInstanceId, model, options, isolation })
}
