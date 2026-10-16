import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow } from './harness.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/verify-criteria.js')
const HEAD = 'a'.repeat(40)
const TREE = '/tmp/repo/.claude/worktrees/agent-x'
const criterion = (n, check = `bash -c 'test ${n}'`) => ({ id: `AC-${n}`, statement: `statement ${n}`, check_kind: 'command', check })
const criteria = (count) => Array.from({ length: count }, (_, i) => criterion(i + 1))
const envelope = (checks) => ({ ok: true, cmd: 'preflight', data: { checks } })
const okChecks = [{ name: 'git', ok: true, detail: 'git 2' }, { name: 'node', ok: true, detail: 'v22' }, { name: 'wfx', ok: true, detail: 'ok' }]
const verdict = (id, extra = {}) => ({ criterion: id, passes: true, evidence: `ran ${id}: ok`, tree_clean: true, missing_paths: [], ...extra })
const idsOf = (prompt) => [...prompt.matchAll(/^(AC-\d+): cd /gm)].map((m) => m[1])

// drop lists ids that get no verdict from a judge. preflight is the envelope for the runner.
const responder = ({ preflight = envelope(okChecks), drop = [], throwJudge = false } = {}) => ({ prompt, opts }) => {
  if (opts.agentType === 'runner') return preflight
  if (throwJudge) throw new Error('judge crashed')
  return { verdicts: idsOf(prompt).filter((id) => !drop.includes(id)).map((id) => verdict(id)) }
}

async function run(callArgs, respondOptions) {
  const workflow = await loadWorkflow(path)
  const workflowCalls = []
  const { globals, trace } = createRuntime({ respond: responder(respondOptions) })
  globals.workflow = (...call) => {
    workflowCalls.push(call)
    throw new Error('child workflow called')
  }
  // The workflow runs in a vm realm, so a JSON round trip gives objects that deepEqual accepts.
  const result = JSON.parse(JSON.stringify(await workflow.run({ ...globals, args: callArgs })))
  return { result, trace, workflowCalls }
}
const call = (extra = {}) => ({ worktree_path: TREE, head: HEAD, criteria: criteria(3), ...extra })
const judges = (trace) => trace.agents.filter(({ opts }) => opts.agentType === 'judge')
const runners = (trace) => trace.agents.filter(({ opts }) => opts.agentType === 'runner')

// AC-18
test('verify-criteria runs alone, returns one verdict for each criterion, and calls no child workflow', async () => {
  const { result, trace, workflowCalls } = await run(call({ criteria: criteria(8) }))
  assert.equal(result.status, 'ok')
  assert.deepEqual(result.verdicts.map((v) => v.criterion), criteria(8).map((c) => c.id))
  assert.deepEqual(result.missing, [])
  assert.deepEqual(result.preflight, { ok: true, failed: [] })
  assert.deepEqual(workflowCalls, [])
  assert.equal(judges(trace).length, 2)
  for (const { opts } of judges(trace)) {
    assert.equal(opts.model, 'sonnet')
    assert.equal(opts.effort, 'medium')
  }
  assert.match(judges(trace)[0].prompt, new RegExp(`git -C ${TREE} rev-parse HEAD`))
  assert.match(judges(trace)[0].prompt, new RegExp(HEAD))
})

test('verify-criteria preflight runs one exact wfx command in a runner and adds pytest on demand', async () => {
  const plain = await run(call())
  assert.equal(runners(plain.trace).length, 1)
  assert.ok(runners(plain.trace)[0].prompt.includes(`wfx preflight --worktree ${TREE} --need git,node,wfx\n`))
  const py = await run(call({ criteria: [criterion(1, 'python -m pytest tests/')] }))
  assert.ok(runners(py.trace)[0].prompt.includes(`--need git,node,wfx,pytest\n`))
})

