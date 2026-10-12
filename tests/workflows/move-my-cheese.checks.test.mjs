// move-my-cheese criterion checks: planner rules, plan-time check validation, judge verdicts, and recon commands.
import assert from 'node:assert/strict'
import test from 'node:test'

import {
  approveP1, consolidatePlan, detail, integrated, keepPlan, keepPlanRoutes, plain, planRoutes, reconOnly, run, sha, verified, wt,
} from './move-my-cheese.fixtures.mjs'

const vacuousCheck = 'cd src && ! grep -q helper gone.js'
const vacuousPlan = () => consolidatePlan({ criteria: [{ id: 'AC-1', statement: 'the old helper is gone', check_kind: 'command', check: vacuousCheck }] })
const checkPlanWith = (check) => run({ prs: [1, 2] }, planRoutes([['plan:minimal', consolidatePlan({ criteria: [{ id: 'AC-1', statement: 's', check_kind: 'command', check }] })]]))
const pinned = { ...integrated(['T-1', 'T-2']), head: sha(97) }

test('planners get the rules that keep criterion checks runnable', async () => {
  const { call } = await run({ prs: [1, 2] }, planRoutes())
  const planner = call('plan:minimal').prompt
  assert.ok(planner.includes('start the check with cd <that directory> &&'))
  assert.ok(planner.includes('Quote every glob. Put every option before --.'))
})

test('a negated grep without an existence test is rejected at plan time; a guarded one passes', async () => {
  const { result, trace, call } = await run({ prs: [1, 2] }, planRoutes([['plan:minimal', vacuousPlan()]]))
  assert.equal(result.status, 'blocked')
  assert.ok(trace.logs.some((l) => /AC-1 check can pass without testing anything: it negates grep over gone\.js/.test(l)))
  assert.ok(call('plan:minimal').prompt.includes('Put test -e <path> && before a negated search'))
})

test('the plan check accepts each negated search with a guard on its own path', async () => {
  for (const check of [
    'test -e src/gone.js && ! grep -q helper src/gone.js',
    '[ -f src/1.js ] && ! rg -q helper src/1.js',
    "[[ -s a ]] && ! egrep -q 'x|y' a",
    'test -d src && ! grep -rq x src',
    'test -e gone.js && ! git grep -q x -- gone.js',
    'cd src && test -r a.js && ! grep -q --regexp=x a.js',
    'test -e a && ! grep -q -m 1 x a',
    'test -e a && ! grep -q x a 2>/dev/null',
    'test -e a && ! grep -q x a > /dev/null 2>&1',
    'test -e ./a && ! grep -q x a',
    'test -e a && ! grep -q x ./a',
    '! git grep -q x',
    "! rg -g '*.py' -q x",
    'grep -c helper src/1.js',
  ]) assert.equal((await checkPlanWith(check)).result.status, 'needs-approval', check)
})

test('the plan check rejects each negated search that can pass on missing input', async () => {
  for (const [check, why] of [
    ['test -e a && ! grep -q x a && ! grep -q x b', /over b /],
    ['test -e b || ! grep -q x b', /over b /],
    ['test -e b; ! grep -q x b', /over b /],
    ['test -e a && cd b && ! grep -q x a', /over a /],
    ['! git grep -q x -- gone.js', /git grep over gone\.js/],
    ['! grep -e x -e y src/1.js', /over src\/1\.js/],
    ['! grep -rq x src', /over src /],
    ['! cat src/1.js | grep -q x', /pipeline into grep/],
    ['! grep -q x', /with no file/],
    ["! grep -q 'x src/1.js", /unclosed quote/],
  ]) {
    const { result, trace } = await checkPlanWith(check)
    assert.equal(result.status, 'blocked', check)
    assert.ok(trace.logs.some((l) => why.test(l)), check)
  }
})

test('code shell-quotes a criterion check, and a dirty tree before a check shows in the verdict', async () => {
  const quoted = { ...keepPlan(), criteria: [{ id: 'AC-1', statement: 'the helper exists', check_kind: 'command', check: "grep -c 'helper' src/1.js" }] }
  const { result, trace, call } = await run({ prs: [1, 2], auto: true }, keepPlanRoutes([
    ['plan:minimal', quoted],
    ['integrate:pre', pinned],
    ['verify:pre:AC-1', { ...verified, tree_clean: false, evidence: 'grep printed 1' }],
  ]))
  assert.ok(call('verify:pre:AC-1').prompt.includes("cd /tmp/int && bash -c 'grep -c '\\''helper'\\'' src/1.js'"))
  assert.match(plain(result.verification.verdicts)[0].evidence, /the worktree had changes from an earlier check/)
  assert.ok(trace.logs.some((l) => /integration worktree had changes before the check/.test(l)))
})

