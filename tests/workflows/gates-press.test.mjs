import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test, { after } from 'node:test'
import { fileURLToPath } from 'node:url'
import { createContext, runInContext, runInNewContext } from 'node:vm'

const repo = fileURLToPath(new URL('../../', import.meta.url))
const syncScript = join(repo, 'claude/workflow-prelude/sync.mjs')
const read = (rel) => readFileSync(join(repo, rel), 'utf8')
const NL = String.fromCharCode(10)
const CR = String.fromCharCode(13)
const BT = String.fromCharCode(96)
const BS = String.fromCharCode(92)
const NAMES = ['validGroundedRange', 'groundedRanges', 'mergeCoupledCurds', 'routeFindings', 'unsafeCheck', 'commandHit', 'normalizeFile']
const GLOBALS = ['agent', 'parallel', 'pipeline', 'phase', 'log', 'workflow', 'args', 'budget', 'Date', 'Math']
const GATES_BEGIN = '// BEGIN shared gates'
const GATES_END = '// END shared gates'

const gatesSource = read('claude/workflow-prelude/gates.js')
const preludeSource = read('claude/workflow-prelude/prelude.js')
const factory = read('claude/workflows/cheese-factory.js')
const board = read('claude/workflows/cheese-board.js')
const g = runInNewContext(`${preludeSource}${NL}${gatesSource}${NL};({ ${NAMES.join(', ')} })`, {})
const j = (v) => JSON.parse(JSON.stringify(v))

const roots = []
after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

// A temp dir with a cheese-factory.js copy and copies of both sources.
function fixture({ gates = gatesSource, prelude = preludeSource, factoryText = factory } = {}) {
  const d = mkdtempSync(join(tmpdir(), 'gates-press-'))
  roots.push(d)
  const p = { dir: d, factory: join(d, 'cheese-factory.js'), gates: join(d, 'gates.js'), prelude: join(d, 'prelude.js') }
  writeFileSync(p.factory, factoryText)
  writeFileSync(p.gates, gates)
  writeFileSync(p.prelude, prelude)
  return p
}
const sync = (p, flags = [], files = [p.factory]) =>
  spawnSync(process.execPath, [syncScript, ...flags, '--source', p.prelude, '--gates-source', p.gates, ...files], { encoding: 'utf8' })
const markerLines = (text) => {
  const lines = text.split(NL)
  return { lines, bi: lines.findIndex((l) => l.startsWith(GATES_BEGIN)), ei: lines.findIndex((l) => l === GATES_END) }
}

test('sync --check exits 0 on an untouched copy and 1 naming only the gates block when gates.js changes', () => {
  const p = fixture()
  assert.equal(sync(p, ['--check']).status, 0)
  writeFileSync(p.gates, gatesSource + 'const addedByPress = 1' + NL)
  const r = sync(p, ['--check'])
  assert.equal(r.status, 1)
  assert.ok(r.stderr.includes('shared gates block differs'), r.stderr)
  assert.ok(!r.stderr.includes('shared prelude block'), r.stderr)
  assert.equal(readFileSync(p.factory, 'utf8'), factory)
})

test('sync --check names only the prelude block when prelude.js changes', () => {
  const p = fixture()
  writeFileSync(p.prelude, preludeSource + 'const addedByPress = 1' + NL)
  const r = sync(p, ['--check'])
  assert.equal(r.status, 1)
  assert.ok(r.stderr.includes('shared prelude block differs'), r.stderr)
  assert.ok(!r.stderr.includes('shared gates block'), r.stderr)
})

