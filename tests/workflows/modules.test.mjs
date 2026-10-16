import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test, { after } from 'node:test'
import { fileURLToPath } from 'node:url'
import { MODULES_DIR, listModules, loadModule, readHeader } from '../../claude/workflow-prelude/load.mjs'

const repo = fileURLToPath(new URL('../../', import.meta.url))
const syncScript = join(repo, 'claude/workflow-prelude/sync.mjs')
const WORKFLOWS = ['claude/workflows/cheese-board.js', 'claude/workflows/cheese-factory.js', 'claude/workflows/move-my-cheese.js']
const PROVIDES = {
  stale: ['SCRATCH_PATH_SRC', 'SCRATCH_WORKTREE_RE', 'FULL_SHA_RE'],
  budget: ['floorReached'],
  call: ['form', 'substance', 'errorText', 'schemaErrors', 'data', 'prompt', 'redoPrompt', 'repairPrompt', 'isWriter', 'attempt', 'typed'],
  ground: ['MOLD', 'DECISION_KINDS', 'RESEARCH_CONFIDENCE', 'GROUNDING_SCHEMA', 'GROUND_RESEARCH_SCHEMA', 'GROUND_RULES', 'researchRule', 'BRIE_GROUND_MAX_AGENTS', 'brieGround'],
  checkpoint: ['stable', 'fnv1a', 'digestOf', 'matchAnswers'],
}
const MODULES = Object.keys(PROVIDES)

const roots = []
after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

const run = (...args) => spawnSync(process.execPath, [syncScript, ...args], { encoding: 'utf8' })
const dir = () => {
  const d = mkdtempSync(join(tmpdir(), 'modules-'))
  roots.push(d)
  return d
}
const put = (d, name, text) => {
  const p = join(d, name)
  writeFileSync(p, text)
  return p
}
const declaration = (name) => new RegExp(`^(const|function) ${name}\\b`, 'm')
const read = (rel) => readFileSync(join(repo, rel), 'utf8')
const moduleText = (name) => readFileSync(join(MODULES_DIR, `${name}.js`), 'utf8')
const BEGIN = (name) => `// BEGIN module ${name}\n`
const END = (name) => `// END module ${name}\n`
const block = (name, body) => `${BEGIN(name)}${body}${END(name)}`
// A temp modules directory with a chain: c requires b, and b requires a.
const chainDir = () => {
  const d = dir()
  put(d, 'a.js', '// module: a; provides: A; requires: none\nconst A = 1\n')
  put(d, 'b.js', '// module: b; provides: B; requires: a\nconst B = A + 1\n')
  put(d, 'c.js', '// module: c; provides: C, twice; requires: b\nconst C = B + 1\nconst twice = (n) => n * 2\n')
  return d
}

test('listModules names exactly the five split modules', () => {
  assert.deepEqual(listModules(), [...MODULES].sort())
})

test('each module header parses, names its file, and lists the names it declares once', () => {
  for (const name of listModules()) {
    const text = moduleText(name)
    const header = readHeader(text)
    assert.equal(header.name, name)
    assert.deepEqual(header.provides, PROVIDES[name], name)
    assert.deepEqual(header.requires, [], `${name} requires`)
    assert.equal(/^\s*(export|import)\b/m.test(text), false, `${name} has no import or export`)
    assert.ok(text.endsWith('\n'), `${name} ends with a newline`)
    const lines = text.split('\n')
    const declared = lines.flatMap((l) => {
      const m = /^(?:const|function) (\w+)/.exec(l)
      return m ? [m[1]] : []
    })
    assert.deepEqual(declared.sort(), [...header.provides].sort(), `${name} declares each provided name once`)
  }
})

test('no workflow-wide name is provided by two modules', () => {
  const all = MODULES.flatMap((m) => PROVIDES[m])
  assert.equal(new Set(all).size, all.length)
})

