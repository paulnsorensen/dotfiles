import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime } from './cheese-factory.fixtures.mjs'
import { loadWorkflow } from './cheese-factory.fixtures.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/cheese-factory.js')

const sha = (n) => n.toString(16).padStart(40, '0')
const BASE_SHA = sha(0xba5e)
const NEW_HEAD = sha(0x2ead)
const CURE_SHA = sha(0xc0de)
const SCRATCH = (name) => `/repo/.claude/worktrees/${name}`
const callsOf = (trace, label) => trace.agents.filter(({ opts }) => opts.label === label)
const recordedOf = (trace) => {
  const prompt = callsOf(trace, 'cleanup')[0].prompt
  return prompt.slice(prompt.indexOf('<data name="recorded_shas">'))
}

const finding = (file, { severity = 'medium', fix_cost_now = 'n/a', claim = 'a claim' } = {}) => ({
  dimension: 'correctness', severity, fix_cost_now, file, line: 1, claim, why_it_matters: 'matters', fix_direction: 'fix it',
})
const ageResult = ({ findings = [], reviewed = [] } = {}) => ({
  status: 'ok', artifact: '.cheese/age/barrier.md', has_medium_plus_findings: findings.some((f) => f.severity !== 'low'), findings, reviewed_slugs: reviewed,
})
const integrateResult = ({ merged, files_by_slug, head = sha(0x1ead), worktree_path = SCRATCH('integ') }) => ({
  worktree_path, merged, conflicted: [], head, files_by_slug, files_changed: 20, lines_changed: 900,
})
const phaseOk = (slug, phase) => ({ status: 'ok', head_sha: sha(2), artifact: `.cheese/${phase}/${slug}.md`, orientation: 'done' })
const cookOk = (slug) => ({ status: 'ok', head_sha: sha(1), worktree_path: SCRATCH(`cook-${slug}`), artifact: `.cheese/cook/${slug}.md`, orientation: 'implemented' })
const taste = () => ({ verdict: 'pass', lenses: [{ lens: 'drift', verdict: 'pass', note: '' }], issues: [], recommendation: 'pass' })
const reviseTaste = () => ({ verdict: 'revise', lenses: [{ lens: 'readability', verdict: 'revise', note: 'tidy' }], issues: ['tidy'], recommendation: 'revise' })
const resolvedFor = (slugs, base_sha = BASE_SHA) => ({ mode: 'resolved', base_sha, spec_path: '/specs/parent.md', spec_text: 'spec body', curd_count: { slug: 'parent', candidate_curds: slugs.length > 1 ? 2 : 1, blast_radius: 'medium' } })

function respondFor(slugs, over) {
  const defaults = {
    resolve: resolvedFor(slugs),
    'decompose:plan': { curds: slugs.map((s) => ({ slug: s, brief: `do ${s}`, files: [`${s}.js`] })) },
    'decompose:write-minispecs': { curds: slugs.map((s) => ({ slug: s, spec_path: `/specs/parent--${s}.md` })) },
    plate: { results: slugs.map((s) => ({ slug: s, status: 'ok', pr_url: `https://example.test/pr/${s}` })) },
    cleanup: { removed: [] },
  }
  for (const s of slugs) {
    defaults[`cook:${s}`] = cookOk(s)
    defaults[`taste:${s}`] = taste()
    defaults[`press:${s}`] = phaseOk(s, 'press')
  }
  return (call) => {
    const base = call.opts.label.replace(/:(?:redo|repair|retry)\d+$/, '')
    const entry = Object.hasOwn(over, base) ? over[base] : defaults[base]
    if (entry === undefined) throw new Error(`unexpected agent ${call.opts.label}`)
    return typeof entry === 'function' ? entry(call) : entry
  }
}

async function run(slugs, over, age) {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: respondFor(slugs, over) })
  const result = await workflow.run({ ...globals, args: { spec: 'parent' }, workflow: async () => age })
  return { result, trace, bySlug: Object.fromEntries(result.curds.map((c) => [c.slug, c])) }
}

const singleOver = { integrate: integrateResult({ merged: ['parent'], files_by_slug: { parent: ['src/parent.js'] } }) }
const single = (findings = [], over = {}) => run(['parent'], { ...singleOver, ...over }, ageResult({ findings, reviewed: ['parent'] }))
const fanOut = (over = {}, findings = []) => {
  const slugs = ['a', 'b']
  return run(slugs, { integrate: integrateResult({ merged: slugs, files_by_slug: { a: ['src/a.js'], b: ['src/b.js'] } }), ...over }, ageResult({ findings, reviewed: slugs }))
}
const cureOver = {
  're-merge': integrateResult({ merged: ['parent'], files_by_slug: { parent: ['src/parent.js'] }, head: NEW_HEAD, worktree_path: SCRATCH('remerge') }),
  'age:reage': ageResult({ reviewed: ['parent'] }),
}
const fullCure = { status: 'ok', committed: true, head_sha: CURE_SHA, artifact: '.cheese/cure/x.md' }

