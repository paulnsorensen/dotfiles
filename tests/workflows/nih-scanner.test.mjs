import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow } from './harness.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/nih-scanner.js')

const detected = (overrides = {}) => ({
  languages: ['typescript'],
  depManifest: ['lodash'],
  fileCount: 10,
  scope: '.',
  ...overrides,
})

const candidate = (overrides = {}) => ({
  id: 1,
  filePath: 'src/utils/uuid.ts',
  lineRange: [12, 28],
  category: 'UUID',
  pattern: 'Hand-rolled UUID v4',
  snippet: 'export function generateUUID() {...}',
  usageCount: 3,
  functionName: 'generateUUID',
  linesOfCode: 16,
  ...overrides,
})

const refuteVerdict = (overrides = {}) => ({ refuted: true, reasoning: 'stdlib usage', ...overrides })
const confirmVerdict = (overrides = {}) => ({
  refuted: false,
  reasoning: 'hand-rolled UUID generator duplicates crypto.randomUUID',
  library: 'crypto.randomUUID',
  effort: 'S',
  citation: 'src/utils/uuid.ts:12',
  ...overrides,
})

function baseRespond(overrides) {
  return ({ opts, prompt }) => {
    if (overrides[opts.label]) return overrides[opts.label]({ opts: { ...opts, prompt } })
    if (opts.label === 'detect') return detected()
    if (opts.label && opts.label.startsWith('scan:')) return { scanMeta: { languages: ['typescript'], filesScanned: 10, serenaAvailable: true, scope: '.' }, candidates: [] }
    if (opts.label && opts.label.startsWith('verify:')) return refuteVerdict()
    if (opts.label === 'rank') return { findings: [], summary: 'nothing found' }
    throw new Error(`unexpected agent ${opts.label}`)
  }
}

test('nih-scanner coerces a bare string arg into scope', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: baseRespond({}) })

  await workflow.run({ ...globals, args: 'src/pkg' })

  assert.match(trace.agents[0].prompt, /scope `src\/pkg`/)
})

test('nih-scanner falls back to "." scope when given unsafe shell characters and logs it', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: baseRespond({}) })

  await workflow.run({ ...globals, args: { scope: 'src; rm -rf /' } })

  assert.match(trace.agents[0].prompt, /scope `\.`/)
  assert.match(trace.logs.join('\n'), /unsafe characters/)
})

test('nih-scanner clamps maxCandidates, workers, and minUsage and logs each clamp', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: baseRespond({
      detect: () => detected({ fileCount: 0 }),
    }),
  })

  await workflow.run({ ...globals, args: { scope: '.', maxCandidates: 500, workers: 99, minUsage: -3 } })

  const logs = trace.logs.join('\n')
  assert.match(logs, /maxCandidates 500 exceeds maximum 100; clamping to 100/)
  assert.match(logs, /workers 99 exceeds maximum 16; clamping to 16/)
  // minUsage is not an integer >= 0 here (it's negative, but still an
  // integer) so it clamps to its floor of 0.
  assert.match(logs, /minUsage -3 below minimum 0; clamping to 0/)
})

test('nih-scanner short-circuits on fileCount 0 with no Scan/Verify/Rank dispatch', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: baseRespond({ detect: () => detected({ fileCount: 0 }) }),
  })

  const result = await workflow.run({ ...globals, args: '.' })

  assert.deepEqual({ ...result, candidates: Array.from(result.candidates), confirmed: Array.from(result.confirmed) }, { scanMeta: null, candidates: [], confirmed: [], report: null })
  assert.deepEqual(trace.agents.map(({ opts }) => opts.label), ['detect'])
  assert.match(trace.logs.join('\n'), /nothing to scan/)
})

test('nih-scanner short-circuits when Detect returns null', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: baseRespond({ detect: () => null }),
  })

  const result = await workflow.run({ ...globals, args: '.' })

  assert.deepEqual({ ...result, candidates: Array.from(result.candidates), confirmed: Array.from(result.confirmed) }, { scanMeta: null, candidates: [], confirmed: [], report: null })
  assert.deepEqual(trace.agents.map(({ opts }) => opts.label), ['detect'])
})

test('nih-scanner dedupes overlapping candidates by filePath:lineRange[0]:functionName', async () => {
  const workflow = await loadWorkflow(path)
  const dupe = candidate()
  const { globals, trace } = createRuntime({
    respond: baseRespond({
      'scan:.': () => ({
        scanMeta: { languages: ['typescript'], filesScanned: 10, serenaAvailable: true, scope: '.' },
        candidates: [dupe, { ...dupe, id: 2, snippet: 'different snippet, same location' }],
      }),
      'verify:generateUUID': () => confirmVerdict(),
    }),
  })

  const result = await workflow.run({ ...globals, args: '.' })

  assert.equal(result.candidates.length, 1)
  assert.match(trace.logs.join('\n'), /Deduped 1 overlapping candidate/)
})

