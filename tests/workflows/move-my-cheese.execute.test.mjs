// move-my-cheese execution without land: assemble, verify, publish, review, poll, and drafts.
import assert from 'node:assert/strict'
import test from 'node:test'

import {
  ageFull, aged, approve, built, builtConsolidation, detail, integrated, keepPlanRoutes, minimalPlan, noTensions,
  openPr, plain, planRoutes, published, ready, reconRoutes, run, sha, survey, verified,
} from './move-my-cheese.fixtures.mjs'

test('auto with clean, already-aged PRs reaches ready without building, publishing, or reviewing', async () => {
  const { result, labels } = await run({ prs: [1, 2], auto: true }, [
    ...reconRoutes([openPr(1), openPr(2)], [aged(1), aged(2)]),
    ['survey', survey],
    ['tensions', noTensions],
    ['integrate:pre', integrated(['T-1', 'T-2'])],
    ['review:1:status', ready(1)],
    ['review:2:status', ready(2)],
  ])
  assert.equal(result.status, 'ready')
  assert.equal(labels.some((l) => /^(target|publish|age|cure|finalize|verify|merge|mark):/.test(l)), false)
  assert.deepEqual(plain(result.targets).map((t) => t.review), ['ready', 'ready'])
  assert.deepEqual(plain(result.verification.verdicts).map((v) => v.result), ['deferred', 'deferred'])
})

test('the poll stops as stalled when /affinage makes no progress', async () => {
  const { result, labels } = await run({ prs: [1], auto: true }, [
    ...reconRoutes([openPr(1)], [aged(1)]),
    ['survey', survey],
    ['tensions', noTensions],
    ['review:1:status', ready(1, { ci: 'fail' })],
    ['review:1:affinage', { status: 'ok', pushed: false, worktree_path: '/tmp/wt-1', note: '' }],
  ])
  assert.equal(result.status, 'partial')
  assert.equal(result.targets[0].review, 'stalled')
  assert.deepEqual(labels.filter((l) => l.startsWith('review:1:')), ['review:1:status:1', 'review:1:affinage:1', 'review:1:status:2'])
})

test('a PR with no reported checks is not ready unless allowNoChecks is set', async () => {
  const routes = [...reconRoutes([openPr(1)], [aged(1)]), ['survey', survey], ['tensions', noTensions], ['review:1:status', ready(1, { ci: 'none' })]]
  const strict = await run({ prs: [1], auto: true }, routes)
  assert.equal(strict.result.targets[0].review, 'exhausted')
  assert.equal(strict.labels.filter((l) => l.startsWith('review:1:status')).length, 6)
  const loose = await run({ prs: [1], auto: true, allowNoChecks: true }, routes)
  assert.equal(loose.result.targets[0].review, 'ready')
})

test('a malformed aged marker reads as no marker, so the PR is reviewed', async () => {
  const { labels, call } = await run({ prs: [1], auto: true }, [
    ...reconRoutes([openPr(1)], [detail(1, { aged_sha: 'abc; rm -rf /', aged_patch: 'x' })]),
    ['survey', survey],
    ['tensions', noTensions],
    ['age:1', ageFull(1)],
    ['finalize:1', { pushed: false, head_sha: sha(1), marker_updated: true }],
    ['review:1:status', ready(1)],
  ])
  assert.ok(labels.includes('age:1'))
  assert.match(call('age:1').prompt, /sha="", patch="", dirty=0/)
  assert.match(call('recon:detail').prompt, /select\(\.user\.login == "me"\)/)
})

test('cure commits that finalize could not push fail the review instead of reading as ready', async () => {
  const { result, labels } = await run({ prs: [1], auto: true }, [
    ...reconRoutes([openPr(1)], [detail(1)]),
    ['survey', survey],
    ['tensions', noTensions],
    ['age:1', ageFull(1, { has_medium_plus_findings: true })],
    ['cure:1', { status: 'ok', committed: true, artifact: 'c.md' }],
    ['reage:1', ageFull(1, { mode: 'incremental' })],
    ['finalize:1', { pushed: false, head_sha: sha(1), marker_updated: false }],
  ])
  assert.equal(result.status, 'partial')
  assert.equal(result.targets[0].review, 'failed')
  assert.match(result.targets[0].reason, /cure commits were not pushed/)
  assert.equal(labels.some((l) => l.startsWith('review:1:status')), false)
})