test('readHeader parses names and rejects a malformed first line', () => {
  assert.deepEqual(readHeader('// module: m; provides: a, b; requires: x, y\nconst a = 1\n'), { name: 'm', provides: ['a', 'b'], requires: ['x', 'y'] })
  assert.deepEqual(readHeader('// module: m; provides: a; requires: none\n').requires, [])
  for (const bad of ['', 'const a = 1', '// module: m; provides: a', '// module: m; provides: ; requires: none', '\n// module: m; provides: a; requires: none']) {
    assert.throws(() => readHeader(bad), /module header/, JSON.stringify(bad))
  }
})

// AC-1
test('sync --check exits 0 on the repo and leaves the workflows unmodified', () => {
  const before = WORKFLOWS.map(read)
  const r = run('--check')
  assert.equal(r.status, 0, r.stderr)
  assert.deepEqual(WORKFLOWS.map(read), before)
})

test('each real workflow holds one block per module and every block equals its module file', () => {
  for (const file of WORKFLOWS) {
    const text = read(file)
    for (const name of MODULES) {
      const b = text.indexOf(BEGIN(name))
      const e = text.indexOf(END(name))
      assert.ok(b >= 0 && e > b, `${file} ${name}`)
      assert.equal(text.indexOf(BEGIN(name), b + 1), -1, `${file} ${name} once`)
      assert.equal(text.slice(b + BEGIN(name).length, e), moduleText(name), `${file} ${name}`)
    }
    assert.equal(/BEGIN shared prelude/.test(text), false, `${file} has no old marker`)
  }
})

test('each workflow declares every provided name once, inside its module block, after meta', () => {
  for (const file of WORKFLOWS) {
    const text = read(file)
    assert.ok(text.indexOf('export const meta') < text.indexOf(BEGIN(MODULES[0])), file)
    for (const name of MODULES) {
      const b = text.indexOf(BEGIN(name))
      const e = text.indexOf(END(name))
      for (const provided of PROVIDES[name]) {
        const all = text.match(new RegExp(declaration(provided).source, 'gm')) ?? []
        assert.equal(all.length, 1, `${file} ${provided}`)
        const at = text.search(declaration(provided))
        assert.ok(at > b && at < e, `${file} ${provided} inside ${name} block`)
      }
    }
  }
})

test('cheese-factory has no SHA_RE and move-my-cheese keeps its 7-to-40-hex SHA_RE', () => {
  assert.doesNotMatch(read('claude/workflows/cheese-factory.js'), /^const SHA_RE\b/m)
  assert.match(read('claude/workflows/move-my-cheese.js'), /^const SHA_RE = \/\^\[0-9a-f\]\{7,40\}\$\/i$/m)
})

test('every workflow with a BEGIN module marker is a sync default target and the check names it', () => {
  const marked = readdirSync(join(repo, 'claude/workflows'))
    .filter((f) => f.endsWith('.js'))
    .map((f) => `claude/workflows/${f}`)
    .filter((f) => /^\/\/ BEGIN module /m.test(read(f)))
    .sort()
  assert.deepEqual(marked, [...WORKFLOWS].sort())
  // Drift in a marked workflow that is not in argv fails the argument-free check: copy the repo layout is heavy, so test a flipped copy by path.
  const d = dir()
  const text = read(WORKFLOWS[0])
  const f = put(d, 'w.js', text.replace(moduleText('budget'), `${moduleText('budget')}// drift\n`))
  const r = run('--check', f)
  assert.equal(r.status, 1)
  assert.ok(r.stderr.includes(f) && r.stderr.includes('budget'), r.stderr)
})

test('each consumer declares a top-level PREAMBLE and a LIMITS object with minBudget', () => {
  for (const file of WORKFLOWS) {
    const text = read(file)
    assert.match(text, /^const PREAMBLE\b/m, `${file} PREAMBLE`)
    assert.match(text, /^const LIMITS = \{[^}\n]*\bminBudget:/m, `${file} LIMITS.minBudget`)
  }
})

test('sync writes only between the markers and a second run changes nothing', () => {
  const d = dir()
  const f = put(d, 'w.js', `head line\n${block('budget', 'OLD\n')}tail line\n`)
  const first = run(f)
  assert.equal(first.status, 0, first.stderr)
  const written = readFileSync(f, 'utf8')
  assert.equal(written, `head line\n${block('budget', moduleText('budget'))}tail line\n`)
  const second = run(f)
  assert.equal(second.status, 0)
  assert.equal(second.stdout, '')
  assert.equal(readFileSync(f, 'utf8'), written)
  assert.equal(run('--check', f).status, 0)
})

