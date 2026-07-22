import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow } from './harness.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/cheese-factory.js')

// ---- fixture builders (match each phase agent's response schema) ----

function resolveCandidates(candidates = ['spec-a', 'spec-b']) {
  return { mode: 'candidates', candidates }
}

function resolveMissing(usage = 'Usage: /cheese-factory { spec: <slug-or-path> } — spec not found at /nowhere.md') {
  return { mode: 'missing', usage }
}

function resolveResolved({ spec_path = '/specs/parent.md', spec_text = 'spec body', slug = 'parent', candidate_curds = 1, blast_radius = 'medium' } = {}) {
  return { mode: 'resolved', spec_path, spec_text, curd_count: { slug, candidate_curds, blast_radius } }
}

function decompose(curds) {
  return { curds }
}

function miniSpecs(entries) {
  return { curds: entries }
}

function cook(slug, { status = 'ok', worktree_path = `/tmp/worktrees/${slug}` } = {}) {
  return { status, worktree_path, artifact: `.cheese/cook/${slug}.md`, orientation: 'implemented' }
}

function taste(verdict, { issues = verdict === 'revise' ? ['fix this'] : [] } = {}) {
  return { verdict, lenses: [{ lens: 'drift', verdict, note: '' }], issues, recommendation: verdict }
}

function correction(committed = true) {
  return { status: 'fixed', summary: 'fixed', committed }
}

function phaseOk(slug, phase) {
  return { status: 'ok', artifact: `.cheese/${phase}/${slug}.md`, orientation: `${phase} done` }
}

function plate(results) {
  return { results }
}

function integrateResult({ worktree_path = '/tmp/worktrees/integration', merged = [], conflicted = [], files_changed = 5, lines_changed = 50 } = {}) {
  return { worktree_path, merged, conflicted, files_changed, lines_changed }
}

function ageBarrierResult({ hasMediumPlus = false, perCurd = [], artifact = '.cheese/age/barrier.md' } = {}) {
  return { status: 'ok', artifact, has_medium_plus_findings: hasMediumPlus, per_curd: perCurd }
}

function cureResult({ status = 'ok', committed = true, artifact = '.cheese/cure/x.md' } = {}) {
  return { status, committed, artifact }
}

// A full clean single-curd chain: cook -> taste pass -> press -> integrate -> age:barrier clean -> plate.
function respondCleanChain({ slug = 'parent' } = {}) {
  return ({ opts }) => {
    if (opts.label === 'resolve') return resolveResolved({ slug })
    if (opts.label === `cook:${slug}`) return cook(slug)
    if (opts.label === `taste:${slug}`) return taste('pass')
    if (opts.label === `press:${slug}`) return phaseOk(slug, 'press')
    if (opts.label === 'integrate') return integrateResult({ merged: [slug] })
    if (opts.label === 'age:barrier') return ageBarrierResult({ hasMediumPlus: false, perCurd: [{ slug, has_medium_plus_findings: false, findings: [] }] })
    if (opts.label === 'plate') return plate([{ slug, status: 'plated', pr_url: `https://example.test/pr/${slug}` }])
    throw new Error(`unexpected agent ${opts.label}`)
  }
}

test('no spec arg returns candidates and dispatches no phase agent', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'resolve') return resolveCandidates(['alpha', 'beta'])
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: {} })

  assert.deepEqual(result.candidates, ['alpha', 'beta'])
  assert.equal(trace.agents.length, 1)
  assert.equal(trace.agents[0].opts.label, 'resolve')
})

test('missing spec file fails loud with a usage message', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'resolve') return resolveMissing('Usage: /cheese-factory { spec: <slug-or-path> } — spec not found at /nowhere.md')
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { spec: 'nowhere' } })

  assert.match(result.error, /Usage:.*spec not found/)
  assert.equal(trace.agents.length, 1)
})

test('single-pass chain runs when candidate_curds < 2, no decompose call', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: respondCleanChain({ slug: 'parent' }) })

  const result = await workflow.run({ ...globals, args: { spec: 'parent' } })

  assert.equal(trace.agents.some(({ opts }) => opts.label.startsWith('decompose')), false)
  assert.equal(result.curds.length, 1)
  assert.equal(result.curds[0].slug, 'parent')
  assert.equal(result.curds[0].status, 'clean')
  assert.equal(result.curds[0].branch, 'curd/parent')
  assert.deepEqual(trace.agents.map(({ opts }) => opts.label), ['resolve', 'cook:parent', 'taste:parent', 'press:parent', 'integrate', 'age:barrier', 'plate'])
})

test('decompose merges file-overlapping curds, writes mini-specs, and fans out only disjoint curds', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'resolve') return resolveResolved({ candidate_curds: 3 })
      if (opts.label === 'decompose:plan') {
        return decompose([
          { slug: 'a', brief: 'do a', files: ['shared.js'] },
          { slug: 'b', brief: 'do b', files: ['shared.js'] },
          { slug: 'c', brief: 'do c', files: ['only-c.js'] },
        ])
      }
      if (opts.label === 'decompose:write-minispecs') {
        return miniSpecs([
          { slug: 'a', spec_path: '/specs/parent--a.md' },
          { slug: 'c', spec_path: '/specs/parent--c.md' },
        ])
      }
      if (opts.label === 'cook:a') return cook('a')
      if (opts.label === 'taste:a') return taste('pass')
      if (opts.label === 'press:a') return phaseOk('a', 'press')
      if (opts.label === 'cook:c') return cook('c')
      if (opts.label === 'taste:c') return taste('pass')
      if (opts.label === 'press:c') return phaseOk('c', 'press')
      if (opts.label === 'integrate') return integrateResult({ merged: ['a', 'c'] })
      if (opts.label === 'age:barrier') {
        return ageBarrierResult({
          hasMediumPlus: false,
          perCurd: [
            { slug: 'a', has_medium_plus_findings: false, findings: [] },
            { slug: 'c', has_medium_plus_findings: false, findings: [] },
          ],
        })
      }
      if (opts.label === 'plate') return plate([{ slug: 'a', status: 'plated', pr_url: 'https://example.test/pr/a' }, { slug: 'c', status: 'plated', pr_url: 'https://example.test/pr/c' }])
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { spec: 'parent' } })

  assert.equal(trace.agents.some(({ opts }) => opts.label === 'cook:b'), false)
  assert.equal(trace.agents.some(({ opts }) => opts.label === 'cook:a'), true)
  assert.equal(trace.agents.some(({ opts }) => opts.label === 'cook:c'), true)

  const slugs = result.curds.map((c) => c.slug).sort()
  assert.deepEqual(slugs, ['a', 'c'])
  assert.ok(result.curds.every((c) => c.status === 'clean'))

  const labelSet = new Set(trace.agents.map(({ opts }) => opts.label))
  assert.deepEqual([...labelSet].sort(), [
    'age:barrier', 'cook:a', 'cook:c', 'decompose:plan', 'decompose:write-minispecs',
    'integrate', 'plate', 'press:a', 'press:c', 'resolve', 'taste:a', 'taste:c',
  ])
})

