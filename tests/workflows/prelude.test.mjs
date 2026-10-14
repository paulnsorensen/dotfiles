import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test, { after } from 'node:test'
import { fileURLToPath } from 'node:url'
import { runInNewContext } from 'node:vm'

const repo = fileURLToPath(new URL('../../', import.meta.url))
const syncScript = join(repo, 'claude/workflow-prelude/sync.mjs')
const sourcePath = join(repo, 'claude/workflow-prelude/prelude.js')
const WORKFLOWS = ['claude/workflows/cheese-board.js', 'claude/workflows/cheese-factory.js', 'claude/workflows/move-my-cheese.js']
const NAMES = [
  'SCRATCH_PATH_SRC', 'SCRATCH_WORKTREE_RE', 'FULL_SHA_RE', 'floorReached', 'form', 'substance',
  'errorText', 'schemaErrors', 'data', 'prompt', 'redoPrompt', 'repairPrompt',
  'MOLD', 'DECISION_KINDS', 'RESEARCH_CONFIDENCE', 'GROUNDING_SCHEMA', 'GROUND_RESEARCH_SCHEMA', 'GROUND_RULES',
  'researchRule', 'BRIE_GROUND_MAX_AGENTS', 'brieGround',
]
const BEGIN = '// BEGIN shared prelude: x\n'
const END = '// END shared prelude\n'

const roots = []
after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