test('sync handles several blocks in one target in file order', () => {
  const d = dir()
  const f = put(d, 'w.js', `h\n${block('stale', 'x\n')}mid\n${block('budget', 'y\n')}t\n`)
  assert.equal(run(f).status, 0)
  assert.equal(readFileSync(f, 'utf8'), `h\n${block('stale', moduleText('stale'))}mid\n${block('budget', moduleText('budget'))}t\n`)
})

test('sync --check exits 1 and names the file and the drifted module only', () => {
  const d = dir()
  const text = `x\n${block('stale', moduleText('stale'))}${block('budget', 'stale\n')}y\n`
  const f = put(d, 'drift.js', text)
  const r = run('--check', f)
  assert.equal(r.status, 1)
  assert.ok(r.stderr.includes(f), r.stderr)
  assert.match(r.stderr, /budget/)
  assert.doesNotMatch(r.stderr, /stale/)
  assert.equal(readFileSync(f, 'utf8'), text)
})

test('sync exits nonzero and names the file with no marker or a duplicate module block', () => {
  const d = dir()
  const pair = block('budget', moduleText('budget'))
  for (const f of [put(d, 'none.js', 'no markers\n'), put(d, 'twice.js', `${pair}${pair}`)]) {
    const r = run('--check', f)
    assert.notEqual(r.status, 0, f)
    assert.ok(r.stderr.includes(f), r.stderr)
    assert.notEqual(run(f).status, 0, f)
  }
})

test('sync fails and writes nothing for an unknown module name', () => {
  const d = dir()
  const text = `${block('budget', 'old\n')}${block('nope', 'old\n')}`
  const f = put(d, 'w.js', text)
  for (const args of [['--check'], []]) {
    const r = run(...args, f)
    assert.equal(r.status, 1)
    assert.ok(r.stderr.includes(f) && r.stderr.includes('nope'), r.stderr)
  }
  assert.equal(readFileSync(f, 'utf8'), text)
})

test('sync fails and writes nothing for unpaired, nested, or mismatched markers', () => {
  const d = dir()
  const cases = {
    beginOnly: BEGIN('budget'),
    endOnly: END('budget'),
    reversed: `${END('budget')}mid\n${BEGIN('budget')}`,
    nested: `${BEGIN('stale')}${BEGIN('budget')}${END('budget')}${END('stale')}`,
    mismatched: `${BEGIN('budget')}x\n${END('stale')}`,
  }
  for (const [label, text] of Object.entries(cases)) {
    const f = put(d, `${label}.js`, text)
    for (const args of [['--check'], []]) {
      const r = run(...args, f)
      assert.equal(r.status, 1, label)
      assert.ok(r.stderr.includes(f), `${label}: ${r.stderr}`)
    }
    assert.equal(readFileSync(f, 'utf8'), text, label)
  }
})

test('sync no longer accepts the old shared prelude markers', () => {
  const d = dir()
  const text = '// BEGIN shared prelude\nconst a = 1\n// END shared prelude\n'
  const f = put(d, 'w.js', text)
  for (const args of [['--check'], []]) {
    const r = run(...args, f)
    assert.equal(r.status, 1)
    assert.ok(r.stderr.includes(f), r.stderr)
  }
  assert.equal(readFileSync(f, 'utf8'), text)
})

test('sync_crlfOutsideMarkers_preservedByteForByte', () => {
  const d = dir()
  const crlf = (s) => s.replaceAll('\n', '\r\n')
  const f = put(d, 'w.js', `head\r\n${crlf(block('budget', 'old\n'))}tail\r\n`)
  assert.equal(run(f).status, 0)
  assert.equal(readFileSync(f, 'utf8'), `head\r\n${crlf(BEGIN('budget'))}${moduleText('budget')}${crlf(END('budget'))}tail\r\n`)
})

