import assert from 'node:assert/strict'
import { existsSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

// Contract pins for the t3-* wrapper skills and t3-core. Pointer resolution
// skips (never fails) where the target skill is not deployed, such as in CI.
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const WRAPPERS = [
  'mold',
  'cook',
  'age',
  'cure',
  'affinage',
  'briesearch',
  'hard-cheese',
  'factory',
  'land',
  'research',
].map((n) => `t3-${n}`)

const CORE_DIR = join(ROOT, 'skills/t3-core')
const CORE_POINTER = '~/.claude/skills/t3-core/SKILL.md'
const MODEL_ID_RE = /claude-[a-z0-9-]+|gpt-[0-9][a-z0-9.-]*/g
const POINTER_RE = /~\/\.claude\/(?:skills\/[a-z0-9-]+\/SKILL\.md|workflows\/[a-z0-9-]+\.js)/g

const read = (p) => readFileSync(p, 'utf8')
const wrapperPath = (name) => join(ROOT, 'skills', name, 'SKILL.md')

function frontmatter(text) {
  const m = text.match(/^---\n([\s\S]*?)\n---/)
  return m ? m[1] : ''
}

function wrapperPointers(text) {
  return [...new Set(text.match(POINTER_RE) ?? [])].filter((p) => p !== CORE_POINTER)
}

const roleMapModels = new Set(
  Object.values(JSON.parse(read(join(CORE_DIR, 'role-map.json')))).map((r) => r.model),
)

// Returns the model ids in text that are not in the allowed set.
function foreignModelIds(text, allowed) {
  const ids = (text.match(MODEL_ID_RE) ?? []).map((id) => id.replace(/[.-]+$/, ''))
  return [...new Set(ids)].filter((id) => !allowed.has(id))
}

for (const name of WRAPPERS) {
  test(`${name}: SKILL.md exists`, () => {
    assert.ok(existsSync(wrapperPath(name)), `missing ${wrapperPath(name)}`)
  })

  test(`${name}: names a pointer, a stop on missing, and the override block`, () => {
    const text = read(wrapperPath(name))
    assert.ok(wrapperPointers(text).length >= 1, 'expected a ~/.claude/skills or workflows pointer')
    assert.match(text, /missing[^\n]*stop|stop[^\n]*missing/i, 'expected a stop when the pointer is missing')
    assert.ok(text.includes(CORE_POINTER), `expected ${CORE_POINTER}`)
  })

  test(`${name}: frontmatter pins model: opus and effort: high`, () => {
    const fm = frontmatter(read(wrapperPath(name)))
    assert.match(fm, /^model: opus$/m)
    assert.match(fm, /^effort: high$/m)
    assert.doesNotMatch(fm, /^disable-model-invocation\s*:/m)
  })

  test(`${name}: pointers resolve where deployed`, (t) => {
    const targets = wrapperPointers(read(wrapperPath(name))).map((p) => p.replace('~', homedir()))
    let checked = 0
    for (const target of targets) {
      const root = target.includes('/workflows/')
        ? join(homedir(), '.claude/workflows')
        : dirname(target)
      if (!existsSync(root)) continue
      checked += 1
      assert.ok(existsSync(target), `pointer target missing: ${target}`)
    }
    if (checked === 0) t.skip('pointer targets not deployed on this machine')
  })

  test(`${name}: model id check — wrapper names no model id`, () => {
    const ids = read(wrapperPath(name)).match(MODEL_ID_RE) ?? []
    assert.deepEqual(ids, [])
  })
}

test('model id: t3-core docs name only role-map ids', () => {
  for (const f of ['SKILL.md', 'references/result-rules.md']) {
    assert.deepEqual(foreignModelIds(read(join(CORE_DIR, f)), roleMapModels), [], f)
  }
})

test('model id: dispatch-protocol names only claude-opus-5-5', () => {
  const text = read(join(CORE_DIR, 'references/dispatch-protocol.md'))
  assert.deepEqual(foreignModelIds(text, new Set(['claude-opus-5-5'])), [])
})

test('model id: checker rejects a fixture wrapper naming gpt-9-fake', () => {
  const fixture = '---\nname: t3-fake\n---\nRun the child on gpt-9-fake.\n'
  assert.deepEqual(foreignModelIds(fixture, roleMapModels), ['gpt-9-fake'])
  assert.notDeepEqual(fixture.match(MODEL_ID_RE) ?? [], [])
})

test('claude.yaml registers t3-core and all ten wrappers', () => {
  const lines = read(join(ROOT, 'chezmoi/.chezmoidata/claude.yaml')).split('\n')
  const entries = new Set(lines.map((l) => l.match(/^\s+-\s+([a-z0-9-]+)\s*$/)?.[1]).filter(Boolean))
  for (const name of ['t3-core', ...WRAPPERS]) {
    assert.ok(entries.has(name), `${name} not listed in claude.yaml`)
  }
})

test('t3-core: frontmatter is inline (disable-model-invocation: true)', () => {
  const fm = frontmatter(read(join(CORE_DIR, 'SKILL.md')))
  assert.match(fm, /^disable-model-invocation: true$/m)
})
