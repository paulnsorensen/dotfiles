import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow } from './harness.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/sliced-bread-audit.js')
const workflow = await loadWorkflow(path)

const slice = (name, over = {}) => ({ name, path: `domains/${name}`, kind: 'domain', summary: 's', key_files: [], ...over })
const finding = (over = {}) => ({
  dimension: 'model-purity',
  severity: 'medium',
  file: 'domains/x/a.py',
  line: 40,
  claim: 'imports an ORM directly',
  evidence: 'from sqlalchemy import Session',
  recommendation: 'introduce a port',
  ...over,
})
const citeOk = (n) => ({ results: Array.from({ length: n }, (_, i) => ({ index: i, ok: true })) })

// Wraps the map/gh-setup/cross-slice boilerplate every run dispatches, and
// delegates slice-eval / cite / refute / issues-batch agents to `on`.
function build({ slices = [], existing = [], ghOk = true, on = () => { throw new Error('no handler') } }) {
  return createRuntime({
    respond: (call) => {
      const label = call.opts.label
      if (label === 'map:slices') return { layout: 'flat', slices }
      if (label === 'map:gh-setup') {
        return ghOk ? { gh_ok: true, repo: 'o/n', existing_fingerprints: existing } : { gh_ok: false, error: 'no gh auth' }
      }
      if (label === 'eval:cross-slice') return { slice: 'cross-slice', findings: [] }
      return on(call)
    },
  })
}

const labels = (trace) => trace.agents.map((a) => a.opts.label)
const hasRefuter = (trace) => trace.agents.some((a) => a.opts.label.startsWith('refute:'))

for (const min_severity of ['critical', 'blocker!', 'HIGH']) {
  test(`rejects an invalid min_severity before dispatching any agent: ${JSON.stringify(min_severity)}`, async () => {
    const { globals, trace } = createRuntime()
    const result = await workflow.run({ ...globals, args: { min_severity } })
    assert.match(result.error, /min_severity must be one of/)
    assert.equal(trace.agents.length, 0)
  })
}

for (const max_issues of [0, -1, 2.5, 'ten']) {
  test(`rejects a non-positive-integer max_issues before dispatching any agent: ${JSON.stringify(max_issues)}`, async () => {
    const { globals, trace } = createRuntime()
    const result = await workflow.run({ ...globals, args: { max_issues } })
    assert.match(result.error, /max_issues must be a positive integer/)
    assert.equal(trace.agents.length, 0)
  })
}

test('a string arg becomes the scope, and an empty slice map aborts before any evaluation', async () => {
  const { globals, trace } = build({ slices: [] })
  const result = await workflow.run({ ...globals, args: 'src/pkg' })

  assert.match(result.error, /found no slices/)
  assert.match(trace.agents.find((a) => a.opts.label === 'map:slices').prompt, /under `src\/pkg`/)
  assert.equal(labels(trace).some((l) => l.startsWith('eval:')), false)
})