test('sync_noTrailingNewlineAfterEndMarker_preserved', () => {
  const d = dir()
  const f = put(d, 'w.js', `${BEGIN('budget')}x\n// END module budget`)
  assert.equal(run(f).status, 0)
  assert.equal(readFileSync(f, 'utf8'), `${BEGIN('budget')}${moduleText('budget')}// END module budget`)
})

test('sync_indentedMarkers_areNotMarkers', () => {
  const d = dir()
  const text = '  // BEGIN module budget\nconst a = 1\n  // END module budget\n'
  const f = put(d, 'w.js', text)
  for (const args of [['--check'], []]) {
    const r = run(...args, f)
    assert.equal(r.status, 1)
    assert.ok(r.stderr.includes(f), r.stderr)
  }
  assert.equal(readFileSync(f, 'utf8'), text)
})

test('sync_markerAsPrefixOfLongerLine_isNotAMarker', () => {
  const d = dir()
  const f = put(d, 'w.js', `${BEGIN('budget')}old\n// END module budget and more\n${END('budget')}`)
  assert.equal(run(f).status, 0)
  assert.equal(readFileSync(f, 'utf8'), block('budget', moduleText('budget')))
})

test('sync_missingWorkflowFile_exitsNonzeroAndNamesFile', () => {
  const missing = join(dir(), 'nope.js')
  const r = run('--check', missing)
  assert.notEqual(r.status, 0)
  assert.ok(r.stderr.includes(missing), r.stderr)
})

test('sync_checkWithSeveralFiles_namesEveryDriftedFileOnly', () => {
  const d = dir()
  const good = put(d, 'good.js', block('budget', moduleText('budget')))
  const bad1 = put(d, 'bad1.js', block('budget', 'x\n'))
  const bad2 = put(d, 'bad2.js', block('budget', 'y\n'))
  const r = run('--check', good, bad1, bad2)
  assert.equal(r.status, 1)
  assert.ok(r.stderr.includes(bad1) && r.stderr.includes(bad2))
  assert.equal(r.stderr.includes(good), false)
})

test('sync_argumentOrder_checkFlagWorksInAnyPosition', () => {
  const f = put(dir(), 'w.js', block('budget', 'x\n'))
  assert.equal(run(f, '--check').status, 1)
  assert.equal(run('--check', f).status, 1)
  assert.equal(run(f).status, 0)
  assert.equal(run('--check', f).status, 0)
})

test('sync_unknownFlag_isRejectedInsteadOfRewriting', () => {
  const text = block('budget', 'x\n')
  const f = put(dir(), 'w.js', text)
  const r = run('--chekc', f)
  assert.notEqual(r.status, 0, 'a typo of --check silently rewrites the file')
  assert.equal(readFileSync(f, 'utf8'), text)
})

test('sync_modulesDirFlagWithoutValue_failsWithMessageNotStackTrace', () => {
  const f = put(dir(), 'w.js', block('budget', 'x\n'))
  const r = run(f, '--modules-dir')
  assert.notEqual(r.status, 0)
  assert.doesNotMatch(r.stderr, /TypeError|\n\s+at /)
})

test('sync_badTargetAmongSeveral_writesNoEarlierTarget', () => {
  const d = dir()
  const text = block('budget', 'old\n')
  const f = put(d, 'w.js', text)
  for (const later of [join(d, 'missing.js'), put(d, 'bad.js', 'no markers\n')]) {
    assert.notEqual(run(f, later).status, 0)
    assert.equal(readFileSync(f, 'utf8'), text)
  }
})

// AC-2
test('sync fails naming the target and the module when a marked module requires an unmarked one', () => {
  const m = chainDir()
  const d = dir()
  const text = `head\n${block('c', 'old\n')}${block('a', 'old\n')}tail\n`
  const f = put(d, 'w.js', text)
  for (const args of [['--check'], []]) {
    const r = run(...args, '--modules-dir', m, f)
    assert.equal(r.status, 1)
    assert.ok(r.stderr.includes(f), r.stderr)
    assert.match(r.stderr, /module c requires module b/)
  }
  assert.equal(readFileSync(f, 'utf8'), text, 'nothing is written')
})

