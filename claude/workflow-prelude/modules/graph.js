// module: graph; provides: waves, duplicates, baseChain, mergeWaitErrors; requires: call
// Returns the sorted ids that appear more than once.
function duplicates(ids) {
  return [...new Set(ids.filter((id, i) => ids.indexOf(id) !== i))].sort()
}
// Groups items by dependency. Each wave holds the ids whose depends_on all finished earlier. cycle lists the ids that never become ready.
function waves(items) {
  const pending = new Map(items.map((t) => [t.id, new Set(t.depends_on)]))
  const out = []
  while (pending.size) {
    const ready = [...pending].filter(([, deps]) => deps.size === 0).map(([id]) => id).sort()
    if (!ready.length) return { order: out, cycle: [...pending.keys()].sort() }
    out.push(ready)
    for (const id of ready) pending.delete(id)
    for (const deps of pending.values()) for (const id of ready) deps.delete(id)
  }
  return { order: out, cycle: [] }
}
// The target ids under a target, nearest first: its base, that target's base, and so on.
// The chain stops at the default branch, which is not a target id, and at a repeated id.
function baseChain(targets, id) {
  const byId = new Map(targets.map((t) => [t.id, t]))
  const chain = []
  let next = byId.get(id)?.base
  while (byId.has(next) && !chain.includes(next) && next !== id) {
    chain.push(next)
    next = byId.get(next).base
  }
  return chain
}
// The plan has no merge-wait field. A target waits for a merge when it depends on a target that is not on its base chain.
// A stacked base needs no merge, because the target builds on that branch.
function mergeWaitErrors(plan) {
  const errors = []
  for (const t of plan.targets) {
    const chain = baseChain(plan.targets, t.id)
    for (const d of t.depends_on) {
      if (!chain.includes(d)) errors.push(substance(`${t.id} waits for ${d}'s merge before publish`))
    }
  }
  return errors
}