const { lines: factoryLines, bi, ei } = markerLines(factory)
const brokenMarkers = {
  'missing begin': factoryLines.filter((_, i) => i !== bi),
  'missing end': factoryLines.filter((_, i) => i !== ei),
  'duplicated begin': [...factoryLines.slice(0, ei), factoryLines[bi], ...factoryLines.slice(ei)],
  'duplicated end': [...factoryLines.slice(0, ei + 1), factoryLines[ei], ...factoryLines.slice(ei + 1)],
  'out of order': factoryLines.map((l, i) => (i === bi ? factoryLines[ei] : i === ei ? factoryLines[bi] : l)),
  'indented begin': factoryLines.map((l, i) => (i === bi ? '  ' + l : l)),
}
for (const [name, lines] of Object.entries(brokenMarkers)) {
  test(`sync refuses a cheese-factory.js with a gates marker that is ${name}, in check and in write mode`, () => {
    const broken = lines.join(NL)
    const p = fixture({ factoryText: broken, prelude: preludeSource + 'const drift = 1' + NL })
    for (const flags of [['--check'], []]) {
      const r = sync(p, flags)
      assert.equal(r.status, 1, `${flags}: ${r.stderr}`)
      assert.ok(r.stderr.includes('expected exactly one') && r.stderr.includes(GATES_BEGIN), r.stderr)
    }
    // A bad input must leave every target unchanged, even where the prelude block would update.
    assert.equal(readFileSync(p.factory, 'utf8'), broken)
  })
}

const markerSources = {
  'bare begin': GATES_BEGIN,
  'begin with a note': GATES_BEGIN + ': note',
  'end': GATES_END,
  'end with a carriage return': GATES_END + CR,
}
for (const [name, marker] of Object.entries(markerSources)) {
  test(`sync refuses a gates.js that contains a ${name} marker line`, () => {
    const p = fixture({ gates: gatesSource + marker + NL })
    for (const flags of [['--check'], []]) {
      const r = sync(p, flags)
      assert.equal(r.status, 1, r.stderr)
      assert.ok(r.stderr.includes('marker line') && r.stderr.includes(p.gates), r.stderr)
    }
    assert.equal(readFileSync(p.factory, 'utf8'), factory)
  })
}

test('sync treats an indented marker in gates.js as data and stays stable', () => {
  const p = fixture({ gates: gatesSource + '  ' + GATES_END + NL })
  assert.equal(sync(p).status, 0)
  assert.equal(sync(p, ['--check']).status, 0)
  assert.equal(markerLines(readFileSync(p.factory, 'utf8')).lines.filter((l) => l === GATES_END).length, 1)
})

// A source that carries the other block's marker would corrupt the target on the next sync.
for (const [name, mk] of [['prelude.js', GATES_END], ['gates.js', '// END shared prelude']]) {
  test(`REAL BUG? sync refuses ${name} when it contains the other block's marker line`, () => {
    const p = fixture(name === 'prelude.js' ? { prelude: preludeSource + mk + NL } : { gates: gatesSource + mk + NL })
    const r = sync(p)
    const after = readFileSync(p.factory, 'utf8')
    assert.equal(r.status, 1, `sync wrote a factory with duplicate markers: ${r.stdout}`)
    assert.equal(after, factory)
  })
}

test('sync writes a drifted gates block back, then is idempotent and passes --check', () => {
  const drifted = factory.replace(GATES_END, 'const drift = 1' + NL + GATES_END)
  assert.notEqual(drifted, factory)
  const p = fixture({ factoryText: drifted })
  const w = sync(p)
  assert.equal(w.status, 0, w.stderr)
  assert.equal(readFileSync(p.factory, 'utf8'), factory)
  const again = sync(p)
  assert.equal(again.status, 0)
  assert.equal(again.stdout, '')
  assert.equal(sync(p, ['--check']).status, 0)
})

test('sync pastes the gates block into cheese-factory.js and into no other workflow', () => {
  const p = fixture({ gates: gatesSource + 'const addedByPress = 1' + NL })
  const other = join(p.dir, 'cheese-board.js')
  writeFileSync(other, board)
  const w = sync(p, [], [p.factory, other])
  assert.equal(w.status, 0, w.stderr)
  assert.ok(readFileSync(p.factory, 'utf8').includes('const addedByPress = 1'))
  assert.equal(readFileSync(other, 'utf8'), board)
})

test('sync fails on a missing gates source and on --gates-source without a value', () => {
  const p = fixture()
  const gone = spawnSync(process.execPath, [syncScript, '--check', '--source', p.prelude, '--gates-source', join(p.dir, 'none.js'), p.factory], { encoding: 'utf8' })
  assert.equal(gone.status, 1)
  assert.ok(gone.stderr.includes('file not found'), gone.stderr)
  const bare = spawnSync(process.execPath, [syncScript, '--gates-source'], { encoding: 'utf8' })
  assert.equal(bare.status, 1)
  assert.ok(bare.stderr.includes('--gates-source needs a file'), bare.stderr)
})