test('verify-criteria blocks on a failed preflight, names the failed checks, and runs no judge', async () => {
  const failed = {
    ok: false,
    cmd: 'preflight',
    error: { code: 'preflight-failed', message: 'preflight failed: node, pytest', details: { checks: [{ name: 'git', ok: true }, { name: 'node', ok: false }, { name: 'pytest', ok: false }] } },
  }
  const { result, trace } = await run(call(), { preflight: failed })
  assert.equal(result.status, 'blocked')
  assert.match(result.reason, /node, pytest/)
  assert.deepEqual(result.preflight, { ok: false, failed: ['node', 'pytest'] })
  assert.equal(judges(trace).length, 0)
})

test('verify-criteria preflight false skips the runner', async () => {
  const { result, trace } = await run(call({ preflight: false }))
  assert.equal(result.status, 'ok')
  assert.equal(runners(trace).length, 0)
  assert.equal(result.preflight, undefined)
  assert.equal(judges(trace).length, 1)
})

test('verify-criteria blocks invalid args with the call shape before any agent', async () => {
  const bad = [
    undefined,
    { ...call(), worktree_path: 'relative/path' },
    { ...call(), head: 'abc123' },
    { ...call(), criteria: [] },
    { ...call(), criteria: [criterion(1), criterion(1)] },
    { ...call(), criteria: [{ id: 'AC-1', statement: 's', check_kind: 'command', check: '  ' }] },
    { ...call(), criteria: [{ id: 'x', statement: 's', check_kind: 'command', check: 'true' }] },
    { ...call(), extra: 1 },
  ]
  for (const input of bad) {
    const { result, trace } = await run(input)
    assert.equal(result.status, 'blocked', JSON.stringify(input))
    assert.match(result.reason, /verify-criteria args: \{worktree_path/, JSON.stringify(input))
    assert.deepEqual(result.verdicts, [])
    assert.equal(trace.agents.length, 0, JSON.stringify(input))
  }
})

test('verify-criteria returns partial with the id in missing when a verdict is absent', async () => {
  const { result } = await run(call(), { drop: ['AC-2'] })
  assert.equal(result.status, 'partial')
  assert.deepEqual(result.missing, ['AC-2'])
  assert.deepEqual(result.verdicts.map((v) => v.criterion), ['AC-1', 'AC-3'])
  assert.match(result.reason, /AC-2/)
})

test('verify-criteria reports every id of a crashed judge as missing', async () => {
  const { result } = await run(call({ batch_size: 2, criteria: criteria(4) }), { throwJudge: true })
  assert.equal(result.status, 'partial')
  assert.deepEqual(result.missing, ['AC-1', 'AC-2', 'AC-3', 'AC-4'])
})

test('verify-criteria respects batch_size, clamps it, and caps the batch count', async () => {
  const sized = await run(call({ batch_size: 2, criteria: criteria(5) }))
  assert.equal(judges(sized.trace).length, 3)
  const clamped = await run(call({ batch_size: 99, criteria: criteria(13) }))
  assert.equal(judges(clamped.trace).length, 2)
  assert.deepEqual(idsOf(judges(clamped.trace)[0].prompt).length, 12)
  const low = await run(call({ batch_size: 0, criteria: criteria(3) }))
  assert.equal(judges(low.trace).length, 3)
  // 20 criteria in batches of 1 would need 20 judges. The cap allows 8.
  const capped = await run(call({ batch_size: 1, criteria: criteria(20) }))
  assert.equal(judges(capped.trace).length, 8)
  assert.equal(capped.result.status, 'partial')
  assert.equal(capped.result.verdicts.length, 8)
  assert.equal(capped.result.missing.length, 12)
  assert.match(capped.result.reason, /batch cap/)
})

test('verify-criteria source holds no Date, Math.random, or child workflow call', async () => {
  const source = await readFile(path, 'utf8')
  assert.doesNotMatch(source, /Date\.now|Math\.random|\bworkflow\(/)
})