test('pass2 #1: the plate prompt checks only tracked files, so untracked scratch paths never block', async () => {
  for (const { trace } of [await single(), await fanOut()]) {
    const prompt = callsOf(trace, 'plate')[0].prompt
    assert.match(prompt, /git status --porcelain --untracked-files=no/)
    assert.match(prompt, /stop and return status blocked/)
  }
})

test('pass2 #2: both plate prompts run the tracked-change check before the slug-to-SHA check', async () => {
  for (const { trace } of [await single(), await fanOut()]) {
    const prompt = callsOf(trace, 'plate')[0].prompt
    const tracked = prompt.indexOf('--untracked-files=no')
    const pinned = prompt.indexOf('git rev-parse refs/heads/curd/<slug>')
    assert.ok(tracked >= 0 && pinned >= 0)
    assert.ok(tracked < pinned, 'tracked-change check comes first')
    assert.ok(pinned < prompt.indexOf('plate/SKILL.md'), 'SHA check runs before any plate step')
  }
})

test('pass2 #2: the fan-out plate prompt allows the provider restack and forbids any other edit', async () => {
  const { trace } = await fanOut()
  const prompt = callsOf(trace, 'plate')[0].prompt
  assert.match(prompt, /may restack the verified branches/)
  assert.match(prompt, /Never stage, commit, or push any other edit/)
  assert.doesNotMatch(prompt, /Publish only the pinned SHAs/)
})

test('pass2 #2: the single-pass plate prompt keeps the pinned-SHA rule', async () => {
  const { trace } = await single()
  assert.match(callsOf(trace, 'plate')[0].prompt, /Publish only the pinned SHA/)
})

test('pass2 #3: a cure answer without committed is a substance error, so the writer redoes and no formatter runs', async () => {
  const { trace, bySlug } = await single([finding('src/parent.js')], {
    ...cureOver,
    'cure:parent': (call) => (call.opts.label === 'cure:parent' ? { status: 'ok', head_sha: CURE_SHA, artifact: '.cheese/cure/x.md' } : fullCure),
  })
  assert.equal(callsOf(trace, 'cure:parent:redo1').length, 1)
  assert.equal(callsOf(trace, 'cure:parent:repair1').length, 0)
  assert.equal(bySlug.parent.status, 'clean')
})

test('pass2 #3: a stopped cure answer stays valid without committed and does not redo', async () => {
  const { trace, bySlug } = await single([finding('src/parent.js')], {
    ...cureOver,
    'cure:parent': { status: 'blocked', reason: 'cannot apply' },
  })
  assert.deepEqual(trace.agents.filter(({ opts }) => opts.label.startsWith('cure:')).map(({ opts }) => opts.label), ['cure:parent'])
  assert.equal(bySlug.parent.status, 'failed')
  assert.match(bySlug.parent.excluded_reason, /cure stopped: blocked/)
})

test('pass2 #3: a corrective answer without committed is a substance error, so the writer redoes', async () => {
  const { trace } = await single([], {
    'taste:parent': reviseTaste,
    'taste:parent:r1': taste,
    'correct:parent:r1': (call) => (call.opts.label === 'correct:parent:r1'
      ? { status: 'fixed', head_sha: sha(0xc0a), worktree_path: SCRATCH('correct-parent'), summary: 'tidied' }
      : { status: 'fixed', committed: true, head_sha: sha(0xc0a), worktree_path: SCRATCH('correct-parent'), summary: 'tidied' }),
  })
  assert.equal(callsOf(trace, 'correct:parent:r1:redo1').length, 1)
  assert.equal(callsOf(trace, 'correct:parent:r1:repair1').length, 0)
})

test('pass2 #4: a padded base_sha from the resolver is trimmed and needs no redo', async () => {
  const { result, trace } = await single([], { resolve: resolvedFor(['parent'], ` ${BASE_SHA}\n`) })
  assert.deepEqual(trace.agents.filter(({ opts }) => opts.label.startsWith('resolve')).map(({ opts }) => opts.label), ['resolve'])
  assert.equal(result.integration.base_sha, BASE_SHA)
})

