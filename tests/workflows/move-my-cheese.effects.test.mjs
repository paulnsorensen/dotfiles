// move-my-cheese effects: the poll, merge, restack, stamp, and cleanup stages run through wfx commands.
import assert from 'node:assert/strict'
import test from 'node:test'

import {
  ageFull, aged, approve, approveDone, built, builtConsolidation, curedReviewRoutes, envelope, failure, finalized, merged, minimalPlan, noTensions, openPr,
  plain, planRoutes, pollData, published, pushedCure, ready, reconRoutes, run, sha, stateMerged, survey, wt,
} from './move-my-cheese.fixtures.mjs'

// One aged PR whose review, pre-merge poll, merge, and merged wait all succeed.
const oneLand = (overrides = []) => [
  ...overrides,
  ...reconRoutes([openPr(1)], [aged(1)]),
  ['survey', survey],
  ['tensions', noTensions],
  ['review:1:status', ready(1)],
  ['advise:done', approveDone],
  ['land:1:status', ready(1)],
  ['merge:1', merged],
  ['merged:1', stateMerged],
]

const landReason = (result) => plain(result.targets)[0].reason

test('merge passes the head the poll checked, and runs only with land', async () => {
  const landed = await run({ prs: [1], auto: true, land: true }, oneLand())
  assert.equal(landed.result.status, 'landed')
  assert.match(landed.call('merge:1').prompt, new RegExp(`wfx merge --pr 1 --head ${sha(1)} --method squash$`))
  assert.equal(landed.call('merge:1').opts.agentType, 'runner')
  const reviewOnly = await run({ prs: [1], auto: true }, oneLand())
  assert.equal(reviewOnly.result.status, 'ready')
  assert.equal(reviewOnly.labels.some((l) => /^merged?:/.test(l)), false)
})

test('the merged wait sleeps between reads and stops at MERGED', async () => {
  let reads = 0
  const { result, labels, call } = await run({ prs: [1], auto: true, land: true }, oneLand([
    ['merged:1', () => ({ state: ++reads < 3 ? 'OPEN' : 'MERGED' })],
  ]))
  assert.equal(result.status, 'landed')
  assert.deepEqual(labels.filter((l) => l.startsWith('merged:')), ['merged:1:1', 'merged:1:2', 'merged:1:3'])
  assert.doesNotMatch(call('merged:1:1').prompt, /sleep/)
  assert.match(call('merged:1:2').prompt, /^.*Command: sleep 540 && wfx poll --pr 1$/s)
})

test('a merge queue demand retries once with --queue', async () => {
  const { result, labels, call } = await run({ prs: [1], auto: true, land: true }, oneLand([
    ['merge:1:queue', { result: 'queued', note: '' }],
    ['merge:1', failure('merge', 'merge-failed', 'the base branch requires a Merge Queue')],
  ]))
  assert.equal(result.status, 'landed')
  assert.deepEqual(labels.filter((l) => l.startsWith('merge:')), ['merge:1', 'merge:1:queue'])
  assert.doesNotMatch(call('merge:1').prompt, /--queue/)
  assert.match(call('merge:1:queue').prompt, new RegExp(`wfx merge --pr 1 --head ${sha(1)} --method squash --queue$`))
})

test('any other merge refusal stops the landing without a retry', async () => {
  const { result, labels } = await run({ prs: [1], auto: true, land: true }, oneLand([
    ['merge:1', failure('merge', 'merge-failed', 'Pull request is not mergeable')],
  ]))
  assert.equal(result.status, 'partial')
  assert.equal(labels.includes('merge:1:queue'), false)
  assert.match(landReason(result), /merge refused: Pull request is not mergeable/)
})