test('sync writes no target when another target lacks a required module', () => {
  const m = chainDir()
  const d = dir()
  const okText = `${block('a', 'old\n')}${block('b', 'old\n')}`
  const ok = put(d, 'ok.js', okText)
  const badText = block('b', 'old\n')
  const bad = put(d, 'bad.js', badText)
  const r = run('--modules-dir', m, ok, bad)
  assert.equal(r.status, 1)
  assert.ok(r.stderr.includes(bad) && r.stderr.includes('a'), r.stderr)
  assert.equal(readFileSync(ok, 'utf8'), okText)
  assert.equal(readFileSync(bad, 'utf8'), badText)
})

test('sync writes every block once the requirements are marked', () => {
  const m = chainDir()
  const f = put(dir(), 'w.js', `${block('a', 'o\n')}${block('b', 'o\n')}${block('c', 'o\n')}`)
  assert.equal(run('--modules-dir', m, f).status, 0)
  const want = ['a', 'b', 'c'].map((n) => block(n, readFileSync(join(m, `${n}.js`), 'utf8'))).join('')
  assert.equal(readFileSync(f, 'utf8'), want)
  assert.equal(run('--check', '--modules-dir', m, f).status, 0)
})

test('sync refuses a module file whose header name differs from its file name', () => {
  const m = dir()
  put(m, 'x.js', '// module: y; provides: X; requires: none\nconst X = 1\n')
  const text = block('x', 'o\n')
  const f = put(dir(), 'w.js', text)
  const r = run('--modules-dir', m, f)
  assert.equal(r.status, 1)
  assert.match(r.stderr, /module x/)
  assert.equal(readFileSync(f, 'utf8'), text)
})

// Flips go into the body of each real module block.
test('drift_byteInsertedInsideRealBlock_checkFailsNamingFileAndModule', () => {
  const d = dir()
  let n = 0
  for (const rel of WORKFLOWS) {
    const text = read(rel)
    for (const name of MODULES) {
      const at = text.indexOf(BEGIN(name)) + BEGIN(name).length + 5
      const f = put(d, `${n++}.js`, `${text.slice(0, at)}Z${text.slice(at)}`)
      const r = run('--check', f)
      assert.equal(r.status, 1, `${rel} ${name}`)
      assert.ok(r.stderr.includes(f), r.stderr)
      assert.ok(r.stderr.includes(name), `${name} not named: ${r.stderr}`)
    }
  }
})

test('drift_syncRepairsTamperedRealBlock_backToOriginalBytes', () => {
  const d = dir()
  for (const rel of WORKFLOWS) {
    const text = read(rel)
    const at = text.indexOf(BEGIN('call')) + BEGIN('call').length + 5
    const f = put(d, 'w.js', `${text.slice(0, at)}Z${text.slice(at)}`)
    assert.equal(run(f).status, 0)
    assert.equal(readFileSync(f, 'utf8'), text)
  }
})

// AC-3
test('loadModule returns every provided name for each module without the Workflow runtime', () => {
  for (const name of listModules()) {
    const loaded = loadModule(name)
    assert.deepEqual(Object.keys(loaded).sort(), [...PROVIDES[name]].sort(), name)
    for (const key of PROVIDES[name]) assert.notEqual(loaded[key], undefined, `${name}.${key}`)
  }
})

test('loadModule evaluates the requirement closure in dependency order and returns only the module names', () => {
  const m = chainDir()
  const c = loadModule('c', { dir: m })
  assert.deepEqual(Object.keys(c).sort(), ['C', 'twice'])
  assert.equal(c.C, 3)
  assert.equal(c.twice(4), 8)
  assert.deepEqual({ ...loadModule('a', { dir: m }) }, { A: 1 })
})

test('loadModule rejects an unknown module and a requirement cycle', () => {
  const m = dir()
  put(m, 'x.js', '// module: x; provides: X; requires: y\nconst X = 1\n')
  put(m, 'y.js', '// module: y; provides: Y; requires: x\nconst Y = 1\n')
  assert.throws(() => loadModule('nope'), /unknown module nope/)
  assert.throws(() => loadModule('x', { dir: m }), /requires itself/)
})

