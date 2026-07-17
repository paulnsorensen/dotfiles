import assert from 'node:assert/strict'
import { mkdtemp, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow, validate } from './harness.mjs'

test('validate rejects fixture drift at the schema path', async () => {
  const runtime = createRuntime({ respond: () => ({ verdict: 'bad' }) })

  await assert.rejects(
    runtime.globals.agent('prompt', {
      schema: {
        type: 'object',
        required: ['verdict'],
        properties: { verdict: { type: 'string', enum: ['pass', 'revise'] } },
      },
    }),
    /\$\.verdict/,
  )
})

test('validate rejects unsupported schema keywords', () => {
  assert.throws(
    () => validate('x', { type: 'string', minLength: 1 }),
    /unsupported schema keyword "minLength"/,
  )
})

test('a workflow fails when an agent schema uses an unsupported keyword', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'workflow-harness-'))
  const path = join(directory, 'unsupported-schema.js')
  await writeFile(path, [
    'export const meta = {',
    "  name: 'unsupported-schema',",
    '}',
    '',
    "return agent('prompt', { schema: { type: 'string', minLength: 1 } })",
    '',
  ].join('\n'))

  const workflow = await loadWorkflow(path)
  await assert.rejects(
    workflow.run(createRuntime({ respond: () => 'fixture' }).globals),
    /unsupported schema keyword "minLength"/,
  )
})

test('validate rejects null for an object schema', () => {
  assert.throws(
    () => validate(null, { type: 'object' }),
    /expected object, got object/,
  )
})

test('validate distinguishes arrays from objects', () => {
  assert.throws(
    () => validate([], { type: 'object' }),
    /expected object, got array/,
  )
})

test('validate rejects unsupported keywords anywhere in the schema tree', () => {
  assert.throws(
    () => validate({}, {
      type: 'object',
      properties: { omitted: { type: 'string', minLength: 1 } },
    }),
    /\$\.omitted: unsupported schema keyword "minLength"/,
  )
})

test('pipeline null-drops a failed item, skips its remaining stages, and continues other chains', async () => {
  const { globals } = createRuntime()
  const continued = []
  const result = await globals.pipeline(
    [1, 2, 3],
    (item) => {
      if (item === 2) throw new Error('stop this item')
      return item * 2
    },
    (item) => {
      continued.push(item)
      return item + 1
    },
  )

  assert.deepEqual(result, [3, null, 7])
  assert.deepEqual(continued, [2, 6])
})

test('pipeline starts each item chain without waiting for another item', async () => {
  const { globals } = createRuntime()
  const started = []
  const releases = []
  const pending = globals.pipeline([1, 2], async (item) => {
    started.push(item)
    await new Promise((resolve) => releases.push(resolve))
    return item
  })

  assert.deepEqual(started, [1, 2])
  releases.forEach((release) => release())
  assert.deepEqual(await pending, [1, 2])
})

test('parallel nulls a thrown thunk without rejecting its barrier', async () => {
  const { globals } = createRuntime()
  const result = await globals.parallel([
    async () => 'first',
    async () => { throw new Error('broken') },
    async () => 'third',
  ])

  assert.deepEqual(result, ['first', null, 'third'])
})

test('budget reports total, spent, and clamped remaining tokens', () => {
  const { budget } = createRuntime({ budgetTotal: 100, budgetSpent: 125 }).globals

  assert.equal(budget.total, 100)
  assert.equal(budget.spent(), 125)
  assert.equal(budget.remaining(), 0)
})

test('budget reports unlimited totals and remaining tokens as null', () => {
  const { budget } = createRuntime({ budgetSpent: 25 }).globals

  assert.equal(budget.total, null)
  assert.equal(budget.spent(), 25)
  assert.equal(budget.remaining(), null)
})

for (const [name, body, error] of [
  ['Date.now()', 'return Date.now()', /not available in workflow scripts/],
  ['Math.random()', 'return Math.random()', /not available in workflow scripts/],
  ['argless new Date()', 'return new Date()', /not available in workflow scripts/],
  ['Date()', 'return Date()', /not available in workflow scripts/],
  ['globalThis.Date.now()', 'return globalThis.Date.now()', /not available in workflow scripts/],
  ['globalThis.Math.random()', 'return globalThis.Math.random()', /not available in workflow scripts/],
  ['process', 'return process', /process is not defined/],
]) {
  test(`workflow code cannot call ${name}`, async () => {
    const directory = await mkdtemp(join(tmpdir(), 'workflow-harness-'))
    const path = join(directory, 'sandbox.js')
    await writeFile(path, `export const meta = {\n  name: 'sandbox',\n}\n\n${body}\n`)

    const workflow = await loadWorkflow(path)
    await assert.rejects(workflow.run(createRuntime().globals), error)
  })
}
