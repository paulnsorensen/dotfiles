// move-my-cheese staleness (AC-21): a moved default branch replans only when it touches a plan file; else the heads restack.
import assert from 'node:assert/strict'
import test from 'node:test'

import { aged, approve, envelope, failure, liveRecon, minimalPlan, planRoutes, run, sha } from './move-my-cheese.fixtures.mjs'

const NEW_BASE = 'c'.repeat(40)
// Keep #1 and modify #2: the plan reshapes, so the old rule replanned on any base move.
const planning = () => planRoutes([['recon:detail', { prs: [aged(1), aged(2)] }], ['plan:minimal', minimalPlan()]])
const movedBase = (probeFiles, extra = []) => [
  ...extra,
  ['stale:recon', liveRecon({ base: NEW_BASE })],
  ['stale:probe:conflict', envelope('probe', { base: {}, heads: [], conflicts: [] })],
  ['stale:probe', envelope('probe', { files: probeFiles })],
  ['stale:restack', ({ opts }) => envelope('restack', { old: sha(1), new: sha(opts.label.endsWith('pr-1') ? 61 : 62) })],
  ...planning(),
]

test('a moved base that touches no plan file restacks every existing target and does not replan', async () => {
  const { args } = await approve(planning())
  const { result, wfxLabels, call } = await run(args, movedBase(['docs/unrelated.md']))
  assert.notEqual(result.status, 'needs-replan')
  assert.deepEqual(wfxLabels.filter((l) => l.startsWith('stale:')), ['stale:recon', 'stale:probe', 'stale:restack:feat/pr-1', 'stale:restack:feat/pr-2', 'stale:probe:conflict'])
  assert.match(call('stale:probe').prompt, new RegExp(`--range ${'b'.repeat(40)}\\.\\.${NEW_BASE}`))
  const restack = call('stale:restack:feat/pr-2').prompt
  assert.ok(restack.includes(`--onto ${NEW_BASE}`) && restack.includes('--push') && restack.includes(`--expect ${sha(2)}`))
  assert.ok(restack.includes("git fetch --quiet origin 'feat/pr-2:feat/pr-2' &&"))
  assert.ok(call('stale:probe:conflict').prompt.includes(`--base ${NEW_BASE} --head ${sha(61)} --head ${sha(62)}`))
})

test('a moved base over a plan file turns the plan into needs-replan with no restack', async () => {
  const { args } = await approve(planning())
  const { result, wfxLabels } = await run(args, movedBase(['src/2.js']))
  assert.equal(result.status, 'needs-replan')
  assert.match(result.reasons.join(' '), /plan files: src\/2\.js/)
  assert.equal(wfxLabels.some((l) => l.startsWith('stale:restack')), false)
})

test('unknown changed files turn the plan into needs-replan', async () => {
  const { args } = await approve(planning())
  const { result } = await run(args, movedBase([], [['stale:probe', failure('probe', 'bad-range', 'unknown revision')]]))
  assert.equal(result.status, 'needs-replan')
  assert.match(result.reasons.join(' '), /changed files are unknown/)
})

test('a restack conflict turns the plan into needs-replan', async () => {
  const { args } = await approve(planning())
  const { result, wfxLabels } = await run(args, movedBase(['docs/unrelated.md'], [['stale:restack:feat/pr-2', failure('restack', 'conflict', 'rebase conflict', { files: ['src/2.js'] })]]))
  assert.equal(result.status, 'needs-replan')
  assert.match(result.reasons.join(' '), /restack of feat\/pr-2 failed \(conflict\)/)
  assert.equal(wfxLabels.includes('stale:probe:conflict'), false)
})

test('restacked heads that conflict with each other turn the plan into needs-replan', async () => {
  const { args } = await approve(planning())
  const conflicts = [{ a: 'x', b: 'y', files: ['src/1.js'] }]
  const { result } = await run(args, movedBase(['docs/unrelated.md'], [['stale:probe:conflict', envelope('probe', { base: {}, heads: [], conflicts })]]))
  assert.equal(result.status, 'needs-replan')
  assert.match(result.reasons.join(' '), /restacked heads conflict/)
})

test('an unmoved base runs only the live recon', async () => {
  const { args } = await approve(planning())
  const { wfxLabels } = await run(args, planning())
  assert.deepEqual(wfxLabels.filter((l) => l.startsWith('stale:')), ['stale:recon'])
})

test('a moved head still turns the plan into needs-replan before any probe', async () => {
  const { args } = await approve(planning())
  const { result, wfxLabels } = await run(args, [['stale:recon', liveRecon({ base: NEW_BASE, heads: { 1: sha(1, 9) } })], ...planning()])
  assert.equal(result.status, 'needs-replan')
  assert.match(result.reasons.join(' '), /#1 head moved/)
  assert.equal(wfxLabels.includes('stale:probe'), false)
})

test('the approval digest stays the same after a restack', async () => {
  const { first, args } = await approve(planning())
  const { result } = await run(args, movedBase(['docs/unrelated.md']))
  assert.equal(result.digest, first.result.digest)
})
