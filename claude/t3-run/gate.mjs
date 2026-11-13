// gate <name>: run the single-source gate helpers from claude/workflow-prelude in one vm context.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { createContext, runInContext } from 'node:vm'
import { CLONE, print, readJson, usage } from './util.mjs'

const NAMES = ['FULL_SHA_RE', 'validGroundedRange', 'groundedRanges', 'mergeCoupledCurds', 'routeFindings', 'unsafeCheck']

// gates.js needs prelude.js first (SCRATCH_PATH_SRC). Top-level const bindings are not context properties, so read them by expression.
export function loadGates() {
  const ctx = createContext({})
  for (const file of ['claude/workflow-prelude/prelude.js', 'claude/workflow-prelude/gates.js']) {
    runInContext(readFileSync(join(CLONE, file), 'utf8'), ctx, { filename: file })
  }
  return runInContext(`({ ${NAMES.join(', ')} })`, ctx)
}

// Values from the vm context carry another realm's prototypes; copy them to plain JSON.
const plain = (value) => JSON.parse(JSON.stringify(value))
const fromMap = (map) => Object.fromEntries([...map].map(([key, value]) => [key, Object.prototype.toString.call(value) === '[object Set]' ? [...value] : value]))

const need = (args, count, what) => {
  if (args.length !== count) throw usage(`gate ${what}`)
}

export function runGate([name, ...args]) {
  if (!name) throw usage('gate needs a name: merge-curds, check-safe, route-findings, ranges, sha')
  const g = loadGates()
  switch (name) {
    case 'merge-curds': {
      need(args, 1, 'merge-curds <curds.json>')
      const curds = readJson(args[0])
      if (!Array.isArray(curds)) throw usage('curds.json must hold an array')
      print(plain(g.mergeCoupledCurds(curds)))
      return 0
    }
    case 'check-safe': {
      need(args, 1, 'check-safe <command-string>')
      const found = g.unsafeCheck(args[0])
      if (!found) return 0
      process.stdout.write(`unsafe: ${found.name}${found.text ? ` (${found.text})` : ''}\n`)
      return 1
    }
    case 'route-findings': {
      need(args, 2, 'route-findings <findings.json> <files_by_slug.json>')
      const raw = readJson(args[0])
      const result = Array.isArray(raw) ? { findings: raw } : raw
      if (!result || !Array.isArray(result.findings)) throw usage('findings.json needs a findings array')
      const filesBySlug = readJson(args[1])
      const routed = g.routeFindings(result, filesBySlug, Object.keys(filesBySlug), result.worktree_path)
      print(plain({
        bySlug: fromMap(routed.bySlug),
        shared: fromMap(routed.shared),
        sharedFindings: fromMap(routed.sharedFindings),
        unrouted: routed.unrouted,
        unownedMedium: routed.unownedMedium,
      }))
      return 0
    }
    case 'ranges': {
      need(args, 1, 'ranges <ranges.json>')
      const ranges = readJson(args[0])
      if (!Array.isArray(ranges)) throw usage('ranges.json must hold an array')
      const kept = plain(g.groundedRanges(ranges))
      let validSeen = 0
      const dropped = []
      for (const range of ranges) {
        if (!g.validGroundedRange(range)) dropped.push({ range, reason: 'invalid' })
        else if (++validSeen > kept.length) dropped.push({ range, reason: 'overflow' })
      }
      print({ kept, dropped })
      return 0
    }
    case 'sha': {
      need(args, 1, 'sha <sha>')
      return g.FULL_SHA_RE.test(args[0]) ? 0 : 1
    }
    default:
      throw usage(`unknown gate '${name}'`)
  }
}
