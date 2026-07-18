import assert from 'node:assert/strict'
import test from 'node:test'

import nihScanner from '../../chezmoi/dot_omp/private_agent/extensions/nih-scanner.ts'

const description = "Run an evidence-ranked NIH (Not-Invented-Here) build-vs-buy audit through OMP's native workflow runner"
const usage = 'Usage: /nih-scanner [scope] [--min-usage=N] [--max-candidates=1..100] [--workers=1..16] [--languages=ts,py,...]'

function expectedPrompt({
  scope = '.',
  minUsage = 0,
  maxCandidates = 25,
  workers = 4,
  languages,
} = {}) {
  return `workflowz

Run a Not-Invented-Here (NIH) build-vs-buy audit.

Scope: ${scope}
Minimum usage count: ${minUsage}
Maximum candidates: ${maxCandidates}
Scan workers: ${workers}
Languages: ${languages ? languages.join(', ') : 'auto-detect'}

Build this as a deterministic task graph, not as a single review. First run one cheap detection pass over the scope to identify languages, dependency manifests, and file count. Split the scope into up to ${workers} chunks and fan out an nih-scanner agent per chunk to find candidate code that reinvents well-supported library functionality. Dedupe overlapping candidates by file, line, and function, drop candidates below the minimum usage count, and cap the surviving set at ${maxCandidates} candidates.

Then run an independent adversarial-skeptic verification task against every candidate, default-refute: a confirmation must name the specific replacement library and cite why the local code duplicates it, or it is refuted. A crashed verification keeps the candidate flagged low-confidence and needs-human, never silently confirmed.

Finally, synthesize a ranked findings table from only the confirmed candidates: category, file:line, function, usage count, replacement library, migration effort, confidence, and recommendation, plus a summary of counts by category and the single highest-leverage action. Never file issues, post comments, or modify production code during this audit — report only.

Return the ranked findings report, refuted candidates, and needs-human candidates.`
}

function loadExtension({ dispatch = async () => {} } = {}) {
  const sent = []
  const notifications = []
  let registered

  const api = {
    registerCommand(name, command) {
      registered = { name, command }
    },
    sendUserMessage(message) {
      sent.push(message)
      return dispatch(message)
    },
  }

  nihScanner(api)
  assert.deepEqual(
    { name: registered?.name, description: registered?.command.description },
    { name: 'nih-scanner', description },
  )

  const ctx = {
    ui: {
      notify(message, level) {
        notifications.push({ message, level })
      },
    },
  }

  return { handler: registered.command.handler, ctx, sent, notifications }
}

test('registers the command and dispatches the exact default workflow contract', async () => {
  const harness = loadExtension()

  await harness.handler('', harness.ctx)

  assert.deepEqual(harness.sent, [expectedPrompt()])
  assert.deepEqual(harness.notifications, [
    { message: 'NIH scanner audit workflow queued.', level: 'info' },
  ])
})

for (const { name, args, options } of [
  { name: 'scope', args: 'src/domain', options: { scope: 'src/domain' } },
  { name: 'minimum min-usage', args: '--min-usage=0', options: { minUsage: 0 } },
  { name: 'positive min-usage', args: '--min-usage=5', options: { minUsage: 5 } },
  { name: 'minimum max-candidates', args: '--max-candidates=1', options: { maxCandidates: 1 } },
  { name: 'maximum max-candidates', args: '--max-candidates=100', options: { maxCandidates: 100 } },
  { name: 'minimum workers', args: '--workers=1', options: { workers: 1 } },
  { name: 'maximum workers', args: '--workers=16', options: { workers: 16 } },
  { name: 'languages', args: '--languages=ts,py', options: { languages: ['ts', 'py'] } },
]) {
  test(`${name} produces the exact dispatch prompt`, async () => {
    const harness = loadExtension()

    await harness.handler(args, harness.ctx)

    assert.deepEqual(harness.sent, [expectedPrompt(options)])
    assert.deepEqual(harness.notifications, [
      { message: 'NIH scanner audit workflow queued.', level: 'info' },
    ])
  })
}

for (const { args, reason } of [
  { args: '--unknown', reason: 'Unknown option: --unknown' },
  { args: '--min-usage=-1', reason: 'min-usage must be an integer >= 0' },
  { args: '--min-usage=1.5', reason: 'min-usage must be an integer >= 0' },
  { args: '--max-candidates=0', reason: 'max-candidates must be an integer from 1 to 100' },
  { args: '--max-candidates=101', reason: 'max-candidates must be an integer from 1 to 100' },
  { args: '--max-candidates=1.5', reason: 'max-candidates must be an integer from 1 to 100' },
  { args: '--workers=0', reason: 'workers must be an integer from 1 to 16' },
  { args: '--workers=17', reason: 'workers must be an integer from 1 to 16' },
  { args: '--workers=1.5', reason: 'workers must be an integer from 1 to 16' },
  { args: '--languages=', reason: 'languages must be a non-empty comma-separated list' },
  { args: 'src/a src/b', reason: 'Pass one scope path only' },
]) {
  test(`rejects ${args} without dispatching`, async () => {
    const harness = loadExtension()

    await harness.handler(args, harness.ctx)

    assert.deepEqual(harness.sent, [])
    assert.deepEqual(harness.notifications, [
      { message: `${reason}\n\n${usage}`, level: 'error' },
    ])
  })
}

test('notifies queued only after dispatch resolves', async () => {
  let resolveDispatch
  const dispatch = new Promise((resolve) => {
    resolveDispatch = resolve
  })
  const harness = loadExtension({ dispatch: () => dispatch })

  const pending = harness.handler('--workers=2', harness.ctx)
  assert.deepEqual(harness.sent, [expectedPrompt({ workers: 2 })])
  assert.deepEqual(harness.notifications, [])

  resolveDispatch()
  await pending

  assert.deepEqual(harness.notifications, [
    { message: 'NIH scanner audit workflow queued.', level: 'info' },
  ])
})

test('dispatch rejection propagates without reporting success', async () => {
  const failure = new Error('dispatch failed')
  const harness = loadExtension({ dispatch: async () => { throw failure } })

  await assert.rejects(harness.handler('', harness.ctx), (error) => error === failure)
  assert.deepEqual(harness.sent, [expectedPrompt()])
  assert.deepEqual(harness.notifications, [])
})
