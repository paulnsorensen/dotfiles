import { createRuntime as baseRuntime } from './harness.mjs'

export const approve = () => ({ verdict: 'approve', concerns: [], guidance: '' })
export const grounded = (overrides = {}) => ({ decisions: [], prior_research: [], research_questions: [], ...overrides })

// Every cheese-factory run now dispatches the Ground explorer and the plan and done advisors.
// A suite that does not script a ground or advise label gets an empty grounding or an approve answer. A scripted label wins.
export const withAdvisors = (respond) => async (call) => {
  try {
    return await respond(call)
  } catch (e) {
    if (!/^unexpected agent/.test(e && e.message)) throw e
    if (/^advise:/.test(call.opts.label)) return approve()
    if (call.opts.label === 'ground') return grounded()
    throw e
  }
}

export function createRuntime({ respond, ...rest } = {}) {
  return baseRuntime({ ...rest, respond: withAdvisors(respond) })
}