test('mini-spec agent dropping a curd slug fails loud before any cook agent spawns', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'resolve') return resolveResolved({ candidate_curds: 3 })
      if (opts.label === 'decompose:plan') {
        return decompose([
          { slug: 'a', brief: 'do a', files: ['shared.js'] },
          { slug: 'b', brief: 'do b', files: ['shared.js'] },
          { slug: 'c', brief: 'do c', files: ['only-c.js'] },
        ])
      }
      if (opts.label === 'decompose:write-minispecs') {
        return miniSpecs([
          { slug: 'a', spec_path: '/specs/parent--a.md' },
        ])
      }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { spec: 'parent' } })

  assert.match(result.error, /Unresolved mini-spec path/)
  assert.match(result.error, /c/)
  assert.equal(trace.agents.some(({ opts }) => opts.label.startsWith('cook:')), false)
})

test('phase order and per-phase model/agentType/isolation assertions', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: respondCleanChain({ slug: 'parent' }) })

  await workflow.run({ ...globals, args: { spec: 'parent' } })

  const labels = trace.agents.map(({ opts }) => opts.label)
  assert.deepEqual(labels, ['resolve', 'cook:parent', 'taste:parent', 'press:parent', 'integrate', 'age:barrier', 'plate'])
  assert.deepEqual(trace.phases, ['Resolve', 'Cook', 'Integrate', 'Age', 'Plate', 'Report'])

  const byLabel = Object.fromEntries(trace.agents.map((call) => [call.opts.label, call.opts]))
  assert.equal(byLabel['cook:parent'].model, 'sonnet')
  assert.equal(byLabel['cook:parent'].agentType, 'coder')
  assert.equal(byLabel['cook:parent'].isolation, 'worktree')

  assert.equal(byLabel['taste:parent'].model, 'opus')
  assert.equal(byLabel['taste:parent'].agentType, 'reviewer')
  assert.equal(byLabel['taste:parent'].isolation, undefined)

  assert.equal(byLabel['press:parent'].model, 'sonnet')
  assert.equal(byLabel['press:parent'].agentType, 'coder')

  assert.equal(byLabel['integrate'].model, 'sonnet')
  assert.equal(byLabel['integrate'].agentType, 'coder')
  assert.equal(byLabel['integrate'].isolation, 'worktree')

  assert.equal(byLabel['age:barrier'].model, 'opus')
  assert.equal(byLabel['age:barrier'].agentType, 'reviewer')

  assert.equal(byLabel['plate'].model, 'opus')
  assert.equal(byLabel['plate'].agentType, 'coder')
})

test('cure is skipped when age reports no medium+ findings', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: respondCleanChain({ slug: 'parent' }) })

  await workflow.run({ ...globals, args: { spec: 'parent' } })

  assert.equal(trace.agents.some(({ opts }) => opts.label.startsWith('cure:')), false)
  assert.equal(trace.agents.some(({ opts }) => opts.label === 're-merge'), false)
  assert.equal(trace.agents.some(({ opts }) => opts.label === 'age:reage'), false)
})

test('cure runs and a clean re-age keeps the curd in plate', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'resolve') return resolveResolved({ slug: 'parent' })
      if (opts.label === 'cook:parent') return cook('parent')
      if (opts.label === 'taste:parent') return taste('pass')
      if (opts.label === 'press:parent') return phaseOk('parent', 'press')
      if (opts.label === 'integrate') return integrateResult({ merged: ['parent'] })
      if (opts.label === 'age:barrier') return ageBarrierResult({ hasMediumPlus: true, perCurd: [{ slug: 'parent', has_medium_plus_findings: true, findings: [] }] })
      if (opts.label === 'cure:parent') return cureResult({ committed: true })
      if (opts.label === 're-merge') return integrateResult({ merged: ['parent'] })
      if (opts.label === 'age:reage') return ageBarrierResult({ hasMediumPlus: false, perCurd: [{ slug: 'parent', has_medium_plus_findings: false, findings: [] }] })
      if (opts.label === 'plate') return plate([{ slug: 'parent', status: 'plated', pr_url: 'https://example.test/pr/parent' }])
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { spec: 'parent' } })

  const labels = trace.agents.map(({ opts }) => opts.label)
  assert.ok(labels.includes('cure:parent'))
  assert.ok(labels.includes('re-merge'))
  assert.ok(labels.includes('age:reage'))
  assert.equal(result.curds[0].status, 'clean')
  assert.equal(result.curds[0].pr_url, 'https://example.test/pr/parent')
})

