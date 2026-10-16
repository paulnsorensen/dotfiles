// module: fanout; provides: errorMessage, safeAgent, runBounded, chunk, dedupe, capList, withRedo; requires: none
// The message of a thrown value, or its text when it has none.
const errorMessage = (e) => (e && e.message ? e.message : String(e))

// agent() resolves to null when the agent ends without a structured result. Treat null as a failure so a caller never dereferences a missing value. agent resolves at call time.
const safeAgent = async (prompt, opts) => {
  try {
    const value = await agent(prompt, opts)
    if (value === null || value === undefined) return { ok: false, error: `agent ${(opts && opts.label) || 'call'} returned no result` }
    return { ok: true, value }
  } catch (error) {
    return { ok: false, error: errorMessage(error) }
  }
}

// Runs task(item, index) for each item with at most limit tasks at once. Results keep the item order.
const runBounded = async (items, task, limit = 4) => {
  const results = new Array(items.length)
  let next = 0
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) {
      const index = next++
      results[index] = await task(items[index], index)
    }
  })
  await Promise.all(workers)
  return results
}

// Splits items into groups of at most size.
const chunk = (items, size) => Array.from({ length: Math.ceil(items.length / size) }, (_, i) => items.slice(i * size, (i + 1) * size))

// Keeps the first item for each key. dropped holds the later items with a key that was already seen.
function dedupe(items, keyOf) {
  const seen = new Set()
  const kept = []
  const dropped = []
  for (const item of items) {
    const key = keyOf(item)
    if (seen.has(key)) dropped.push(item)
    else {
      seen.add(key)
      kept.push(item)
    }
  }
  return { kept, dropped }
}

// Keeps the first max items. dropped holds the rest.
const capList = (items, max) => ({ kept: items.slice(0, max), dropped: items.slice(max) })

// Runs an expensive agent call, and redoes it up to rounds times when it returns no result. agent and log resolve at call time.
const withRedo = async (prompt, opts, rounds = 1) => {
  for (let round = 0; round <= rounds; round++) {
    const out = await agent(prompt, round ? { ...opts, label: `${opts.label}:redo${round}` } : opts)
    if (out) return out
    log(`${opts.label}: no result${round < rounds ? '; redoing once' : ''}.`)
  }
  return null
}
