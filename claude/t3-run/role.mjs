// role <role>: print the dispatch target for one role from skills/t3-core/role-map.json.
import { join } from 'node:path'
import { CLONE, print, readJson, usage } from './util.mjs'

export const loadRoleMap = () => readJson(join(CLONE, 'skills/t3-core/role-map.json'))

export function runRole(args) {
  if (args.length !== 1) throw usage('role needs exactly one role name')
  const map = loadRoleMap()
  if (!Object.hasOwn(map, args[0])) throw usage(`unknown role '${args[0]}'. Known roles: ${Object.keys(map).join(', ')}`)
  const { providerInstanceId, model, options, isolation } = map[args[0]]
  print({ providerInstanceId, model, options, isolation })
}