test('re-age still medium+ marks the curd dirty and excludes it from plate', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'resolve') return resolveResolved({ slug: 'parent' })
      if (opts.label === 'cook:parent') return cook('parent')
      if (opts.label === 'taste:parent') return taste('pass')
      if (opts.label === 'press:parent') return phaseOk('parent', 'press')
      if (opts.label === 'integrate') return integrateResult({ merged: ['parent'] })
      if (opts.label === 'age:barrier') return ageBarrierResult({ hasMediumPlus: true, perCurd: [{ slug: 'parent', has_medium_plus_findings: true, findings: [] }] })
      if (opts.label === 'cure:parent') return cureResult({ committed: true })
      if (opts.label === 're-merge') return integrateResult({ merged: ['parent'] })
      if (opts.label === 'age:reage') return ageBarrierResult({ hasMediumPlus: true, perCurd: [{ slug: 'parent', has_medium_plus_findings: true, findings: [] }] })
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { spec: 'parent' } })

  assert.equal(result.curds[0].status, 'dirty')
  assert.match(result.curds[0].excluded_reason, /re-age/)
  assert.equal(result.curds[0].pr_url, undefined)
  assert.equal(trace.agents.some(({ opts }) => opts.label === 'plate'), false)
})

test('bounded corrective taste loop caps at correctiveRounds and excludes the curd from plate', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'resolve') return resolveResolved({ slug: 'parent' })
      if (opts.label === 'cook:parent') return cook('parent')
      if (opts.label.startsWith('taste:parent')) return taste('revise')
      if (opts.label.startsWith('correct:parent')) return correction(true)
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { spec: 'parent', correctiveRounds: 2 } })

  const labels = trace.agents.map(({ opts }) => opts.label)
  assert.deepEqual(labels, [
    'resolve', 'cook:parent', 'taste:parent', 'correct:parent:r1', 'taste:parent:r1', 'correct:parent:r2', 'taste:parent:r2',
  ])
  assert.equal(labels.some((l) => l.startsWith('press:')), false)
  assert.equal(result.curds[0].status, 'failed')
  assert.equal(trace.agents.some(({ opts }) => opts.label === 'plate'), false)
})

test('correctiveRounds above the max of 3 clamps to 3', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'resolve') return resolveResolved({ slug: 'parent' })
      if (opts.label === 'cook:parent') return cook('parent')
      if (opts.label.startsWith('taste:parent')) return taste('revise')
      if (opts.label.startsWith('correct:parent')) return correction(true)
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  await workflow.run({ ...globals, args: { spec: 'parent', correctiveRounds: 10 } })

  assert.match(trace.logs.join('\n'), /clamping to 3/)
  const correctCalls = trace.agents.filter(({ opts }) => opts.label.startsWith('correct:parent')).length
  assert.equal(correctCalls, 3)
})

test('plate runs exactly once, after all chains, with only clean curds', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'resolve') return resolveResolved({ candidate_curds: 2 })
      if (opts.label === 'decompose:plan') {
        return decompose([
          { slug: 'good', brief: 'do good', files: ['good.js'] },
          { slug: 'bad', brief: 'do bad', files: ['bad.js'] },
        ])
      }
      if (opts.label === 'decompose:write-minispecs') {
        return miniSpecs([
          { slug: 'good', spec_path: '/specs/parent--good.md' },
          { slug: 'bad', spec_path: '/specs/parent--bad.md' },
        ])
      }
      if (opts.label === 'cook:good') return cook('good')
      if (opts.label === 'taste:good') return taste('pass')
      if (opts.label === 'press:good') return phaseOk('good', 'press')
      if (opts.label === 'cook:bad') return cook('bad', { status: 'blocked' })
      if (opts.label === 'cook:bad:c1') return cook('bad', { status: 'blocked' })
      if (opts.label === 'cook:bad:c2') return cook('bad', { status: 'blocked' })
      if (opts.label === 'integrate') return integrateResult({ merged: ['good'] })
      if (opts.label === 'age:barrier') return ageBarrierResult({ hasMediumPlus: false, perCurd: [{ slug: 'good', has_medium_plus_findings: false, findings: [] }] })
      if (opts.label === 'plate') return plate([{ slug: 'good', status: 'plated', pr_url: 'https://example.test/pr/good' }])
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { spec: 'parent' } })

  const plateCalls = trace.agents.filter(({ opts }) => opts.label === 'plate')
  assert.equal(plateCalls.length, 1)
  assert.match(plateCalls[0].prompt, /"slug":"good"/)
  assert.doesNotMatch(plateCalls[0].prompt, /"slug":"bad"/)

  const integrateCall = trace.agents.find(({ opts }) => opts.label === 'integrate')
  assert.ok(integrateCall)
  assert.doesNotMatch(integrateCall.prompt, /bad/)

  const ageBarrierCall = trace.agents.find(({ opts }) => opts.label === 'age:barrier')
  assert.doesNotMatch(ageBarrierCall.prompt, /"slug":"bad"/)

  const bySlug = Object.fromEntries(result.curds.map((c) => [c.slug, c]))
  assert.equal(bySlug.good.status, 'clean')
  assert.equal(bySlug.bad.status, 'failed')
})

test('report shape carries curds[] and summary', async () => {
  const workflow = await loadWorkflow(path)
  const { globals } = createRuntime({ respond: respondCleanChain({ slug: 'parent' }) })

  const result = await workflow.run({ ...globals, args: { spec: 'parent' } })

  assert.ok(Array.isArray(result.curds))
  assert.equal(result.curds[0].slug, 'parent')
  assert.equal(result.curds[0].branch, 'curd/parent')
  assert.equal(result.curds[0].status, 'clean')
  assert.equal(result.curds[0].pr_url, 'https://example.test/pr/parent')
  assert.equal(result.curds[0].excluded_reason, undefined)
  assert.deepEqual({ ...result.summary }, { clean: 1, dirty: 0, failed: 0 })
  assert.deepEqual(JSON.parse(JSON.stringify(result.integration)), { merged: ['parent'], conflicted: [] })
  assert.deepEqual(JSON.parse(JSON.stringify(result.curds[0].age)), { mode: 'single', has_medium_plus_findings: false })
})