test('a medium finding ships on a confirmed citation alone — no adversarial refuter — and is still returned when gh is unavailable', async () => {
  const { globals, trace } = build({
    slices: [slice('x')],
    ghOk: false,
    on: ({ opts }) => {
      if (opts.label === 'eval:x') return { slice: 'x', findings: [finding()] }
      if (opts.label.startsWith('cite:')) return citeOk(1)
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: {} })

  assert.equal(hasRefuter(trace), false)
  assert.equal(result.confirmed.length, 1)
  assert.equal(result.confirmed[0].verification, 'citation-checked')
  // gh down must not lose the finding — it rides back in the report, marked unfiled.
  assert.equal(result.issues[0].skipped_reason, 'gh unavailable')
})

test('a below-floor (low) finding is never citation-checked and never confirmed', async () => {
  const { globals, trace } = build({
    slices: [slice('x')],
    on: ({ opts }) => {
      if (opts.label === 'eval:x') {
        return { slice: 'x', findings: [finding({ severity: 'low', file: 'domains/x/low.py', line: 5 }), finding()] }
      }
      if (opts.label.startsWith('cite:')) return citeOk(1)
      if (opts.label.startsWith('issues:batch')) return { results: [{ index: 0, created: true, url: 'https://gh/1' }] }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: {} })

  const citePrompt = trace.agents.find((a) => a.opts.label === 'cite:x').prompt
  assert.match(citePrompt, /a\.py:40/)
  assert.doesNotMatch(citePrompt, /low\.py/)
  assert.equal(result.confirmed.length, 1)
  assert.equal(result.below_floor.length, 1)
  assert.match(result.below_floor[0], /low\.py/)
})

test('a blocker/high finding is refuted when the adversarial refuter refutes it', async () => {
  const { globals, trace } = build({
    slices: [slice('x')],
    on: ({ opts }) => {
      if (opts.label === 'eval:x') return { slice: 'x', findings: [finding({ severity: 'high', dimension: 'import-direction' })] }
      if (opts.label.startsWith('cite:')) return citeOk(1)
      if (opts.label.startsWith('refute:')) return { refuted: true, reasoning: 'rule misapplied' }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { dry_run: true } })

  assert.equal(hasRefuter(trace), true)
  assert.equal(result.confirmed.length, 0)
  assert.equal(result.refuted.length, 1)
  assert.match(result.refuted[0], /refuter: rule misapplied/)
})

test('a crashed refuter counts as a refutation — an unconfirmed high finding must never ship', async () => {
  const { globals, trace } = build({
    slices: [slice('x')],
    on: ({ opts }) => {
      if (opts.label === 'eval:x') return { slice: 'x', findings: [finding({ severity: 'blocker', dimension: 'import-direction' })] }
      if (opts.label.startsWith('cite:')) return citeOk(1)
      if (opts.label.startsWith('refute:')) throw new Error('refuter crashed')
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { dry_run: true } })

  assert.equal(hasRefuter(trace), true)
  assert.equal(result.confirmed.length, 0)
  assert.equal(result.refuted.length, 1)
  assert.match(result.refuted[0], /refuter crashed \(conservative refute\)/)
})

test('a high finding the refuter fails to refute is confirmed and filed as a GitHub issue', async () => {
  const { globals } = build({
    slices: [slice('x')],
    on: ({ opts }) => {
      if (opts.label === 'eval:x') return { slice: 'x', findings: [finding({ severity: 'high', dimension: 'import-direction' })] }
      if (opts.label.startsWith('cite:')) return citeOk(1)
      if (opts.label.startsWith('refute:')) return { refuted: false, reasoning: 'rule genuinely applies' }
      if (opts.label.startsWith('issues:batch')) return { results: [{ index: 0, created: true, url: 'https://gh/1' }] }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: {} })

  assert.equal(result.confirmed[0].verification, 'citation-checked + refuter-tested')
  assert.deepEqual(result.issue_urls, ['https://gh/1'])
})

test('a confirmed finding matching an existing audit issue fingerprint is not re-filed', async () => {
  const { globals, trace } = build({
    slices: [slice('x')],
    existing: ['sba:domains/x/a.py:model-purity:4'],
    on: ({ opts }) => {
      if (opts.label === 'eval:x') return { slice: 'x', findings: [finding()] }
      if (opts.label.startsWith('cite:')) return citeOk(1)
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: {} })

  assert.equal(result.confirmed.length, 1)
  assert.equal(result.issues.length, 0)
  assert.equal(labels(trace).some((l) => l.startsWith('issues:batch')), false)
  assert.match(trace.logs.join('\n'), /already exists/)
})

test('max_issues caps how many confirmed findings are filed, and the rest stay in the report', async () => {
  const { globals, trace } = build({
    slices: [slice('x')],
    on: ({ opts }) => {
      if (opts.label === 'eval:x') {
        return { slice: 'x', findings: [finding({ file: 'domains/x/a.py' }), finding({ file: 'domains/x/b.py' })] }
      }
      if (opts.label.startsWith('cite:')) return citeOk(2)
      if (opts.label.startsWith('issues:batch')) return { results: [{ index: 0, created: true, url: 'https://gh/1' }] }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { max_issues: 1 } })

  assert.equal(result.confirmed.length, 2)
  assert.equal(result.issues.length, 1)
  assert.match(trace.logs.join('\n'), /Capping at 1/)
})

test('a dry run tells gh setup not to mutate labels and files no issues', async () => {
  const { globals, trace } = build({
    slices: [slice('x')],
    on: ({ opts }) => {
      if (opts.label === 'eval:x') return { slice: 'x', findings: [finding()] }
      if (opts.label.startsWith('cite:')) return citeOk(1)
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { dry_run: true } })

  assert.match(trace.agents.find((a) => a.opts.label === 'map:gh-setup').prompt, /Dry run/)
  assert.equal(labels(trace).some((l) => l.startsWith('issues:batch')), false)
  assert.equal(result.issues[0].skipped_reason, 'dry_run')
})
