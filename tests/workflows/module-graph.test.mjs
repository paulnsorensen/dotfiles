import strict from 'node:assert/strict'
import test from 'node:test'
import { loadModule } from '../../claude/workflow-prelude/load.mjs'
// A module runs in a vm context, so its values have another realm's prototypes. Compare by JSON shape.
const toPlain = (v) => (v === undefined ? v : JSON.parse(JSON.stringify(v)))
const assert = { ...strict, deepEqual: (a, b, m) => strict.deepEqual(toPlain(a), toPlain(b), m) }

const g = loadModule('graph', { globals: {} })
const t = (id, base, depends_on = []) => ({ id, base, depends_on })

test('graph_duplicates_returnsSortedRepeatedIds', () => {
  assert.deepEqual(g.duplicates(['b', 'a', 'b', 'a', 'a', 'c']), ['a', 'b'])
  assert.deepEqual(g.duplicates(['a', 'b']), [])
})

test('graph_waves_groupsByDependencyAndReportsCycle', () => {
  const r = g.waves([t('T-2', 'main', ['T-1']), t('T-1', 'main'), t('T-3', 'main', ['T-1'])])
  assert.deepEqual(r.order, [['T-1'], ['T-2', 'T-3']])
  assert.deepEqual(r.cycle, [])
  const c = g.waves([t('T-1', 'main', ['T-2']), t('T-2', 'main', ['T-1']), t('T-3', 'main')])
  assert.deepEqual(c.order, [['T-3']])
  assert.deepEqual(c.cycle, ['T-1', 'T-2'])
})

test('graph_baseChain_walksBasesUntilTheDefaultBranch', () => {
  const targets = [t('T-1', 'main'), t('T-2', 'T-1', ['T-1']), t('T-3', 'T-2', ['T-2'])]
  assert.deepEqual(g.baseChain(targets, 'T-3'), ['T-2', 'T-1'])
  assert.deepEqual(g.baseChain(targets, 'T-1'), [])
  const loop = [t('T-1', 'T-2'), t('T-2', 'T-1')]
  assert.deepEqual(g.baseChain(loop, 'T-1'), ['T-2'])
})

// AC-9
test('graph_mergeWaitErrors_stackedDependencyNeedsNoMerge', () => {
  const plan = { targets: [t('T-1', 'main'), t('T-2', 'T-1', ['T-1']), t('T-3', 'T-2', ['T-2', 'T-1'])] }
  assert.deepEqual(g.mergeWaitErrors(plan), [])
})

test('graph_mergeWaitErrors_dependencyOffTheBaseChainWaitsForMerge', () => {
  const plan = { targets: [t('T-1', 'main'), t('T-2', 'main', ['T-1'])] }
  const errors = g.mergeWaitErrors(plan)
  assert.equal(errors.length, 1)
  assert.equal(errors[0].kind, 'substance')
  assert.equal(errors[0].msg, "T-2 waits for T-1's merge before publish")
})

test('graph_mergeWaitErrors_namesEachOffChainDependency', () => {
  const plan = { targets: [t('T-1', 'main'), t('T-2', 'main'), t('T-3', 'T-1', ['T-1', 'T-2'])] }
  assert.deepEqual(g.mergeWaitErrors(plan).map((e) => e.msg), ["T-3 waits for T-2's merge before publish"])
})
