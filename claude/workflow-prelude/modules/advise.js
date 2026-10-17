// module: advise; provides: adviceSchema, ADVICE_SCHEMA, ROUND_TWO_RULE, checkAdvice, checkPlanAdvice, checkRoundTwo, adviceStep, adviseLoop, adviceResult, blockingOf; requires: call, schema, criteria
// blocking true adds blocking_questions: questions only the user can settle.
const adviceSchema = ({ blocking = false } = {}) => ({
  type: 'object',
  required: ['verdict', 'concerns', 'guidance', ...(blocking ? ['blocking_questions'] : [])],
  properties: {
    verdict: { type: 'string', enum: ADVICE_VERDICTS },
    concerns: { type: 'array', items: { type: 'string' } },
    guidance: { type: 'string', description: 'Under 80 words' },
    ...(blocking ? {
      blocking_questions: { type: 'array', description: 'Questions only the user can settle; leave empty when none', items: {
        type: 'object',
        required: ['question', 'options', 'recommended', 'evidence'],
        properties: {
          question: { type: 'string' },
          options: { type: 'array', items: { type: 'string' } },
          recommended: { type: 'string', description: 'one of options, or empty' },
          evidence: { type: 'string' },
        },
      } },
    } : {}),
  },
})
const ADVICE_SCHEMA = adviceSchema()
// A second review judges the first review's concerns. It does not reopen the plan.
const ROUND_TWO_RULE = 'payload.prior_concerns holds your concerns from the last round. Judge only whether each prior concern is resolved. Raise a new concern only when it makes the work wrong or unsafe, and start it with "NEW:". Never reverse a prior concern.'
function checkAdvice(advice) {
  return advice.verdict !== 'approve' && !advice.concerns.length
    ? [substance(`verdict ${advice.verdict} needs at least one concern`)]
    : []
}
function checkPlanAdvice(advice, ids) {
  const errors = []
  const idError = refError(advice.chosen, ids, 'chosen')
  if (idError) errors.push(idError)
  if (advice.verdict !== 'approve' && !advice.concerns.length) errors.push(substance(`verdict ${advice.verdict} needs at least one concern`))
  return errors
}
// ROUND_TWO_RULE as code: a round-two concern repeats a prior concern or starts with "NEW:".
function checkRoundTwo(advice, priorConcerns) {
  return advice.concerns
    .filter((c) => !priorConcerns.includes(c) && !(typeof c === 'string' && c.startsWith('NEW:')))
    .map((c) => substance(`concern '${c}' is neither a prior concern nor marked NEW:`))
}
// round counts the revisions done so far. A revise verdict ends unsettled once the revisions are spent.
function adviceStep(advice, round, maxRevisions) {
  if (!advice) return 'unsettled'
  if (advice.verdict === 'approve') return 'approve'
  if (advice.verdict === 'stop') return 'stop'
  return round < maxRevisions ? 'revise' : 'unsettled'
}
// ask(round, priorConcerns) returns advice. revise(advice, round) changes the work. Returns { outcome, advice, rounds }.
const adviseLoop = async ({ ask, revise, maxRevisions }) => {
  let prior = []
  for (let round = 0; ; round++) {
    const advice = await ask(round, prior)
    const outcome = adviceStep(advice, round, maxRevisions)
    if (outcome !== 'revise') return { outcome, advice, rounds: round }
    await revise(advice, round)
    prior = advice.concerns
  }
}
// The record of one advice stage: ok is true when no error remains.
const adviceResult = (stage, value, errors) => ({ stage, value, errors, ok: errors.length === 0 })
function blockingOf(advice) {
  return (Array.isArray(advice.blocking_questions) ? advice.blocking_questions : []).filter((b) => b && typeof b.question === 'string' && b.question.trim())
}
