import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow } from './harness.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/wiki-drift-audit.js')

const mapPages = (...paths) => ({ pages: paths.map((p) => ({ path: p, title: p })) })
const claim = (text, verdict, extra = {}) => ({ claim: text, verdict, evidence: 'evidence', ...extra })
const report = { drift_table: [], rewrites: [], summary: 'done', report_path: '' }

test('wiki-drift-audit associates a reverified claim by verbatim text match', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'map') return mapPages('a.md')
      if (opts.label === 'falsify:a.md') return { page: 'a.md', claims: [claim('claim one', 'stale')] }
      if (opts.label === 'verify:a.md') return { page: 'a.md', claims: [claim('claim one', 'current')] }
      if (opts.label === 'report') return report
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: {} })

  assert.equal(result.pages_audited, 1)
  assert.deepEqual(trace.agents.map(({ opts }) => opts.label), ['map', 'falsify:a.md', 'verify:a.md', 'report'])
})

test('wiki-drift-audit falls back to positional alignment when claim text is not unique', async () => {
  const workflow = await loadWorkflow(path)
  let reportPrompt = ''
  const { globals } = createRuntime({
    respond: ({ prompt, opts }) => {
      if (opts.label === 'map') return mapPages('a.md')
      if (opts.label === 'falsify:a.md') {
        return { page: 'a.md', claims: [claim('dup', 'stale'), claim('dup', 'contradicted')] }
      }
      if (opts.label === 'verify:a.md') {
        return { page: 'a.md', claims: [claim('dup', 'current'), claim('dup', 'stale')] }
      }
      if (opts.label === 'report') { reportPrompt = prompt; return report }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  await workflow.run({ ...globals, args: {} })

  // Positional alignment: first flagged position gets verify.claims[0] (current),
  // second gets verify.claims[1] (stale) — not a text-keyed lookup, which would
  // collide on the duplicate "dup" text.
  assert.match(reportPrompt, /"verdict": "current"/)
  assert.match(reportPrompt, /"verdict": "stale"/)
})

test('wiki-drift-audit partial-match fallback marks an unmatched flagged claim unverified, not confirmed drift', async () => {
  const workflow = await loadWorkflow(path)
  let reportPrompt = ''
  const { globals } = createRuntime({
    respond: ({ prompt, opts }) => {
      if (opts.label === 'map') return mapPages('a.md')
      if (opts.label === 'falsify:a.md') {
        return { page: 'a.md', claims: [claim('claim A', 'stale'), claim('claim A', 'contradicted'), claim('claim B', 'stale')] }
      }
      if (opts.label === 'verify:a.md') {
        // Duplicate 'claim A' text disables text-match-covers-all; 1 returned
        // claim vs 3 flagged positions disables positional alignment -> falls to
        // the partial-match branch. Only 'claim B' is present in the returned
        // set, so both 'claim A' positions are left genuinely unmatched.
        return { page: 'a.md', claims: [claim('claim B', 'current')] }
      }
      if (opts.label === 'report') { reportPrompt = prompt; return report }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  await workflow.run({ ...globals, args: {} })

  const parsed = JSON.parse(reportPrompt.match(/Per-page claims \(JSON\):\n([\s\S]*?)\n\nRules:/)[1])
  const claims = parsed[0].claims

  // Unmatched 'claim A' positions keep their first-pass verdict but are marked
  // unverified — the Verify pass never confirmed the drift, so it must not
  // read as confirmed.
  assert.equal(claims[0].verdict, 'stale')
  assert.equal(claims[0].unverified, true)
  assert.equal(claims[1].verdict, 'contradicted')
  assert.equal(claims[1].unverified, true)
  // 'claim B' matched and is confirmed current, not left flagged as drift.
  assert.equal(claims[2].verdict, 'current')
  assert.equal(claims[2].unverified, undefined)
})

test('wiki-drift-audit marks a claim unverified, not confirmed drift, when Verify returns nothing for the page', async () => {
  const workflow = await loadWorkflow(path)
  let reportPrompt = ''
  const { globals, trace } = createRuntime({
    respond: ({ prompt, opts }) => {
      if (opts.label === 'map') return mapPages('a.md')
      if (opts.label === 'falsify:a.md') return { page: 'a.md', claims: [claim('claim one', 'stale')] }
      if (opts.label === 'verify:a.md') throw new Error('verify agent crashed')
      if (opts.label === 'report') { reportPrompt = prompt; return report }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  await workflow.run({ ...globals, args: {} })

  const parsed = JSON.parse(reportPrompt.match(/Per-page claims \(JSON\):\n([\s\S]*?)\n\nRules:/)[1])
  assert.equal(parsed[0].claims[0].verdict, 'stale')
  assert.equal(parsed[0].claims[0].unverified, true)
  assert.match(trace.logs.join('\n'), /Verify pass returned nothing for page a\.md/)
})

test('wiki-drift-audit drops a reverified claim from drift once its verdict returns to current', async () => {
  const workflow = await loadWorkflow(path)
  let reportPrompt = ''
  const { globals } = createRuntime({
    respond: ({ prompt, opts }) => {
      if (opts.label === 'map') return mapPages('a.md')
      if (opts.label === 'falsify:a.md') return { page: 'a.md', claims: [claim('claim one', 'contradicted')] }
      if (opts.label === 'verify:a.md') return { page: 'a.md', claims: [claim('claim one', 'current')] }
      if (opts.label === 'report') { reportPrompt = prompt; return report }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  await workflow.run({ ...globals, args: {} })

  const parsed = JSON.parse(reportPrompt.match(/Per-page claims \(JSON\):\n([\s\S]*?)\n\nRules:/)[1])
  assert.equal(parsed[0].claims[0].verdict, 'current')
  assert.equal(parsed[0].claims[0].unverified, undefined)
})

test('wiki-drift-audit clamps a maxPages above MAX_PAGES and logs it', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'map') return { pages: [] }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  await workflow.run({ ...globals, args: { maxPages: 5000 } })

  assert.match(trace.logs.join('\n'), /maxPages=200/)
  assert.match(trace.logs.join('\n'), /maxPages 5000 exceeds max 200 — clamping to 200/)
})

test('wiki-drift-audit falls back repoRoot to "." and logs it when it contains a shell metacharacter', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'map') return { pages: [] }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { repoRoot: '/tmp/foo; rm -rf /' } })

  assert.equal(result.repo_root, undefined)
  assert.match(trace.agents[0].prompt, /Repo root: \.\n/)
  assert.match(trace.logs.join('\n'), /repoRoot "\/tmp\/foo; rm -rf \/" contains unsafe characters — falling back to "\."/)
})