test('a judge that finds a missing path fails the criterion before publish', async () => {
  const { result, call } = await run({ prs: [1, 2], auto: true }, keepPlanRoutes([
    ['integrate:pre', pinned],
    ['verify:pre:AC-1', { ...verified, missing_paths: ['src/2.js'], evidence: 'grep printed 1' }],
  ]))
  assert.equal(result.status, 'fail')
  assert.match(result.note, /criteria failed: AC-1/)
  assert.match(plain(result.verification.verdicts)[0].evidence, /the check reads missing paths: src\/2\.js/)
  assert.ok(call('verify:pre:AC-1').prompt.includes('Put each missing path in missing_paths'))
})

// Mirrors digestOf in the workflow, so a test can hold an approval that a newer plan check rejects.
function digestOf(value) {
  const stable = (v) => Array.isArray(v) ? `[${v.map(stable).join(',')}]`
    : v && typeof v === 'object' ? `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${stable(v[k])}`).join(',')}}`
      : JSON.stringify(v) ?? 'null'
  const fnv1a = (input, seed) => {
    let hash = seed >>> 0
    for (let i = 0; i < input.length; i++) hash = Math.imul(hash ^ input.charCodeAt(i), 16777619) >>> 0
    return hash.toString(16).padStart(8, '0')
  }
  const canonical = stable(value)
  return `${fnv1a(canonical, 2166136261)}${fnv1a(canonical, 3735928559)}`
}

test('an approval that a newer check rejects blocks with a revise hint, and revise repairs it', async () => {
  const first = await run({ prs: [1, 2] }, planRoutes())
  assert.equal(digestOf(plain(first.result.landing)), first.result.digest)
  const landing = { ...plain(first.result.landing), plan: vacuousPlan() }
  const approve = digestOf(landing)
  const blocked = await run({ prs: [1, 2], plan: landing, approve }, reconOnly())
  assert.equal(blocked.result.status, 'blocked')
  assert.match(blocked.result.error, /no longer validates: AC-1 check can pass without testing anything.*revise/)
  const repaired = await run({ prs: [1, 2], plan: landing, approve, revise: 'guard AC-1 with an existence test' }, [
    ...reconOnly(),
    ['plan:revise', consolidatePlan()],
    ['advise:plan:revise', approveP1],
  ])
  assert.equal(repaired.result.status, 'needs-approval')
  const planner = repaired.call('plan:revise').prompt
  assert.ok(planner.includes('<data name="plan_errors">'))
  assert.ok(planner.includes('AC-1 check can pass without testing anything'))
})

test('recon reads counts and checks with exact commands, code caps the body, and tensions get every pair', async () => {
  const { result, call } = await run({ prs: [1, 2] }, planRoutes([
    ['recon:detail', { prs: [detail(1, { body: 'x'.repeat(2000) }), detail(2)] }],
  ]))
  assert.ok(call('recon:detail').prompt.includes('.body[:1500]'))
  assert.ok(call('recon:detail').prompt.includes('reviewThreads(first: 100)'))
  assert.ok(call('recon:detail').prompt.includes('gh pr checks <n> --json bucket'))
  assert.ok(!call('survey:1').prompt.includes('x'.repeat(1501)))
  assert.ok(call('tensions').prompt.includes('<data name="pairs">'))
  assert.ok(result.estimate.agents_max > 0)
})

test('a redone integration records every attempt worktree for cleanup', async () => {
  let calls = 0
  const { result, call } = await run({ prs: [1, 2], auto: true }, keepPlanRoutes([
    ['integrate:pre', () => (++calls === 1
      ? { ...integrated(['T-1']), worktree_path: wt('int1'), head: sha(97) }
      : { ...integrated(['T-1', 'T-2']), worktree_path: wt('int2'), head: sha(97) })],
    ['verify:pre:AC-1', { ...verified, evidence: 'grep printed 1 and 1' }],
  ]))
  assert.equal(result.status, 'ready')
  const sweep = call('cleanup').prompt
  assert.ok(sweep.includes(wt('int1')) && sweep.includes(wt('int2')))
})
