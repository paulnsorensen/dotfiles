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
const citeOk = (n) => ({ results: Array.from({ length: n }, (_, i) => ({ index: i, ok: true })) })

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
  assert.deepEqual(Array.from(result.refuter_outcomes, (outcome) => ({ ...outcome })), [{
    location: 'domains/x/a.py:40',
    outcome: 'refuted',
    reason: 'rule misapplied',
  }])
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
    on: ({ opts }) => {
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
    on: ({ opts }) => {
      if (opts.label === 'eval:canonical') return { slice: 'spoofed', findings: [finding()] }
      if (opts.label === 'cite:canonical') return citeOk(1)
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
    respond: ({ opts }) => {
      if (opts.label === 'map:slices') return { layout: 'flat', slices: [slice('x')] }
      if (opts.label === 'map:gh-setup') return { gh_ok: true, repo: 'o/n', existing_fingerprints: [], error: '' }
      if (opts.label === 'eval:x') return { slice: 'wrong', findings: [finding({ ...duplicate, severity: 'high' })] }
      if (opts.label === 'eval:cross-slice') {
        return { slice: 'wrong', findings: [finding({ ...duplicate, claim: 'valid graph-level duplicate' })] }
      }
      if (opts.label === 'cite:x' || opts.label === 'cite:cross-slice') return citeOk(1)
      if (opts.label.startsWith('refute:')) return { refuted: true, reasoning: 'slice-local interpretation was invalid' }
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
    respond: ({ opts }) => {
      if (opts.label === 'map:slices') return { layout: 'flat', slices: [slice('eval-fails'), slice('cite-fails')] }
      if (opts.label === 'map:gh-setup') return { gh_ok: false, repo: '', existing_fingerprints: [], error: 'auth refused' }
      if (opts.label === 'eval:eval-fails') throw new Error('evaluator exploded')
      if (opts.label === 'eval:cross-slice') throw new Error('graph exploded')
      if (opts.label === 'eval:cite-fails') return { slice: 'ignored', findings: [finding()] }
      if (opts.label === 'cite:cite-fails') throw new Error('citation service unavailable')
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
  assert.deepEqual(Array.from(result.floor_unverified), ['[medium] domains/x/a.py:40 — imports an ORM directly'])
})

test('requires complete GitHub setup context before filing', async () => {
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'map:slices') return { layout: 'flat', slices: [slice('x')] }
      if (opts.label === 'map:gh-setup') return { gh_ok: true, repo: 'o/n', error: '' }
      if (opts.label === 'eval:x') return { slice: 'x', findings: [finding()] }
      if (opts.label === 'eval:cross-slice') return { slice: 'cross-slice', findings: [] }
      if (opts.label === 'cite:x') return citeOk(1)
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
    on: ({ opts }) => {
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
      if (opts.label === 'cite:x') return citeOk(1)
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
    on: ({ opts }) => {
      if (opts.label === 'eval:x') return { slice: 'x', findings: [finding()] }
      if (opts.label === 'cite:x') return citeOk(1)
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
    on: ({ opts }) => {
      if (opts.label === 'eval:x') {
        return {
          slice: 'x',
          findings: [
            finding({ severity: 'high', file: 'domains/x/high.py', line: 11, dimension: 'correctness' }),
            finding({ file: 'domains/x/medium.py', line: 22 }),
          ],
        }
      }
      if (opts.label === 'cite:x') return citeOk(2)
      if (opts.label.startsWith('refute:')) return { refuted: false, reasoning: 'valid' }
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
    slices: [slice('a'), slice('b'), slice('c')],
    on: async ({ opts }) => {
      if (opts.label.startsWith('eval:')) {
        active++
        peak = Math.max(peak, active)
        await new Promise((resolve) => setTimeout(resolve, 10))
        active--
        return { slice: 'untrusted', findings: [finding({ severity: 'high', file: `${opts.label}.py` })] }
      }
      if (opts.label.startsWith('cite:')) return citeOk(1)
      if (opts.label.startsWith('refute:')) {
        refuters++
        active++
        peak = Math.max(peak, active)
        await new Promise((resolve) => setTimeout(resolve, 10))
        active--
        return { refuted: false, reasoning: 'valid' }
      }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { dry_run: true, workers: 2 } })

  assert.equal(peak, 2)
  assert.equal(refuters, 3)
  assert.equal(result.failures.length, 0)
})

test('retains a filing batch exception as an actionable issue outcome', async () => {
  const { globals } = build({
    slices: [slice('x')],
    on: ({ opts }) => {
      if (opts.label === 'eval:x') return { slice: 'x', findings: [finding()] }
      if (opts.label === 'cite:x') return citeOk(1)
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
    on: ({ opts }) => {
      if (opts.label === 'eval:x') return { slice: 'x', findings: [finding()] }
      if (opts.label === 'cite:x') return citeOk(1)
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
    on: ({ opts }) => {
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
      if (opts.label.startsWith('cite:')) return citeOk(3)
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
    on: ({ opts }) => {
      if (opts.label === 'eval:x') return { slice: 'x', findings: [finding({ evidence })] }
      if (opts.label.startsWith('cite:')) return citeOk(1)
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