test('the pasted blocks define every gates symbol in a vm context that holds only the workflow globals', () => {
  const lines = factory.split(NL)
  const slice = (from, to) => lines.slice(lines.findIndex((l) => l.startsWith(from)), lines.findIndex((l) => l === to) + 1).join(NL)
  const preludeBlock = slice('// BEGIN shared prelude', '// END shared prelude')
  const gatesBlock = slice(GATES_BEGIN, GATES_END)
  const context = createContext(Object.fromEntries(GLOBALS.map((n) => [n, undefined])), { codeGeneration: { strings: false, wasm: false } })
  runInContext(preludeBlock, context)
  runInContext(gatesBlock, context)
  const topLevel = gatesSource.split(NL).filter((l) => l.startsWith('const ') || l.startsWith('function ')).map((l) => l.replace(/^(?:const|function) ([A-Za-z0-9_]+).*$/, '$1'))
  assert.ok(topLevel.length > 30, `parsed ${topLevel.length} top-level names`)
  for (const name of topLevel) assert.notEqual(runInContext(`typeof ${name}`, context), 'undefined', name)
  assert.equal(runInContext(`normalizeFile('/home/u/repo/.claude/worktrees/agent-1/src/a.js')`, context), 'src/a.js')
  assert.equal(runInContext(`unsafeCheck('curl x').name`, context), 'command not on the read-only allowlist')
})

test('gates.js alone fails to load: it needs SCRATCH_PATH_SRC from the prelude block', () => {
  assert.throws(() => runInNewContext(gatesSource, {}), /SCRATCH_PATH_SRC/)
})

test('mergeCoupledCurds merges a dependency chain whatever the listing order', () => {
  const curds = [
    { slug: 'c', brief: 'C', files: ['c.js'], depends_on: ['b'] },
    { slug: 'x', brief: 'X', files: ['x.js'] },
    { slug: 'b', brief: 'B', files: ['b.js'], depends_on: ['a'] },
    { slug: 'a', brief: 'A', files: ['a.js'] },
  ]
  const out = g.mergeCoupledCurds(curds)
  assert.equal(out.length, 2)
  assert.deepEqual(j(out.find((o) => o.merged_from).merged_from).sort(), ['a', 'b', 'c'])
  assert.deepEqual(j(out.find((o) => !o.merged_from)).slug, 'x')
  assert.deepEqual(j(out.find((o) => o.merged_from).files).sort(), ['a.js', 'b.js', 'c.js'])
})

test('mergeCoupledCurds merges a dependency cycle into one group and terminates', () => {
  const out = g.mergeCoupledCurds([
    { slug: 'a', brief: 'A', files: ['a.js'], depends_on: ['b'] },
    { slug: 'b', brief: 'B', files: ['b.js'], depends_on: ['a'] },
    { slug: 's', brief: 'S', files: ['s.js'], depends_on: ['s'] },
  ])
  assert.equal(out.length, 2)
  assert.deepEqual(j(out[0].merged_from), ['a', 'b'])
  assert.equal(out[1].slug, 's')
  assert.equal(out[1].merged_from, undefined)
})

test('mergeCoupledCurds leaves curds apart when depends_on names an unknown slug, even a shared one', () => {
  const out = g.mergeCoupledCurds([
    { slug: 'a', brief: 'A', files: ['a.js'], depends_on: ['ghost'] },
    { slug: 'b', brief: 'B', files: ['b.js'], depends_on: ['ghost'] },
  ])
  assert.deepEqual(j(out.map((o) => o.slug)), ['a', 'b'])
  assert.ok(out.every((o) => o.merged_from === undefined))
})