test('pass2 #5: cleanup records the checkpoint of a partial cook that a continuation replaced', async () => {
  const checkpoint = sha(0xcc)
  const { trace } = await single([], {
    'cook:parent': { status: 'partial', checkpoint, completed: 'half', remaining: 'rest', source_ranges: [], worktree_path: SCRATCH('cook-parent-p1') },
    'cook:parent:c1': cookOk('parent'),
  })
  assert.ok(recordedOf(trace).includes(checkpoint), 'partial checkpoint recorded')
})

test('pass2 #6: a "blocked: <reason>" taste answer fails the curd with the reason', async () => {
  const { bySlug } = await single([], { 'taste:parent': { status: 'blocked: spec unreadable' } })
  assert.equal(bySlug.parent.status, 'failed')
  assert.match(bySlug.parent.excluded_reason, /taste reviewer is blocked: spec unreadable/)
})

test('pass2 #7: the taste prompt tells the tester to run its own seven lenses', async () => {
  const { trace } = await single()
  const prompt = callsOf(trace, 'taste:parent')[0].prompt
  assert.match(prompt, /seven lenses/)
  assert.doesNotMatch(prompt, /5-lens/)
  assert.ok(prompt.includes('## Contract'))
})

test('pass2 #9: an unowned contained low makes the curd dirty without reporting medium+', async () => {
  const { bySlug } = await single([finding('src/elsewhere.js', { severity: 'low', fix_cost_now: 'contained' })])
  assert.equal(bySlug.parent.status, 'dirty')
  assert.equal(bySlug.parent.age.has_medium_plus_findings, false)
})

test('pass2 #9: an unowned medium finding reports medium+ only on curds in the integrated diff', async () => {
  const { bySlug } = await fanOut({ 'cook:b': { status: 'blocked', reason: 'nope' }, integrate: integrateResult({ merged: ['a'], files_by_slug: { a: ['src/a.js'] } }) }, [finding('src/elsewhere.js')])
  assert.equal(bySlug.a.age.has_medium_plus_findings, true)
  assert.equal(bySlug.b.status, 'failed')
  assert.equal(bySlug.b.age.has_medium_plus_findings, false)
})

// A finding field is a review fact. A formatter cannot know it, so a bad field makes the reviewer answer again.
// The runtime schema rejects a missing required key and the workflow retries. A code check catches the enum errors and the workflow redoes.
const without = (f, key) => Object.fromEntries(Object.entries(f).filter(([k]) => k !== key))
const badFindings = {
  'a finding without file': [[without(finding('src/parent.js'), 'file')], 'retry1'],
  'a finding without severity': [[without(finding('src/parent.js'), 'severity')], 'retry1'],
  'a finding with an out-of-enum severity': [[finding('src/parent.js', { severity: 'critical' })], 'redo1'],
  'a finding with an out-of-enum fix_cost_now': [[finding('src/parent.js', { fix_cost_now: 'huge' })], 'redo1'],
}
const smallIntegrate = { ...integrateResult({ merged: ['parent'], files_by_slug: { parent: ['src/parent.js'] } }), files_changed: 1, lines_changed: 10 }
const cleanAge = ageResult({ reviewed: ['parent'] })

for (const [name, [findings, again]] of Object.entries(badFindings)) {
  test(`finding facts: ${name} makes the single reviewer answer again and no formatter runs`, async () => {
    const { trace, bySlug } = await run(['parent'], {
      integrate: smallIntegrate,
      'age:barrier': (call) => (call.opts.label === 'age:barrier' ? { ...cleanAge, has_medium_plus_findings: true, findings } : cleanAge),
    })
    assert.equal(callsOf(trace, `age:barrier:${again}`).length, 1)
    assert.equal(callsOf(trace, 'age:barrier:repair1').length, 0)
    assert.equal(bySlug.parent.status, 'clean')
  })

  test(`finding facts: ${name} from the fan-out falls back to the single reviewer`, async () => {
    const { trace } = await run(['parent'], {
      integrate: integrateResult({ merged: ['parent'], files_by_slug: { parent: ['src/parent.js'] } }),
      'age:barrier': cleanAge,
    }, { ...cleanAge, has_medium_plus_findings: true, findings })
    assert.equal(callsOf(trace, 'age:barrier').length, 1)
    assert.ok(trace.logs.some((l) => l.includes('age-fanout unavailable')))
    assert.equal(trace.agents.filter(({ opts }) => /:repair\d+$/.test(opts.label)).length, 0)
  })
}