const scratch = () => loadModule('stale')
const withRuntime = (extra = {}) =>
  loadModule('budget', { globals: { LIMITS: { minBudget: 10 }, budget: { total: 100, remaining: () => 5 }, ...extra } })

test('floorReached_resolvesRuntimeNamesAtCallTime', () => {
  assert.equal(withRuntime().floorReached(), true)
  assert.equal(withRuntime({ budget: { total: 0, remaining: () => 0 } }).floorReached(), false)
})

test('stale_scratchWorktreeReorderedBeforePathSrc_throwsAtLoad', () => {
  const lines = moduleText('stale').split('\n')
  const i = lines.findIndex((l) => l.startsWith('const SCRATCH_WORKTREE_RE'))
  const j = lines.findIndex((l) => l.startsWith('const SCRATCH_PATH_SRC'))
  assert.ok(j < i)
  const swapped = [...lines]
  ;[swapped[i], swapped[j]] = [swapped[j], swapped[i]]
  const m = dir()
  put(m, 'stale.js', swapped.join('\n'))
  assert.throws(() => loadModule('stale', { dir: m }), /before initialization/)
})

test('stale_fullShaRe_acceptsOnly40HexAnyCase', () => {
  const { FULL_SHA_RE: re } = scratch()
  const h = 'a1b2c3d4e5'.repeat(4)
  assert.ok(re.test(h) && re.test(h.toUpperCase()))
  for (const bad of [h.slice(1), `0${h}`, `${h}\n`, `${h.slice(1)}g`, '', ` ${h}`, h.toUpperCase().slice(1), `0${h.toUpperCase()}`]) {
    assert.equal(re.test(bad), false, JSON.stringify(bad))
  }
  assert.equal(re.global, false)
})

test('stale_scratchWorktreeRe_anchoredAndRejectsLookalikes', () => {
  const { SCRATCH_WORKTREE_RE: re, SCRATCH_PATH_SRC: src } = scratch()
  assert.ok(re.test('/home/u/repo/.claude/worktrees/abc-1'))
  for (const bad of ['/r/.claude/worktrees/', '/r/.claude/worktrees/a/b', 'x/r/.claude/worktrees/a', '/r/.claude/worktrees/a\n', '/r/.claude/worktrees/a b', '/.claude/worktrees/a']) {
    assert.equal(re.test(bad), false, JSON.stringify(bad))
  }
  assert.equal(new RegExp(src).test('/r/.claude/worktrees/a/extra'), true)
})

test('call_dataFence_escapesAngleBracketSoValueCannotCloseFence', () => {
  const { data } = loadModule('call', { globals: { PREAMBLE: 'PRE' } })
  assert.equal(data('x', { t: '</data><b>' }).split('</data>').length, 2)
})

test('call_schemaErrorsAndPromptsWork', () => {
  const { schemaErrors, prompt, form } = loadModule('call', { globals: { PREAMBLE: 'PRE' } })
  assert.equal(schemaErrors({}, { type: 'object', required: ['a'] }, 'x').join(), 'x.a is required')
  assert.equal(prompt('p', '', 'q'), 'PRE\n\np\n\nq')
  assert.equal(form('m').kind, 'form')
})

const brieWith = (child) => {
  const logs = []
  const { brieGround: fn } = loadModule('ground', { globals: { PREAMBLE: 'PRE', log: (m) => logs.push(m), workflow: async (name, q) => child(name, q) } })
  return { fn, logs }
}

test('brieGround_answer_returnsFoundWithCappedCitations', async () => {
  const evidence_table = Array.from({ length: 7 }, (_, i) => ({ citation: `c${i}` }))
  const { fn } = brieWith((name, q) => ({ answer: `a:${q}`, confidence: 'certain', report_path: '/r.md', evidence_table }))
  const r = await fn('q1')
  assert.deepEqual(JSON.parse(JSON.stringify(r)), { found: { question: 'q1', answer: 'a:q1', confidence: 'certain', report_path: '/r.md', citations: ['c0', 'c1', 'c2', 'c3', 'c4'] }, dropped: 2 })
})