// A two-PR stack: #2 sits on #1 and must restack onto main after #1 merges.
const stackRoutes = (overrides = []) => [
  ...overrides,
  ...reconRoutes([openPr(1), openPr(2, { base: 'feat/pr-1' })], [aged(1), aged(2, { base: 'feat/pr-1' })]),
  ['survey', survey],
  ['tensions', noTensions],
  ['review:1:status', ready(1)],
  ['review:2:status', ready(2)],
  ['advise:done', approveDone],
  ['land:1:status', ready(1)],
  ['merge:1', merged],
  ['merged:1', stateMerged],
  ['recheck-age:2', ageFull(2)],
  ['land:2:status', ready(2)],
  ['merge:2', merged],
  ['merged:2', stateMerged],
  ['restack:2:retarget', envelope('pr', { pr: 2, base: 'main' })],
]

test('a restack conflict falls back to the /melt agent and logs the conflicting files', async () => {
  const { result, labels, call, trace } = await run({ prs: [1, 2], auto: true, land: true }, stackRoutes([
    ['restack:2:melt', { status: 'ok', pushed: true, worktree_path: wt('melt'), note: '' }],
    ['restack:2', failure('restack', 'conflict', 'rebase hit conflicts', { files: ['src/a.js', 'src/b.js'], stderr: '' })],
  ]))
  assert.equal(result.status, 'landed')
  assert.deepEqual(labels.filter((l) => l.startsWith('restack:')), ['restack:2', 'restack:2:melt'])
  const melt = call('restack:2:melt')
  assert.equal(melt.opts.isolation, 'worktree')
  assert.ok(melt.prompt.includes('git rebase --onto origin/main origin/feat/pr-1'))
  assert.ok(melt.prompt.includes('/melt'))
  assert.ok(trace.logs.some((l) => /restack:2 conflicts in src\/a\.js, src\/b\.js/.test(l)))
})

test('a restack conflict that /melt cannot resolve stops the landing', async () => {
  const { result } = await run({ prs: [1, 2], auto: true, land: true }, stackRoutes([
    ['restack:2:melt', { status: 'blocked', pushed: false, worktree_path: wt('melt'), note: 'conflicts remain' }],
    ['restack:2', failure('restack', 'conflict', 'rebase hit conflicts', { files: ['src/a.js'], stderr: '' })],
  ]))
  assert.equal(result.status, 'partial')
  assert.match(plain(result.targets).find((t) => t.pr === 2).reason, /restack failed: conflicts remain/)
})

test('a restack error other than a conflict stops the landing without /melt', async () => {
  const { result, labels } = await run({ prs: [1, 2], auto: true, land: true }, stackRoutes([
    ['restack:2', failure('restack', 'push-rejected', 'the lease failed')],
  ]))
  assert.equal(result.status, 'partial')
  assert.equal(labels.includes('restack:2:melt'), false)
  assert.match(plain(result.targets).find((t) => t.pr === 2).reason, /restack failed: push-rejected: the lease failed/)
})

// Poll readiness: each wfx poll shape maps to a verdict that decides whether /affinage or a human runs.
const pollRoutes = (data) => [
  ...reconRoutes([openPr(1)], [aged(1)]),
  ['survey', survey],
  ['tensions', noTensions],
  ['review:1:status', envelope('poll', pollData({ pr: 1, headRefOid: sha(1), ...data }))],
  ['review:1:affinage', { status: 'ok', pushed: false, worktree_path: wt('affinage'), note: '' }],
]

test('a draft PR is not ready, even when its merge state reads clean', async () => {
  const { result, labels } = await run({ prs: [1], auto: true }, pollRoutes({ isDraft: true, mergeStateStatus: 'CLEAN' }))
  assert.notEqual(result.status, 'ready')
  assert.equal(plain(result.targets)[0].review, 'draft')
  assert.equal(labels.some((l) => l.includes(':affinage')), false)
})

test('a BEHIND branch and a failing check each send the PR to /affinage', async () => {
  for (const data of [{ mergeStateStatus: 'BEHIND' }, { checks: { passing: 0, failing: 2, pending: 0, items: [{}, {}] } }]) {
    const { labels } = await run({ prs: [1], auto: true }, pollRoutes(data))
    assert.ok(labels.includes('review:1:affinage:1'), JSON.stringify(data))
  }
})