test('args arrive as a JSON string', async () => {
  const workflow = await loadWorkflow(path)
  const { globals } = createRuntime({ respond: respondCleanChain({ slug: 'parent' }) })

  const result = await workflow.run({ ...globals, args: JSON.stringify({ spec: 'parent' }) })

  assert.equal(result.curds[0].status, 'clean')
})

test('invalid decomposed curd slug is rejected before any phase agent spawns', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'resolve') return resolveResolved({ candidate_curds: 2 })
      if (opts.label === 'decompose:plan') {
        return decompose([
          { slug: 'bad slug!', brief: 'nope', files: ['a.js'] },
          { slug: 'fine', brief: 'ok', files: ['b.js'] },
        ])
      }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { spec: 'parent' } })

  assert.match(result.error, /Invalid curd slug/)
  assert.equal(trace.agents.some(({ opts }) => opts.label === 'decompose:write-minispecs'), false)
  assert.equal(trace.agents.some(({ opts }) => opts.label.startsWith('cook:')), false)
})

test('duplicate decomposed curd slugs are rejected before any phase agent spawns', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'resolve') return resolveResolved({ candidate_curds: 2 })
      if (opts.label === 'decompose:plan') {
        return decompose([
          { slug: 'dup', brief: 'one', files: ['a.js'] },
          { slug: 'dup', brief: 'two', files: ['b.js'] },
        ])
      }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { spec: 'parent' } })

  assert.match(result.error, /Duplicate curd slug/)
  assert.equal(trace.agents.some(({ opts }) => opts.label === 'decompose:write-minispecs'), false)
  assert.equal(trace.agents.some(({ opts }) => opts.label.startsWith('cook:')), false)
})

test('curds that all overlap transitively merge to one and fall back to single-pass', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'resolve') return resolveResolved({ candidate_curds: 3 })
      if (opts.label === 'decompose:plan') {
        return decompose([
          { slug: 'a', brief: 'do a', files: ['a.js', 'shared-ab.js'] },
          { slug: 'b', brief: 'do b', files: ['shared-ab.js', 'shared-bc.js'] },
          { slug: 'c', brief: 'do c', files: ['shared-bc.js'] },
        ])
      }
      if (opts.label === 'cook:parent') return cook('parent')
      if (opts.label === 'taste:parent') return taste('pass')
      if (opts.label === 'press:parent') return phaseOk('parent', 'press')
      if (opts.label === 'integrate') return integrateResult({ merged: ['parent'] })
      if (opts.label === 'age:barrier') return ageBarrierResult({ hasMediumPlus: false, perCurd: [{ slug: 'parent', has_medium_plus_findings: false, findings: [] }] })
      if (opts.label === 'plate') return plate([{ slug: 'parent', status: 'plated', pr_url: 'https://example.test/pr/parent' }])
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { spec: 'parent' } })

  assert.equal(trace.agents.some(({ opts }) => opts.label === 'decompose:write-minispecs'), false)
  assert.equal(result.curds.length, 1)
  assert.equal(result.curds[0].slug, 'parent')
  assert.equal(result.curds[0].status, 'clean')
  assert.match(trace.logs.join('\n'), /single-pass/)
})

test('correctiveRounds 0 fails a revise verdict immediately with no corrective pass', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'resolve') return resolveResolved({ slug: 'parent' })
      if (opts.label === 'cook:parent') return cook('parent')
      if (opts.label === 'taste:parent') return taste('revise')
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { spec: 'parent', correctiveRounds: 0 } })

  assert.equal(trace.agents.some(({ opts }) => opts.label.startsWith('correct:')), false)
  assert.equal(result.curds[0].status, 'failed')
  assert.equal(trace.agents.some(({ opts }) => opts.label === 'plate'), false)
})

test('an uncommitted correction stops the taste loop and the curd fails', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'resolve') return resolveResolved({ slug: 'parent' })
      if (opts.label === 'cook:parent') return cook('parent')
      if (opts.label === 'taste:parent') return taste('revise')
      if (opts.label === 'correct:parent:r1') return correction(false)
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { spec: 'parent', correctiveRounds: 2 } })

  const labels = trace.agents.map(({ opts }) => opts.label)
  assert.deepEqual(labels, ['resolve', 'cook:parent', 'taste:parent', 'correct:parent:r1'])
  assert.match(trace.logs.join('\n'), /uncommitted correction/)
  assert.equal(result.curds[0].status, 'failed')
})

test('a mid-chain agent error becomes a structured stage failure, not a lost curd', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'resolve') return resolveResolved({ slug: 'parent' })
      if (opts.label === 'cook:parent') return cook('parent')
      if (opts.label === 'taste:parent') return taste('pass')
      if (opts.label === 'press:parent') throw new Error('press agent died')
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { spec: 'parent' } })

  assert.equal(result.curds.length, 1)
  assert.equal(result.curds[0].status, 'failed')
  assert.match(result.curds[0].excluded_reason, /press/)
  assert.equal(trace.agents.some(({ opts }) => opts.label === 'plate'), false)
})

test('candidates mode tolerates a missing candidates array', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'resolve') return { mode: 'candidates' }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: {} })

  assert.deepEqual(Array.from(result.candidates), [])
  assert.equal(trace.agents.length, 1)
})

test('an invalid parent slug from the resolver fails loud before any phase agent spawns', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'resolve') return resolveResolved({ slug: 'bad slug; rm -rf /' })
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { spec: 'parent' } })

  assert.match(result.error, /Invalid parent slug/)
  assert.equal(trace.agents.length, 1)
  assert.equal(trace.agents.some(({ opts }) => opts.label.startsWith('cook:')), false)
})

test('an invalid spec arg fails loud before any phase agent spawns', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { spec: 'bad slug; rm -rf /' } })

  assert.match(result.error, /Invalid spec arg/)
  assert.equal(trace.agents.length, 0)
})