test('brieGround_capDrops_areLoggedAndReturned', async () => {
  const cited = brieWith(() => ({ answer: 'a', confidence: 'certain', evidence_table: Array.from({ length: 8 }, (_, i) => ({ citation: `c${i}` })) }))
  assert.equal((await cited.fn('q1')).dropped, 3)
  assert.match(cited.logs.join('\n'), /dropped 3 citation/)
  const open = brieWith(() => ({ answer: 'unclear', confidence: 'dont_know', open_questions: ['a', 'b', 'c', 'd', 'e'] }))
  assert.equal((await open.fn('q1')).dropped, 3)
  assert.match(open.logs.join('\n'), /dropped 3 follow-up/)
  const none = brieWith(() => ({ answer: 'a', confidence: 'certain', evidence_table: [{ citation: 'c0' }] }))
  assert.equal('dropped' in (await none.fn('q1')), false)
  assert.deepEqual(none.logs, [])
})

test('brieGroundMaxAgents_equalsBrieGroundWorstCase', () => {
  const src = read('claude/workflows/brie-ground.js')
  const num = (re) => Number(src.match(re)[1])
  const subs = num(/^const MAX_SUBQUESTIONS = (\d+)$/m)
  const redo = num(/^const REDO_ROUNDS = (\d+)$/m)
  const deep = num(/^\s+MAX_DEEP_SUBQUESTIONS: (\d+),$/m)
  const extracts = Math.ceil(num(/^\s+MAX_FETCH: (\d+),$/m) / num(/^\s+EXTRACT_BATCH: (\d+),$/m))
  // recall + its verify, plan + redo, deep mixed (wiki, search, extracts, code, verify), shallow mixed (wiki, web, verify), synthesis + redo, prototype 2.
  const worst = 2 + (1 + redo) + deep * (4 + extracts) + (subs - deep) * 3 + (1 + redo) + 2
  assert.equal(worst, 35)
  assert.equal(loadModule('ground').BRIE_GROUND_MAX_AGENTS, worst)
})

test('brieGround_blankDontKnow_isUnsettledNotFailed', async () => {
  const { fn } = brieWith(() => ({ answer: '', confidence: 'dont_know', open_questions: [] }))
  assert.deepEqual(JSON.parse(JSON.stringify(await fn('q1'))), { unsettled: ['q1'] })
})

test('brieGround_dontKnow_keepsAtMostTwoFollowUps', async () => {
  const { fn } = brieWith(() => ({ answer: 'unclear', confidence: 'dont_know', open_questions: ['a', 'b', 'c', 'd'] }))
  assert.deepEqual(JSON.parse(JSON.stringify(await fn('q1'))), { unsettled: ['q1', 'a', 'b'], dropped: 2 })
})

test('brieGround_blankSettledAnswer_stillFails', async () => {
  const { fn } = brieWith(() => ({ answer: '  ', confidence: 'certain' }))
  assert.deepEqual(JSON.parse(JSON.stringify(await fn('q1'))), { failed: 'research failed: q1' })
})

test('brieGround_dontKnow_returnsUnsettledWithFollowUps', async () => {
  const { fn } = brieWith(() => ({ answer: 'unclear', confidence: 'dont_know', open_questions: ['q2', '', 3] }))
  assert.deepEqual(JSON.parse(JSON.stringify(await fn('q1'))), { unsettled: ['q1', 'q2'] })
})

test('brieGround_throwOrBadShape_returnsFailedAndLogsThrow', async () => {
  const thrown = brieWith(() => { throw new Error('boom') })
  assert.deepEqual(JSON.parse(JSON.stringify(await thrown.fn('q1'))), { failed: 'research failed: q1' })
  assert.match(thrown.logs[0], /boom/)
  for (const bad of [null, { error: 'x' }, { answer: ' ', confidence: 'certain' }, { answer: 'a', confidence: 'sure' }]) {
    assert.ok((await brieWith(() => bad).fn('q')).failed, JSON.stringify(bad))
  }
})
