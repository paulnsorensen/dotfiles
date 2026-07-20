import assert from 'node:assert/strict'
import test from 'node:test'

import milknadoTodoGuard from '../../chezmoi/dot_omp/private_agent/extensions/milknado-todo-guard.ts'

const message = 'Native /todo is disabled. Use Milknado MCP for work tracking.'

function loadExtension() {
  const notifications = []
  let inputHandler

  milknadoTodoGuard({
    on(event, handler) {
      assert.equal(event, 'input')
      inputHandler = handler
    },
  })

  assert.equal(typeof inputHandler, 'function')

  const ctx = {
    ui: {
      notify(text, level) {
        notifications.push({ text, level })
      },
    },
  }

  return { inputHandler, ctx, notifications }
}

test('blocks native todo commands and identifies Milknado as the owner', async () => {
  const harness = loadExtension()

  for (const text of ['/todo', '/todo append Implementation\nWrite guard', '/todo\tview']) {
    const result = await harness.inputHandler(
      { type: 'input', text, source: 'interactive' },
      harness.ctx,
    )
    assert.deepEqual(result, { action: 'handled' })
  }

  assert.deepEqual(harness.notifications, [
    { text: message, level: 'warning' },
    { text: message, level: 'warning' },
    { text: message, level: 'warning' },
  ])
})

test('leaves non-command input untouched', async () => {
  const harness = loadExtension()

  for (const text of ['Use /todo later', '/todone', ' /todo', 'plain input']) {
    const result = await harness.inputHandler(
      { type: 'input', text, source: 'interactive' },
      harness.ctx,
    )
    assert.deepEqual(result, { action: 'continue' })
  }

  assert.deepEqual(harness.notifications, [])
})
