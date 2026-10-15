import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow } from './harness.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/deep-research.js')
const report = { answer: 'a', confidence: 'speculating', evidence_table: [] }

// Runs the shim with a stub child. The stub records each workflow() call and returns, throws, or yields what the test gives it.
async function runShim(args, child = () => report) {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: () => { throw new Error('unexpected agent') } })
  const calls = []
  const result = await workflow.run({
    ...globals,
    args,
    workflow: async (name, childArgs) => {
      calls.push({ name, args: childArgs })
      return child(childArgs)
    },
  })
  return { result, calls, trace }
}

test('deep-research forwards a bare question to brie-ground and returns its report', async () => {
  const { result, calls, trace } = await runShim('  how does X work?  ')

  assert.deepEqual(calls, [{ name: 'brie-ground', args: 'how does X work?' }])
  assert.equal(result, report)
  assert.deepEqual(Array.from(trace.phases), ['Delegate'])
  assert.equal(trace.agents.length, 0)
})

test('deep-research reads the question from an object or from that object sent as a JSON string', async () => {
  for (const args of [{ question: ' q1 ' }, '{"question": "q1"}']) {
    const { calls } = await runShim(args)
    assert.deepEqual(calls, [{ name: 'brie-ground', args: 'q1' }], JSON.stringify(args))
  }
  // A question that only starts with a brace stays text.
  const { calls } = await runShim('{draft} how does Y work?')
  assert.deepEqual(calls, [{ name: 'brie-ground', args: '{draft} how does Y work?' }])
})

test('deep-research rejects a missing question with its own usage before any research', async () => {
  for (const args of [undefined, '', '   ', {}, { question: '' }, '{"topic": "x"}', 42, ['q']]) {
    const { result, calls } = await runShim(args)
    assert.equal(calls.length, 0, JSON.stringify(args))
    assert.match(result.error, /Usage: \/deep-research <question>/, JSON.stringify(args))
    assert.doesNotMatch(result.error, /brie-ground/)
  }
})

test('deep-research turns a brie-ground throw into an error result that carries the question', async () => {
  const { result, trace } = await runShim('q2', () => { throw new Error('unknown workflow: brie-ground') })

  assert.match(result.error, /brie-ground failed: unknown workflow: brie-ground/)
  assert.equal(result.question, 'q2')
  assert.ok(trace.logs.some((l) => /brie-ground failed: unknown workflow/.test(l)))
})

test('deep-research reports an error when brie-ground returns no result object', async () => {
  for (const value of [null, undefined, 'text', []]) {
    const { result } = await runShim('q3', () => value)
    assert.match(result.error, /brie-ground returned no result object/, String(value))
    assert.equal(result.question, 'q3')
  }
})

test('deep-research passes a brie-ground error result through unchanged', async () => {
  const failed = { error: 'Planning failed — no plan produced.' }
  const { result } = await runShim('q4', () => failed)
  assert.equal(result, failed)
})
