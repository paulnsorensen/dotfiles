import assert from 'node:assert/strict'
import test from 'node:test'

import noForkAll from '../../chezmoi/dot_omp/private_agent/extensions/no-fork-all.ts'

const reason =
  "fork_turns:'all' forks the entire transcript into the worker and burns quota. Re-spawn with fork_turns:'none' (or a small integer only if this sub-task genuinely needs prior turns)."

function loadExtension() {
  let toolCallHandler

  noForkAll({
    on(event, handler) {
      assert.equal(event, 'tool_call')
      toolCallHandler = handler
    },
  })

  assert.equal(typeof toolCallHandler, 'function')

  return { toolCallHandler }
}

for (const toolName of ['spawn_agent', 'task']) {
  test(`blocks ${toolName} spawns with fork_turns:'all'`, async () => {
    const harness = loadExtension()

    const result = await harness.toolCallHandler({ toolName, input: { fork_turns: 'all' } })

    assert.deepEqual(result, { block: true, reason })
  })
}

for (const forkTurns of ['none', 0, 3, undefined]) {
  test(`allows fork_turns:${JSON.stringify(forkTurns)} on the spawn tool`, async () => {
    const harness = loadExtension()

    const result = await harness.toolCallHandler({ toolName: 'task', input: { fork_turns: forkTurns } })

    assert.equal(result, undefined)
  })
}

test('ignores tool_call events for unrelated tools', async () => {
  const harness = loadExtension()

  const result = await harness.toolCallHandler({ toolName: 'bash', input: { fork_turns: 'all' } })

  assert.equal(result, undefined)
})
