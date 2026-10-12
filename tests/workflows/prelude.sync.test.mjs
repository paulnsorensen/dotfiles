import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import { runInNewContext } from 'node:vm'

const repo = fileURLToPath(new URL('../../', import.meta.url))
const syncScript = join(repo, 'claude/workflow-prelude/sync.mjs')
const sourcePath = join(repo, 'claude/workflow-prelude/prelude.js')
const WORKFLOWS = ['claude/workflows/cheese-factory.js', 'claude/workflows/move-my-cheese.js']
const BEGIN = '// BEGIN shared prelude: x\n'
const END = '// END shared prelude\n'

const run = (...args) => spawnSync(process.execPath, [syncScript, ...args], { encoding: 'utf8' })
const dir = () => mkdtempSync(join(tmpdir(), 'prelude-sync-'))
const put = (d, name, text) => {
  const p = join(d, name)
  writeFileSync(p, text)
  return p
}

test('sync_crlfOutsideMarkers_preservedByteForByte', () => {
  const d = dir()
  const src = put(d, 'p.js', 'const a = 1\n')
  const crlf = (s) => s.replace('\n', '\r\n')
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
  const f = put(d, 'w.js', '  // BEGIN shared prelude\nx\n  // END shared prelude\n')
  const r = run('--check', '--source', src, f)
  assert.notEqual(r.status, 0)
  assert.ok(r.stderr.includes(f))
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

test('drift_oneByteFlipInsideRealBlock_checkFailsNamingFile', () => {
  for (const rel of WORKFLOWS) {
    const text = readFileSync(join(repo, rel), 'utf8')
    const begin = text.indexOf('\n', text.indexOf('// BEGIN shared prelude')) + 1
    const end = text.indexOf('// END shared prelude')
    for (const at of [begin, Math.floor((begin + end) / 2), end - 2, end - 1]) {
      const flipped = text.slice(0, at) + (text[at] === 'x' ? 'y' : 'x') + text.slice(at + 1)
      const f = put(dir(), 'w.js', flipped)
      const r = run('--check', '--source', sourcePath, f)
      assert.equal(r.status, 1, `${rel}@${at}`)
      assert.ok(r.stderr.includes(f))
    }
  }
})

test('drift_syncRepairsFlippedRealBlock_backToOriginalBytes', () => {
  for (const rel of WORKFLOWS) {
    const text = readFileSync(join(repo, rel), 'utf8')
    const begin = text.indexOf('\n', text.indexOf('// BEGIN shared prelude')) + 1
    const f = put(dir(), 'w.js', `${text.slice(0, begin + 5)}Z${text.slice(begin + 5)}`)
    assert.equal(run('--source', sourcePath, f).status, 0)
    assert.equal(readFileSync(f, 'utf8'), text)
  }
})

test('drift_realCheckLeavesRepoFilesUnmodified', () => {
  const before = WORKFLOWS.map((w) => readFileSync(join(repo, w), 'utf8'))
  assert.equal(run('--check').status, 0)
  assert.deepEqual(WORKFLOWS.map((w) => readFileSync(join(repo, w), 'utf8')), before)
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
