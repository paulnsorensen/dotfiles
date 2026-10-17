import strict from 'node:assert/strict'
import test from 'node:test'
import { loadModule } from '../../claude/workflow-prelude/load.mjs'
// A module runs in a vm context, so its values have another realm's prototypes. Compare by JSON shape.
const toPlain = (v) => (v === undefined ? v : JSON.parse(JSON.stringify(v)))
const assert = { ...strict, deepEqual: (a, b, m) => strict.deepEqual(toPlain(a), toPlain(b), m) }

const c = loadModule('criteria', { globals: {} })
const kinds = (errors) => errors.map((e) => e.kind)
const verdict = (criterion, evidence = 'ran it: ok') => ({ criterion, passes: true, evidence, tree_clean: true, missing_paths: [] })
const batch = [{ id: 'AC-1' }, { id: 'AC-2' }]

test('criteria_normAndBlank', () => {
  assert.equal(c.norm(' ac-1 '), 'AC-1')
  assert.equal(c.blank('  '), true)
  assert.equal(c.blank(7), true)
  assert.equal(c.blank('x'), false)
})

test('criteria_refError_formForCaseSlipSubstanceForUnknown', () => {
  assert.equal(c.refError('AC-1', ['AC-1'], 'w'), null)
  assert.deepEqual(c.refError('ac-1', ['AC-1'], 'w'), { kind: 'form', msg: "w: 'ac-1' should be 'AC-1'" })
  assert.deepEqual(c.refError('AC-9', ['AC-1'], 'w'), { kind: 'substance', msg: "w: unknown id 'AC-9'" })
})

test('criteria_refError_fixOfSetsTheCanonicalForm', () => {
  const fixOf = (r) => `#${r}`
  assert.equal(c.refError('5', ['#5'], 'w', fixOf).kind, 'form')
})

test('criteria_checkVerdicts_acceptsOneVerdictPerCriterion', () => {
  assert.deepEqual(c.checkVerdicts({ verdicts: [verdict('AC-1'), verdict('AC-2')] }, batch), [])
})

test('criteria_checkVerdicts_flagsDuplicateBlankEvidenceAndUnknown', () => {
  const errors = c.checkVerdicts({ verdicts: [verdict('AC-1'), verdict('AC-1', ' '), verdict('AC-7')] }, batch)
  const msgs = errors.map((e) => e.msg)
  assert.ok(msgs.some((m) => m.includes('twice')), msgs.join('|'))
  assert.ok(msgs.some((m) => m.includes('evidence')), msgs.join('|'))
  assert.ok(msgs.some((m) => m.includes("unknown id 'AC-7'")), msgs.join('|'))
  assert.ok(msgs.some((m) => m.includes('no verdict for AC-2')), msgs.join('|'))
})

test('criteria_checkVerdicts_requireAllFalseAllowsAMissingId', () => {
  const only = { verdicts: [verdict('AC-1')] }
  assert.equal(c.checkVerdicts(only, batch).length, 1)
  assert.deepEqual(c.checkVerdicts(only, batch, { requireAll: false }), [])
})

const crit = (id, check = 'test -e a && ls a', kind = 'command') => ({ id, statement: 's', check_kind: kind, check })

test('criteria_checkCriteria_exactCoverageIsClean', () => {
  assert.deepEqual(c.checkCriteria(['AC-1', 'AC-2'])({ criteria: [crit('AC-1'), crit('AC-2')] }), [])
})

test('criteria_checkCriteria_flagsMissingDuplicateAndBlank', () => {
  const errors = c.checkCriteria(['AC-1', 'AC-2'])({ criteria: [crit('AC-1'), crit('AC-1', ' ')] })
  const msgs = errors.map((e) => e.msg)
  assert.ok(msgs.includes("$.criteria[1].id: duplicate id 'AC-1'"), msgs.join('|'))
  assert.ok(msgs.includes('$.criteria[1].check must not be blank'), msgs.join('|'))
  assert.ok(msgs.includes('AC-2 has no criterion'), msgs.join('|'))
  assert.deepEqual(kinds(errors), ['substance', 'substance', 'substance'])
})

test('criteria_checkCriteria_gateRunsOnNonCiChecksOnly', () => {
  const seen = []
  const gate = (crit, where) => { seen.push([crit.id, where]); return [{ kind: 'substance', msg: `${where} unsafe` }] }
  const errors = c.checkCriteria(['AC-1', 'AC-2'], gate)({ criteria: [crit('AC-1'), crit('AC-2', 'CI job passes', 'ci')] })
  assert.deepEqual(seen, [['AC-1', '$.criteria[0]']])
  assert.deepEqual(errors.map((e) => e.msg), ['$.criteria[0] unsafe'])
})

test('criteria_schemas_requireTheirDecisionFields', () => {
  assert.deepEqual(c.CRITERIA_SCHEMA.properties.criteria.items.properties.check_kind.enum, ['command', 'test', 'inspection', 'ci'])
  assert.equal(c.VERIFY_BATCH_SCHEMA.properties.verdicts.items, c.VERDICT_SCHEMA)
  assert.ok(c.VERDICT_SCHEMA.required.includes('passes'))
})