test('a keep-only plan with a command criterion still integrates and verifies in an isolated judge worktree', async () => {
  const { result, labels, call } = await run({ prs: [1, 2], auto: true }, keepPlanRoutes([
    ['integrate:pre', { ...integrated(['T-1', 'T-2']), head: sha(97) }],
    ['verify:pre:AC-1', verified],
  ]))
  assert.equal(result.status, 'ready')
  assert.equal(call('verify:pre:AC-1').opts.isolation, 'worktree')
  assert.match(call('verify:pre:AC-1').prompt, new RegExp(`git checkout --detach ${sha(97)}`))
  assert.deepEqual(plain(result.verification.verdicts).map((v) => v.result), ['pass'])
  assert.equal(labels.some((l) => l.startsWith('target:') || l === 'publish'), false)
})

test('an integration that drops a target fails before publish', async () => {
  const { result, labels } = await run({ prs: [1, 2], auto: true }, keepPlanRoutes([['integrate:pre', integrated(['T-1'])]]))
  assert.equal(result.status, 'fail')
  assert.match(result.note, /T-2 is in neither merged nor conflicted/)
  assert.equal(labels.some((l) => l.startsWith('verify:') || l.startsWith('review:')), false)
})

test('an approved consolidation builds, verifies, publishes, and drafts the superseded PRs', async () => {
  const { args } = await approve(planRoutes())
  const { result, labels, call } = await run(args, builtConsolidation())
  assert.equal(result.status, 'ready')
  assert.equal(labels.some((l) => l.startsWith('survey') || l.startsWith('plan:')), false)
  assert.equal(call('publish').opts.model, 'sonnet')
  assert.match(call('mark').prompt, /gh pr ready <pr> --undo/)
  assert.match(call('mark').prompt, /move-my-cheese:landing digest=/)
  assert.doesNotMatch(call('mark').prompt, /gh pr close/)
  assert.deepEqual(plain(result.inputs).map((i) => [i.number, i.action, i.mark]), [[1, 'supersede', 'drafted'], [2, 'supersede', 'drafted']])
})

test('builders, integration, and publish use a run-scoped local branch, never the PR branch itself', async () => {
  const { first, args } = await approve(planRoutes())
  const local = `mmc/${first.result.digest.slice(0, 8)}/land/combined`
  const { result, call } = await run(args, builtConsolidation())
  assert.equal(result.status, 'ready')
  assert.ok(call('target:T-1').prompt.includes(`git checkout -B ${local} origin/main`))
  assert.ok(call('integrate:pre').prompt.includes(`T-1=${local}`))
  assert.ok(call('publish').prompt.includes(`"local_branch": "${local}"`))
  assert.ok(call('publish').prompt.includes('<local_branch>:refs/heads/<branch>'))
  assert.ok(call('publish').prompt.includes(`move-my-cheese:landing digest=${first.result.digest}`))
})

test('a failed target build stops the run before anything is pushed', async () => {
  const { args } = await approve(planRoutes())
  const blocked = { status: 'blocked', completed: [], remaining: ['combine'], checkpoint: '', head_sha: '', worktree_path: '', note: 'conflicts remain' }
  const { result, labels } = await run(args, planRoutes([['target:T-1', blocked]]))
  assert.equal(result.status, 'fail')
  assert.match(result.note, /T-1 \(blocked\).*nothing was pushed/)
  assert.equal(labels.some((l) => l === 'publish' || l.startsWith('integrate:')), false)
})

test('publish never reruns after an invalid report', async () => {
  const { args } = await approve(planRoutes())
  const { result, labels } = await run(args, builtConsolidation([['publish', published('T-1', 1, sha(50))]]))
  assert.equal(result.status, 'fail')
  assert.match(result.note, /check the remote branches/)
  assert.deepEqual(labels.filter((l) => l.startsWith('publish')), ['publish'])
})

test('a branch this run rebuilt gets a full review, never an incremental one', async () => {
  const { args } = await approve(planRoutes([['recon:detail', { prs: [aged(1), aged(2)] }], ['plan:minimal', minimalPlan()]]))
  const { result, call } = await run(args, planRoutes([
    ['recon:detail', { prs: [aged(1), aged(2)] }],
    ['plan:minimal', minimalPlan()],
    ['target:T-2', built(sha(60), '/tmp/wt-t2')],
    ['integrate:pre', integrated(['T-1', 'T-2'])],
    ['verify:pre:AC-1', verified],
    ['publish', published('T-2', 2, sha(60))],
    ['age:2', ageFull(2, { worktree_path: '/tmp/wt-t2' })],
    ['finalize:2', { pushed: false, head_sha: sha(60), marker_updated: true }],
    ['review:1:status', ready(1)],
    ['review:2:status', ready(2, { head_sha: sha(60) })],
  ]))
  assert.equal(result.status, 'ready')
  assert.match(call('age:2').prompt, /This run rebuilt the branch/)
  assert.doesNotMatch(call('age:2').prompt, /Mode incremental/)
})