test('mergeCoupledCurds puts file overlap and a dependency in one group, with one copy of each file', () => {
  const out = g.mergeCoupledCurds([
    { slug: 'a', brief: 'A', files: ['x.js', 'a.js'] },
    { slug: 'b', brief: 'B', files: ['x.js'] },
    { slug: 'c', brief: 'C', depends_on: ['b'] },
  ])
  assert.equal(out.length, 1)
  assert.deepEqual(j(out[0].merged_from), ['a', 'b', 'c'])
  assert.deepEqual(j(out[0].files).sort(), ['a.js', 'x.js'])
  assert.equal(out[0].brief, ['A', 'B', 'C'].join(NL + NL))
})

test('mergeCoupledCurds accepts curds without files or depends_on and an empty list', () => {
  assert.deepEqual(j(g.mergeCoupledCurds([])), [])
  const out = g.mergeCoupledCurds([{ slug: 'a', brief: 'A' }, { slug: 'b', brief: 'B' }])
  assert.equal(out.length, 2)
  assert.deepEqual(j(out[0].files), [])
})

test('routeFindings normalizes ./ prefixes, repeated ./, and any scratch worktree root', () => {
  const owners = { one: ['a.js', 'dir/b.js'] }
  const files = ['././a.js', './dir/b.js', '/h/u/repo/.claude/worktrees/agent-9/a.js', '/h/u/repo/.claude/worktrees/agent-9/./dir/b.js', ' a.js ']
  for (const file of files) {
    const out = g.routeFindings({ findings: [{ severity: 'high', file }] }, owners, ['one'], null)
    assert.equal(out.unrouted, false, file)
    assert.equal(out.bySlug.get('one').length, 1, file)
  }
  const own = '/h/u/repo/.claude/worktrees/own-1'
  const withTrailingSlash = g.routeFindings({ findings: [{ severity: 'high', file: own + '/a.js' }] }, owners, ['one'], own + '//')
  assert.equal(withTrailingSlash.bySlug.get('one')[0].file, 'a.js')
  const other = g.routeFindings({ findings: [{ severity: 'high', file: '/h/u/repo/.claude/worktrees/agent-9/a.js' }] }, owners, ['one'], own)
  assert.equal(other.bySlug.get('one')[0].file, 'a.js')
})

test('routeFindings does not strip a path that is not a scratch worktree', () => {
  const out = g.routeFindings({ findings: [{ severity: 'high', file: '/etc/a.js' }, { severity: 'high', file: '../a.js' }] }, { one: ['a.js'] }, ['one'], null)
  assert.equal(out.bySlug.size, 0)
  assert.equal(out.unrouted, true)
  assert.equal(out.unownedMedium, true)
})

test('routeFindings sends a two-owner finding to the first owner in slug order and shares it with the rest', () => {
  const result = { findings: [{ severity: 'medium', file: 'a.js', id: 1 }] }
  const out = g.routeFindings(result, { z: ['a.js'], m: ['a.js'], b: ['a.js'] }, ['b', 'z', 'm'], null)
  assert.deepEqual([...out.bySlug.keys()], ['b'])
  assert.deepEqual(j([...out.shared.keys()]), ['z', 'm'])
  assert.deepEqual(j([...out.shared.get('z')]), ['b'])
  assert.deepEqual(j([...out.shared.get('m')]), ['b'])
  assert.deepEqual(j(out.sharedFindings.get('m')), [{ severity: 'medium', file: 'a.js', id: 1 }])
  assert.equal(out.bySlug.get('b').length, 1)
  assert.equal(out.unrouted, false)
})

test('routeFindings: an unowned low that needs no cure stays out; an unowned contained low does not', () => {
  const owners = { one: ['a.js'] }
  for (const fix_cost_now of [undefined, 'large', 'trivial']) {
    const out = g.routeFindings({ findings: [{ severity: 'low', file: 'zzz.js', fix_cost_now }] }, owners, ['one'], null)
    assert.equal(out.unrouted, false, String(fix_cost_now))
    assert.equal(out.unownedMedium, false)
    assert.equal(out.bySlug.size, 0)
  }
  const contained = g.routeFindings({ findings: [{ severity: 'low', file: 'zzz.js', fix_cost_now: 'contained' }] }, owners, ['one'], null)
  assert.equal(contained.unrouted, true)
  assert.equal(contained.unownedMedium, false)
  const owned = g.routeFindings({ findings: [{ severity: 'low', file: 'a.js', fix_cost_now: 'contained' }] }, owners, ['one'], null)
  assert.equal(owned.bySlug.get('one').length, 1)
  const ignored = g.routeFindings({ findings: [{ severity: 'low', file: 'a.js', fix_cost_now: 'large' }] }, owners, ['one'], null)
  assert.equal(ignored.bySlug.size, 0)
})

