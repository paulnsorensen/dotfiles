// move-my-cheese execution without land: assemble, verify, publish, review, poll, and drafts.
import assert from 'node:assert/strict'
import test from 'node:test'

import {
  BASE_SHA, INT_WORKTREE, ageFull, aged, approve, built, builtConsolidation, detail, envelope, failure, finalized, keepPlanRoutes, minimalPlan,
  noTensions, openPr, passingVerdict, plain, planRoutes, published, ready, reconRoutes, run, sha, survey,
} from './move-my-cheese.fixtures.mjs'

test('auto with clean, already-aged PRs reaches ready without building, publishing, or reviewing', async () => {
  const { result, labels } = await run({ prs: [1, 2], auto: true }, [
    ...reconRoutes([openPr(1), openPr(2)], [aged(1), aged(2)]),
    ['survey', survey],
    ['tensions', noTensions],
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
    ['finalize:1', finalized],
    ['review:1:status', ready(1)],
  ])
  assert.ok(labels.includes('age:1'))
  assert.match(call('age:1').prompt, /sha="", patch="", dirty=0/)
  assert.match(call('recon:detail').prompt, /select\(\.user\.login == "me"\)/)
})

test('cure commits that cure could not push fail the review before re-age, finalize, or polling', async () => {
  const { result, labels } = await run({ prs: [1], auto: true }, [
    ...reconRoutes([openPr(1)], [detail(1)]),
    ['survey', survey],
    ['tensions', noTensions],
    ['age:1', ageFull(1, { artifact: 'a.md', has_medium_plus_findings: true })],
    ['cure:1', { status: 'blocked', committed: true, pushed: false, head_sha: sha(1, 5), worktree_path: '/tmp/wt-c', artifact: 'c.md', note: '' }],
  ])
  assert.equal(result.status, 'partial')
  assert.equal(result.targets[0].review, 'failed')
  assert.match(result.targets[0].reason, /cure commits were not pushed/)
  assert.equal(labels.some((l) => l === 'reage:1' || l === 'finalize:1' || l.startsWith('review:1:status')), false)
})

test('a keep-only plan with a command criterion verifies in the pinned integration worktree without a checkout', async () => {
  const { result, labels, call, workflowCalls } = await run({ prs: [1, 2], auto: true }, keepPlanRoutes([
    ['worktree:add', envelope('worktree', { path: INT_WORKTREE, landing: 'lnd', name: 'verify-pre', head: sha(97) })],
  ]), null, null, (input) => ({ status: 'ok', verdicts: [{ ...passingVerdict(input.criteria[0]), evidence: 'grep printed 1 and 1' }], missing: [] }))
  assert.equal(result.status, 'ready')
  assert.deepEqual(workflowCalls.map((c) => c.name), ['verify-criteria'])
  const input = workflowCalls[0].input
  assert.equal(input.worktree_path, INT_WORKTREE)
  assert.equal(input.head, sha(97))
  assert.equal(input.criteria[0].check, 'node --test --test-name-pattern helpers tests/helper.test.mjs')
  assert.equal(call('worktree:add:pre').opts.isolation, undefined)
  assert.deepEqual(plain(result.verification.verdicts).map((v) => [v.result, v.evidence]), [['pass', 'grep printed 1 and 1']])
  assert.equal(labels.some((l) => l.startsWith('target:') || l.startsWith('publish')), false)
})

test('a target that conflicts during integration fails before verification, publish, or review', async () => {
  const { result, labels, wfxLabels, workflowCalls } = await run({ prs: [1, 2], auto: true }, keepPlanRoutes([
    ['integrate:T-2', failure('integrate', 'conflict', 'x', { conflict: { target: 'T-2', files: ['a.js'] } })],
  ]))
  assert.equal(result.status, 'fail')
  assert.match(result.note, /T-2 conflicts with the targets merged before it in a\.js/)
  assert.equal(workflowCalls.length, 0)
  assert.equal(wfxLabels.some((l) => l.startsWith('worktree:')), false)
  assert.equal(labels.some((l) => l.startsWith('review:') || l.startsWith('publish')), false)
})

