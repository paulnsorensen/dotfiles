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

function age(hasMediumPlus, slug, label = 'age') {
  return { status: 'ok', artifact: `.cheese/${label}/${slug}.md`, has_medium_plus_findings: hasMediumPlus }
}

function plate(results) {
  return { results }
}

// A full clean single-curd chain: cook -> taste pass -> press -> age clean -> plate.
function respondCleanChain({ slug = 'parent' } = {}) {
  return ({ opts }) => {
    if (opts.label === 'resolve') return resolveResolved({ slug })
    if (opts.label === `cook:${slug}`) return cook(slug)
    if (opts.label === `taste:${slug}`) return taste('pass')
    if (opts.label === `press:${slug}`) return phaseOk(slug, 'press')
    if (opts.label === `age:${slug}`) return age(false, slug)
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
      if (opts.label === 'age:a') return age(false, 'a')
      if (opts.label === 'cook:c') return cook('c')
      if (opts.label === 'taste:c') return taste('pass')
      if (opts.label === 'press:c') return phaseOk('c', 'press')
      if (opts.label === 'age:c') return age(false, 'c')
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
  assert.deepEqual(labels, ['resolve', 'cook:parent', 'taste:parent', 'press:parent', 'age:parent', 'plate'])
  assert.deepEqual(trace.phases, ['Resolve', 'Cook', 'Plate', 'Report'])

  const byLabel = Object.fromEntries(trace.agents.map((call) => [call.opts.label, call.opts]))
  assert.equal(byLabel['cook:parent'].model, 'sonnet')
  assert.equal(byLabel['cook:parent'].agentType, 'coder')
  assert.equal(byLabel['cook:parent'].isolation, 'worktree')

  assert.equal(byLabel['taste:parent'].model, 'opus')
  assert.equal(byLabel['taste:parent'].agentType, 'reviewer')
  assert.equal(byLabel['taste:parent'].isolation, undefined)

  assert.equal(byLabel['press:parent'].model, 'sonnet')
  assert.equal(byLabel['press:parent'].agentType, 'coder')

  assert.equal(byLabel['age:parent'].model, 'opus')
  assert.equal(byLabel['age:parent'].agentType, 'reviewer')

  assert.equal(byLabel['plate'].model, 'opus')
  assert.equal(byLabel['plate'].agentType, 'coder')
})

test('cure is skipped when age reports no medium+ findings', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: respondCleanChain({ slug: 'parent' }) })

  await workflow.run({ ...globals, args: { spec: 'parent' } })

  assert.equal(trace.agents.some(({ opts }) => opts.label.startsWith('cure:')), false)
  assert.equal(trace.agents.some(({ opts }) => opts.label.startsWith('reage:')), false)
})

test('cure runs and a clean re-age keeps the curd in plate', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'resolve') return resolveResolved({ slug: 'parent' })
      if (opts.label === 'cook:parent') return cook('parent')
      if (opts.label === 'taste:parent') return taste('pass')
      if (opts.label === 'press:parent') return phaseOk('parent', 'press')
      if (opts.label === 'age:parent') return age(true, 'parent', 'age')
      if (opts.label === 'cure:parent') return phaseOk('parent', 'cure')
      if (opts.label === 'reage:parent') return age(false, 'parent', 'reage')
      if (opts.label === 'plate') return plate([{ slug: 'parent', status: 'plated', pr_url: 'https://example.test/pr/parent' }])
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { spec: 'parent' } })

  const labels = trace.agents.map(({ opts }) => opts.label)
  assert.ok(labels.includes('cure:parent'))
  assert.ok(labels.includes('reage:parent'))
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
      if (opts.label === 'age:parent') return age(true, 'parent', 'age')
      if (opts.label === 'cure:parent') return phaseOk('parent', 'cure')
      if (opts.label === 'reage:parent') return age(true, 'parent', 'reage')
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
      if (opts.label === 'age:good') return age(false, 'good')
      if (opts.label === 'cook:bad') return cook('bad', { status: 'blocked' })
      if (opts.label === 'plate') return plate([{ slug: 'good', status: 'plated', pr_url: 'https://example.test/pr/good' }])
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: { spec: 'parent' } })

  const plateCalls = trace.agents.filter(({ opts }) => opts.label === 'plate')
  assert.equal(plateCalls.length, 1)
  assert.match(plateCalls[0].prompt, /"slug":"good"/)
  assert.doesNotMatch(plateCalls[0].prompt, /"slug":"bad"/)

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
      if (opts.label === 'age:parent') return age(false, 'parent')
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