test('integrate receives slug-sorted curds and small diffs skip the age-fanout workflow', async () => {
  const workflow = await loadWorkflow(path)
  const workflowCalls = []
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'resolve') return resolveResolved({ candidate_curds: 2 })
      if (opts.label === 'decompose:plan') {
        return decompose([
          { slug: 'b', brief: 'do b', files: ['b.js'] },
          { slug: 'a', brief: 'do a', files: ['a.js'] },
        ])
      }
      if (opts.label === 'decompose:write-minispecs') {
        return miniSpecs([
          { slug: 'b', spec_path: '/specs/parent--b.md' },
          { slug: 'a', spec_path: '/specs/parent--a.md' },
        ])
      }
      if (opts.label === 'cook:a') return cook('a')
      if (opts.label === 'taste:a') return taste('pass')
      if (opts.label === 'press:a') return phaseOk('a', 'press')
      if (opts.label === 'cook:b') return cook('b')
      if (opts.label === 'taste:b') return taste('pass')
      if (opts.label === 'press:b') return phaseOk('b', 'press')
      if (opts.label === 'integrate') return integrateResult({ merged: ['a', 'b'], files_changed: 4, lines_changed: 40 })
      if (opts.label === 'age:barrier') {
        return ageBarrierResult({
          hasMediumPlus: false,
          perCurd: [
            { slug: 'a', has_medium_plus_findings: false, findings: [] },
            { slug: 'b', has_medium_plus_findings: false, findings: [] },
          ],
        })
      }
      if (opts.label === 'plate') return plate([{ slug: 'a', status: 'plated', pr_url: 'https://example.test/pr/a' }, { slug: 'b', status: 'plated', pr_url: 'https://example.test/pr/b' }])
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const workflowOverride = (name, opts) => {
    workflowCalls.push({ name, opts })
    throw new Error('workflow override should not be called for small diffs')
  }

  await workflow.run({ ...globals, args: { spec: 'parent' }, workflow: workflowOverride })

  const integrateCalls = trace.agents.filter(({ opts }) => opts.label === 'integrate')
  assert.equal(integrateCalls.length, 1)
  const prompt = integrateCalls[0].prompt
  assert.ok(prompt.indexOf('"slug":"a"') < prompt.indexOf('"slug":"b"'))

  assert.equal(workflowCalls.length, 0)
  assert.equal(trace.agents.some(({ opts }) => opts.label === 'age:barrier'), true)
})

test('a large integrated diff dispatches age-fanout with exact workflow args', async () => {
  const workflow = await loadWorkflow(path)
  const fanoutCalls = []
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'resolve') return resolveResolved({ slug: 'a' })
      if (opts.label === 'cook:a') return cook('a')
      if (opts.label === 'taste:a') return taste('pass')
      if (opts.label === 'press:a') return phaseOk('a', 'press')
      if (opts.label === 'integrate') return integrateResult({ merged: ['a'], files_changed: 20, lines_changed: 900 })
      if (opts.label === 'plate') return plate([{ slug: 'a', status: 'plated', pr_url: 'https://example.test/pr/a' }])
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const workflowOverride = async (name, opts) => {
    fanoutCalls.push({ name, opts: JSON.parse(JSON.stringify(opts)) })
    return ageBarrierResult({ hasMediumPlus: false, perCurd: [{ slug: 'a', has_medium_plus_findings: false, findings: [] }] })
  }

  const result = await workflow.run({ ...globals, args: { spec: 'parent' }, workflow: workflowOverride })

  assert.equal(fanoutCalls.length, 1)
  assert.equal(fanoutCalls[0].name, 'age-fanout')
  assert.deepEqual(fanoutCalls[0].opts, {
    worktree_path: '/tmp/worktrees/integration',
    range: 'origin/main...HEAD',
    slug: 'a',
    route_curds: [{ slug: 'a', branch: 'curd/a' }],
  })
  assert.equal(trace.agents.some(({ opts }) => opts.label === 'age:barrier'), false)
  assert.equal(result.curds[0].age.mode, 'fanout')
})

test('fanout per-curd findings drive cure only for the flagged curd', async () => {
  const workflow = await loadWorkflow(path)
  const CLAIM = 'unbounded recursion in parseTree'
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'resolve') return resolveResolved({ candidate_curds: 2 })
      if (opts.label === 'decompose:plan') {
        return decompose([
          { slug: 'a', brief: 'do a', files: ['a.js'] },
          { slug: 'b', brief: 'do b', files: ['b.js'] },
        ])
      }
      if (opts.label === 'decompose:write-minispecs') {
        return miniSpecs([
          { slug: 'a', spec_path: '/specs/parent--a.md' },
          { slug: 'b', spec_path: '/specs/parent--b.md' },
        ])
      }
      if (opts.label === 'cook:a') return cook('a')
      if (opts.label === 'taste:a') return taste('pass')
      if (opts.label === 'press:a') return phaseOk('a', 'press')
      if (opts.label === 'cook:b') return cook('b')
      if (opts.label === 'taste:b') return taste('pass')
      if (opts.label === 'press:b') return phaseOk('b', 'press')
      if (opts.label === 'integrate') return integrateResult({ merged: ['a', 'b'], files_changed: 20, lines_changed: 900 })
      if (opts.label === 'cure:a') return cureResult({ committed: true })
      if (opts.label === 're-merge') return integrateResult({ merged: ['a', 'b'] })
      if (opts.label === 'age:reage') return ageBarrierResult({ hasMediumPlus: false, perCurd: [{ slug: 'a', has_medium_plus_findings: false, findings: [] }] })
      if (opts.label === 'plate') return plate([{ slug: 'a', status: 'plated', pr_url: 'https://example.test/pr/a' }, { slug: 'b', status: 'plated', pr_url: 'https://example.test/pr/b' }])
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const workflowOverride = async () => ageBarrierResult({
    hasMediumPlus: true,
    perCurd: [
      { slug: 'a', has_medium_plus_findings: true, findings: [{ claim: CLAIM }] },
      { slug: 'b', has_medium_plus_findings: false, findings: [] },
    ],
  })

  const result = await workflow.run({ ...globals, args: { spec: 'parent' }, workflow: workflowOverride })

  const cureCall = trace.agents.find(({ opts }) => opts.label === 'cure:a')
  assert.ok(cureCall)
  assert.match(cureCall.prompt, new RegExp(CLAIM))
  assert.equal(trace.agents.some(({ opts }) => opts.label === 'cure:b'), false)

  const bySlug = Object.fromEntries(result.curds.map((c) => [c.slug, c]))
  assert.equal(bySlug.a.status, 'clean')
  assert.equal(bySlug.b.status, 'clean')
})