test('a BLOCKED PR with green checks waits for a human review', async () => {
  const { result } = await run({ prs: [1], auto: true }, pollRoutes({ mergeStateStatus: 'BLOCKED', reviewDecision: 'REVIEW_REQUIRED' }))
  assert.notEqual(result.status, 'ready')
  assert.equal(plain(result.targets)[0].review, 'awaiting-review')
})

test('a poll with no checks is ready only when no checks are allowed', async () => {
  const none = { checks: { passing: 0, failing: 0, pending: 0, items: [] } }
  const blocked = await run({ prs: [1], auto: true }, pollRoutes(none))
  assert.notEqual(blocked.result.status, 'ready')
  const allowed = await run({ prs: [1], auto: true, allowNoChecks: true }, pollRoutes(none))
  assert.equal(allowed.result.status, 'ready')
})

test('a failed poll envelope fails the review with its error', async () => {
  const { result } = await run({ prs: [1], auto: true }, pollRoutes({}).map(([p, v]) => (p === 'review:1:status' ? [p, failure('poll', 'gh-failed', 'gh pr view exited 1')] : [p, v])))
  assert.match(plain(result.targets)[0].reason, /status failed: gh-failed: gh pr view exited 1/)
})

test('the first poll reads at once and later rounds sleep first', async () => {
  const { call } = await run({ prs: [1], auto: true }, pollRoutes({ mergeStateStatus: 'BEHIND' }))
  assert.match(call('review:1:status:1').prompt, /Command: wfx poll --pr 1$/)
  assert.match(call('review:1:status:2').prompt, /Command: sleep 540 && wfx poll --pr 1$/)
})

