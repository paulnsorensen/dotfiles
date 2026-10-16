import strict from 'node:assert/strict'
import test from 'node:test'
import { loadModule } from '../../claude/workflow-prelude/load.mjs'
// A module runs in a vm context, so its values have another realm's prototypes. Compare by JSON shape.
const toPlain = (v) => (v === undefined ? v : JSON.parse(JSON.stringify(v)))
const assert = { ...strict, deepEqual: (a, b, m) => strict.deepEqual(toPlain(a), toPlain(b), m) }

const a = loadModule('advise', { globals: {} })
const adv = (verdict, concerns = []) => ({ verdict, concerns, guidance: 'g' })

test('advise_adviceSchema_blockingAddsTheQuestionList', () => {
  assert.deepEqual(a.ADVICE_SCHEMA.required, ['verdict', 'concerns', 'guidance'])
  assert.equal(a.ADVICE_SCHEMA.properties.blocking_questions, undefined)
  const b = a.adviceSchema({ blocking: true })
  assert.deepEqual(b.required, ['verdict', 'concerns', 'guidance', 'blocking_questions'])
  assert.deepEqual(b.properties.blocking_questions.items.required, ['question', 'options', 'recommended', 'evidence'])
  assert.deepEqual(b.properties.verdict.enum, ['approve', 'revise', 'stop'])
})

test('advise_checkAdvice_nonApproveNeedsAConcern', () => {
  assert.deepEqual(a.checkAdvice(adv('approve')), [])
  assert.deepEqual(a.checkAdvice(adv('revise', ['c'])), [])
  assert.equal(a.checkAdvice(adv('revise'))[0].msg, 'verdict revise needs at least one concern')
  assert.equal(a.checkAdvice(adv('stop'))[0].kind, 'substance')
})

test('advise_checkPlanAdvice_chosenMustBeAKnownId', () => {
  assert.deepEqual(a.checkPlanAdvice({ ...adv('approve'), chosen: 'T-1' }, ['T-1']), [])
  assert.equal(a.checkPlanAdvice({ ...adv('approve'), chosen: 'T-9' }, ['T-1'])[0].kind, 'substance')
  assert.equal(a.checkPlanAdvice({ ...adv('revise'), chosen: 't-1' }, ['T-1']).length, 2)
})

test('advise_checkRoundTwo_newConcernNeedsTheNewPrefix', () => {
  const prior = ['tests missing']
  assert.deepEqual(a.checkRoundTwo(adv('revise', ['tests missing', 'NEW: leaks a secret']), prior), [])
  const errors = a.checkRoundTwo(adv('revise', ['style nit']), prior)
  assert.equal(errors.length, 1)
  assert.equal(errors[0].kind, 'substance')
  assert.ok(errors[0].msg.includes('style nit'))
  assert.equal(a.checkRoundTwo(adv('revise', ['NEWS: x']), prior).length, 1)
})

test('advise_roundTwoRule_namesThePrefixCheckRoundTwoEnforces', () => {
  assert.ok(a.ROUND_TWO_RULE.includes('"NEW:"'))
})

test('advise_adviceStep_mapsVerdictAndBudget', () => {
  assert.equal(a.adviceStep(adv('approve'), 0, 2), 'approve')
  assert.equal(a.adviceStep(adv('stop', ['c']), 0, 2), 'stop')
  assert.equal(a.adviceStep(adv('revise', ['c']), 1, 2), 'revise')
  assert.equal(a.adviceStep(adv('revise', ['c']), 2, 2), 'unsettled')
  assert.equal(a.adviceStep(null, 0, 2), 'unsettled')
})

test('advise_adviseLoop_revisesThenApproves', async () => {
  const log = []
  const answers = [adv('revise', ['fix a']), adv('approve')]
  const r = await a.adviseLoop({
    ask: async (round, prior) => { log.push(['ask', round, prior]); return answers[round] },
    revise: async (advice, round) => { log.push(['revise', advice.concerns, round]) },
    maxRevisions: 2,
  })
  assert.equal(r.outcome, 'approve')
  assert.equal(r.rounds, 1)
  assert.deepEqual(log, [['ask', 0, []], ['revise', ['fix a'], 0], ['ask', 1, ['fix a']]])
})

test('advise_adviseLoop_stopsUnsettledWhenRevisionsRunOut', async () => {
  let revisions = 0
  const r = await a.adviseLoop({
    ask: async () => adv('revise', ['still wrong']),
    revise: async () => { revisions++ },
    maxRevisions: 2,
  })
  assert.equal(r.outcome, 'unsettled')
  assert.equal(revisions, 2)
  assert.equal(r.rounds, 2)
})

test('advise_adviseLoop_stopVerdictEndsWithoutRevising', async () => {
  const r = await a.adviseLoop({ ask: async () => adv('stop', ['no']), revise: async () => assert.fail('revise ran'), maxRevisions: 3 })
  assert.equal(r.outcome, 'stop')
})

test('advise_adviceResult_okOnlyWithoutErrors', () => {
  assert.deepEqual(a.adviceResult('plan', adv('approve'), []), { stage: 'plan', value: adv('approve'), errors: [], ok: true })
  assert.equal(a.adviceResult('plan', null, [{ kind: 'substance', msg: 'x' }]).ok, false)
})

test('advise_blockingOf_dropsBlankQuestions', () => {
  const advice = { blocking_questions: [{ question: ' Q? ' }, { question: '  ' }, null, { question: 3 }] }
  assert.deepEqual(a.blockingOf(advice), [{ question: ' Q? ' }])
  assert.deepEqual(a.blockingOf({}), [])
})
