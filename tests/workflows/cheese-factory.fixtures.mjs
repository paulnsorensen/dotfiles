import { createRuntime as baseRuntime, loadWorkflow as baseLoadWorkflow } from './harness.mjs'

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

// Verify sends every non-ci check to one judge call labeled verify, with the checks in a data block.
// The batch answer takes each check id's verdict from table['verify:<id>'], else from fallback(id). A null leaves that id without a verdict.
export const verifyFrom = (table, fallback) => (call) => {
  const checks = JSON.parse(/<data name="checks">\n([\s\S]*?)\n<\/data>/.exec(call.prompt)[1])
  return { verdicts: checks.map(({ id }) => (table[`verify:${id}`] || (() => fallback(id)))(call)).filter((v) => v != null) }
}

// The wfx rev-parse envelope that a short-SHA expansion runner returns for one prefix.
export const revParse = (prefix, full) => ({ ok: true, cmd: 'wfx rev-parse', data: { shas: { [prefix]: full } } })

// Verify runs in the verify-criteria child workflow. The offline harness cannot start a child.
// This stub answers 'verify-criteria' by calling the test's agent stub with label 'verify' and a prompt that carries the old checks block and check lines.
// Any other workflow name goes to the test's own workflow stub, else it throws as the harness does.
const shq = (s) => `'${String(s).replaceAll("'", "'\\''")}'`
// A test passes verifyChild(q) to replace the stub: it returns the child result or throws.
const verifyChild = (agent, next, child) => async (name, q) => {
  if (name === 'verify-criteria' && child) return child(q)
  if (name !== 'verify-criteria') {
    if (next) return next(name, q)
    throw new Error('workflow() is not supported in the offline harness')
  }
  const path = q.worktree_path
  const prompt = [
    'Judge mode: verify',
    `worktree_path: ${path}. head: ${q.head}, the combined result of every curd.`,
    `Run each command below in list order:\n${q.criteria.map((ac) => `${ac.id}: cd ${path} && bash -c ${shq(ac.check)}`).join('\n')}`,
    `<data name="checks">\n${JSON.stringify(q.criteria.map((ac) => ({ id: ac.id, criterion: ac.statement, check: ac.check })))}\n</data>`,
  ].join('\n\n')
  const answer = await agent(prompt, { label: 'verify', phase: 'Verify', agentType: 'judge', model: 'sonnet', effort: 'medium' })
  if (answer && !Array.isArray(answer.verdicts)) return { status: 'blocked', reason: 'the judge returned no verdict list' }
  const verdicts = answer ? answer.verdicts : []
  const have = new Set(verdicts.map((v) => v && v.criterion))
  const missing = q.criteria.map((ac) => ac.id).filter((id) => !have.has(id))
  return { status: missing.length ? 'partial' : 'ok', verdicts, missing }
}

// A drop-in for the harness loadWorkflow. Its run() adds the verify-criteria stub to the workflow global.
export async function loadWorkflow(path) {
  const wf = await baseLoadWorkflow(path)
  return { ...wf, run: (overrides = {}) => wf.run({ ...overrides, workflow: verifyChild(overrides.agent, overrides.workflow, overrides.verifyChild) }) }
}
export function createRuntime({ respond, ...rest } = {}) {
  return baseRuntime({ ...rest, respond: withAdvisors(respond) })
}
