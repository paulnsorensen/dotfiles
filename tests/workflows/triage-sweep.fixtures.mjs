import { resolve } from 'node:path'

export const path = resolve(import.meta.dirname, '../../claude/workflows/triage-sweep.js')

export const issue = (number, title = `issue ${number}`) => ({ number, kind: 'issue', title, url: `https://github.com/owner/name/issues/${number}` })
export const pr = (number, title = `pr ${number}`) => ({ number, kind: 'pr', title, url: `https://github.com/owner/name/pull/${number}` })

export const ground = (number, verdict = 'valid', extra = {}) => ({
  number,
  verdict,
  duplicate_of: 0,
  evidence: [{ claim: 'checked', citation: 'src/a.js:1' }],
  summary: `summary ${number}`,
  recommendation: 'fix now',
  links: [],
  ...extra,
})

export const verify = (number, refuted, finalVerdict, note = 'checked') => ({
  number, refuted, final_verdict: finalVerdict, counter_evidence: [], note,
})

// Reads one fenced <data name="..."> block from a prompt and returns its JSON value.
export function readData(prompt, name) {
  const match = prompt.match(new RegExp(`<data name="${name}">\\n([\\s\\S]*?)\\n</data>`))
  if (!match) throw new Error(`no <data name="${name}"> block in prompt`)
  return JSON.parse(match[1])
}

// A route reply that closes each closable item and sends the rest to fix-now.
export function routeAll(digest) {
  return {
    routed: digest.map((d, i) => ({
      number: d.number,
      route: d.closable ? 'close' : 'fix-now',
      rank: i + 1,
      why: 'why',
      close_reason: d.closable ? 'completed' : '',
      duplicate_of: 0,
      confidence: d.closable ? 'certain' : '',
      comment: d.closable ? 'Fixed in #9.' : '',
    })),
    domains: [],
    summary: 'summary',
  }
}

// Answers each agent from its label. `grounds` maps an item number to a verdict string or a full ground entry.
export function responder({ gather = [], grounds = {}, verifies = {}, map, route, overrides = {} } = {}) {
  return (call) => {
    const { opts, prompt } = call
    if (overrides[opts.label]) return overrides[opts.label](call)
    if (opts.label === 'gather') return { items: gather }
    if (opts.label.startsWith('ground:')) {
      return {
        results: readData(prompt, 'items').map((i) => {
          const g = grounds[i.number]
          return g && typeof g === 'object' ? g : ground(i.number, g || 'valid')
        }),
      }
    }
    if (opts.label.startsWith('verify:')) {
      return { results: readData(prompt, 'claims').map((c) => verifies[c.number] || verify(c.number, false, c.verdict)) }
    }
    if (opts.label.startsWith('map:')) return map ? map(call) : { touches: [], links: [] }
    if (opts.label === 'route') return route ? route(call) : routeAll(readData(prompt, 'items'))
    throw new Error(`unexpected agent ${opts.label}`)
  }
}

export const labels = (trace) => trace.agents.map(({ opts }) => opts.label)
export const plain = (value) => JSON.parse(JSON.stringify(value))
