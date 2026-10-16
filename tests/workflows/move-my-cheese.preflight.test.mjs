// move-my-cheese preflight (AC-19): the tools must work before any planning or survey agent runs.
import assert from 'node:assert/strict'
import test from 'node:test'

import { envelope, failure, plain, planRoutes, run } from './move-my-cheese.fixtures.mjs'

test('a failed preflight blocks with the failed check names before any other agent runs', async () => {
  const checks = [{ name: 'git', ok: true, detail: '/usr/bin/git' }, { name: 'gh', ok: false, detail: 'gh not found' }, { name: 'wfx', ok: false, detail: 'wfx not found on PATH' }]
  const { result, raw } = await run({ prs: [1, 2] }, planRoutes([['preflight', failure('preflight', 'preflight-failed', 'checks failed', { checks })]]))
  assert.equal(result.status, 'blocked')
  assert.equal(result.reason, 'preflight failed: gh, wfx')
  assert.deepEqual(plain(result.preflight), { ok: false, failed: ['gh', 'wfx'] })
  assert.deepEqual(raw.agents.map(({ opts }) => opts.label), ['preflight'])
})

test('a failed preflight without check details names the error code', async () => {
  const { result, raw } = await run({ prs: [1, 2] }, planRoutes([['preflight', failure('preflight', 'bad-input', 'no repo')]]))
  assert.equal(result.status, 'blocked')
  assert.deepEqual(plain(result.preflight.failed), ['bad-input'])
  assert.equal(raw.agents.some(({ opts }) => /^(plan|survey|recon)/.test(opts.label)), false)
})

test('preflight runs once, first, and asks for git, node, wfx, and gh', async () => {
  const { result, raw } = await run({ prs: [1, 2] }, planRoutes([['preflight', envelope('preflight', { checks: [] })]]))
  assert.equal(result.status, 'needs-approval')
  assert.equal(raw.agents[0].opts.label, 'preflight')
  assert.equal(raw.agents.filter(({ opts }) => opts.label === 'preflight').length, 1)
  assert.match(raw.agents[0].prompt, /wfx preflight --worktree .* --need git,node,wfx,gh/)
})

test('a run with no PR selector and no plan skips preflight and returns candidates', async () => {
  const { result, wfxLabels } = await run({}, planRoutes())
  assert.equal(result.status, 'candidates')
  assert.deepEqual(wfxLabels, [])
})
