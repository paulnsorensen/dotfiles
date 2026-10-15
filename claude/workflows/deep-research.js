export const meta = {
  name: 'deep-research',
  description: 'Deep, multi-source, fact-checked research — runs the combined brie-ground engine (dynamic wiki + Tavily fan-out, prior-research reuse, adversarial verify, cited synthesis).',
  whenToUse: 'When the user wants a deep, multi-source, fact-checked research report on any topic. BEFORE invoking, check if the question is specific enough to research directly — if underspecified (e.g., "what car to buy" without budget/use-case/region), ask 2-3 clarifying questions to narrow scope. Then pass the refined question as args, weaving the answers in.',
  phases: [{ title: 'Delegate', detail: 'run the brie-ground engine on the question' }],
}

// DISABLES the bundled deep-research workflow by shadowing it. Claude Code
// filters out any built-in workflow whose name a user (or plugin) workflow
// already defines — the merger does `v7r().filter(a => !userNames.has(a.name))`.
// Deploying this file as ~/.claude/workflows/deep-research.js (claude asset →
// chezmoi exact_workflows) claims the `deep-research` name, so the compiled-in
// version is dropped and /deep-research runs the combined engine below instead.
//
// One implementation: the bundled pipeline's capability (multi-angle fan-out,
// fetch, adversarial verify, synthesis) now lives in brie-ground as a dynamic
// per-sub-question "deep" escalation, hard-coded to Tavily. The bundled run
// always starts about 97 agents. brie-ground starts fewer for a narrow
// question, but its worst case is 35 agents (see its fan-out caps). This shim
// adds no agent of its own.
//
// The shim owns the /deep-research entry contract: it reads the question,
// rejects a missing one with its own usage before any research starts, and
// turns a child failure into an error result that carries the question, so
// the caller can rerun with the same input.

const USAGE = 'Usage: /deep-research <question>, or args { question }.'

// Accepts a bare question, { question }, or that object sent as a JSON string.
function questionOf(input) {
  let value = input
  if (typeof value === 'string' && /^\s*\{/.test(value)) {
    try {
      value = JSON.parse(value)
    } catch {
      // A question that only starts with a brace stays text.
    }
  }
  if (value && typeof value === 'object' && !Array.isArray(value)) value = value.question
  return typeof value === 'string' ? value.trim() : ''
}

const question = questionOf(args)
if (!question) {
  log(`No question provided. ${USAGE}`)
  return { error: `No question provided. ${USAGE}` }
}

phase('Delegate')
let result = null
try {
  result = await workflow('brie-ground', question)
} catch (e) {
  const reason = `brie-ground failed: ${(e && e.message) || e}`
  log(reason)
  return { error: `${reason}. Check that brie-ground is deployed (dots sync), then rerun /deep-research with the same question.`, question }
}
if (!result || typeof result !== 'object' || Array.isArray(result)) {
  log('brie-ground returned no result object.')
  return { error: 'brie-ground returned no result object. Rerun /deep-research with the same question.', question }
}
return result
