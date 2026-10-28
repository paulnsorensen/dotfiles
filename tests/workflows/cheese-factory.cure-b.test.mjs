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

const finding = (file, { severity = 'medium', fix_cost_now = 'n/a', claim = 'a claim' } = {}) => ({
  dimension: 'correctness', severity, fix_cost_now, file, line: 1, claim, why_it_matters: 'matters', fix_direction: 'fix it',
})
const ageResult = ({ findings = [], reviewed = [] } = {}) => ({
  status: 'ok', artifact: '.cheese/age/barrier.md', has_medium_plus_findings: findings.some((f) => f.severity !== 'low'), findings, reviewed_slugs: reviewed,
})
const integrateResult = ({ merged, files_by_slug, head = sha(0x1ead), worktree_path = SCRATCH('integ') }) => ({
  worktree_path, merged, conflicted: [], head, files_by_slug, files_changed: 20, lines_changed: 900,
})
const cure = (committed) => ({ status: 'ok', committed, head_sha: CURE_SHA, artifact: '.cheese/cure/x.md' })
const phaseOk = (slug, phase) => ({ status: 'ok', head_sha: sha(2), artifact: `.cheese/${phase}/${slug}.md`, orientation: 'done' })
const cookOk = (slug) => ({ status: 'ok', head_sha: sha(1), worktree_path: SCRATCH(`cook-${slug}`), artifact: `.cheese/cook/${slug}.md`, orientation: 'implemented' })
const taste = () => ({ verdict: 'pass', lenses: [{ lens: 'drift', verdict: 'pass', note: '' }], issues: [], recommendation: 'pass' })