test('workflow() throwing falls back to age:barrier', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'resolve') return resolveResolved({ slug: 'parent' })
      if (opts.label === 'cook:parent') return cook('parent')
      if (opts.label === 'taste:parent') return taste('pass')
      if (opts.label === 'press:parent') return phaseOk('parent', 'press')
      if (opts.label === 'integrate') return integrateResult({ merged: ['parent'], files_changed: 20, lines_changed: 900 })
      if (opts.label === 'age:barrier') return ageBarrierResult({ hasMediumPlus: false, perCurd: [{ slug: 'parent', has_medium_plus_findings: false, findings: [] }] })
      if (opts.label === 'plate') return plate([{ slug: 'parent', status: 'plated', pr_url: 'https://example.test/pr/parent' }])
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const workflowOverride = async () => { throw new Error('age-fanout dispatch failed') }

  const result = await workflow.run({ ...globals, args: { spec: 'parent' }, workflow: workflowOverride })

  assert.equal(trace.agents.some(({ opts }) => opts.label === 'age:barrier'), true)
  assert.match(trace.logs.join('\n'), /age-fanout unavailable/)
  assert.equal(result.curds[0].status, 'clean')
  assert.equal(result.curds[0].age.mode, 'single')
})

test('cure that does not commit marks the curd dirty and skips re-merge, re-age, and plate', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'resolve') return resolveResolved({ slug: 'parent' })
      if (opts.label === 'cook:parent') return cook('parent')
      if (opts.label === 'taste:parent') return taste('pass')
      if (opts.label === 'press:parent') return phaseOk('parent', 'press')
      if (opts.label === 'integrate') return integrateResult({ merged: ['parent'] })
      if (opts.label === 'age:barrier') return ageBarrierResult({ hasMediumPlus: true, perCurd: [{ slug: 'parent', has_medium_plus_findings: true, findings: [] }] })
      if (opts.label === 'cure:parent') return cureResult({ committed: false })
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { spec: 'parent' } })

  assert.equal(result.curds[0].status, 'dirty')
  assert.match(result.curds[0].excluded_reason, /cure did not commit a fix/)
  assert.equal(trace.agents.some(({ opts }) => opts.label === 're-merge'), false)
  assert.equal(trace.agents.some(({ opts }) => opts.label === 'age:reage'), false)
  assert.equal(trace.agents.some(({ opts }) => opts.label === 'plate'), false)
})

test('mixed cure outcome: one curd clears re-age, the other stays dirty', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'resolve') return resolveResolved({ candidate_curds: 2 })
      if (opts.label === 'decompose:plan') {
        return decompose([
          { slug: 'x', brief: 'do x', files: ['x.js'] },
          { slug: 'y', brief: 'do y', files: ['y.js'] },
        ])
      }
      if (opts.label === 'decompose:write-minispecs') {
        return miniSpecs([
          { slug: 'x', spec_path: '/specs/parent--x.md' },
          { slug: 'y', spec_path: '/specs/parent--y.md' },
        ])
      }
      if (opts.label === 'cook:x') return cook('x')
      if (opts.label === 'taste:x') return taste('pass')
      if (opts.label === 'press:x') return phaseOk('x', 'press')
      if (opts.label === 'cook:y') return cook('y')
      if (opts.label === 'taste:y') return taste('pass')
      if (opts.label === 'press:y') return phaseOk('y', 'press')
      if (opts.label === 'integrate') return integrateResult({ merged: ['x', 'y'] })
      if (opts.label === 'age:barrier') {
        return ageBarrierResult({
          hasMediumPlus: true,
          perCurd: [
            { slug: 'x', has_medium_plus_findings: true, findings: [] },
            { slug: 'y', has_medium_plus_findings: true, findings: [] },
          ],
        })
      }
      if (opts.label === 'cure:x') return cureResult({ committed: true })
      if (opts.label === 'cure:y') return cureResult({ committed: true })
      if (opts.label === 're-merge') return integrateResult({ merged: ['x', 'y'] })
      if (opts.label === 'age:reage') {
        return ageBarrierResult({
          hasMediumPlus: true,
          perCurd: [
            { slug: 'x', has_medium_plus_findings: false, findings: [] },
            { slug: 'y', has_medium_plus_findings: true, findings: [] },
          ],
        })
      }
      if (opts.label === 'plate') return plate([{ slug: 'x', status: 'plated', pr_url: 'https://example.test/pr/x' }])
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { spec: 'parent' } })

  const bySlug = Object.fromEntries(result.curds.map((c) => [c.slug, c]))
  assert.equal(bySlug.x.status, 'clean')
  assert.equal(bySlug.x.pr_url, 'https://example.test/pr/x')
  assert.equal(bySlug.y.status, 'dirty')
  assert.match(bySlug.y.excluded_reason, /re-age still reports medium\+ findings/)

  const plateCall = trace.agents.find(({ opts }) => opts.label === 'plate')
  assert.match(plateCall.prompt, /"slug":"x"/)
  assert.doesNotMatch(plateCall.prompt, /"slug":"y"/)
})

