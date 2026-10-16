// move-my-cheese agent types: gh and git steps start a runner, and form repairs start a formatter.
import assert from 'node:assert/strict'
import test from 'node:test'

import {
  aged, approve, approveDone, builtConsolidation, merged, noTensions, openPr, planRoutes, published, ready, reconRoutes, run, sha, stateMerged, survey,
} from './move-my-cheese.fixtures.mjs'

const RUNNER = /^(recon:index|recon:detail|publish|mark|stamp|cleanup|salvage:T-\d+|age-fanout-prep:\d+|finalize:\d+|merge:\d+|merged:\d+:\d+|(review|land):\d+:status(:\d+)?)$/
const FORMATTER = /:repair\d+$/

const typesOf = (trace) => trace.agents.map(({ opts }) => [opts.label, opts.agentType])

function assertTypes(trace) {
  for (const [label, type] of typesOf(trace)) {
    if (FORMATTER.test(label)) assert.equal(type, 'formatter', label)
    else if (RUNNER.test(label)) assert.equal(type, 'runner', label)
  }
}

const seen = (trace, re) => typesOf(trace).filter(([label]) => re.test(label)).map(([label]) => label)

test('publish, its form repair, age-fanout prep, finalize, mark, stamp, cleanup, and recon start the narrow types', async () => {
  const { args } = await approve(planRoutes())
  const big = published('T-1', 10, sha(50))
  big.results[0].changed_files = 40
  const bad = { results: [...big.results, { ...big.results[0], target: 't-1' }] }
  const fanout = async () => ({ status: 'ok', artifact: '.cheese/age/pr-10.md', has_medium_plus_findings: false, has_cheap_lows: false })
  const { result, trace } = await run(args, builtConsolidation([
    ['publish', ({ opts }) => (opts.label === 'publish' ? bad : big)],
    ['age-fanout-prep', { worktree_path: '/tmp/fan-10' }],
  ]), null, fanout)
  assert.equal(result.status, 'ready', result.note)
  assertTypes(trace)
  const labels = seen(trace, /./)
  for (const label of ['recon:index', 'recon:detail', 'publish', 'publish:repair1', 'age-fanout-prep:10', 'finalize:10', 'mark', 'stamp:10', 'cleanup:sweep']) {
    assert.ok(labels.includes(label), `${label} ran`)
  }
  assert.ok(labels.some((l) => /^review:10:status/.test(l)))
})

test('a target that ends without a result starts a salvage runner', async () => {
  const { args } = await approve(planRoutes())
  const { trace } = await run(args, planRoutes([['target:T-1', null], ['salvage:T-1', { found: false, checkpoint: '', completed: [], remaining: [] }]]))
  assertTypes(trace)
  assert.ok(seen(trace, RUNNER).includes('salvage:T-1'))
})

test('a typed form repair starts a formatter', async () => {
  const wrongPr = ({ opts }) => (opts.label.endsWith(':repair1') ? survey({ opts: { label: 'survey:1' } }) : { ...survey({ opts }), pr: 9 })
  const { trace } = await run({ prs: [1, 2] }, planRoutes([['survey:1', wrongPr]]))
  assertTypes(trace)
  assert.deepEqual(seen(trace, FORMATTER), ['survey:1:repair1'])
})

test('land status, merge, and merged polls start runners', async () => {
  const { result, trace } = await run({ prs: [1], auto: true, land: true }, [
    ...reconRoutes([openPr(1)], [aged(1)]),
    ['survey', survey],
    ['tensions', noTensions],
    ['review:1:status', ready(1)],
    ['advise:done', approveDone],
    ['land:1:status', ready(1)],
    ['merge:1', merged],
    ['merged:1', stateMerged],
  ])
  assert.equal(result.status, 'landed')
  assertTypes(trace)
  const labels = seen(trace, RUNNER)
  for (const label of ['merge:1', 'merged:1:1']) assert.ok(labels.includes(label), `${label} ran`)
  assert.ok(labels.some((l) => l.startsWith('land:1:status')))
})