test('routeFindings is unrouted when the result claims findings its list does not carry', () => {
  const owners = { one: ['a.js'] }
  const claimMedium = g.routeFindings({ has_medium_plus_findings: true, findings: [] }, owners, ['one'], null)
  assert.equal(claimMedium.unrouted, true)
  assert.equal(claimMedium.unownedMedium, true)
  const claimLows = g.routeFindings({ has_cheap_lows: true, findings: [{ severity: 'low', file: 'a.js', fix_cost_now: 'large' }] }, owners, ['one'], null)
  assert.equal(claimLows.unrouted, true)
  assert.equal(claimLows.unownedMedium, false)
  const honest = g.routeFindings({ has_medium_plus_findings: true, has_cheap_lows: true, findings: [{ severity: 'high', file: 'a.js' }, { severity: 'low', file: 'a.js', fix_cost_now: 'contained' }] }, owners, ['one'], null)
  assert.equal(honest.unrouted, false)
  assert.equal(honest.bySlug.get('one').length, 2)
})

const blocked = [
  // wrappers
  'env rm x', 'sudo touch f', 'nice -n 5 rm x', 'xargs rm', 'ls | xargs -I{} cp {} /tmp', 'xargs -n 1 rm', 'xargs -P4 -I % rm %',
  'timeout 5 sh -c x', 'timeout -s KILL 5 rm x', 'env FOO=1 sh -c x', 'sudo -u root sh -c x', 'sudo -- rm x', 'nohup sh -c x', 'time chmod 777 f',
  'env -i chmod 777 f', 'nice -n -5 chmod 777 f', 'command git commit -m x', 'sudo git config user.name x', 'env git push',
  // shell and interpreter code
  'sh -c x', 'bash -lc x', 'sh', 'zsh -s', 'node -e 1', 'node --eval=1', 'node --print 1', 'python -', 'python3 -c 1', 'perl -pi -e 1 f', 'ruby -e 1', 'deno eval 1', 'eval x', 'exec ls', 'source x', '. x', './run.sh', '/bin/ls',
  // quoting tricks
  `c${'"'}ur${'"'}l example.com`, `'curl' example.com`, `c${BS}url example.com`, '/usr/bin/curl x', 'CURL x', 'echo x; rm y',
  `echo ${'"'}x${'"'} > f`, `echo '>' > f`, `echo '${BS}' > f`, `echo 'abc > f`, 'echo hi >> f', 'echo hi > /dev/nullx', 'echo hi > /dev/null/../f', `echo '>' ; chmod 600 f`,
  // expansion, substitution, newlines, here documents
  'echo $HOME', `echo ${'"'}$HOME${'"'}`, `echo ${'"'}$(id)${'"'}`, `echo ${BT}id${BT}`, `echo ${'"'}${BT}id${BT}${'"'}`, `echo ${'"'}x${'"'}${NL}rm y`, 'ls' + CR, 'cat <<EOF', 'cat <<-EOF', 'FOO=1 ls', '! rm x',
  // git
  'git config user.name x', 'git -c core.pager=sh log', 'git -ccore.pager=sh log', 'git --config-env=a=B log', 'git fetch', 'git ls-remote', 'git push', 'git clone u', 'git -C /tmp commit -m x', 'git diff --output=x', 'git log --output=x', 'git grep -O x', 'git branch -D x', 'git branch -m x', 'git branch --delete x', 'git stash', 'git worktree add x', 'git checkout x', 'git submodule update',
  // sed, awk, find
  'sed -i s/a/b/ f', 'sed --in-place=.bak s/a/b/ f', 'sed -ni p f', 'sed -f script f', 'sed --file=x f', `sed 's/a/b/w out' f`, `sed -n 'w out' f`, `sed -e '1e id' f`, 's' + 'ed s/a/b/e f',
  `awk 'BEGIN{system(${'"'}id${'"'})}'`, `awk ${'"'}BEGIN{system(${BS}${'"'}id${BS}${'"'})}${'"'}`, `awk '{ system ( ${'"'}x${'"'}) }'`, `awk 'BEGIN { ${'"'}date${'"'} | getline d }'`, `awk '{print > ${'"'}x${'"'}}'`, `awk '{print | ${'"'}sh${'"'}}'`, 'gawk -f x', 'mawk -f x', 'awk -i inplace 1 f', 'awk -l ext 1 f',
  'find . -delete', 'find . -exec rm {} ;', 'find . -execdir ls ;', 'find . -fprint x', 'find . -ok ls ;',
  // network and package fetch
  'wget x', 'nc -z h 1', 'ssh h', 'rsync a b', 'socat a b', 'npx foo', 'npm install', 'npm i', 'pnpm dlx x', 'bun x y', 'pip install x', 'uvx tool', 'cargo publish',
  // sequencing
  'ls; rm x', 'ls && touch f', 'true || mkdir d', 'ls & chmod 1 f', 'cat f | tee g', 'ls | sh', '(rm x)', '(mkdir d)', 'ls |& sh',
  // other mutation
  'dd if=a of=b', 'shred f', 'ln -s a b', 'patch -p1', 'gh pr merge 1', 'gh api x -X POST', 'gh api x -f a=b', 'npm run lint', 'python script.py',
]
const allowed = [
  'test -e a.js && git status', 'grep -n foo src/a.js | head -5', 'git diff --stat 5ae89056..HEAD', 'node --test tests/workflows/', 'just lint-shell', 'ls -la | wc -l', 'git log --oneline -5',
  'git status', 'git -C /tmp status', 'git --git-dir=x status', 'git branch --list', 'git branch -a', 'git branch --show-current', 'git branch -vv', 'git diff --name-only', 'git show HEAD:a.js',
  'rg foo src', `rg ${'"'}foo|bar${'"'} src`, 'jq . package.json', 'echo hi 2>&1', 'ls > /dev/null', 'ls >/dev/null; echo x', 'ls 2>&-', 'test -f x || echo missing', 'npm test', 'npm run test', 'python3 -m pytest',
  'find . -name x', 'sed -n 1,5p f', `sed -n '/warn/p' f`, 'sed y/abc/xyz/ f', `awk '{print $1}' f`, `awk -F: '{print $1}' f`, 'sed s/a/b/ f',
  // quoted metacharacters are data
  `echo ${'"'}a > b${'"'}`, `echo '>' x`, `grep ';' f`, `grep 'a|b' f`, `echo '$(id)'`, `echo '$HOME'`, `echo '${BT}id${BT}'`, `echo '<<'`, `echo 'a; rm'`, `echo ${BS}> f`, `echo ${BS}$HOME`,
]
for (const check of blocked) {
  test(`unsafeCheck blocks ${JSON.stringify(check)}`, () => {
    const out = g.unsafeCheck(check)
    assert.ok(out && typeof out.name === 'string' && out.name.length > 0, `not blocked: ${JSON.stringify(check)}`)
  })
}
for (const check of allowed) {
  test(`unsafeCheck allows ${JSON.stringify(check)}`, () => {
    assert.equal(g.unsafeCheck(check), null)
  })
}