test('an integrate conflict fails the conflicting curd and keeps the merged one clean', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'resolve') return resolveResolved({ candidate_curds: 2 })
      if (opts.label === 'decompose:plan') {
        return decompose([
          { slug: 'ok', brief: 'do ok', files: ['ok.js'] },
          { slug: 'clash', brief: 'do clash', files: ['clash.js'] },
        ])
      }
      if (opts.label === 'decompose:write-minispecs') {
        return miniSpecs([
          { slug: 'ok', spec_path: '/specs/parent--ok.md' },
          { slug: 'clash', spec_path: '/specs/parent--clash.md' },
        ])
      }
      if (opts.label === 'cook:ok') return cook('ok')
      if (opts.label === 'taste:ok') return taste('pass')
      if (opts.label === 'press:ok') return phaseOk('ok', 'press')
      if (opts.label === 'cook:clash') return cook('clash')
      if (opts.label === 'taste:clash') return taste('pass')
      if (opts.label === 'press:clash') return phaseOk('clash', 'press')
      if (opts.label === 'integrate') return integrateResult({ merged: ['ok'], conflicted: ['clash'] })
      if (opts.label === 'age:barrier') return ageBarrierResult({ hasMediumPlus: false, perCurd: [{ slug: 'ok', has_medium_plus_findings: false, findings: [] }] })
      if (opts.label === 'plate') return plate([{ slug: 'ok', status: 'plated', pr_url: 'https://example.test/pr/ok' }])
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { spec: 'parent' } })

  const bySlug = Object.fromEntries(result.curds.map((c) => [c.slug, c]))
  assert.equal(bySlug.clash.status, 'failed')
  assert.match(bySlug.clash.excluded_reason, /integrate: merge conflict/)
  assert.equal(bySlug.ok.status, 'clean')

  const ageBarrierCall = trace.agents.find(({ opts }) => opts.label === 'age:barrier')
  assert.doesNotMatch(ageBarrierCall.prompt, /"slug":"clash"/)
})

test('an integrate failure fails the whole chain before age:barrier', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'resolve') return resolveResolved({ slug: 'parent' })
      if (opts.label === 'cook:parent') return cook('parent')
      if (opts.label === 'taste:parent') return taste('pass')
      if (opts.label === 'press:parent') return phaseOk('parent', 'press')
      if (opts.label === 'integrate') throw new Error('integrate agent died')
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { spec: 'parent' } })

  assert.equal(result.curds[0].status, 'failed')
  assert.match(result.curds[0].excluded_reason, /integrate: barrier integration failed/)
  assert.equal(trace.agents.some(({ opts }) => opts.label === 'age:barrier'), false)
  assert.equal(trace.agents.some(({ opts }) => opts.label.startsWith('cure:')), false)
  assert.equal(trace.agents.some(({ opts }) => opts.label === 'plate'), false)
})

test('a cook that never reaches ok status blocks the curd before integrate, dispatching exactly 2 continuations', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'resolve') return resolveResolved({ slug: 'parent' })
      if (opts.label === 'cook:parent') return cook('parent', { status: 'blocked' })
      if (opts.label === 'cook:parent:c1') return cook('parent', { status: 'blocked' })
      if (opts.label === 'cook:parent:c2') return cook('parent', { status: 'blocked' })
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { spec: 'parent' } })

  const continuationCalls = trace.agents.filter(({ opts }) => /^cook:parent:c\d+$/.test(opts.label))
  assert.equal(continuationCalls.length, 2)
  assert.equal(trace.agents.some(({ opts }) => opts.label === 'integrate'), false)
  assert.equal(trace.agents.some(({ opts }) => opts.label === 'age:barrier'), false)
  assert.equal(trace.agents.some(({ opts }) => opts.label === 'plate'), false)
  assert.equal(result.curds[0].status, 'failed')
  assert.match(result.curds[0].excluded_reason, /cook did not reach status ok with a worktree_path \(last status: blocked\) — curd\/parent may carry committed WIP from continuation rounds/)
})

test('a blocked cook with a worktree_path gets a continuation that reaches ok, and the chain proceeds through taste\/press', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'resolve') return resolveResolved({ slug: 'parent' })
      if (opts.label === 'cook:parent') return cook('parent', { status: 'blocked' })
      if (opts.label === 'cook:parent:c1') return cook('parent', { status: 'ok' })
      if (opts.label === 'taste:parent') return taste('pass')
      if (opts.label === 'press:parent') return phaseOk('parent', 'press')
      if (opts.label === 'integrate') return integrateResult({ merged: ['parent'] })
      if (opts.label === 'age:barrier') return ageBarrierResult({ hasMediumPlus: false, perCurd: [{ slug: 'parent', has_medium_plus_findings: false, findings: [] }] })
      if (opts.label === 'plate') return plate([{ slug: 'parent', status: 'plated', pr_url: 'https://example.test/pr/parent' }])
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { spec: 'parent' } })

  const labels = trace.agents.map(({ opts }) => opts.label)
  assert.deepEqual(labels, ['resolve', 'cook:parent', 'cook:parent:c1', 'taste:parent', 'press:parent', 'integrate', 'age:barrier', 'plate'])
  assert.equal(result.curds[0].status, 'clean')
  assert.equal(result.curds[0].pr_url, 'https://example.test/pr/parent')
})

test('a blocked cook without a worktree_path gets no continuation and fails immediately', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'resolve') return resolveResolved({ slug: 'parent' })
      if (opts.label === 'cook:parent') return { status: 'blocked', worktree_path: '', artifact: '.cheese/cook/parent.md', orientation: 'stuck' }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { spec: 'parent' } })

  assert.equal(trace.agents.some(({ opts }) => opts.label.startsWith('cook:parent:c')), false)
  assert.equal(trace.agents.some(({ opts }) => opts.label === 'integrate'), false)
  assert.equal(result.curds[0].status, 'failed')
  assert.match(result.curds[0].excluded_reason, /cook did not reach status ok with a worktree_path \(last status: blocked\)/)
})