test('stamps go through wfx with the digest and the head, and skip a PR whose head moved', async () => {
  const { first, args } = await approve(builtConsolidation())
  const { call, labels, trace } = await run(args, builtConsolidation([
    ['stampcheck:10', envelope('poll', pollData({ pr: 10, headRefOid: sha(60) }))],
  ]))
  assert.equal(labels.includes('stamp:10'), false)
  assert.ok(trace.logs.some((l) => /stamp skipped for #10: its head moved/.test(l)))
  const same = await run(args, builtConsolidation())
  assert.match(same.call('stamp:10').prompt, new RegExp(`wfx stamp --pr 10 --marker ${first.result.digest} --sha ${sha(50)}$`))
  assert.equal(call('stampcheck:10').opts.agentType, 'runner')
})

test('a worktree the cleanup scan cannot remove is reported as leftover_worktrees', async () => {
  const left = { path: '/repo/.claude/worktrees/lnd@stuck', landing: 'lnd', name: 'stuck', head: sha(9), branch: 'mmc/x/feat/pr-1' }
  // The cured review leaves scratch worktrees, so the final cleanup runs.
  const { result, call } = await run({ prs: [1], auto: true }, [
    ['cleanup:sweep', envelope('worktree', { root: '/repo', worktrees: [left] })],
    ...curedReviewRoutes(pushedCure),
  ])
  assert.equal(result.status, 'ready')
  assert.deepEqual(plain(result.leftover_worktrees), [left])
  assert.match(call('cleanup:sweep').prompt, /wfx worktree list --repo .* --landing [0-9a-f]+$/)
  const clean = await run({ prs: [1], auto: true }, curedReviewRoutes(pushedCure))
  assert.equal('leftover_worktrees' in plain(clean.result), false)
})

// ---- Publish: one wfx step per call ----
// The PR 2 on the remote sits on prBase, a stacked base inside the run; the plan moves it to main.
const existingPlanRoutes = (prBase, extra = []) => planRoutes([
  ['recon:detail', { prs: [aged(1), aged(2, { base: prBase })] }], ['plan:minimal', minimalPlan()], ...extra,
])
const builtExisting = (base, extra = []) => existingPlanRoutes(base, [
  ['target:T-2', built(sha(60), '/tmp/wt-t2')],
  ['publish', published('T-2', 2, sha(60))],
  ['age:2', ageFull(2, { worktree_path: '/tmp/wt-t2' })],
  ['finalize:2', finalized],
  ['review:1:status', ready(1)],
  ['review:2:status', ready(2, { head_sha: sha(60) })],
  ...extra,
])

test('publish pushes the built head with a lease on the remote head, or none for a new branch', async () => {
  const { args } = await approve(planRoutes())
  const fresh = await run(args, builtConsolidation())
  assert.equal(fresh.result.status, 'ready')
  assert.match(fresh.call('publish:T-1:push').prompt, new RegExp(`wfx publish --repo .* --branch 'land/combined' --sha ${sha(50)} --expect none$`))
  const plan = existingPlanRoutes('main')
  const existing = await approve(plan)
  const kept = await run(existing.args, builtExisting('main'))
  assert.equal(kept.result.status, 'ready')
  assert.match(kept.call('publish:T-2:push').prompt, new RegExp(`--branch 'feat/pr-2' --sha ${sha(60)} --expect ${sha(2)}$`))
})

test('an existing target whose PR sits on another base is retargeted, and one on the same base is not', async () => {
  const moved = await approve(existingPlanRoutes('feat/pr-1'))
  const { result, call, labels } = await run(moved.args, builtExisting('feat/pr-1'))
  assert.equal(result.status, 'ready')
  assert.match(call('publish:T-2:retarget').prompt, /wfx pr retarget --pr 2 --base 'main'$/)
  assert.equal(labels.includes('publish:T-2:create'), false)
  const same = await approve(existingPlanRoutes('main'))
  const unchanged = await run(same.args, builtExisting('main'))
  assert.equal(unchanged.labels.includes('publish:T-2:retarget'), false)
})

test('a new target opens its PR with the brief and a Supersedes line for each folded PR, then comments the marker', async () => {
  const { first, args } = await approve(planRoutes())
  const { result, call } = await run(args, builtConsolidation())
  assert.equal(result.status, 'ready')
  const create = call('publish:T-1:create').prompt
  assert.match(create, /wfx pr create --base 'main' --head 'land\/combined' --title 'feat: combined' --body-file /)
  assert.ok(create.includes('combine both'))
  assert.ok(create.includes('Supersedes #1') && create.includes('Supersedes #2'))
  assert.match(call('publish:T-1:comment').prompt, /wfx pr comment --pr 10 --body-file /)
  assert.ok(call('publish:T-1:comment').prompt.includes(`move-my-cheese:landing digest=${first.result.digest}`))
})

test('a lease-rejected new target adopts the one open PR of its branch', async () => {
  const { args } = await approve(planRoutes())
  const { result, call, labels } = await run(args, builtConsolidation([
    ['publish:T-1:push', failure('publish', 'lease-rejected', 'the remote branch exists')],
    ['publish:T-1:adopt', [{ number: 10, url: 'https://example.test/pr/10', headRefOid: sha(40) }]],
  ]))
  assert.equal(result.status, 'ready')
  assert.match(call('publish:T-1:adopt').prompt, /gh pr list --head 'land\/combined' --state open --json number,url,headRefOid/)
  assert.match(call('publish:T-1:adopt:push').prompt, new RegExp(`--sha ${sha(50)} --expect ${sha(40)}$`))
  assert.equal(labels.includes('publish:T-1:create'), false)
  assert.match(call('publish:T-1:comment').prompt, /wfx pr comment --pr 10 /)
})

test('a lease-rejected new target with no open PR fails and says to check the remote', async () => {
  const { args } = await approve(planRoutes())
  const { result, labels } = await run(args, builtConsolidation([['publish:T-1:push', failure('publish', 'lease-rejected', 'the remote branch exists')]]))
  assert.equal(result.status, 'fail')
  assert.match(result.note, /publish T-1 failed at push: lease-rejected/)
  assert.match(result.note, /not one; check the remote branches and PRs before a rerun/)
  assert.equal(labels.some((l) => l === 'publish:T-1:create' || l === 'publish:T-1:adopt:push'), false)
})

test('a failed stats call reports zero changes and does not stop the run', async () => {
  const { args } = await approve(planRoutes())
  const { result, labels } = await run(args, builtConsolidation([['publish:T-1:stats', null]]))
  assert.equal(result.status, 'ready')
  assert.ok(labels.includes('publish:T-1:stats'))
})
