import assert from 'node:assert/strict'
import { cp, mkdir, mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

const root = await mkdtemp(join(tmpdir(), 'doom-loop-omp-'))
const originalHome = process.env.HOME
const originalStateDir = process.env.DOOM_LOOP_STATE_DIR
process.env.HOME = root
process.env.DOOM_LOOP_STATE_DIR = join(root, 'state')
await mkdir(join(root, '.claude', 'lib'), { recursive: true })
await cp(
  new URL('../../agents/lib/doom-loop-guard.js', import.meta.url),
  join(root, '.claude', 'lib', 'doom-loop-guard.js'),
)
const { default: doomLoopGuard } = await import(
  '../../chezmoi/dot_omp/private_agent/extensions/doom-loop-guard.ts'
)

function loadExtension(session = 'omp-session') {
  const handlers = new Map()
  const messages = []
  let aborts = 0

  doomLoopGuard({
    on(event, handler) {
      handlers.set(event, handler)
    },
    sendMessage(message, options) {
      messages.push({ message, options })
    },
  })

  const ctx = {
    sessionManager: {
      getSessionFile() {
        return session
      },
    },
    abort() {
      aborts += 1
    },
  }

  return { handlers, messages, ctx, aborts: () => aborts }
}

test('OMP observes, blocks, and aborts within one agent run', async () => {
  const harness = loadExtension()
  const agentStart = harness.handlers.get('agent_start')
  const toolCall = harness.handlers.get('tool_call')
  assert.equal(typeof agentStart, 'function')
  assert.equal(typeof toolCall, 'function')

  await agentStart({ type: 'agent_start' }, harness.ctx)
  const event = (toolCallId) => ({
    type: 'tool_call',
    toolCallId,
    toolName: 'read',
    input: { path: 'a' },
  })
  assert.equal(await toolCall(event('call-1'), harness.ctx), undefined)
  assert.equal(await toolCall(event('call-2'), harness.ctx), undefined)
  assert.equal(harness.messages.length, 1)
  assert.equal(harness.messages[0].options.deliverAs, 'steer')
  assert.match(harness.messages[0].message.content, /repeated/i)

  for (let call = 3; call <= 5; call += 1) {
    assert.equal((await toolCall(event(`call-${call}`), harness.ctx)).block, true)
  }

  assert.equal((await toolCall(event('call-6'), harness.ctx)).block, true)
  assert.equal(harness.aborts(), 1)
})

test('OMP resets repetition counts for a new agent run', async () => {
  const harness = loadExtension('omp-reset')
  const agentStart = harness.handlers.get('agent_start')
  const toolCall = harness.handlers.get('tool_call')
  const event = (toolCallId) => ({
    type: 'tool_call',
    toolCallId,
    toolName: 'read',
    input: { path: 'a' },
  })

  await agentStart({ type: 'agent_start' }, harness.ctx)
  assert.equal(await toolCall(event('first-1'), harness.ctx), undefined)
  assert.equal(await toolCall(event('first-2'), harness.ctx), undefined)
  assert.equal(harness.messages.length, 1)

  await agentStart({ type: 'agent_start' }, harness.ctx)
  assert.equal(await toolCall(event('second-1'), harness.ctx), undefined)
  assert.equal(harness.messages.length, 1)
})

test.after(async () => {
  if (originalHome === undefined) delete process.env.HOME
  else process.env.HOME = originalHome
  if (originalStateDir === undefined) delete process.env.DOOM_LOOP_STATE_DIR
  else process.env.DOOM_LOOP_STATE_DIR = originalStateDir
  await rm(root, { recursive: true, force: true })
})