test('age:barrier reporting medium+ with no per-curd routing marks the curd dirty', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'resolve') return resolveResolved({ slug: 'parent' })
      if (opts.label === 'cook:parent') return cook('parent')
      if (opts.label === 'taste:parent') return taste('pass')
      if (opts.label === 'press:parent') return phaseOk('parent', 'press')
      if (opts.label === 'integrate') return integrateResult({ merged: ['parent'] })
      if (opts.label === 'age:barrier') return ageBarrierResult({ hasMediumPlus: true, perCurd: [] })
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { spec: 'parent' } })

  assert.equal(result.curds[0].status, 'dirty')
  assert.match(result.curds[0].excluded_reason, /age reported medium\+ findings without per-curd routing/)
  assert.match(trace.logs.join('\n'), /no per-curd routing/)
  assert.equal(trace.agents.some(({ opts }) => opts.label === 'plate'), false)
})

test('a bare non-JSON string spec arg runs resolve in spec mode with the arg quoted in the prompt', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'resolve') return resolveMissing('Usage: /cheese-factory { spec: <slug-or-path> } — spec not found at /specs/parent.md')
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  await workflow.run({ ...globals, args: '/specs/parent.md' })

  assert.equal(trace.agents.length, 1)
  assert.match(trace.agents[0].prompt, /A spec was given: "\/specs\/parent\.md"/)
})

test('a JSON-quoted string spec arg behaves like a bare string', async () => {
  const workflow = await loadWorkflow(path)
  const { globals } = createRuntime({ respond: respondCleanChain({ slug: 'parent' }) })

  const result = await workflow.run({ ...globals, args: JSON.stringify('parent') })

  assert.equal(result.curds[0].status, 'clean')
})

test('absolute and ~/ spec paths pass validation; a spec arg with .. is rejected', async () => {
  const workflow = await loadWorkflow(path)

  for (const spec of ['/abs/path.md', '~/x/y.md']) {
    const { globals } = createRuntime({ respond: respondCleanChain({ slug: 'parent' }) })
    const result = await workflow.run({ ...globals, args: { spec } })
    assert.equal(result.curds[0].status, 'clean')
  }

  const { globals, trace } = createRuntime({
    respond: ({ opts }) => { throw new Error(`unexpected agent ${opts.label}`) },
  })
  const result = await workflow.run({ ...globals, args: { spec: 'a/../b' } })

  assert.match(result.error, /Invalid spec arg/)
  assert.equal(trace.agents.length, 0)
})

test('two curds coupled purely by depends_on merge into one and fall back to single-pass', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'resolve') return resolveResolved({ candidate_curds: 2 })
      if (opts.label === 'decompose:plan') {
        return decompose([
          { slug: 'a', brief: 'do a', files: ['a.js'] },
          { slug: 'b', brief: 'do b', files: ['b.js'], depends_on: ['a'] },
        ])
      }
      if (opts.label === 'cook:parent') return cook('parent')
      if (opts.label === 'taste:parent') return taste('pass')
      if (opts.label === 'press:parent') return phaseOk('parent', 'press')
      if (opts.label === 'integrate') return integrateResult({ merged: ['parent'] })
      if (opts.label === 'age:barrier') return ageBarrierResult({ hasMediumPlus: false, perCurd: [{ slug: 'parent', has_medium_plus_findings: false, findings: [] }] })
      if (opts.label === 'plate') return plate([{ slug: 'parent', status: 'plated', pr_url: 'https://example.test/pr/parent' }])
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { spec: 'parent' } })

  assert.equal(trace.agents.some(({ opts }) => opts.label === 'decompose:write-minispecs'), false)
  assert.equal(result.curds.length, 1)
  assert.equal(result.curds[0].slug, 'parent')
  assert.equal(result.curds[0].status, 'clean')
  assert.match(trace.logs.join('\n'), /single-pass/)
})

test('a depends_on edge merges two of three curds, leaving the third independent and fanning out', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'resolve') return resolveResolved({ candidate_curds: 3 })
      if (opts.label === 'decompose:plan') {
        return decompose([
          { slug: 'a', brief: 'do a', files: ['a.js'] },
          { slug: 'b', brief: 'do b', files: ['b.js'], depends_on: ['a'] },
          { slug: 'c', brief: 'do c', files: ['c.js'] },
        ])
      }
      if (opts.label === 'decompose:write-minispecs') {
        return miniSpecs([
          { slug: 'a', spec_path: '/specs/parent--a.md' },
          { slug: 'c', spec_path: '/specs/parent--c.md' },
        ])
      }
      if (opts.label === 'cook:a') return cook('a')
      if (opts.label === 'taste:a') return taste('pass')
      if (opts.label === 'press:a') return phaseOk('a', 'press')
      if (opts.label === 'cook:c') return cook('c')
      if (opts.label === 'taste:c') return taste('pass')
      if (opts.label === 'press:c') return phaseOk('c', 'press')
      if (opts.label === 'integrate') return integrateResult({ merged: ['a', 'c'] })
      if (opts.label === 'age:barrier') {
        return ageBarrierResult({
          hasMediumPlus: false,
          perCurd: [
            { slug: 'a', has_medium_plus_findings: false, findings: [] },
            { slug: 'c', has_medium_plus_findings: false, findings: [] },
          ],
        })
      }
      if (opts.label === 'plate') return plate([{ slug: 'a', status: 'plated', pr_url: 'https://example.test/pr/a' }, { slug: 'c', status: 'plated', pr_url: 'https://example.test/pr/c' }])
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { spec: 'parent' } })

  assert.equal(trace.agents.some(({ opts }) => opts.label === 'cook:b'), false)
  assert.equal(trace.agents.some(({ opts }) => opts.label === 'cook:a'), true)
  assert.equal(trace.agents.some(({ opts }) => opts.label === 'cook:c'), true)
  assert.match(trace.logs.join('\n'), /Merged coupled curd group\(s\): a\+b/)
})