test('nih-scanner caps at maxCandidates and logs the drop', async () => {
  const workflow = await loadWorkflow(path)
  const many = Array.from({ length: 3 }, (_, i) => candidate({ id: i + 1, filePath: `src/f${i}.ts`, functionName: `fn${i}` }))
  const { globals, trace } = createRuntime({
    respond: baseRespond({
      'scan:.': () => ({
        scanMeta: { languages: ['typescript'], filesScanned: 10, serenaAvailable: true, scope: '.' },
        candidates: many,
      }),
      'verify:fn0': () => confirmVerdict(),
    }),
  })

  const result = await workflow.run({ ...globals, args: { scope: '.', maxCandidates: 1 } })

  assert.equal(result.candidates.length, 1)
  assert.match(trace.logs.join('\n'), /2 candidate\(s\) dropped by the maxCandidates cap \(1\)/)
})

test('nih-scanner drops refuted candidates from confirmed and from the report data', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: baseRespond({
      'scan:.': () => ({
        scanMeta: { languages: ['typescript'], filesScanned: 10, serenaAvailable: true, scope: '.' },
        candidates: [candidate()],
      }),
      'verify:generateUUID': () => refuteVerdict({ reasoning: 'this is crypto.randomUUID usage, not NIH' }),
    }),
  })

  const result = await workflow.run({ ...globals, args: '.' })

  assert.equal(result.confirmed.length, 0)
  assert.equal(result.candidates.length, 1)
  assert.equal(result.candidates[0].refuted, true)
  const rankPrompt = trace.agents.find(({ opts }) => opts.label === 'rank').prompt
  assert.match(rankPrompt, /"candidates":\s*\[\]|DATA \(JSON\):\n\[\]/)
})

test('a crashed verify keeps the candidate flagged low-confidence and never confirms it', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: baseRespond({
      'scan:.': () => ({
        scanMeta: { languages: ['typescript'], filesScanned: 10, serenaAvailable: true, scope: '.' },
        candidates: [candidate()],
      }),
      'verify:generateUUID': () => { throw new Error('verify agent crashed') },
    }),
  })

  const result = await workflow.run({ ...globals, args: '.' })

  assert.equal(result.confirmed.length, 0)
  assert.equal(result.candidates.length, 1)
  assert.equal(result.candidates[0].verifyFailed, true)
  assert.equal(result.candidates[0].confidence, 'low')
  assert.match(trace.logs.join('\n'), /Verify crashed for generateUUID/)
})

test('the report is built only from confirmed findings', async () => {
  const workflow = await loadWorkflow(path)
  const confirmedCandidate = candidate()
  const refutedCandidate = candidate({ id: 2, filePath: 'src/other.ts', functionName: 'otherFn' })
  const { globals, trace } = createRuntime({
    respond: baseRespond({
      'scan:.': () => ({
        scanMeta: { languages: ['typescript'], filesScanned: 10, serenaAvailable: true, scope: '.' },
        candidates: [confirmedCandidate, refutedCandidate],
      }),
      'verify:generateUUID': () => confirmVerdict(),
      'verify:otherFn': () => refuteVerdict(),
      rank: ({ opts }) => {
        assert.doesNotMatch(opts.prompt, /otherFn/)
        return { findings: [{ category: 'UUID', location: 'src/utils/uuid.ts:12', functionName: 'generateUUID', usageCount: 3, library: 'crypto.randomUUID', effort: 'S', confidence: 'high', recommendation: 'replace with crypto.randomUUID' }], summary: '1 finding' }
      },
    }),
  })

  const result = await workflow.run({ ...globals, args: '.' })

  assert.equal(result.confirmed.length, 1)
  assert.equal(result.confirmed[0].functionName, 'generateUUID')
  assert.equal(result.report.findings.length, 1)
  const rankPrompt = trace.agents.find(({ opts }) => opts.label === 'rank').prompt
  assert.doesNotMatch(rankPrompt, /otherFn/)
})

test('a non-refuted verify without a named library is not confirmed (needs-human, low confidence)', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: baseRespond({
      'scan:.': () => ({
        scanMeta: { languages: ['typescript'], filesScanned: 10, serenaAvailable: true, scope: '.' },
        candidates: [candidate()],
      }),
      'verify:generateUUID': () => ({ refuted: false, reasoning: 'plausible but no concrete library named', effort: 'S' }),
    }),
  })

  const result = await workflow.run({ ...globals, args: '.' })

  assert.equal(result.confirmed.length, 0)
  assert.equal(result.candidates[0].verifyFailed, true)
  assert.equal(result.candidates[0].confidence, 'low')
  assert.match(result.candidates[0].note, /without naming a replacement library/)
})