// Each wrapper below sits in WRAPPERS, but its option value is not skipped, so the real command is missed.
const wrapperBypasses = [
  ["env -S takes a command string", `env -S 'chmod 777 f'`],
  ['timeout --signal KILL (long option with a separate value)', 'timeout --signal KILL 5 chmod 777 f'],
  ['sudo --user root (long option with a separate value)', 'sudo --user root chmod 777 f'],
  ['doas -u root', 'doas -u root chmod 777 f'],
  ['stdbuf -o L', 'stdbuf -o L chmod 777 f'],
  ['xargs --max-args 1', 'xargs --max-args 1 chmod 777'],
]
for (const [name, check] of wrapperBypasses) {
  test(`REAL BUG: unsafeCheck blocks a wrapper bypass: ${name}`, () => {
    assert.ok(g.unsafeCheck(check), `bypass: ${check}`)
  })
}

test('unsafeCheck reports a stable category for representative bypass attempts', () => {
  const name = (c) => g.unsafeCheck(c)?.name
  assert.equal(name('env rm x'), 'command not on the read-only allowlist')
  assert.equal(name('xargs rm'), 'command not on the read-only allowlist')
  assert.equal(name('sh -c x'), 'command not on the read-only allowlist')
  assert.equal(name('git config user.name x'), 'git mutation')
  assert.equal(name('git -c core.pager=sh log'), 'git config override')
  assert.equal(name('git diff --output=x'), 'git option that writes a file or runs a program')
  assert.equal(name('sed -i s/a/b/ f'), 'in-place edit')
  assert.equal(name(`awk 'BEGIN{system(${'"'}id${'"'})}'`), 'awk program that writes or runs a command')
  assert.equal(name('echo $HOME'), 'shell expansion or substitution')
  assert.equal(name('cat <<EOF'), 'here document')
  assert.equal(name('ls' + NL + 'ls'), 'raw newline or carriage return')
  assert.equal(name('ls # x'), 'shell comment')
  assert.equal(name('ls {a,b}'), 'brace expansion')
})