const run = (...args) => spawnSync(process.execPath, [syncScript, ...args], { encoding: 'utf8' })
const dir = () => {
  const d = mkdtempSync(join(tmpdir(), 'prelude-'))
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

test('sync --check exits 0 on the real workflows and leaves them unmodified', () => {
  const before = WORKFLOWS.map(read)
  const r = run('--check')
  assert.equal(r.status, 0, r.stderr)
  assert.deepEqual(WORKFLOWS.map(read), before)
})

test('each real workflow block equals the prelude source', () => {
  const source = readFileSync(sourcePath, 'utf8')
  for (const file of WORKFLOWS) {
    const text = read(file)
    const begin = text.indexOf('// BEGIN shared prelude')
    const end = text.indexOf('// END shared prelude')
    assert.ok(begin > 0 && end > begin, file)
    assert.equal(text.slice(text.indexOf('\n', begin) + 1, end), source, file)
  }
})

test('prelude declares exactly the shared names, each with one lead comment, and exports nothing', () => {
  const lines = readFileSync(sourcePath, 'utf8').split('\n')
  assert.equal(lines.some((l) => /^\s*export\b/.test(l)), false)
  const declared = lines.flatMap((l, i) => {
    const m = /^(?:const|function) (\w+)/.exec(l)
    return m ? [{ name: m[1], i }] : []
  })
  assert.deepEqual(declared.map((d) => d.name).sort(), [...NAMES].sort())
  for (const { name, i } of declared) {
    assert.match(lines[i - 1], /^\/\//, `${name} lead comment`)
    assert.doesNotMatch(lines[i - 2] ?? '', /^\/\//, `${name} has one lead comment`)
  }
})

test('each workflow declares every prelude name once, inside the block, after meta', () => {
  for (const file of WORKFLOWS) {
    const text = read(file)
    const begin = text.indexOf('// BEGIN shared prelude')
    const end = text.indexOf('// END shared prelude')
    assert.ok(text.indexOf('export const meta') < begin, file)
    for (const name of NAMES) {
      const all = text.match(new RegExp(declaration(name).source, 'gm')) ?? []
      assert.equal(all.length, 1, `${file} ${name}`)
      const at = text.search(declaration(name))
      assert.ok(at > begin && at < end, `${file} ${name} inside block`)
    }
  }
})

test('cheese-factory has no SHA_RE and move-my-cheese keeps its 7-to-40-hex SHA_RE', () => {
  assert.doesNotMatch(read('claude/workflows/cheese-factory.js'), /^const SHA_RE\b/m)
  assert.match(read('claude/workflows/move-my-cheese.js'), /^const SHA_RE = \/\^\[0-9a-f\]\{7,40\}\$\/i$/m)
})

test('the workflow files with a BEGIN marker equal the sync DEFAULT_FILES', () => {
  const list = /const DEFAULT_FILES = \[([^\]]*)\]/.exec(readFileSync(syncScript, 'utf8'))?.[1]
  assert.ok(list, 'DEFAULT_FILES not found in sync.mjs')
  const listed = [...list.matchAll(/'([^']+)'/g)].map((m) => m[1]).sort()
  const marked = readdirSync(join(repo, 'claude/workflows'))
    .filter((f) => f.endsWith('.js'))
    .map((f) => `claude/workflows/${f}`)
    .filter((f) => /^\/\/ BEGIN shared prelude/m.test(read(f)))
    .sort()
  assert.ok(listed.length > 0)
  assert.deepEqual(marked, listed)
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
  const src = put(d, 'p.js', 'const a = 1\n')
  const f = put(d, 'w.js', `head line\n${BEGIN}OLD\n${END}tail line\n`)
  const first = run('--source', src, f)
  assert.equal(first.status, 0, first.stderr)
  const written = readFileSync(f, 'utf8')
  assert.equal(written, `head line\n${BEGIN}const a = 1\n${END}tail line\n`)
  const second = run('--source', src, f)
  assert.equal(second.status, 0)
  assert.equal(second.stdout, '')
  assert.equal(readFileSync(f, 'utf8'), written)
  assert.equal(run('--check', '--source', src, f).status, 0)
})

test('sync --check exits nonzero and names the file when a block drifted', () => {
  const d = dir()
  const src = put(d, 'p.js', 'const a = 1\n')
  const text = `x\n${BEGIN}stale\n${END}y\n`
  const f = put(d, 'drift.js', text)
  const r = run('--check', '--source', src, f)
  assert.notEqual(r.status, 0)
  assert.ok(r.stderr.includes(f), r.stderr)
  assert.equal(readFileSync(f, 'utf8'), text)
})

test('sync exits nonzero and names the file with zero or duplicate marker pairs', () => {
  const d = dir()
  const src = put(d, 'p.js', 'const a = 1\n')
  const pair = `${BEGIN}const a = 1\n${END}`
  for (const f of [put(d, 'none.js', 'no markers\n'), put(d, 'twice.js', `${pair}${pair}`)]) {
    const r = run('--check', '--source', src, f)
    assert.notEqual(r.status, 0, f)
    assert.ok(r.stderr.includes(f), r.stderr)
    assert.notEqual(run('--source', src, f).status, 0, f)
  }
})

test('sync_crlfOutsideMarkers_preservedByteForByte', () => {
  const d = dir()
  const src = put(d, 'p.js', 'const a = 1\n')
  const crlf = (s) => s.replaceAll('\n', '\r\n')
  const f = put(d, 'w.js', `head\r\n${crlf(BEGIN)}old\r\n${crlf(END)}tail\r\n`)
  assert.equal(run('--source', src, f).status, 0)
  assert.equal(readFileSync(f, 'utf8'), `head\r\n${crlf(BEGIN)}const a = 1\n${crlf(END)}tail\r\n`)
})

test('sync_noTrailingNewlineAfterEndMarker_preserved', () => {
  const d = dir()
  const src = put(d, 'p.js', 'const a = 1\n')
  const f = put(d, 'w.js', `${BEGIN}x\n// END shared prelude`)
  assert.equal(run('--source', src, f).status, 0)
  assert.equal(readFileSync(f, 'utf8'), `${BEGIN}const a = 1\n// END shared prelude`)
})

test('sync_reversedMarkers_failsNamesFileAndWritesNothing', () => {
  const d = dir()
  const src = put(d, 'p.js', 'const a = 1\n')
  const text = `${END}mid\n${BEGIN}`
  const f = put(d, 'w.js', text)
  for (const args of [['--check'], []]) {
    const r = run(...args, '--source', src, f)
    assert.notEqual(r.status, 0)
    assert.ok(r.stderr.includes(f), r.stderr)
  }
  assert.equal(readFileSync(f, 'utf8'), text)
})

test('sync_indentedMarkers_areNotMarkers', () => {
  const d = dir()
  const src = put(d, 'p.js', 'const a = 1\n')
  const text = '  // BEGIN shared prelude\nconst a = 1\n  // END shared prelude\n'
  const f = put(d, 'w.js', text)
  for (const args of [['--check'], []]) {
    const r = run(...args, '--source', src, f)
    assert.notEqual(r.status, 0)
    assert.ok(r.stderr.includes(f), r.stderr)
    assert.match(r.stderr, /expected exactly one .* marker line/)
  }
  assert.equal(readFileSync(f, 'utf8'), text)
})

test('sync_missingWorkflowFile_exitsNonzeroAndNamesFile', () => {
  const d = dir()
  const src = put(d, 'p.js', 'const a = 1\n')
  const missing = join(d, 'nope.js')
  const r = run('--check', '--source', src, missing)
  assert.notEqual(r.status, 0)
  assert.ok(r.stderr.includes(missing), r.stderr)
})

test('sync_missingSourceFile_exitsNonzeroAndLeavesWorkflowUntouched', () => {
  const d = dir()
  const text = `${BEGIN}x\n${END}`
  const f = put(d, 'w.js', text)
  const r = run('--source', join(d, 'nope.js'), f)
  assert.notEqual(r.status, 0)
  assert.equal(readFileSync(f, 'utf8'), text)
})

test('sync_checkWithSeveralFiles_namesEveryDriftedFileOnly', () => {
  const d = dir()
  const src = put(d, 'p.js', 'const a = 1\n')
  const good = put(d, 'good.js', `${BEGIN}const a = 1\n${END}`)
  const bad1 = put(d, 'bad1.js', `${BEGIN}x\n${END}`)
  const bad2 = put(d, 'bad2.js', `${BEGIN}y\n${END}`)
  const r = run('--check', '--source', src, good, bad1, bad2)
  assert.equal(r.status, 1)
  assert.ok(r.stderr.includes(bad1) && r.stderr.includes(bad2))
  assert.equal(r.stderr.includes(good), false)
})

test('sync_argumentOrder_sourceFlagAndCheckFlagWorkInAnyPosition', () => {
  const d = dir()
  const src = put(d, 'p.js', 'const a = 1\n')
  const f = put(d, 'w.js', `${BEGIN}x\n${END}`)
  assert.equal(run(f, '--source', src, '--check').status, 1)
  assert.equal(run(f, '--source', src).status, 0)
  assert.equal(run('--check', f, '--source', src).status, 0)
})

test('sync_emptySource_blockBecomesEmptyAndStaysStable', () => {
  const d = dir()
  const src = put(d, 'p.js', '')
  const f = put(d, 'w.js', `h\n${BEGIN}x\n${END}t\n`)
  assert.equal(run('--source', src, f).status, 0)
  assert.equal(readFileSync(f, 'utf8'), `h\n${BEGIN}${END}t\n`)
  assert.equal(run('--check', '--source', src, f).status, 0)
})

test('sync_sourceWithoutTrailingNewline_keepsEndMarkerOnItsOwnLine', () => {
  const d = dir()
  const src = put(d, 'p.js', 'const a = 1')
  const f = put(d, 'w.js', `${BEGIN}old\n${END}`)
  run('--source', src, f)
  assert.match(readFileSync(f, 'utf8'), /^\/\/ END shared prelude$/m, 'END marker fused onto the last source line')
  assert.equal(run('--check', '--source', src, f).status, 0, 'sync output must pass its own --check')
})

test('sync_sourceContainingEndMarker_isRefusedInsteadOfCorruptingTarget', () => {
  const d = dir()
  const src = put(d, 'p.js', `const a = 1\n${END}`)
  const text = `${BEGIN}old\n${END}`
  const f = put(d, 'w.js', text)
  const r = run('--source', src, f)
  assert.notEqual(r.status, 0, 'writes a block that breaks the target on the next run')
  assert.equal(readFileSync(f, 'utf8'), text)
})

test('sync_sourceFlagWithoutValue_failsWithMessageNotStackTrace', () => {
  const f = put(dir(), 'w.js', `${BEGIN}x\n${END}`)
  const r = run(f, '--source')
  assert.notEqual(r.status, 0)
  assert.doesNotMatch(r.stderr, /TypeError|\n\s+at /)
})

test('sync_unknownFlag_isRejectedInsteadOfRewriting', () => {
  const d = dir()
  const src = put(d, 'p.js', 'const a = 1\n')
  const text = `${BEGIN}x\n${END}`
  const f = put(d, 'w.js', text)
  const r = run('--chekc', '--source', src, f)
  assert.notEqual(r.status, 0, 'a typo of --check silently rewrites the file')
  assert.equal(readFileSync(f, 'utf8'), text)
})

test('sync_missingLaterTarget_writesNoEarlierTarget', () => {
  const d = dir()
  const src = put(d, 'p.js', 'const a = 1\n')
  const text = `${BEGIN}old\n${END}`
  const f = put(d, 'w.js', text)
  const r = run('--source', src, f, join(d, 'missing.js'))
  assert.notEqual(r.status, 0)
  assert.equal(readFileSync(f, 'utf8'), text)
})

test('sync_laterTargetWithoutMarkers_writesNoEarlierTarget', () => {
  const d = dir()
  const src = put(d, 'p.js', 'const a = 1\n')
  const text = `${BEGIN}old\n${END}`
  const f = put(d, 'w.js', text)
  const bad = put(d, 'bad.js', 'no markers\n')
  const r = run('--source', src, f, bad)
  assert.notEqual(r.status, 0)
  assert.equal(readFileSync(f, 'utf8'), text)
})

test('sync_markerAsPrefixOfLongerLine_isNotAMarker', () => {
  const d = dir()
  const src = put(d, 'p.js', 'const a = 1\n')
  const f = put(d, 'w.js', `${BEGIN}old\n// END shared prelude and more\n${END}`)
  const r = run('--source', src, f)
  assert.equal(r.status, 0)
  assert.equal(readFileSync(f, 'utf8'), `${BEGIN}const a = 1\n${END}`)
})

test('drift_oneByteFlipInsideRealBlock_checkFailsNamingEveryFlippedCopy', () => {
  const d = dir()
  const drifted = []
  const unmarked = []
  for (const rel of WORKFLOWS) {
    const text = read(rel)
    const begin = text.indexOf('\n', text.indexOf('// BEGIN shared prelude')) + 1
    const end = text.indexOf('// END shared prelude')
    for (const at of [begin, Math.floor((begin + end) / 2), end - 2, end - 1]) {
      const copy = text.slice(0, at) + (text[at] === 'x' ? 'y' : 'x') + text.slice(at + 1)
      // A flip of the newline before the END marker breaks the marker, which fails before the drift report.
      ;(at === end - 1 ? unmarked : drifted).push(put(d, `${drifted.length + unmarked.length}.js`, copy))
    }
  }
  for (const group of [drifted, unmarked]) {
    const r = run('--check', '--source', sourcePath, ...group)
    assert.equal(r.status, 1)
    for (const f of group) assert.ok(r.stderr.includes(f), `${f} not named: ${r.stderr}`)
  }
})

test('drift_syncRepairsFlippedRealBlock_backToOriginalBytes', () => {
  const d = dir()
  for (const rel of WORKFLOWS) {
    const text = read(rel)
    const begin = text.indexOf('\n', text.indexOf('// BEGIN shared prelude')) + 1
    const f = put(d, 'w.js', `${text.slice(0, begin + 5)}Z${text.slice(begin + 5)}`)
    assert.equal(run('--source', sourcePath, f).status, 0)
    assert.equal(readFileSync(f, 'utf8'), text)
  }
})

const prelude = readFileSync(sourcePath, 'utf8')
const load = (src, extra = {}) =>
  runInNewContext(`${src}\n;({ SCRATCH_PATH_SRC, SCRATCH_WORKTREE_RE, FULL_SHA_RE, form, data, floorReached, schemaErrors })`, {
    PREAMBLE: 'PRE', LIMITS: { minBudget: 10 }, budget: { total: 100, remaining: () => 5 }, ...extra,
  })

test('prelude_evaluatedStandalone_definesNamesAndResolvesLateBindings', () => {
  const p = load(prelude)
  assert.equal(typeof p.schemaErrors, 'function')
  assert.equal(p.floorReached(), true)
  assert.equal(load(prelude, { budget: { total: 0, remaining: () => 0 } }).floorReached(), false)
})

test('prelude_scratchWorktreeReorderedBeforePathSrc_throwsAtLoad', () => {
  const lines = prelude.split('\n')
  const i = lines.findIndex((l) => l.startsWith('const SCRATCH_WORKTREE_RE'))
  const j = lines.findIndex((l) => l.startsWith('const SCRATCH_PATH_SRC'))
  assert.ok(j < i)
  const swapped = [...lines]
  ;[swapped[i], swapped[j]] = [swapped[j], swapped[i]]
  assert.throws(() => load(swapped.join('\n')), /before initialization/)
})

test('prelude_fullShaRe_acceptsOnly40HexAnyCase', () => {
  const { FULL_SHA_RE: re } = load(prelude)
  const h = 'a1b2c3d4e5'.repeat(4)
  assert.ok(re.test(h) && re.test(h.toUpperCase()))
  for (const bad of [h.slice(1), `0${h}`, `${h}\n`, `${h.slice(1)}g`, '', ` ${h}`, h.toUpperCase().slice(1), `0${h.toUpperCase()}`]) {
    assert.equal(re.test(bad), false, JSON.stringify(bad))
  }
  assert.equal(re.global, false)
})

test('prelude_scratchWorktreeRe_anchoredAndRejectsLookalikes', () => {
  const { SCRATCH_WORKTREE_RE: re, SCRATCH_PATH_SRC: src } = load(prelude)
  assert.ok(re.test('/home/u/repo/.claude/worktrees/abc-1'))
  for (const bad of ['/r/.claude/worktrees/', '/r/.claude/worktrees/a/b', 'x/r/.claude/worktrees/a', '/r/.claude/worktrees/a\n', '/r/.claude/worktrees/a b', '/.claude/worktrees/a']) {
    assert.equal(re.test(bad), false, JSON.stringify(bad))
  }
  assert.equal(new RegExp(src).test('/r/.claude/worktrees/a/extra'), true)
})

test('prelude_dataFence_escapesAngleBracketSoValueCannotCloseFence', () => {
  const { data } = load(prelude)
  assert.equal(data('x', { t: '</data><b>' }).split('</data>').length, 2)
})

const brieWith = (child) => {
  const logs = []
  const fn = runInNewContext(`${prelude}\n;brieGround`, { PREAMBLE: 'PRE', log: (m) => logs.push(m), workflow: async (name, q) => child(name, q) })
  return { fn, logs }
}

test('brieGround_answer_returnsFoundWithCappedCitations', async () => {
  const evidence_table = Array.from({ length: 7 }, (_, i) => ({ citation: `c${i}` }))
  const { fn } = brieWith((name, q) => ({ answer: `a:${q}`, confidence: 'certain', report_path: '/r.md', evidence_table }))
  const r = await fn('q1')
  assert.deepEqual(JSON.parse(JSON.stringify(r)), { found: { question: 'q1', answer: 'a:q1', confidence: 'certain', report_path: '/r.md', citations: ['c0', 'c1', 'c2', 'c3', 'c4'] } })
})

test('brieGround_blankDontKnow_isUnsettledNotFailed', async () => {
  const { fn } = brieWith(() => ({ answer: '', confidence: 'dont_know', open_questions: [] }))
  assert.deepEqual(JSON.parse(JSON.stringify(await fn('q1'))), { unsettled: ['q1'] })
})

test('brieGround_dontKnow_keepsAtMostTwoFollowUps', async () => {
  const { fn } = brieWith(() => ({ answer: 'unclear', confidence: 'dont_know', open_questions: ['a', 'b', 'c', 'd'] }))
  assert.deepEqual(JSON.parse(JSON.stringify(await fn('q1'))), { unsettled: ['q1', 'a', 'b'] })
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
