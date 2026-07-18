import assert from 'node:assert/strict'
import test from 'node:test'

import slicedBreadAudit from '../../chezmoi/dot_omp/private_agent/extensions/sliced-bread-audit.ts'

const description = "Run a severity-ranked Sliced Bread audit through OMP's native workflow runner"
const usage = 'Usage: /sliced-bread-audit [scope] [--dry-run] [--min-severity=blocker|high|medium|low] [--max-issues=1..100] [--workers=1..16]'

function expectedPrompt({
  scope = '.',
  minSeverity = 'medium',
  maxIssues = 25,
  workers = 4,
  dryRun = false,
} = {}) {
  return `workflowz

Run a Sliced Bread architecture and code-quality audit.

Scope: ${scope}
Severity floor: ${minSeverity}
Maximum issues: ${maxIssues}
Evaluation workers: ${workers}
Dry run: ${dryRun}

Build this as a deterministic task graph, not as a single review. First map the scope into vertical slices; merge micro-directories with fewer than three files into their parent. In parallel, prepare GitHub deduplication context and assign evaluator workers to slices plus one cross-slice dependency/API pass. Run no more than ${workers} evaluator tasks concurrently, including the cross-slice pass. Every evaluator returns structured candidate findings with dimension, severity, file, line, quoted evidence, behavioral impact, and one-line fix direction.

After all evaluators finish, run a citation-verification task that rejects uncited, below-floor, or malformed findings. Then run an independent adversarial-refuter task against every blocker and high finding; retain only verified high-severity findings. Dedupe surviving findings by file, dimension, and ten-line bucket, then against existing audit issues.

When dry run is false, file at most ${maxIssues} fresh confirmed findings as GitHub issues using labels sliced-bread-audit and sev:<severity>. When dry run is true, do not mutate GitHub; report the proposed issues instead. Never modify production code during this audit.

Return a severity-ranked report with findings, refuted candidates, clean dimensions, and every issue URL or proposed issue.`
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

  slicedBreadAudit(api)
  assert.deepEqual(
    { name: registered?.name, description: registered?.command.description },
    { name: 'sliced-bread-audit', description },
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
    { message: 'Sliced Bread audit workflow queued.', level: 'info' },
  ])
})

for (const { name, args, options } of [
  { name: 'scope', args: 'src/domain', options: { scope: 'src/domain' } },
  { name: 'dry run', args: '--dry-run', options: { dryRun: true } },
  ...['blocker', 'high', 'medium', 'low'].map((minSeverity) => ({
    name: `severity ${minSeverity}`,
    args: `--min-severity=${minSeverity}`,
    options: { minSeverity },
  })),
  { name: 'minimum max issues', args: '--max-issues=1', options: { maxIssues: 1 } },
  { name: 'maximum max issues', args: '--max-issues=100', options: { maxIssues: 100 } },
  { name: 'minimum workers', args: '--workers=1', options: { workers: 1 } },
  { name: 'maximum workers', args: '--workers=16', options: { workers: 16 } },
]) {
  test(`${name} produces the exact dispatch prompt`, async () => {
    const harness = loadExtension()

    await harness.handler(args, harness.ctx)

    assert.deepEqual(harness.sent, [expectedPrompt(options)])
    assert.deepEqual(harness.notifications, [
      { message: 'Sliced Bread audit workflow queued.', level: 'info' },
    ])
  })
}

for (const { args, reason } of [
  { args: '--unknown', reason: 'Unknown option: --unknown' },
  { args: '--min-severity=critical', reason: 'Invalid min severity: critical' },
  { args: '--min-severity=toString', reason: 'Invalid min severity: toString' },
  { args: '--min-severity=constructor', reason: 'Invalid min severity: constructor' },
  { args: '--min-severity=__proto__', reason: 'Invalid min severity: __proto__' },
  { args: '--max-issues=0', reason: 'max-issues must be an integer from 1 to 100' },
  { args: '--max-issues=101', reason: 'max-issues must be an integer from 1 to 100' },
  { args: '--max-issues=1.5', reason: 'max-issues must be an integer from 1 to 100' },
  { args: '--workers=0', reason: 'workers must be an integer from 1 to 16' },
  { args: '--workers=17', reason: 'workers must be an integer from 1 to 16' },
  { args: '--workers=1.5', reason: 'workers must be an integer from 1 to 16' },
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
    { message: 'Sliced Bread audit workflow queued.', level: 'info' },
  ])
})

test('dispatch rejection propagates without reporting success', async () => {
  const failure = new Error('dispatch failed')
  const harness = loadExtension({ dispatch: async () => { throw failure } })

  await assert.rejects(harness.handler('', harness.ctx), (error) => error === failure)
  assert.deepEqual(harness.sent, [expectedPrompt()])
  assert.deepEqual(harness.notifications, [])
})