test('the allowlist reason names the head that is not allowed', () => {
  const reason = (c) => { const h = g.unsafeCheck(c); return [h?.name, h?.text] }
  assert.deepEqual(reason('ls; rm x'), ['command not on the read-only allowlist', 'rm'])
  assert.deepEqual(reason('NICE -n 5 touch x'), ['command not on the read-only allowlist', 'touch'])
  assert.deepEqual(reason('ENV touch x'), ['command not on the read-only allowlist', 'touch'])
})

test('no top-level gates.js name is declared again in cheese-factory.js outside the gates block', () => {
  const names = gatesSource.split(NL).filter((l) => /^(?:const|let|var|function) /.test(l)).map((l) => l.replace(/^(?:const|let|var|function) ([A-Za-z0-9_$]+).*$/, '$1'))
  assert.ok(names.length > 30, `parsed ${names.length} names`)
  assert.equal(new Set(names).size, names.length, 'gates.js declares a name twice')
  const lines = factory.split(NL)
  const outside = [...lines.slice(0, lines.findIndex((l) => l.startsWith(GATES_BEGIN))), ...lines.slice(lines.findIndex((l) => l === GATES_END))]
  const dupes = outside.filter((l) => names.some((n) => new RegExp(`^(?:export )?(?:async )?(?:const|let|var|function\\*?) ${n}\\b`).test(l)))
  assert.deepEqual(dupes, [])
})

