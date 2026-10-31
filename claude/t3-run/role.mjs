// role <role> | --agent-type <type>: print the dispatch target for one role from skills/t3-core/role-map.json.
import { join } from 'node:path'
import { CLONE, childDepth, parseFlags, print, readJson, usage } from './util.mjs'

export const loadRoleMap = () => readJson(join(CLONE, 'skills/t3-core/role-map.json'))
export const loadAgentTypeRules = () => readJson(join(CLONE, 'skills/t3-core/agent-type-rules.json'))

// The source `model:` values a workflow passes as the tier.
const TIERS = ['opus', 'sonnet', 'haiku']

// First matching rule wins. A rule field that is absent matches any value.
function resolveAgentType(type, tier, mode) {
  const rules = loadAgentTypeRules()
  const known = [...new Set(rules.map((r) => r.agentType))]
  if (!known.includes(type)) throw usage(`unknown agent type '${type}'. Known types: ${known.join(', ')}`)
  const modes = [...new Set(rules.filter((r) => r.agentType === type && r.mode !== undefined).map((r) => r.mode))]
  if (tier !== undefined && !TIERS.includes(tier)) throw usage(`unknown tier '${tier}' for agent type '${type}'. Accepted tiers: ${TIERS.join(', ')}`)
  if (mode !== undefined && !modes.includes(mode)) throw usage(`unknown mode '${mode}' for agent type '${type}'. Accepted modes: ${modes.join(', ') || '(none)'}`)
  const rule = rules.find((r) => r.agentType === type && (r.tier === undefined || r.tier === tier) && (r.mode === undefined || r.mode === mode))
  if (!rule) throw usage(`no rule for agent type '${type}' with tier '${tier ?? ''}' and mode '${mode ?? ''}'`)
  return rule.role
}

export function runRole(args) {
  const { positional, flags } = parseFlags(args, ['agent-type', 'tier', 'mode', 'depth'])
  childDepth(flags.depth)
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
