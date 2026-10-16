// move-my-cheese isolation: each writer runs in its own worktree, and a successful run sweeps them.
import assert from 'node:assert/strict'
import test from 'node:test'

import {
  ageFull, approve, builtConsolidation, curedReviewRoutes, planRoutes, pushedCure, run, sha, wt,
} from './move-my-cheese.fixtures.mjs'

// The prompts of the per-worktree wfx remove calls, joined.
const cleanupPrompts = (trace) => trace.agents.filter(({ opts }) => /^cleanup:\d+$/.test(opts.label)).map((a) => a.prompt).join('\n')
test('every stage that edits code runs in its own isolated worktree and never enters another agent tree', async () => {
  const { result, trace, labels, call } = await run({ prs: [1], auto: true }, curedReviewRoutes(pushedCure))
  assert.equal(result.status, 'ready')
  for (const label of ['age:1', 'cure:1', 'reage:1', 'review:1:affinage:1', 'review:1:affinage:2']) {
    assert.equal(call(label).opts.isolation, 'worktree', label)
  }
  for (const { prompt, opts } of trace.agents) assert.doesNotMatch(prompt, /\bcd \//, opts.label)
  assert.ok(call('age:1').prompt.includes(`git checkout --detach ${sha(1)}`))
  const cure = call('cure:1').prompt
  assert.ok(cure.includes(`git checkout --detach ${sha(1)}`))
  assert.ok(cure.includes(`cp ${wt('age')}/.cheese/age/pr-1.md .cheese/age/pr-1.md`))
  assert.ok(cure.includes('git push origin HEAD:feat/pr-1'))
  assert.ok(call('reage:1').prompt.includes(`git checkout --detach ${sha(1, 5)}`))
  const local = `mmc/${result.digest.slice(0, 8)}/feat/pr-1`
  assert.ok(call('review:1:affinage:1').prompt.includes(`git checkout --ignore-other-worktrees -B ${local}--review-1 origin/feat/pr-1`))
  assert.ok(call('review:1:affinage:2').prompt.includes(`git checkout --ignore-other-worktrees -B ${local}--review-2 origin/feat/pr-1`))
  assert.ok(call('review:1:affinage:1').prompt.includes('When /plate pushes, it pushes with git push origin HEAD:feat/pr-1'))
  assert.ok(labels.includes('cleanup:sweep'))
})

test('finalize stamps the pushed cure head from refs alone, with no worktree and no push', async () => {
  const { call } = await run({ prs: [1], auto: true }, curedReviewRoutes(pushedCure))
  const finalize = call('finalize:1')
  assert.equal(finalize.opts.isolation, undefined)
  assert.ok(finalize.prompt.includes(`sha: ${sha(1, 5)}`))
  assert.ok(finalize.prompt.includes(`git diff origin/main...${sha(1, 5)}`))
  assert.doesNotMatch(finalize.prompt, /git push/)
})

test('a successful run removes every recorded scratch worktree and its run refs', async () => {
  const { result, call, trace } = await run({ prs: [1], auto: true }, curedReviewRoutes(pushedCure))
  // Each recorded worktree has its own wfx remove call; the sweep call removes the run branches and refs.
  const removed = cleanupPrompts(trace)
  for (const name of ['age', 'cure', 'reage', 'review-1-affinage-1', 'review-1-affinage-2']) assert.ok(removed.includes(`--path '${wt(name)}'`), name)
  const sweep = call('cleanup:sweep')
  assert.ok(sweep.prompt.includes(`refs/heads/mmc/${result.digest.slice(0, 8)}/`))
  assert.equal(sweep.opts.isolation, undefined)
})

test('a failed run keeps its worktrees for inspection', async () => {
  const { result, labels } = await run({ prs: [1], auto: true }, curedReviewRoutes({ ...pushedCure, status: 'blocked', pushed: false }))
  assert.equal(result.status, 'partial')
  assert.equal(labels.some((l) => l.startsWith('cleanup')), false)
})

test('an unsafe age report path never reaches the cure prompt', async () => {
  const { result, labels } = await run({ prs: [1], auto: true }, [
    ['age:1', ageFull(1, { artifact: '../../etc/x; rm -rf ~', worktree_path: wt('age'), has_medium_plus_findings: true })],
    ...curedReviewRoutes(pushedCure),
  ])
  assert.equal(result.targets[0].review, 'failed')
  assert.match(result.targets[0].reason, /no readable age report path/)
  assert.equal(labels.includes('cure:1'), false)
})

test('a target build continuation resumes in a fresh isolated worktree from the run-scoped ref', async () => {
  const { first, args } = await approve(planRoutes())
  const local = `mmc/${first.result.digest.slice(0, 8)}/land/combined`
  const { result, call, trace } = await run(args, builtConsolidation([
    ['target:T-1:c1', { status: 'done', completed: ['a', 'b'], remaining: [], checkpoint: sha(50), head_sha: sha(50), worktree_path: wt('t1-c1'), note: '' }],
    ['target:T-1', { status: 'partial', completed: ['a'], remaining: ['b'], checkpoint: sha(40), head_sha: '', worktree_path: wt('t1'), note: '' }],
  ]))
  assert.equal(result.status, 'ready')
  const resume = call('target:T-1:c1')
  assert.equal(resume.opts.isolation, 'worktree')
  assert.ok(resume.prompt.includes(`git checkout --detach ${sha(40)}`))
  assert.ok(resume.prompt.includes(`git update-ref refs/heads/${local} HEAD`))
  assert.doesNotMatch(resume.prompt, /\bcd \//)
  const sweep = cleanupPrompts(trace)
  assert.ok(sweep.includes(wt('t1')) && sweep.includes(wt('t1-c1')))
})