test('an approved consolidation builds, verifies, publishes, and drafts the superseded PRs', async () => {
  const { args } = await approve(planRoutes())
  const { result, labels, call } = await run(args, builtConsolidation())
  assert.equal(result.status, 'ready')
  assert.equal(labels.some((l) => l.startsWith('survey') || l.startsWith('plan:')), false)
  assert.equal(call('publish:T-1:push').opts.model, 'haiku')
  assert.equal(call('publish:T-1:push').opts.agentType, 'runner')
  assert.match(call('mark').prompt, /gh pr ready <pr> --undo/)
  assert.match(call('mark').prompt, /move-my-cheese:landing digest=/)
  assert.doesNotMatch(call('mark').prompt, /gh pr close/)
  assert.deepEqual(plain(result.inputs).map((i) => [i.number, i.action, i.mark]), [[1, 'supersede', 'drafted'], [2, 'supersede', 'drafted']])
})

test('builders and integration use a run-scoped local branch, and publish pushes the built head by SHA', async () => {
  const { first, args } = await approve(planRoutes())
  const local = `mmc/${first.result.digest.slice(0, 8)}/land/combined`
  const { result, call } = await run(args, builtConsolidation())
  assert.equal(result.status, 'ready')
  const target = call('target:T-1').prompt
  assert.ok(target.includes('git checkout --detach origin/main'))
  assert.ok(target.includes(`git update-ref refs/heads/${local} HEAD`))
  assert.ok(!target.includes('git checkout -B'))
  const merge = call('integrate:T-1').prompt
  assert.ok(merge.includes(`--target '${sha(50)}'`))
  assert.ok(merge.includes(`--base '${BASE_SHA}'`))
  assert.match(merge, /--branch 'mmc\/integrate-/)
  assert.ok(!merge.includes(local))
  const push = call('publish:T-1:push').prompt
  assert.ok(push.includes(`--branch 'land/combined' --sha ${sha(50)} --expect none`))
  assert.ok(call('publish:T-1:comment').prompt.includes(`move-my-cheese:landing digest=${first.result.digest}`))
  assert.ok(!push.includes(local))
})

test('a failed target build stops the run before anything is pushed', async () => {
  const { args } = await approve(planRoutes())
  const blocked = { status: 'blocked', completed: [], remaining: ['combine'], checkpoint: '', head_sha: '', worktree_path: '', note: 'conflicts remain' }
  const { result, labels } = await run(args, planRoutes([['target:T-1', blocked]]))
  assert.equal(result.status, 'fail')
  assert.match(result.note, /T-1 \(blocked\).*nothing was pushed/)
  assert.equal(labels.some((l) => l.startsWith('publish') || l.startsWith('integrate:')), false)
})

test('publish never reruns after a failed step', async () => {
  const { args } = await approve(planRoutes())
  const { result, labels } = await run(args, builtConsolidation([['publish:T-1:push', failure('publish', 'push-failed', 'network down')]]))
  assert.equal(result.status, 'fail')
  assert.match(result.note, /publish T-1 failed at push: push-failed: network down; check the remote branches and PRs before a rerun/)
  assert.deepEqual(labels.filter((l) => l.startsWith('publish')), ['publish:T-1:push'])
})

test('a branch this run rebuilt gets a full review, never an incremental one', async () => {
  const { args } = await approve(planRoutes([['recon:detail', { prs: [aged(1), aged(2)] }], ['plan:minimal', minimalPlan()]]))
  const { result, call } = await run(args, planRoutes([
    ['recon:detail', { prs: [aged(1), aged(2)] }],
    ['plan:minimal', minimalPlan()],
    ['target:T-2', built(sha(60), '/tmp/wt-t2')],
    ['publish', published('T-2', 2, sha(60))],
    ['age:2', ageFull(2, { worktree_path: '/tmp/wt-t2' })],
    ['finalize:2', finalized],
    ['review:1:status', ready(1)],
    ['review:2:status', ready(2, { head_sha: sha(60) })],
  ]))
  assert.equal(result.status, 'ready')
  assert.match(call('age:2').prompt, /This run rebuilt the branch/)
  assert.doesNotMatch(call('age:2').prompt, /Mode incremental/)
})
