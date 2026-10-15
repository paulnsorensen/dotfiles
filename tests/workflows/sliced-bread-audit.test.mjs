import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow } from './harness.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/sliced-bread-audit.js')
const workflow = await loadWorkflow(path)

const slice = (name, over = {}) => ({ name, path: `domains/${name}`, kind: 'domain', ...over })
const finding = (over = {}) => ({
  dimension: 'model-purity',
  severity: 'medium',
  file: 'domains/x/a.py',
  line: 40,
  claim: 'imports an ORM directly',
  evidence: 'from sqlalchemy import Session',
  impact: 'domain behavior now depends on persistence infrastructure',
  recommendation: 'introduce a port',
  ...over,
})
// Citation and refuter agents take numbered batches; these mocks answer every item in the batch prompt.
const batchItems = (prompt) => prompt.split(/^\d+\. \[/m).slice(1)
const citeAll = (prompt) => ({ results: batchItems(prompt).map((_, index) => ({ index, ok: true, reason: '' })) })
const verdicts = (prompt, verdict) => ({
  verdicts: batchItems(prompt).map((item, index) => ({ index, ...(typeof verdict === 'function' ? verdict(item) : verdict) })),
})

// Wraps the map/gh-setup/cross-slice boilerplate every run dispatches, and
// delegates slice-eval / cite / refute / issues-batch agents to `on`.
function build({ slices = [], existing = [], ghOk = true, on = () => { throw new Error('no handler') } }) {
  return createRuntime({
    respond: (call) => {
      const label = call.opts.label
      if (label === 'map:slices') return { layout: 'flat', slices }
      if (label === 'map:gh-setup') {
        return ghOk
          ? { gh_ok: true, repo: 'o/n', existing_fingerprints: existing, error: '' }
          : { gh_ok: false, repo: '', existing_fingerprints: [], error: 'no gh auth' }
      }
      if (label === 'eval:cross-slice') return { slice: 'cross-slice', findings: [] }
      return on(call)
    },
  })
}

const labels = (trace) => trace.agents.map((a) => a.opts.label)
const hasRefuter = (trace) => trace.agents.some((a) => a.opts.label.startsWith('refute:'))

for (const min_severity of ['critical', 'blocker!', 'HIGH', 'toString']) {
  test(`rejects an invalid min_severity before dispatching any agent: ${JSON.stringify(min_severity)}`, async () => {
    const { globals, trace } = createRuntime()
    const result = await workflow.run({ ...globals, args: { min_severity } })
    assert.match(result.error, /min_severity must be one of/)
    assert.equal(trace.agents.length, 0)
  })
}

for (const max_issues of [0, -1, 2.5, 'ten', 101]) {
  test(`rejects an out-of-range max_issues before dispatching any agent: ${JSON.stringify(max_issues)}`, async () => {
    const { globals, trace } = createRuntime()
    const result = await workflow.run({ ...globals, args: { max_issues } })
    assert.match(result.error, /max_issues must be an integer from 1 to 100/)
    assert.equal(trace.agents.length, 0)
  })
}
for (const workers of [0, 17, 1.5, 'two']) {
  test(`rejects an out-of-range worker limit before dispatching any agent: ${JSON.stringify(workers)}`, async () => {
    const { globals, trace } = createRuntime()
    const result = await workflow.run({ ...globals, args: { workers } })
    assert.match(result.error, /workers must be an integer from 1 to 16/)
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
    on: ({ opts, prompt }) => {
      if (opts.label === 'eval:x') return { slice: 'x', findings: [finding()] }
      if (opts.label.startsWith('cite:')) return citeAll(prompt)
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
    on: ({ opts, prompt }) => {
      if (opts.label === 'eval:x') {
        return { slice: 'x', findings: [finding({ severity: 'low', file: 'domains/x/low.py', line: 5 }), finding()] }
      }
      if (opts.label.startsWith('cite:')) return citeAll(prompt)
      if (opts.label.startsWith('issues:batch')) return { results: [{ index: 0, created: true, url: 'https://gh/1' }] }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: {} })

  const citePrompt = trace.agents.find((a) => a.opts.label.startsWith('cite:')).prompt
  assert.match(citePrompt, /a\.py:40/)
  assert.doesNotMatch(citePrompt, /low\.py/)
  assert.equal(result.confirmed.length, 1)
  assert.equal(result.below_floor.length, 1)
  assert.match(result.below_floor[0], /low\.py/)
})

test('a blocker/high finding is refuted when the adversarial refuter refutes it', async () => {
  const { globals, trace } = build({
    slices: [slice('x')],
    on: ({ opts, prompt }) => {
      if (opts.label === 'eval:x') return { slice: 'x', findings: [finding({ severity: 'high', dimension: 'import-direction' })] }
      if (opts.label.startsWith('cite:')) return citeAll(prompt)
      if (opts.label.startsWith('refute:')) return verdicts(prompt, { refuted: true, reason: 'rule misapplied' })
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { dry_run: true } })

  assert.equal(hasRefuter(trace), true)
  assert.equal(result.confirmed.length, 0)
  assert.equal(result.refuted.length, 1)
  assert.match(result.refuted[0], /refuter: rule misapplied/)
  assert.deepEqual(Array.from(result.refuter_outcomes, (outcome) => ({ ...outcome })), [{
    location: 'domains/x/a.py:40',
    outcome: 'refuted',
    reason: 'rule misapplied',
  }])
})

test('a crashed refuter counts as a refutation — an unconfirmed high finding must never ship', async () => {
  const { globals, trace } = build({
    slices: [slice('x')],
    on: ({ opts, prompt }) => {
      if (opts.label === 'eval:x') return { slice: 'x', findings: [finding({ severity: 'blocker', dimension: 'import-direction' })] }
      if (opts.label.startsWith('cite:')) return citeAll(prompt)
      if (opts.label.startsWith('refute:')) throw new Error('refuter crashed')
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { dry_run: true } })

  assert.equal(hasRefuter(trace), true)
  assert.equal(result.confirmed.length, 0)
  assert.equal(result.refuted.length, 1)
  assert.match(result.refuted[0], /refuter failed: refuter crashed/)
  assert.deepEqual(Array.from(result.refuter_outcomes, (outcome) => ({ ...outcome })), [{
    location: 'domains/x/a.py:40',
    outcome: 'failed',
    reason: 'refuter crashed',
  }])
})

test('a high finding the refuter fails to refute is confirmed and filed as a GitHub issue', async () => {
  const { globals, trace } = build({
    slices: [slice('x')],
    on: ({ opts, prompt }) => {
      if (opts.label === 'eval:x') return { slice: 'x', findings: [finding({ severity: 'high', dimension: 'import-direction' })] }
      if (opts.label.startsWith('cite:')) return citeAll(prompt)
      if (opts.label.startsWith('refute:')) return verdicts(prompt, { refuted: false, reason: 'rule genuinely applies' })
      if (opts.label.startsWith('issues:batch')) return { results: [{ index: 0, created: true, url: 'https://gh/1' }] }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: {} })

  assert.equal(result.confirmed[0].verification, 'citation-checked + refuter-tested')
  assert.deepEqual(Array.from(result.issue_urls), ['https://gh/1'])
  const filingPrompt = trace.agents.find((call) => call.opts.label === 'issues:batch-1').prompt
  assert.doesNotMatch(filingPrompt, /imports an ORM directly|from sqlalchemy import Session|introduce a port/)
  const payloadHex = filingPrompt.match(/PAYLOAD_HEX=([0-9a-f]+)$/m)[1]
  const [payload] = JSON.parse(Buffer.from(payloadHex, 'hex').toString('utf8'))
  assert.deepEqual(payload.labels, ['sliced-bread-audit', 'sev:high'])
  assert.equal(payload.location, 'domains/x/a.py:40')
  assert.match(payload.body, /\*\*Impact:\*\* domain behavior now depends on persistence infrastructure/)
})

test('a confirmed finding matching an existing audit issue fingerprint is not re-filed', async () => {
  const { globals, trace } = build({
    slices: [slice('x')],
    existing: ['sba:domains/x/a.py:model-purity:4'],
    on: ({ opts, prompt }) => {
      if (opts.label === 'eval:x') return { slice: 'x', findings: [finding()] }
      if (opts.label.startsWith('cite:')) return citeAll(prompt)
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: {} })

  assert.equal(result.confirmed.length, 1)
  assert.equal(result.issues.length, 0)
  assert.equal(labels(trace).some((l) => l.startsWith('issues:batch')), false)
  assert.match(trace.logs.join('\n'), /already exists/)
})

test('gh setup extracts markers with a jq scan, and code normalizes wrapped markers before the dedupe', async () => {
  const { globals, trace } = build({
    slices: [slice('x')],
    existing: ['  <!-- sba:domains/x/a.py:model-purity:4 -->\n', 'not a marker'],
    on: ({ opts, prompt }) => {
      if (opts.label === 'eval:x') return { slice: 'x', findings: [finding()] }
      if (opts.label.startsWith('cite:')) return citeAll(prompt)
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: {} })

  const setupPrompt = trace.agents.find((a) => a.opts.label === 'map:gh-setup').prompt
  assert.match(setupPrompt, /scan\("<!-- \(sba:\[\^ \]\+\) -->"\)/)
  assert.match(setupPrompt, /Do not read issue bodies or extract markers yourself/)
  assert.equal(result.issues.length, 0)
  assert.equal(labels(trace).some((l) => l.startsWith('issues:batch')), false)
})

test('code accepts a marker that ends with the --!> comment form and still dedupes it', async () => {
  const { globals, trace } = build({
    slices: [slice('x')],
    existing: ['<!-- sba:domains/x/a.py:model-purity:4 --!>', '<!--sba:domains/x/a.py:model-purity:9-->'],
    on: ({ opts, prompt }) => {
      if (opts.label === 'eval:x') return { slice: 'x', findings: [finding()] }
      if (opts.label.startsWith('cite:')) return citeAll(prompt)
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: {} })

  assert.equal(result.issues.length, 0)
  assert.equal(labels(trace).some((l) => l.startsWith('issues:batch')), false)
})

test('max_issues caps how many confirmed findings are filed, and the rest stay in the report', async () => {
  const { globals, trace } = build({
    slices: [slice('x')],
    on: ({ opts, prompt }) => {
      if (opts.label === 'eval:x') {
        return { slice: 'x', findings: [finding({ file: 'domains/x/a.py' }), finding({ file: 'domains/x/b.py' })] }
      }
      if (opts.label.startsWith('cite:')) return citeAll(prompt)
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
    on: ({ opts, prompt }) => {
      if (opts.label === 'eval:x') return { slice: 'x', findings: [finding()] }
      if (opts.label.startsWith('cite:')) return citeAll(prompt)
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { dry_run: true } })

  assert.match(
    trace.agents.find((a) => a.opts.label === 'map:gh-setup').prompt,
    /do NOT create labels, issues, comments, files, or mutate GitHub in any way/
  )
  assert.equal(labels(trace).some((l) => l.startsWith('issues:batch')), false)
  assert.equal(result.issues[0].skipped_reason, 'dry_run')
})
test('paginates setup context and gives only the cross-slice evaluator the full slice index', async () => {
  const { globals, trace } = build({
    slices: [
      slice('x', { key_files: ['domains/x/index.py'] }),
      slice('unrelated-secret-name'),
    ],
    on: ({ opts, prompt }) => {
      if (opts.label.startsWith('eval:')) return { slice: 'ignored', findings: [] }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  await workflow.run({ ...globals, args: { dry_run: true } })

  const setupPrompt = trace.agents.find((call) => call.opts.label === 'map:gh-setup').prompt
  const slicePrompt = trace.agents.find((call) => call.opts.label === 'eval:x').prompt
  const crossPrompt = trace.agents.find((call) => call.opts.label === 'eval:cross-slice').prompt
  assert.match(setupPrompt, /gh api --paginate/)
  assert.match(slicePrompt, /Direct entry-point context: domains\/x\/index\.py/)
  assert.doesNotMatch(slicePrompt, /unrelated-secret-name/)
  assert.match(crossPrompt, /unrelated-secret-name \(domains\/unrelated-secret-name, domain\)/)
})


test('uses the pipeline item as canonical slice identity', async () => {
  const { globals } = build({
    slices: [slice('canonical')],
    on: ({ opts, prompt }) => {
      if (opts.label === 'eval:canonical') return { slice: 'spoofed', findings: [finding()] }
      if (opts.label.startsWith('cite:')) return citeAll(prompt)
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { dry_run: true } })

  assert.equal(result.confirmed[0].slice, 'canonical')
  assert.match(result.issues[0].body, /\*\*Slice:\*\* canonical/)
})

test('verifies duplicate candidates before deduplication', async () => {
  const duplicate = { file: 'domains/x/a.py', line: 40, dimension: 'model-purity' }
  const { globals } = createRuntime({
    respond: ({ opts, prompt }) => {
      if (opts.label === 'map:slices') return { layout: 'flat', slices: [slice('x')] }
      if (opts.label === 'map:gh-setup') return { gh_ok: true, repo: 'o/n', existing_fingerprints: [], error: '' }
      if (opts.label === 'eval:x') return { slice: 'wrong', findings: [finding({ ...duplicate, severity: 'high' })] }
      if (opts.label === 'eval:cross-slice') {
        return { slice: 'wrong', findings: [finding({ ...duplicate, claim: 'valid graph-level duplicate' })] }
      }
      if (opts.label.startsWith('cite:')) return citeAll(prompt)
      if (opts.label.startsWith('refute:')) return verdicts(prompt, { refuted: true, reason: 'slice-local interpretation was invalid' })
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { dry_run: true } })

  assert.deepEqual(
    Array.from(result.confirmed, ({ slice, claim, location }) => ({ slice, claim, location })),
    [{ slice: 'cross-slice', claim: 'valid graph-level duplicate', location: 'domains/x/a.py:40' }],
  )
  assert.match(result.refuted[0], /slice-local interpretation was invalid/)
})

test('retains evaluator, cross-slice, and verification failures with their error details', async () => {
  const { globals } = createRuntime({
    respond: ({ opts, prompt }) => {
      if (opts.label === 'map:slices') return { layout: 'flat', slices: [slice('eval-fails'), slice('cite-fails')] }
      if (opts.label === 'map:gh-setup') return { gh_ok: false, repo: '', existing_fingerprints: [], error: 'auth refused' }
      if (opts.label === 'eval:eval-fails') throw new Error('evaluator exploded')
      if (opts.label === 'eval:cross-slice') throw new Error('graph exploded')
      if (opts.label === 'eval:cite-fails') return { slice: 'ignored', findings: [finding()] }
      if (opts.label.startsWith('cite:')) throw new Error('citation service unavailable')
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: {} })

  assert.deepEqual(Array.from(result.failures, (failure) => ({ ...failure })), [
    { stage: 'evaluate', slice: 'eval-fails', error: 'evaluator exploded' },
    { stage: 'evaluate', slice: 'cross-slice', error: 'graph exploded' },
    { stage: 'verify', slice: 'cite-fails', error: 'citation service unavailable' },
  ])
  assert.equal(result.setup.error, 'auth refused')
  assert.deepEqual(Array.from(result.floor_unverified), [
    '[medium] domains/x/a.py:40 — imports an ORM directly (citation check failed: citation service unavailable)',
  ])
})

test('requires complete GitHub setup context before filing', async () => {
  const { globals, trace } = createRuntime({
    respond: ({ opts, prompt }) => {
      if (opts.label === 'map:slices') return { layout: 'flat', slices: [slice('x')] }
      if (opts.label === 'map:gh-setup') return { gh_ok: true, repo: 'o/n', error: '' }
      if (opts.label === 'eval:x') return { slice: 'x', findings: [finding()] }
      if (opts.label === 'eval:cross-slice') return { slice: 'cross-slice', findings: [] }
      if (opts.label.startsWith('cite:')) return citeAll(prompt)
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: {} })

  assert.match(result.setup.error, /existing_fingerprints.*required/)
  assert.equal(labels(trace).some((label) => label.startsWith('issues:batch')), false)
  assert.equal(result.issues[0].skipped_reason, 'gh unavailable')
})

test('dry-run issue payload is complete and redacts credential-like evidence', async () => {
  const secret = 'ghp_1234567890abcdefghijklmnopqrstuvwxyz'
  const { globals } = build({
    slices: [slice('x')],
    on: ({ opts, prompt }) => {
      if (opts.label === 'eval:x') {
        return {
          slice: 'x',
          findings: [finding({
            dimension: 'security',
            claim: 'hard-coded token',
            evidence: `token = "${secret}"`,
            impact: 'the credential can be used by unauthorized callers',
            recommendation: 'load the token from a secret store',
          })],
        }
      }
      if (opts.label.startsWith('cite:')) return citeAll(prompt)
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { dry_run: true } })
  const proposed = result.issues[0]

  assert.deepEqual(Array.from(proposed.labels), ['sliced-bread-audit', 'sev:medium'])
  assert.equal(proposed.location, 'domains/x/a.py:40')
  assert.equal(proposed.evidence, 'token = "[REDACTED]"')
  assert.equal(proposed.recommendation, 'load the token from a secret store')
  assert.match(proposed.body, /\*\*Impact:\*\* the credential can be used by unauthorized callers/)
  assert.match(proposed.body, /token = "\[REDACTED\]"/)
  assert.doesNotMatch(proposed.body, new RegExp(secret))
  assert.equal(proposed.skipped_reason, 'dry_run')
})

test('reports only fully audited dimensions as clean', async () => {
  const { globals } = build({
    slices: [slice('x')],
    on: ({ opts, prompt }) => {
      if (opts.label === 'eval:x') return { slice: 'x', findings: [finding()] }
      if (opts.label.startsWith('cite:')) return citeAll(prompt)
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { dry_run: true } })

  assert.deepEqual(Array.from(result.clean_dimensions), [
    'import-direction',
    'crust-integrity',
    'growth-justification',
    'event-usage',
    'correctness',
    'security',
    'complexity',
    'deslop',
    'tests',
  ])
})

test('max_issues preserves the exact capped identity and complete proposed issue', async () => {
  const { globals } = build({
    slices: [slice('x')],
    on: ({ opts, prompt }) => {
      if (opts.label === 'eval:x') {
        return {
          slice: 'x',
          findings: [
            finding({ severity: 'high', file: 'domains/x/high.py', line: 11, dimension: 'correctness' }),
            finding({ file: 'domains/x/medium.py', line: 22 }),
          ],
        }
      }
      if (opts.label.startsWith('cite:')) return citeAll(prompt)
      if (opts.label.startsWith('refute:')) return verdicts(prompt, { refuted: false, reason: 'valid' })
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { dry_run: true, max_issues: 1 } })

  assert.deepEqual(Array.from(result.confirmed, (entry) => entry.location), ['domains/x/high.py:11', 'domains/x/medium.py:22'])
  assert.equal(result.issues.length, 1)
  assert.equal(result.issues[0].location, 'domains/x/high.py:11')
  assert.deepEqual(Array.from(result.issues[0].labels), ['sliced-bread-audit', 'sev:high'])
  assert.match(result.issues[0].body, /domains\/x\/high\.py:11/)
})

test('bounds evaluator and refuter dispatch by the requested worker limit', async () => {
  let active = 0
  let peak = 0
  let refuters = 0
  const { globals } = build({
    slices: ['a', 'b', 'c', 'd', 'e'].map((name) => slice(name)),
    on: async ({ opts, prompt }) => {
      if (opts.label.startsWith('eval:')) {
        active++
        peak = Math.max(peak, active)
        await new Promise((resolve) => setTimeout(resolve, 10))
        active--
        return { slice: 'untrusted', findings: [finding({ severity: 'high', file: `${opts.label}.py` })] }
      }
      if (opts.label.startsWith('cite:')) return citeAll(prompt)
      if (opts.label.startsWith('refute:')) {
        refuters++
        active++
        peak = Math.max(peak, active)
        await new Promise((resolve) => setTimeout(resolve, 10))
        active--
        return verdicts(prompt, { refuted: false, reason: 'valid' })
      }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { dry_run: true, workers: 2 } })

  assert.equal(peak, 2)
  // Five high findings need two refuters: one batch of four and one batch of one.
  assert.equal(refuters, 2)
  assert.equal(result.failures.length, 0)
})

test('retains a filing batch exception as an actionable issue outcome', async () => {
  const { globals } = build({
    slices: [slice('x')],
    on: ({ opts, prompt }) => {
      if (opts.label === 'eval:x') return { slice: 'x', findings: [finding()] }
      if (opts.label.startsWith('cite:')) return citeAll(prompt)
      if (opts.label.startsWith('issues:batch')) throw new Error('gh API rate limited')
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: {} })

  assert.equal(result.issues[0].created, false)
  assert.equal(result.issues[0].skipped_reason, 'filing batch failed: gh API rate limited')
  assert.equal(result.issues[0].location, 'domains/x/a.py:40')
})

test('does not count a URL-less filing response as created', async () => {
  const { globals } = build({
    slices: [slice('x')],
    on: ({ opts, prompt }) => {
      if (opts.label === 'eval:x') return { slice: 'x', findings: [finding()] }
      if (opts.label.startsWith('cite:')) return citeAll(prompt)
      if (opts.label.startsWith('issues:batch')) return { results: [{ index: 0, created: true }] }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: {} })

  assert.deepEqual(Array.from(result.issue_urls), [])
  assert.equal(result.issues[0].created, false)
  assert.equal(result.issues[0].skipped_reason, 'filing agent returned created=true without url')
})

test('dedupes confirmed findings by line bucket (floor(line/10)) — same bucket collapses, adjacent bucket does not', async () => {
  const { globals } = build({
    slices: [slice('x')],
    on: ({ opts, prompt }) => {
      if (opts.label === 'eval:x') {
        return {
          slice: 'x',
          findings: [
            finding({ line: 5 }),
            finding({ line: 9 }),
            finding({ line: 10 }),
          ],
        }
      }
      if (opts.label.startsWith('cite:')) return citeAll(prompt)
      if (opts.label.startsWith('issues:batch')) {
        return { results: [{ index: 0, created: true, url: 'https://gh/1' }, { index: 1, created: true, url: 'https://gh/2' }] }
      }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: {} })

  // line 9 shares bucket 0 with line 5 (floor(5/10) === floor(9/10) === 0) and is dropped;
  // line 10 is bucket 1 and survives as its own confirmed finding.
  assert.deepEqual(
    Array.from(result.confirmed, (entry) => entry.location),
    ['domains/x/a.py:5', 'domains/x/a.py:10'],
  )
  assert.equal(result.issues.length, 2)
  assert.deepEqual(Array.from(result.issues, (issue) => issue.location), ['domains/x/a.py:5', 'domains/x/a.py:10'])
})

test('a triple-backtick run in evidence stays inside the issue body code fence', async () => {
  const evidence = 'before\n```js\nsomeCode()\n```\nafter'
  const { globals } = build({
    slices: [slice('x')],
    on: ({ opts, prompt }) => {
      if (opts.label === 'eval:x') return { slice: 'x', findings: [finding({ evidence })] }
      if (opts.label.startsWith('cite:')) return citeAll(prompt)
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { dry_run: true } })
  const body = result.issues[0].body

  const fenceMatch = body.match(/\*\*Evidence:\*\*\n(`+)\n/)
  assert.ok(fenceMatch, 'expected a fence line right after **Evidence:**')
  const fence = fenceMatch[1]
  assert.equal(fence, '````')
  assert.equal(fence.length, 4)

  const longestBacktickRunInEvidence = Math.max(...(evidence.match(/`+/g) || []).map((run) => run.length))
  assert.equal(longestBacktickRunInEvidence, 3)
  assert.ok(fence.length > longestBacktickRunInEvidence)

  assert.equal(body, [
    `**Dimension:** model-purity · **Severity:** medium · **Slice:** x`,
    '',
    '**Location:** `domains/x/a.py:40`',
    '',
    '**Finding:** imports an ORM directly',
    '',
    '**Impact:** domain behavior now depends on persistence infrastructure',
    '',
    '**Evidence:**',
    fence,
    evidence,
    fence,
    '',
    '**Recommendation:** introduce a port',
    '',
    '---',
    '_Filed by the sliced-bread-audit workflow (citation-checked)._',
    '<!-- sba:domains/x/a.py:model-purity:4 -->',
  ].join('\n'))
})


test('dispatches each audit stage on its selected model and effort tier', async () => {
  const { globals, trace } = build({
    slices: [slice('x')],
    on: ({ opts, prompt }) => {
      if (opts.label === 'eval:x') return { slice: 'x', findings: [finding({ severity: 'high' })] }
      if (opts.label.startsWith('cite:')) return citeAll(prompt)
      if (opts.label.startsWith('refute:')) return verdicts(prompt, { refuted: false, reason: 'confirmed' })
      if (opts.label.startsWith('issues:batch')) return { results: [{ index: 0, created: true, url: 'https://gh/1' }] }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })
  await workflow.run({ ...globals, args: {} })
  const byLabel = new Map(trace.agents.map(({ opts, prompt }) => [opts.label, opts]))
  assert.deepEqual([byLabel.get('map:slices').model, byLabel.get('map:slices').effort], ['sonnet', 'medium'])
  assert.deepEqual([byLabel.get('map:gh-setup').model, byLabel.get('map:gh-setup').effort], ['haiku', 'low'])
  assert.deepEqual([byLabel.get('eval:x').model, byLabel.get('eval:x').effort], ['opus', 'high'])
  assert.deepEqual([byLabel.get('cite:batch-1').model, byLabel.get('cite:batch-1').effort], ['sonnet', 'low'])
  assert.equal(byLabel.get('cite:batch-1').agentType, 'explorer')
  assert.equal(byLabel.get('map:slices').agentType, 'explorer')
  const refuter = [...byLabel.entries()].find(([label]) => label.startsWith('refute:'))[1]
  assert.deepEqual([refuter.model, refuter.effort], ['opus', 'high'])
  assert.deepEqual([byLabel.get('issues:batch-1').model, byLabel.get('issues:batch-1').effort], ['haiku', 'low'])
})

test('one refuter runs per distinct finding, across slices, and reused votes carry over', async () => {
  const refuted = []
  const same = finding({ severity: 'high', file: 'domains/x/shared.py', line: 10 })
  // Same line bucket as `same`, but a different claim: it needs its own refuter.
  const other = { ...same, line: 12, claim: 'calls an adapter from the domain' }
  const { globals } = build({
    slices: [slice('a'), slice('b')],
    on: ({ opts, prompt }) => {
      if (opts.label === 'eval:a') return { slice: 'a', findings: [same, { ...same, line: 11 }, other] }
      if (opts.label === 'eval:b') return { slice: 'b', findings: [same] }
      if (opts.label.startsWith('cite:')) return citeAll(prompt)
      if (opts.label.startsWith('refute:')) {
        return verdicts(prompt, (item) => {
          const isOther = item.includes(other.claim)
          refuted.push(isOther ? 'other' : 'same')
          return isOther ? { refuted: false, reason: 'rule applies' } : { refuted: true, reason: 'rule misapplied' }
        })
      }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { dry_run: true } })

  assert.deepEqual(refuted.sort(), ['other', 'same'])
  assert.equal(result.refuted.length, 3)
  assert.equal(result.confirmed.length, 1)
})

test('code caps opus evaluators at 20 slices and refuters at 12 per run', async () => {
  let refuters = 0
  const slices = Array.from({ length: 25 }, (_, i) => slice(`s${i}`))
  const { globals, trace } = build({
    slices,
    on: ({ opts, prompt }) => {
      if (opts.label.startsWith('eval:s')) return { slice: 'x', findings: [finding({ severity: 'high', file: `${opts.label}.py` })] }
      if (opts.label.startsWith('cite:')) return citeAll(prompt)
      if (opts.label.startsWith('refute:')) { refuters++; return verdicts(prompt, { refuted: false, reason: 'valid' }) }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { dry_run: true } })

  assert.equal(labels(trace).filter((l) => /^eval:s\d+$/.test(l)).length, 20)
  assert.equal(result.failures.filter((f) => /over the 20-slice cap/.test(f.error)).length, 5)
  // Twelve refuted findings in batches of four need three refuters; twenty findings need one citation check.
  assert.equal(refuters, 3)
  assert.equal(labels(trace).filter((l) => l.startsWith('cite:')).length, 1)
  assert.equal(result.confirmed.length, 12)
  assert.equal(result.floor_unverified.length, 8)
  assert.match(result.floor_unverified[0], /\(past the 12-finding refuter cap\)$/)
  assert.ok(trace.logs.some((l) => /8 high\+ finding\(s\) past the 12-finding refuter cap/.test(l)))
})

for (const [name, args, pattern] of [
  ['a string dry_run', { dry_run: 'true' }, /dry_run must be true or false/],
  ['a camelCase dryRun key', { dryRun: true }, /unknown args: dryRun/],
  ['a non-string scope', { scope: 7 }, /scope must be a string/],
  ['malformed JSON-string args', '{"dry_run": tru', /args look like JSON but do not parse/],
  ['an array', ['src'], /args must be a scope string or an object/],
]) {
  test(`rejects ${name} with usage text before dispatching any agent`, async () => {
    const { globals, trace } = createRuntime()
    const result = await workflow.run({ ...globals, args })
    assert.match(result.error, pattern)
    assert.match(result.error, /Usage: \/sliced-bread-audit/)
    assert.equal(trace.agents.length, 0)
  })
}

test('JSON-string object args parse into options instead of becoming the scope', async () => {
  const { globals, trace } = build({ slices: [] })
  const result = await workflow.run({ ...globals, args: '{"scope": "src/pkg", "dry_run": true}' })

  assert.match(result.error, /found no slices/)
  const mapPrompt = trace.agents.find((a) => a.opts.label === 'map:slices').prompt
  assert.match(mapPrompt, /under `src\/pkg`/)
  assert.doesNotMatch(mapPrompt, /dry_run/)
})

test('a null gh-setup result is a setup failure, not a crash', async () => {
  const { globals } = createRuntime({
    respond: ({ opts, prompt }) => {
      if (opts.label === 'map:slices') return { layout: 'flat', slices: [slice('x')] }
      if (opts.label === 'map:gh-setup') return null
      if (opts.label.startsWith('eval:')) return { slice: opts.label.slice(5), findings: [] }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: {} })

  assert.equal(result.setup.gh_ok, false)
  assert.match(result.setup.error, /map:gh-setup returned no result/)
})

test('a null evaluator result records an evaluate failure and the run still completes', async () => {
  const { globals } = build({
    slices: [slice('x')],
    on: ({ opts, prompt }) => {
      if (opts.label === 'eval:x') return null
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { dry_run: true } })

  const evaluateFailures = result.failures.filter((f) => f.stage === 'evaluate')
  assert.equal(evaluateFailures.length, 1)
  assert.equal(evaluateFailures[0].slice, 'x')
  assert.equal(evaluateFailures[0].error, 'agent eval:x returned no result')
})

test('a null filing-batch result marks each issue unfiled instead of crashing', async () => {
  const { globals } = build({
    slices: [slice('x')],
    on: ({ opts, prompt }) => {
      if (opts.label === 'eval:x') return { slice: 'x', findings: [finding()] }
      if (opts.label.startsWith('cite:')) return citeAll(prompt)
      if (opts.label.startsWith('issues:batch')) return null
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: {} })

  assert.equal(result.issues.length, 1)
  assert.notEqual(result.issues[0].created, true)
  assert.match(result.issues[0].skipped_reason, /filing batch failed: agent issues:batch-1 returned no result/)
})

test('the refuter sees the rubric and severity guide, and no evaluator prompt asks for shell grep', async () => {
  const { globals, trace } = build({
    slices: [slice('x')],
    on: ({ opts, prompt }) => {
      if (opts.label === 'eval:x') return { slice: 'x', findings: [finding({ severity: 'high' })] }
      if (opts.label.startsWith('cite:')) return citeAll(prompt)
      if (opts.label.startsWith('refute:')) return verdicts(prompt, { refuted: true, reason: 'misapplied' })
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  await workflow.run({ ...globals, args: { dry_run: true } })

  const refuter = trace.agents.find((a) => a.opts.label.startsWith('refute:'))
  assert.ok(refuter, 'a high finding must reach the refuter')
  assert.match(refuter.prompt, /SLICED BREAD ARCHITECTURE RUBRIC/)
  assert.match(refuter.prompt, /Severity: blocker = /)
  const evaluators = trace.agents.filter((a) => a.opts.label.startsWith('eval:'))
  assert.equal(evaluators.length, 2)
  for (const evaluator of evaluators) {
    assert.match(evaluator.prompt, /tilth_search/)
    assert.doesNotMatch(evaluator.prompt, /grep\/read|by grepping/)
  }
})

test('citation checks batch floor findings across slices after the Evaluate barrier', async () => {
  const citeSizes = []
  const { globals, trace } = build({
    slices: [slice('a'), slice('b'), slice('c')],
    on: ({ opts, prompt }) => {
      if (opts.label === 'eval:a') {
        return { slice: 'a', findings: Array.from({ length: 19 }, (_, i) => finding({ file: `domains/a/f${i}.py` })) }
      }
      if (opts.label.startsWith('eval:')) return { slice: 'x', findings: [finding({ file: `${opts.label}.py` })] }
      if (opts.label.startsWith('cite:')) { citeSizes.push(batchItems(prompt).length); return citeAll(prompt) }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { dry_run: true } })

  assert.deepEqual(labels(trace).filter((l) => l.startsWith('cite:')), ['cite:batch-1', 'cite:batch-2'])
  assert.deepEqual(citeSizes, [20, 1])
  assert.equal(result.confirmed.length, 21)
})

test('the refuter cap keeps the highest-severity findings, not the earliest slices', async () => {
  const refuted = []
  const slices = Array.from({ length: 14 }, (_, i) => slice(`s${i}`))
  const { globals } = build({
    slices,
    on: ({ opts, prompt }) => {
      if (opts.label === 'eval:s13') return { slice: 's13', findings: [finding({ severity: 'blocker', file: 'domains/s13/late.py' })] }
      if (opts.label.startsWith('eval:s')) return { slice: 'x', findings: [finding({ severity: 'high', file: `${opts.label}.py` })] }
      if (opts.label.startsWith('cite:')) return citeAll(prompt)
      if (opts.label.startsWith('refute:')) {
        return verdicts(prompt, (item) => { refuted.push(item.split('\n')[0]); return { refuted: false, reason: 'valid' } })
      }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { dry_run: true } })

  assert.equal(refuted.length, 12)
  assert.ok(refuted.some((line) => line.includes('domains/s13/late.py')), 'the blocker must reach a refuter')
  assert.equal(result.confirmed[0].location, 'domains/s13/late.py:40')
  assert.equal(result.confirmed[0].verification, 'citation-checked + refuter-tested')
  // Thirteen highs plus one blocker: the blocker and eleven highs fill the 12-finding cap.
  assert.equal(result.floor_unverified.length, 2)
  for (const entry of result.floor_unverified) assert.match(entry, /^\[high\].*\(past the 12-finding refuter cap\)$/)
})

test('the citation schema requires a reason, so a cite result without one fails schema validation', async () => {
  const { globals, trace } = build({
    slices: [slice('x')],
    on: ({ opts }) => {
      if (opts.label === 'eval:x') return { slice: 'x', findings: [finding()] }
      if (opts.label.startsWith('cite:')) return { results: [{ index: 0, ok: true }] }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })
  const result = await workflow.run({ ...globals, args: { dry_run: true } })
  const cite = trace.agents.find((a) => a.opts.label.startsWith('cite:'))
  assert.deepEqual([...cite.opts.schema.properties.results.items.required], ['index', 'ok', 'reason'])
  assert.equal(result.confirmed.length, 0)
  assert.match(result.floor_unverified[0], /citation check failed/)
})

test('code rejects a finding with empty evidence or a line below 1 before citation', async () => {
  const { globals, trace } = build({
    slices: [slice('x')],
    on: ({ opts, prompt }) => {
      if (opts.label === 'eval:x') {
        return {
          slice: 'x',
          findings: [
            finding({ file: 'domains/x/empty.py', evidence: '   ' }),
            finding({ file: 'domains/x/zero.py', line: 0 }),
            finding({ file: 'domains/x/good.py' }),
          ],
        }
      }
      if (opts.label.startsWith('cite:')) return citeAll(prompt)
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })
  const result = await workflow.run({ ...globals, args: { dry_run: true } })
  const citePrompt = trace.agents.find((a) => a.opts.label.startsWith('cite:')).prompt
  assert.doesNotMatch(citePrompt, /empty\.py|zero\.py/)
  assert.deepEqual([...result.confirmed.map((f) => f.location)], ['domains/x/good.py:40'])
  assert.equal(result.refuted.length, 2)
  assert.match(result.refuted.find((r) => r.includes('empty.py')), /\(invalid: evidence is empty\)$/)
  assert.match(result.refuted.find((r) => r.includes('zero.py')), /\(invalid: line 0 is not a positive integer\)$/)
})

test('duplicate slice paths get one evaluator', async () => {
  const { globals, trace } = build({
    slices: [slice('x'), slice('x-again', { path: './domains/x/' }), slice('y')],
    on: ({ opts }) => {
      if (opts.label.startsWith('eval:')) return { slice: opts.label.slice(5), findings: [] }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })
  await workflow.run({ ...globals, args: { dry_run: true } })
  assert.deepEqual(labels(trace).filter((l) => l.startsWith('eval:')).sort(), ['eval:cross-slice', 'eval:x', 'eval:y'])
  assert.ok(trace.logs.some((l) => /Removed 1 duplicate slice path/.test(l)))
})

test('no evaluator starts when the remaining budget is below the minimum for one Opus agent', async () => {
  const { globals, trace } = createRuntime({
    budgetTotal: 1000000,
    budgetSpent: 1000000 - 20000,
    respond: ({ opts }) => {
      if (opts.label === 'map:slices') return { layout: 'flat', slices: [slice('x')] }
      if (opts.label === 'map:gh-setup') return { gh_ok: true, repo: 'o/n', existing_fingerprints: [], error: '' }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })
  const result = await workflow.run({ ...globals, args: { dry_run: true } })
  assert.equal(labels(trace).some((l) => l.startsWith('eval:')), false)
  assert.match(result.truncated, /budget exhausted before Evaluate/)
})

test('a dry run returns resume.file_findings, and a resume files them without a new audit', async () => {
  const dry = build({
    slices: [slice('x')],
    on: ({ opts, prompt }) => {
      if (opts.label === 'eval:x') return { slice: 'x', findings: [finding()] }
      if (opts.label.startsWith('cite:')) return citeAll(prompt)
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })
  const preview = await workflow.run({ ...dry.globals, args: { dry_run: true } })
  assert.equal(preview.resume.file_findings.length, 1)
  assert.equal(preview.resume.file_findings[0].evidence, finding().evidence)
  assert.equal(preview.resume.file_findings[0].recommendation, finding().recommendation)

  const live = build({
    on: ({ opts }) => {
      if (opts.label === 'issues:batch-1') return { results: [{ index: 0, created: true, url: 'https://gh/1' }] }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })
  const result = await workflow.run({ ...live.globals, args: JSON.parse(JSON.stringify(preview.resume)) })

  assert.deepEqual(labels(live.trace), ['map:gh-setup', 'issues:batch-1'])
  assert.deepEqual([...result.issue_urls], ['https://gh/1'])
  assert.equal(result.confirmed[0].location, 'domains/x/a.py:40')
  assert.equal(result.clean_dimensions.length, 0)
  assert.equal(result.resume, undefined)
})

test('a resume skips findings that already have an audit issue', async () => {
  const dry = build({
    slices: [slice('x')],
    on: ({ opts, prompt }) => {
      if (opts.label === 'eval:x') return { slice: 'x', findings: [finding()] }
      if (opts.label.startsWith('cite:')) return citeAll(prompt)
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })
  const preview = await workflow.run({ ...dry.globals, args: { dry_run: true } })
  const marker = preview.issues[0].body.match(/<!-- (sba:\S+) -->/)[1]
  const again = build({ existing: [marker], on: ({ opts }) => { throw new Error(`unexpected agent ${opts.label}`) } })

  const result = await workflow.run({ ...again.globals, args: preview.resume })

  assert.deepEqual(labels(again.trace), ['map:gh-setup'])
  assert.equal(result.issues.length, 0)
})

for (const [name, file_findings] of [
  ['not an array', 'x'],
  ['an empty array', []],
  ['an unknown dimension', [finding({ slice: 'x', dimension: 'vibes' })]],
  ['an unknown severity', [finding({ slice: 'x', severity: 'critical' })]],
  ['line 0', [finding({ slice: 'x', line: 0 })]],
  ['empty evidence', [finding({ slice: 'x', evidence: ' ' })]],
  ['a missing claim', [finding({ slice: 'x', claim: undefined })]],
]) {
  test(`rejects file_findings with ${name} before dispatching any agent`, async () => {
    const { globals, trace } = createRuntime()
    const result = await workflow.run({ ...globals, args: { file_findings } })
    assert.match(result.error, /^file_findings/)
    assert.equal(trace.agents.length, 0)
  })
}
