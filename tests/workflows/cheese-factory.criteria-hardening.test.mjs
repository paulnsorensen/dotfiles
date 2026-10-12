import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime } from './cheese-factory.fixtures.mjs'
import { loadWorkflow } from './harness.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/cheese-factory.js')

// Defect proofs for the criteria gate. Each test fails against HEAD d642b116 and states the intended behavior.

const sha = (n) => n.toString(16).padStart(40, '0')
const HEAD = sha(0x1ead)
const crit = (id, over = {}) => ({ id, statement: `statement ${id}`, check_kind: 'command', check: 'test -e src/parent.js', ...over })
const resolved = (spec_text) => ({ mode: 'resolved', base_sha: sha(0xba5e), spec_path: '/specs/parent.md', spec_text, curd_count: { slug: 'parent', candidate_curds: 1, blast_radius: 'medium' } })

function table(over) {
  const base = {
    resolve: () => resolved('- AC-1: THE SYSTEM SHALL y.\n'),
    criteria: () => ({ criteria: [crit('AC-1')] }),
    'advise:plan': () => ({ verdict: 'approve', concerns: [], guidance: '' }),
    'cook:parent': () => ({ status: 'ok', head_sha: sha(1), worktree_path: '/tmp/worktrees/parent', artifact: '.cheese/cook/parent.md', orientation: 'x' }),
    'taste:parent': () => ({ verdict: 'pass', lenses: [{ lens: 'drift', verdict: 'pass', note: '' }], issues: [], recommendation: 'pass' }),
    'press:parent': () => ({ status: 'ok', head_sha: sha(2), artifact: '.cheese/press/parent.md', orientation: 'x' }),
    integrate: () => ({ worktree_path: '/repo/.claude/worktrees/integration', merged: ['parent'], conflicted: [], head: HEAD, files_by_slug: { parent: ['src/parent.js'] }, files_changed: 1, lines_changed: 1 }),
    'age:barrier': () => ({ status: 'ok', artifact: '.cheese/age/barrier.md', has_medium_plus_findings: false, findings: [], reviewed_slugs: ['parent'] }),
    'verify:AC-1': () => ({ criterion: 'AC-1', passes: true, evidence: 'exit 0', tree_clean: true, missing_paths: [] }),
    'advise:done': () => ({ verdict: 'approve', concerns: [], guidance: '' }),
    plate: () => ({ results: [{ slug: 'parent', status: 'ok', pr_url: 'https://example.test/pr/parent' }] }),
    cleanup: () => ({ removed: [] }),
    ...over,
  }
  return ({ opts }) => {
    const fn = base[opts.label.replace(/(:(redo|repair|retry)\d+)+$/, '')]
    if (!fn) throw new Error(`unexpected agent ${opts.label}`)
    return fn()
  }
}

async function run(over) {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({ respond: table(over) })
  const result = await workflow.run({ ...globals, args: { spec: 'parent' } })
  return { result, trace, logs: trace.logs }
}

const rejects = (check, kind = 'command') => async () => {
  const { result, trace } = await run({ criteria: () => ({ criteria: [crit('AC-1', { check_kind: kind, check })] }) })

  assert.ok(result.error, `check was accepted: ${check}`)
  assert.equal(trace.agents.some(({ opts }) => opts.label.startsWith('cook:')), false)
}

// DEFECT 1 (medium, certain): UNSAFE_CHECKS output-redirection regex is /\>(?!&|\s*\/dev\/null)/ (cheese-factory.js:1043).
// `>&file` is a bash redirect of stdout and stderr into `file`, and the lookahead skips every `>&`.
test('defect_checkCriteria_redirectAmpersandToFile_shouldBeRejected', rejects('echo x >&out.txt'))

// DEFECT 2 (medium, certain): the same lookahead accepts any path that merely starts with /dev/null.
test('defect_checkCriteria_redirectToPathPrefixedDevNull_shouldBeRejected', rejects('echo x > /dev/null.bak'))

// DEFECT 3 (medium, speculative): the denylist has no entry for plain file-creating or moving commands.
// A verify judge runs the check in the shared integration worktree and later judges and Plate read that tree.
for (const [name, check] of [['touch', 'touch src/marker && test -e src/marker'], ['mkdir', 'mkdir -p out && test -d out'], ['cp', 'cp src/a.js src/b.js && test -e src/b.js'], ['mv', 'mv src/a.js src/b.js && test -e src/b.js'], ['git add', 'git add -A && test -e src/a.js'], ['chmod', 'chmod +x src/a.js && test -x src/a.js']]) {
  test(`defect_checkCriteria_${name}_shouldBeRejectedAsAMutation`, rejects(check))
}

// DEFECT 4 (medium, speculative): a check that always exits 0 passes the vacuity gate, which only inspects negated searches.
for (const [name, check] of [['or true', 'grep -q foo src/x.js || true'], ['bare true', 'true'], ['exit 0', 'test -e src/x.js; exit 0']]) {
  test(`defect_checkCriteria_${name}_shouldBeRejectedAsVacuous`, rejects(check))
}

// DEFECT 5 (medium, speculative): the AC regex has no notion of code fences, so an example `- AC-1:` line in a fenced block counts as a spec criterion.
test('defect_extract_acLineInsideCodeFence_shouldNotCountAsACriterion', async () => {
  const spec = '# Format\n\nWrite each criterion like this:\n\n```text\n- AC-1: WHEN x THE SYSTEM SHALL y.\n```\n'
  const { result, trace } = await run({ resolve: () => resolved(spec) })

  assert.equal(trace.agents.some(({ opts }) => opts.label.startsWith('criteria')), false)
  assert.equal(result.verification.status, 'skipped-no-criteria')
})

// DEFECT 6 (low, speculative): the judge reports tree_clean false when an earlier check dirtied the shared worktree.
// move-my-cheese logs this and annotates the evidence (move-my-cheese.js:1181-1182); cheese-factory drops it silently.
test('defect_verify_treeCleanFalse_shouldBeSurfacedInLogsOrEvidence', async () => {
  const { result, logs } = await run({ 'verify:AC-1': () => ({ criterion: 'AC-1', passes: true, evidence: 'exit 0', tree_clean: false, missing_paths: [] }) })
  const surfaced = logs.some((l) => /clean|changes/.test(l) && /AC-1/.test(l)) || /worktree had changes/.test(result.verification.criteria[0].evidence)

  assert.equal(surfaced, true)
})
