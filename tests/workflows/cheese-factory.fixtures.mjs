import { createRuntime as baseRuntime } from './harness.mjs'

export const approve = () => ({ verdict: 'approve', concerns: [], guidance: '' })

// Every cheese-factory run now dispatches the plan and done advisors.
// A suite that does not script an advise label gets an approve answer. A scripted label wins.
export const withAdvisors = (respond) => async (call) => {
  try {
    return await respond(call)
  } catch (e) {
    if (/^advise:/.test(call.opts.label) && /^unexpected agent/.test(e && e.message)) return approve()
    throw e
  }
}

export function createRuntime({ respond, ...rest } = {}) {
  return baseRuntime({ ...rest, respond: withAdvisors(respond) })
}