function respondFor(slugs, over) {
  const resolved = { mode: 'resolved', base_sha: BASE_SHA, spec_path: '/specs/parent.md', spec_text: 'spec body', curd_count: { slug: 'parent', candidate_curds: slugs.length > 1 ? 2 : 1, blast_radius: 'medium' } }
  const defaults = {
    resolve: resolved,
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

const single = (findings = []) => run(
  ['parent'],
  { integrate: integrateResult({ merged: ['parent'], files_by_slug: { parent: ['src/parent.js'] } }) },
  ageResult({ findings, reviewed: ['parent'] }),
)

test('#1: the plate prompt makes the coder read the plate SKILL.md and never says run /plate', async () => {
  const { trace } = await single()
  const prompt = callsOf(trace, 'plate')[0].prompt
  assert.match(prompt, /Single-pass mode/)
  assert.match(prompt, /~\/\.claude\/skills\/plate\/SKILL\.md/)
  assert.doesNotMatch(prompt, /run \/plate/)
  assert.match(prompt, /The Skill tool is not available to you/)
  assert.ok(prompt.indexOf('git rev-parse refs/heads/curd/<slug>') < prompt.indexOf('plate/SKILL.md'))
  assert.match(prompt, /NEVER merge/)
})

test('#1: the fan-out plate prompt reads the plate SKILL.md too', async () => {
  const slugs = ['a', 'b']
  const files = { a: ['src/a.js'], b: ['src/b.js'] }
  const { trace } = await run(slugs, { integrate: integrateResult({ merged: slugs, files_by_slug: files }) }, ageResult({ reviewed: slugs }))
  const prompt = callsOf(trace, 'plate')[0].prompt
  assert.match(prompt, /Fan-out mode/)
  assert.match(prompt, /~\/\.claude\/skills\/plate\/SKILL\.md/)
  assert.doesNotMatch(prompt, /run \/plate/)
  assert.match(prompt, /The Skill tool is not available to you/)
})

test('the fan-out plate prompt lets plate pick the PR topology and never requests a stack', async () => {
  const slugs = ['a', 'b']
  const files = { a: ['src/a.js'], b: ['src/b.js'] }
  const { trace } = await run(slugs, { integrate: integrateResult({ merged: slugs, files_by_slug: files }) }, ageResult({ reviewed: slugs }))
  const prompt = callsOf(trace, 'plate')[0].prompt
  assert.doesNotMatch(prompt, /stacked-PR chain/)
  assert.doesNotMatch(prompt, /Stack the verified branches/)
  assert.match(prompt, /Let the plate skill pick the PR topology/)
  assert.match(prompt, /Do not request a stack/)
})

test('#15: the plate prompt publishes only the pinned SHAs and stops on a dirty checkout', async () => {
  const { trace } = await single()
  const prompt = callsOf(trace, 'plate')[0].prompt
  assert.match(prompt, /git status --porcelain/)
  assert.match(prompt, /stop and return status blocked/)
  assert.match(prompt, /Publish only the pinned SHA/)
})

test('#14: cleanup drops --force, checks HEAD against recorded SHAs, and keeps branches', async () => {
  const { trace } = await single()
  const prompt = callsOf(trace, 'cleanup')[0].prompt
  assert.doesNotMatch(prompt, /worktree remove --force/)
  assert.match(prompt, /Never pass --force/)
  assert.match(prompt, /git -C <path> rev-parse HEAD/)
  assert.match(prompt, /keep every curd\/\* branch/)
  assert.ok(prompt.slice(prompt.indexOf('<data name="recorded_shas">')).includes(sha(2)))
})

test('#14: cleanup records the cook head and each corrective head', async () => {
  const CORRECTIVE_SHA = sha(0xc0a)
  let tastes = 0
  const { trace } = await run(['parent'], {
    integrate: integrateResult({ merged: ['parent'], files_by_slug: { parent: ['src/parent.js'] } }),
    'taste:parent': () => ({ verdict: 'revise', lenses: [{ lens: 'readability', verdict: 'revise', note: 'tidy' }], issues: ['tidy'], recommendation: 'revise' }),
    'correct:parent:r1': { status: 'fixed', committed: true, head_sha: CORRECTIVE_SHA, worktree_path: SCRATCH('correct-parent'), summary: 'tidied' },
    'taste:parent:r1': () => { tastes++; return taste() },
  }, ageResult({ reviewed: ['parent'] }))
  assert.equal(tastes, 1)
  const prompt = callsOf(trace, 'cleanup')[0].prompt
  const recorded = prompt.slice(prompt.indexOf('<data name="recorded_shas">'))
  assert.ok(recorded.includes(sha(1)), 'cook head recorded')
  assert.ok(recorded.includes(CORRECTIVE_SHA), 'corrective head recorded')
  assert.ok(recorded.includes(sha(2)), 'press head recorded')
})

test('#14: the taste prompt names the curd contract under a Contract heading', async () => {
  const { trace } = await single()
  const prompt = callsOf(trace, 'taste:parent')[0].prompt
  const section = prompt.slice(prompt.indexOf('## Contract'), prompt.indexOf('Diff under review'))
  assert.ok(prompt.includes('## Contract'))
  assert.match(section, /<data name="spec_path">\s*"\/specs\/parent\.md"/)
})

test('#14: the taste prompt for a fan-out curd names its mini-spec and brief', async () => {
  const slugs = ['a', 'b']
  const files = { a: ['src/a.js'], b: ['src/b.js'] }
  const { trace } = await run(slugs, { integrate: integrateResult({ merged: slugs, files_by_slug: files }) }, ageResult({ reviewed: slugs }))
  const prompt = callsOf(trace, 'taste:a')[0].prompt
  assert.match(prompt, /## Contract[\s\S]*"\/specs\/parent--a\.md"[\s\S]*"do a"[\s\S]*Diff under review/)
})

test('#14: cleanup does not run when a curd is dirty', async () => {
  const { trace, bySlug } = await single([finding('src/elsewhere.js')])
  assert.equal(bySlug.parent.status, 'dirty')
  assert.equal(callsOf(trace, 'cleanup').length, 0)
})

test('#3: a co-owner stays dirty when its owner is dirty only through the owner\'s own shared owner', async () => {
  const slugs = ['a', 'b', 'c']
  const files = { a: ['src/x.js'], b: ['src/x.js', 'src/y.js'], c: ['src/y.js'] }
  const { trace, bySlug } = await run(slugs, {
    integrate: integrateResult({ merged: slugs, files_by_slug: files }),
    'cure:a': cure(false),
    'cure:b': cure(true),
    're-merge': integrateResult({ merged: slugs, files_by_slug: files, head: NEW_HEAD, worktree_path: SCRATCH('remerge') }),
    'age:reage': ageResult({ reviewed: slugs }),
  }, ageResult({ reviewed: slugs, findings: [finding('src/x.js', { claim: 'F2' }), finding('src/y.js', { claim: 'F1' })] }))

  assert.equal(callsOf(trace, 'cure:c').length, 0)
  assert.equal(bySlug.a.status, 'dirty')
  assert.equal(bySlug.b.status, 'dirty')
  assert.equal(bySlug.c.status, 'dirty')
  assert.match(bySlug.b.excluded_reason, /owning curd did not commit.*owner a/)
  assert.match(bySlug.c.excluded_reason, /owner b/)
  assert.equal(callsOf(trace, 'plate').length, 0)
})

test('#3: the chain is clean when every owner in it is clean', async () => {
  const slugs = ['a', 'b', 'c']
  const files = { a: ['src/x.js'], b: ['src/x.js', 'src/y.js'], c: ['src/y.js'] }
  const { bySlug } = await run(slugs, {
    integrate: integrateResult({ merged: slugs, files_by_slug: files }),
    'cure:a': cure(true),
    'cure:b': cure(true),
    're-merge': integrateResult({ merged: slugs, files_by_slug: files, head: NEW_HEAD, worktree_path: SCRATCH('remerge') }),
    'age:reage': ageResult({ reviewed: slugs }),
  }, ageResult({ reviewed: slugs, findings: [finding('src/x.js'), finding('src/y.js')] }))

  assert.deepEqual(slugs.map((s) => bySlug[s].status), ['clean', 'clean', 'clean'])
})

test('#12: an unowned sprawling low needs no cure, so the curds stay clean and plate', async () => {
  const { trace, bySlug } = await single([finding('src/elsewhere.js', { severity: 'low', fix_cost_now: 'sprawling' })])
  assert.equal(bySlug.parent.status, 'clean')
  assert.equal(callsOf(trace, 'cure:parent').length, 0)
  assert.equal(callsOf(trace, 'plate').length, 1)
})

test('#20: an unowned medium finding makes the curd dirty and reports has_medium_plus_findings', async () => {
  const { bySlug } = await single([finding('src/elsewhere.js')])
  assert.equal(bySlug.parent.status, 'dirty')
  assert.equal(bySlug.parent.age.has_medium_plus_findings, true)
})