// These bypasses of the command gate stay closed. The allowlist flags each one.
const DQ = '"'
const gateBypassesFlagged = [
  `git push --force origin main #'`, `shred -u secret #'`, 'cat <(git push origin main)', 'f()(git reset --hard);f', `busybox sh -c 'git push'`, 'flock /tmp/l git push',
  'watch rm x', 'script -c x f', 'chroot / sh',
  `env -S${DQ}touch foo${DQ}`, `env '-Schmod 777 file'`, `env -vS ${DQ}touch x${DQ}`, `env -iS${DQ}mkdir d${DQ}`, `env -S ${DQ}FOO=1 mkdir x${DQ}`,
  `sed 's#a#chmod 777 file#e' input`, `sed 's|a|b|w out' input`,
  'gh --repo owner/repo pr merge 1', 'gh -R owner/repo issue close 1',
  'git branch injected', 'git branch -u origin/x', 'git branch --list --force x',
  'ionice -t mkdir build', 'echo d | xargs --eof mkdir',
  'git remote set-url origin x', 'git merge-file a b c', 'git update-index --skip-worktree f', 'git symbolic-ref HEAD refs/heads/x', 'git hash-object -w f', 'git reflog expire --all', 'git lfs pull',
  'go install x@latest', 'brew install foo', 'Git push origin main', 'Sudo rm x',
  // brace and glob forms, quoted heads
  'ls {a,b}', 'ls {1..3}', 'cat {a,b}.js', 'git st*', 'gh pr v* 1', 'l* -l', `'gh' pr merge 1`, `g${DQ}h${DQ} pr merge 1`, `${DQ}tee${DQ} f`, `t'ee' f`, 'echo x | tee f',
  // gh forms
  'gh pr -R o/r merge 1', 'gh --repo o/r api repos/o/r -X PATCH -f description=x', 'gh api repos/o/r --method=DELETE', 'gh api repos/o/r -XPOST', 'gh api repos/o/r --input f',
  // wrappers
  'echo push | xargs git', `env -S '${DQ}chmod${DQ} 777 file'`, 'parallel rm ::: x', 'taskset 1 touch x', 'chrt 1 touch x', 'uv run touch x', 'strace touch x', 'unbuffer touch x', 'caffeinate touch x', 'NICE -n 5 touch x', 'ENV touch x',
  // sed programs that write or run
  `sed -n '1w out' f`, `sed 's/a/b/;w out' f`, `sed -e 'e id' f`, `sed 's/a/b/e' f`, `sed -n '/x/W out' f`, `sed --expression='1e id' f`,
  // output files and other writers
  'sort -o out f', 'sort f -o out', 'sort --output=out f', 'uniq in out', 'gzip f', 'tar xf a.tar', 'split f', 'yq -i . f', 'cargo fmt',
  // git subcommands that write
  'git repack', 'git credential approve', 'git unpack-file x', 'git rerere', 'git pack-refs', 'git merge-tree --write-tree a b', 'git instaweb', 'git cat-file --batch', 'xargs git status',
]
for (const check of gateBypassesFlagged) {
  test(`gate bypass flagged: ${JSON.stringify(check)}`, () => {
    assert.ok(g.unsafeCheck(check), `not flagged: ${check}`)
  })
}
const gateStillSafe = [
  'nice -n 5 just test', 'timeout 60 npm test', 'git status', 'git log --oneline', 'git diff', 'ls -la', 'cat README.md',
  'git branch', 'git branch --list', 'git branch -a', 'git branch -r', 'git branch -v', 'git branch -vv', 'git branch --show-current',
  'git branch --contains HEAD', 'git branch --merged main', 'git branch --no-merged main', 'git branch --list feat*',
  'env FOO=1 ls', 'env -i ls', 'sed s/a/b/g f', `sed -n '/warn/p' f`, 'gh pr view 1', 'gh --repo owner/repo pr view 1', 'xargs -n 1 echo', 'ionice -c 3 ls',
  `grep '#' f`, `echo 'a(b'`, 'ls && (ls)',
  '[[ -d src ]]', `awk '$1 > 3' f`, 'sort f', 'sort -u f', 'uniq -c f', 'gh pr view 1', 'gh pr list', 'gh api repos/o/r', 'gh api repos/o/r -X GET', 'git cat-file -p HEAD', 'echo push | xargs echo',
  'ls src/*.js', 'git log --oneline -3 -- src', `sed -n '1,5p' f`, 'ls > /dev/null',
]
for (const check of gateStillSafe) {
  test(`gate still safe: ${JSON.stringify(check)}`, () => {
    assert.equal(g.unsafeCheck(check), null)
  })
}

test('sync rejects nested shared blocks before any write', () => {
  const text = ['// BEGIN shared prelude', '// BEGIN shared gates', '// END shared gates', '// END shared prelude', ''].join(NL)
  const p = fixture({ factoryText: text })
  const r = sync(p)
  assert.equal(r.status, 1)
  assert.ok(!r.stderr.includes('TypeError'), r.stderr)
  assert.equal(readFileSync(p.factory, 'utf8'), text)
})

test('sync rejects a prelude block nested inside the gates block before any write', () => {
  const text = ['// BEGIN shared gates', '// BEGIN shared prelude', '// END shared prelude', '// END shared gates', ''].join(NL)
  const p = fixture({ factoryText: text })
  const r = sync(p)
  assert.equal(r.status, 1)
  assert.ok(r.stderr.includes('nests'), r.stderr)
  assert.equal(readFileSync(p.factory, 'utf8'), text)
})
