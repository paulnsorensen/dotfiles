// module: findings; provides: isMediumPlus, needsCure, normalizeFile, routeFindings, findingErrors, enumErrors, splitBlocked, cureBatches; requires: call, stale, schema
const isMediumPlus = (f) => f.severity !== 'low'
const needsCure = (f) => isMediumPlus(f) || f.fix_cost_now === 'contained'
// A finding file may carry a leading ./ or a worktree prefix; both name the same repo path.
// The prefix is the producer's own worktree_path, or any scratch worktree root.
const normalizeFile = (file, worktreePath) => {
  let p = String(file).trim()
  const root = worktreePath ? String(worktreePath).replace(/\/+$/, '') + '/' : null
  p = root && p.startsWith(root) ? p.slice(root.length) : p.replace(new RegExp(`^${SCRATCH_PATH_SRC}\\/`), '')
  return p.replace(/^(\.\/)+/, '')
}
// A finding owned by two curds routes to the first owner in slug order. Each other owner lands in shared, keyed to the owners that cure it.
// unrouted is true when a finding that needs cure has no owner (an unowned low that needs no cure stays out),
// or when the result claims medium+ findings or contained lows that its list does not carry.
function routeFindings(result, filesBySlug, slugs, worktreePath) {
  const bySlug = new Map()
  const shared = new Map()
  const sharedFindings = new Map()
  // unownedMedium marks a medium+ finding that no curd owns. unrouted also fires for an unowned contained low.
  let unownedMedium = Boolean(result.has_medium_plus_findings) && !result.findings.some(isMediumPlus)
  let unrouted = unownedMedium ||
    (Boolean(result.has_cheap_lows) && !result.findings.some((f) => f.severity === 'low' && f.fix_cost_now === 'contained'))
  for (const f of result.findings.filter(needsCure)) {
    const file = normalizeFile(f.file, worktreePath)
    const owners = slugs.filter((s) => (filesBySlug[s] || []).includes(file))
    if (!owners.length) {
      unrouted = true
      if (isMediumPlus(f)) unownedMedium = true
      continue
    }
    const [first, ...others] = owners
    bySlug.set(first, [...(bySlug.get(first) || []), { ...f, file }])
    for (const s of others) {
      shared.set(s, new Set([...(shared.get(s) || []), first]))
      sharedFindings.set(s, [...(sharedFindings.get(s) || []), { ...f, file }])
    }
  }
  return { bySlug, shared, sharedFindings, unrouted, unownedMedium }
}
// A closed set checked in code: the schema keeps the field a plain string.
const enumErrors = (path, value, allowed, kind = form) => (allowed.includes(value) ? [] : [kind(`${path} must be one of ${allowed.join(', ')}`)])
const findingErrors = (v) => v.findings.flatMap((f, i) => [
  ...enumErrors(`$.findings[${i}].severity`, f.severity, FINDING_SEVERITIES, substance),
  ...enumErrors(`$.findings[${i}].fix_cost_now`, f.fix_cost_now, FIX_COSTS, substance),
])
// A reviewer may answer status "blocked: <reason>" as one string. Code splits it into status and reason.
// A halt is a blocked review too. Every caller still treats a status other than ok as no review.
const splitBlocked = (v) => {
  const m = v !== null && typeof v === 'object' && typeof v.status === 'string' ? /^(blocked|halt)\s*:\s*(.+)$/i.exec(v.status.trim()) : null
  if (m) {
    v.status = 'blocked'
    v.reason = typeof v.reason === 'string' && v.reason.trim() ? v.reason : m[2]
  }
  return v
}
// bySlug maps a curd slug to its findings. Returns { slug, findings } batches in map order. A batch holds at most cap findings.
function cureBatches(bySlug, cap) {
  const size = Math.max(1, cap)
  const batches = []
  for (const [slug, found] of bySlug) {
    for (let i = 0; i < found.length; i += size) batches.push({ slug, findings: found.slice(i, i + size) })
  }
  return batches
}