test('a non-refuted verify with a whitespace-only library is not confirmed', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: baseRespond({
      'scan:.': () => ({
        scanMeta: { languages: ['typescript'], filesScanned: 10, serenaAvailable: true, scope: '.' },
        candidates: [candidate()],
      }),
      'verify:generateUUID': () => confirmVerdict({ library: '   ' }),
    }),
  })

  const result = await workflow.run({ ...globals, args: '.' })

  assert.equal(result.confirmed.length, 0)
  assert.equal(result.candidates[0].verifyFailed, true)
  assert.equal(result.candidates[0].confidence, 'low')
})

test('scanMeta flags underScanned when aggregated filesScanned is less than detected fileCount', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: baseRespond({
      detect: () => detected({ fileCount: 50 }),
      'scan:.': () => ({
        scanMeta: { languages: ['typescript'], filesScanned: 12, serenaAvailable: true, scope: '.' },
        candidates: [],
      }),
    }),
  })

  const result = await workflow.run({ ...globals, args: '.' })

  assert.equal(result.scanMeta.underScanned, true)
  assert.equal(result.scanMeta.filesScanned, 12)
  assert.match(trace.logs.join('\n'), /Under-scanned: scanned 12 of 50/)
})

test('scanMeta does not flag underScanned when filesScanned covers detected fileCount', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: baseRespond({}) })

  const result = await workflow.run({ ...globals, args: '.' })

  assert.equal(result.scanMeta.underScanned, false)
  assert.doesNotMatch(trace.logs.join('\n'), /Under-scanned/)
})

test('a crashed Rank agent returns report:null while keeping candidates and confirmed', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: baseRespond({
      'scan:.': () => ({
        scanMeta: { languages: ['typescript'], filesScanned: 10, serenaAvailable: true, scope: '.' },
        candidates: [candidate()],
      }),
      'verify:generateUUID': () => confirmVerdict(),
      rank: () => { throw new Error('rank agent crashed') },
    }),
  })

  const result = await workflow.run({ ...globals, args: '.' })

  assert.equal(result.report, null)
  assert.equal(result.confirmed.length, 1)
  assert.equal(result.candidates.length, 1)
  assert.match(trace.logs.join('\n'), /Rank agent crashed/)
})

test('budget exhaustion before Verify skips Verify/Rank and returns the capped candidates unverified', async () => {
  const workflow = await loadWorkflow(path)
  let spent = 0
  const budget = { total: 10, spent: () => spent, remaining: () => Math.max(0, 10 - spent) }
  const { globals, trace } = createRuntime({
    respond: baseRespond({
      'scan:.': () => {
        spent = 10
        return { scanMeta: { languages: ['typescript'], filesScanned: 10, serenaAvailable: true, scope: '.' }, candidates: [candidate()] }
      },
    }),
  })

  const result = await workflow.run({ ...globals, args: '.', budget })

  assert.equal(result.confirmed.length, 0)
  assert.equal(result.candidates.length, 1)
  assert.equal(result.report, null)
  assert.deepEqual(trace.agents.map(({ opts }) => opts.label), ['detect', 'scan:.'])
  assert.match(trace.logs.join('\n'), /skipping Verify\/Rank/)
})

test('budget exhaustion before Rank skips Rank and returns confirmed candidates without a report', async () => {
  const workflow = await loadWorkflow(path)
  let spent = 0
  const budget = { total: 10, spent: () => spent, remaining: () => Math.max(0, 10 - spent) }
  const { globals, trace } = createRuntime({
    respond: baseRespond({
      'scan:.': () => ({
        scanMeta: { languages: ['typescript'], filesScanned: 10, serenaAvailable: true, scope: '.' },
        candidates: [candidate()],
      }),
      'verify:generateUUID': () => {
        spent = 10
        return confirmVerdict()
      },
    }),
  })

  const result = await workflow.run({ ...globals, args: '.', budget })

  assert.equal(result.confirmed.length, 1)
  assert.equal(result.report, null)
  assert.deepEqual(trace.agents.map(({ opts }) => opts.label), ['detect', 'scan:.', 'verify:generateUUID'])
  assert.match(trace.logs.join('\n'), /skipping Rank/)
})

test('verifyPrompt uses disjoint effort buckets S=1-3, M=4-9, L=10+', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: baseRespond({
      'scan:.': () => ({
        scanMeta: { languages: ['typescript'], filesScanned: 10, serenaAvailable: true, scope: '.' },
        candidates: [candidate()],
      }),
      'verify:generateUUID': () => confirmVerdict(),
    }),
  })

  await workflow.run({ ...globals, args: '.' })

  const verifyPrompt = trace.agents.find(({ opts }) => opts.label === 'verify:generateUUID').prompt
  assert.match(verifyPrompt, /S = 1-3 callers, M = 4-9, L = 10\+/)
})
