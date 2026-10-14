import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow } from './harness.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/cheese-factory.js')

// Regression proofs for the criteria gate: each test states a behavior of the check gate or the verify path.

const sha = (n) => n.toString(16).padStart(40, '0')
const HEAD = sha(0x1ead)
const crit = (id, over = {}) => ({ id, statement: `statement ${id}`, check_kind: 'command', check: 'test -e src/parent.js', ...over })
const resolved = (spec_text) => ({ mode: 'resolved', base_sha: sha(0xba5e), spec_path: '/specs/parent.md', spec_text, curd_count: { slug: 'parent', candidate_curds: 1, blast_radius: 'medium' } })
const approve = () => ({ verdict: 'approve', concerns: [], guidance: '' })

function table(over) {
  const base = {
    resolve: () => resolved('- AC-1: THE SYSTEM SHALL y.\n'),
    ground: () => ({ decisions: [], prior_research: [], research_questions: [] }),
    criteria: () => ({ criteria: [crit('AC-1')] }),
    'advise:plan': approve,
    'advise:plan:r1': approve,
    'cook:parent': () => ({ status: 'ok', head_sha: sha(1), worktree_path: '/tmp/worktrees/parent', artifact: '.cheese/cook/parent.md', orientation: 'x' }),
    'taste:parent': () => ({ verdict: 'pass', lenses: [{ lens: 'drift', verdict: 'pass', note: '' }], issues: [], recommendation: 'pass' }),
    'press:parent': () => ({ status: 'ok', head_sha: sha(2), artifact: '.cheese/press/parent.md', orientation: 'x' }),
    integrate: () => ({ worktree_path: '/repo/.claude/worktrees/integration', merged: ['parent'], conflicted: [], head: HEAD, files_by_slug: { parent: ['src/parent.js'] }, files_changed: 1, lines_changed: 1 }),
    'age:barrier': () => ({ status: 'ok', artifact: '.cheese/age/barrier.md', has_medium_plus_findings: false, findings: [], reviewed_slugs: ['parent'] }),
    'verify:AC-1': () => ({ criterion: 'AC-1', passes: true, evidence: 'exit 0', tree_clean: true, missing_paths: [] }),
    'advise:done': approve,
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
  const started = performance.now()
  const result = await workflow.run({ ...globals, args: { spec: 'parent' } })
  return { result, trace, logs: trace.logs, ms: performance.now() - started }
}

const withCheck = (check, kind = 'command') => ({ criteria: () => ({ criteria: [crit('AC-1', { check_kind: kind, check })] }) })

const rejects = (check, kind = 'command', pattern = /check is unsafe|can pass without testing anything/) => async () => {
  const { result, trace } = await run(withCheck(check, kind))

  assert.match(result.error ?? '', pattern, `check was accepted: ${check}`)
  assert.equal(trace.agents.some(({ opts }) => opts.label.startsWith('cook:')), false)
}

const accepts = (check) => async () => {
  const { result } = await run(withCheck(check))

  assert.equal(result.error, undefined, `check was rejected: ${check}`)
}

// An output redirection of `>&file` writes stdout and stderr into the file.
test('checkCriteria_redirectAmpersandToFile_isRejected', rejects('echo x >&out.txt'))

// A path that merely starts with /dev/null is a file.
test('checkCriteria_redirectToPathPrefixedDevNull_isRejected', rejects('echo x > /dev/null.bak'))

// A verify judge runs the check in the shared integration worktree, so a check must not create or move files.
for (const [name, check] of [['touch', 'touch src/marker && test -e src/marker'], ['mkdir', 'mkdir -p out && test -d out'], ['cp', 'cp src/a.js src/b.js && test -e src/b.js'], ['mv', 'mv src/a.js src/b.js && test -e src/b.js'], ['git add', 'git add -A && test -e src/a.js'], ['chmod', 'chmod +x src/a.js && test -x src/a.js']]) {
  test(`checkCriteria_${name}_isRejectedAsAMutation`, rejects(check))
}

// The structural pre-filter and the command rules close the shapes that hide a mutation from the lexical denylist.
const BYPASSES = [
  ['eval', 'eval "touch src/marker"'],
  ['command substitution', 'test -e src/a.js && echo $(touch src/marker)'],
  ['braced expansion', 'test -e src/a.js && echo ${HOME}'],
  ['backticks', 'test -e src/a.js && echo `touch src/marker`'],
  ['backticks inside double quotes', 'test -e src/a.js && echo "`touch src/marker`"'],
  ['raw newline', 'test -e src/a.js\ntouch src/marker'],
  ['carriage return', 'test -e src/a.js\rtouch src/marker'],
  ['NAME= prefix', 'GIT_DIR=x test -e src/a.js'],
  ['absolute command path', '/bin/mv src/a.js src/b.js && test -e src/b.js'],
  ['relative command path', './scripts/check.sh'],
  ['brace group', '{ touch src/marker; }'],
  ['if then', 'if test -e src/a.js; then touch src/marker; fi'],
  ['while loop', 'while test -e src/a.js; do touch src/marker; done'],
  ['for loop', 'for f in src/*.js; do touch $f; done'],
  ['source', 'source scripts/env.sh && test -e src/a.js'],
  ['dot source', '. scripts/env.sh && test -e src/a.js'],
  ['exec', 'exec touch src/marker'],
  ['python -Bc', 'python3 -Bc "open(\'f\', \'w\')"'],
  ['python -c after other flag', 'python3 -I -c "print(1)"'],
  ['node -p', 'node -p "require(\'fs\').writeFileSync(\'f\', \'x\')"'],
  ['node --eval', 'node --eval "1"'],
  ['perl -E', 'perl -E "say 1"'],
  ['ruby -e', 'ruby -e "puts 1"'],
  ['awk system', 'awk \'BEGIN { system("touch src/marker") }\''],
  ['awk print to file', 'awk \'{ print $1 > "out.txt" }\' src/a.js'],
  ['awk getline pipe', 'awk \'BEGIN { "touch f" | getline }\''],
  ['bash -c', 'bash -c "touch src/marker"'],
  ['sh -lc', 'sh -lc "touch src/marker"'],
  ['zsh -c', 'zsh -c "touch src/marker"'],
  ['find -exec', 'find . -name x -exec touch {} +'],
  ['find -fprint', 'find . -fprint out.txt'],
  ['find -delete', 'find . -name x -delete'],
  ['sed w command', 'sed -n \'w out.txt\' src/a.js'],
  ['sed s///w', 'sed -n \'s/a/b/w out.txt\' src/a.js'],
  ['sed -i after other flag', 'sed -n -i s/a/b/ src/a.js'],
  ['git -c', 'git -c core.fsmonitor=touch status'],
  ['git --config-env', 'git --config-env=core.pager=X log'],
  ['git log --output', 'git log --output=out.txt'],
  ['git fetch', 'git fetch origin'],
  ['git pull', 'git pull'],
  ['git clone', 'git clone https://example.test/x.git'],
  ['git ls-remote', 'git ls-remote origin'],
  ['git push after global option', 'git -C . push'],
  ['npx --yes', 'npx --yes left-pad'],
  ['npm exec', 'npm exec left-pad'],
  ['pnpm dlx', 'pnpm dlx left-pad'],
  ['yarn install', 'yarn install'],
  ['pip install', 'pip install requests'],
  ['env wrapper', 'env mv src/a.js src/b.js'],
  ['timeout wrapper', 'timeout 5 touch src/marker'],
  ['xargs wrapper', 'echo src/a.js | xargs -I {} mv {} src/b.js'],
  ['heredoc', 'cat <<EOF\nx\nEOF'],
]
for (const [name, check] of BYPASSES) {
  test(`checkCriteria_bypass_${name.replaceAll(/\W+/g, '_')}_isRejected`, rejects(check, 'command', /check is unsafe/))
}

// Every read-only check shape keeps passing the gate.
const ACCEPTED = [
  'grep -q foo src/a.js',
  'rg -q foo src',
  'test -e src/a.js',
  '[ -e src/a.js ]',
  '[[ -d src ]]',
  'git log --oneline -5',
  'git diff --stat',
  'git show HEAD:src/a.js',
  'git status --porcelain',
  'git grep -q foo -- src',
  'git -C . log --oneline',
  'node --test tests/a.test.js',
  'just check',
  'npm test',
  'test -e src/a.js || test -e src/b.js',
  'test -e src/a.js 2>/dev/null && grep -q x src/a.js >/dev/null 2>&1',
  'grep -q \'a$\' src/a.js',
  'grep -q \'$(foo)\' src/a.js',
]
for (const check of ACCEPTED) test(`checkCriteria_readOnlyCheck_${check.replaceAll(/\W+/g, '_')}_isAccepted`, accepts(check))

// A redirect operator inside a quoted pattern is data, not a redirect.
for (const check of ["grep -q 'async () =>' src/a.js", "grep -q 'Map<string, number>' src/a.js", "awk '$1 > 3' src/a.js", 'grep -q "a > b" src/a.js']) {
  test(`checkCriteria_quotedRedirectCharacter_${check.replaceAll(/\W+/g, '_')}_isAccepted`, accepts(check))
}

test('checkCriteria_redirectToFile_errorNamesTheOffendingText', async () => {
  const { result } = await run(withCheck('test -e src/a.js && echo x > out.txt'))

  assert.match(result.error, /output redirection to a file/)
  assert.ok(result.error.includes('> out.txt'), result.error)
})

// A git subcommand lookup walks tokens, so a long option run costs linear time.
const manyOptions = Array.from({ length: 30 }, (_, i) => `--opt${i + 1}`).join(' ')

test('checkCriteria_gitLogWith30Options_isClassifiedWithin50ms', async () => {
  const { result, ms } = await run(withCheck(`git ${manyOptions} log --oneline`))

  assert.equal(result.error, undefined)
  assert.ok(ms < 50, `classification took ${ms} ms`)
})

test('checkCriteria_gitPushWith30Options_isRejectedWithin50ms', async () => {
  const { result, ms } = await run(withCheck(`git ${manyOptions} push`))

  assert.match(result.error, /git mutation/)
  assert.ok(ms < 50, `classification took ${ms} ms`)
})

// A check that always exits 0 proves nothing, whatever form the always-pass tail takes.
const ALWAYS_PASS = [
  ['or true', 'grep -q foo src/x.js || true'],
  ['bare true', 'true'],
  ['exit 0', 'test -e src/x.js; exit 0'],
  ['or echo', 'grep -q foo src/x.js || echo missing'],
  ['or colon', 'grep -q foo src/x.js || :'],
  ['semicolon echo', 'test -e src/x.js; echo done'],
  ['pipe into wc', 'grep -q foo src/x.js | wc -l'],
  ['pipe into cat', 'grep foo src/x.js | cat'],
  ['pipe into true', 'grep -q foo src/x.js | true'],
  ['pipe into head after and', 'test -e src/x.js && git log --oneline | head -1'],
  ['bare echo', 'echo ok'],
  ['bare printf', 'printf ok'],
  ['subshell exit 0', '( exit 0 )'],
  ['true and true', 'true && true'],
  ['all constant', 'echo a && echo b'],
  ['exit 0 with redirect', 'exit 0 2>/dev/null'],
  ['exit with no code', 'test -e src/x.js; exit'],
  ['trailing background', 'test -e src/x.js & echo ok'],
]
for (const [name, check] of ALWAYS_PASS) {
  test(`checkCriteria_alwaysPass_${name.replaceAll(' ', '_')}_isRejectedAsVacuous`, rejects(check, 'command', /can pass without testing anything/))
}

test('checkCriteria_alwaysPassWithNewlineTail_isRejected', rejects('test -e src/x.js\necho ok'))

test('checkCriteria_andChainEndingInEcho_isAccepted', accepts('grep -q foo src/x.js && echo found'))

// A fenced example line `- AC-1:` is not a spec criterion.
test('extract_acLineInsideCodeFence_doesNotCountAsACriterion', async () => {
  const spec = '# Format\n\nWrite each criterion like this:\n\n```text\n- AC-1: WHEN x THE SYSTEM SHALL y.\n```\n'
  const { result, trace } = await run({ resolve: () => resolved(spec) })

  assert.equal(trace.agents.some(({ opts }) => opts.label.startsWith('criteria')), false)
  assert.equal(result.verification.status, 'skipped-no-criteria')
})

// The judge reports tree_clean false when an earlier check dirtied the shared worktree; the run surfaces that in the logs or the evidence.
test('verify_treeCleanFalse_isSurfacedInLogsOrEvidence', async () => {
  const { result, logs } = await run({ 'verify:AC-1': () => ({ criterion: 'AC-1', passes: true, evidence: 'exit 0', tree_clean: false, missing_paths: [] }) })
  const surfaced = logs.some((l) => /clean|changes/.test(l) && /AC-1/.test(l)) || /worktree had changes/.test(result.verification.criteria[0].evidence)

  assert.equal(surfaced, true)
})
