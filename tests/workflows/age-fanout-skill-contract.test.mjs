import assert from 'node:assert/strict'
import { readFileSync, existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

// Deployed-file contract pin for age-fanout.js's dimension-parsing contract.
// The age skill is vendored from an external repo; CI won't have it, so this
// test skips (never fails) when the file is absent.
const DIMENSIONS_PATH = join(homedir(), '.claude/skills/age/references/dimensions.md')

// Must match age-fanout.js's DIM_SLUG_PATTERN verbatim -- workflow scripts
// can't be imported here, so the pattern is inlined.
const DIM_SLUG_RE = /^[a-z][a-z-]*$/

test('deployed age skill: dimensions.md has the headings age-fanout.js parses', (t) => {
  if (!existsSync(DIMENSIONS_PATH)) {
    t.skip('deployed age skill not present — contract unpinned')
    return
  }

  const content = readFileSync(DIMENSIONS_PATH, 'utf8')
  const lines = content.split('\n')

  const rubricsIdx = lines.findIndex((l) => l.trim() === '## Per-dimension rubrics')
  assert.notEqual(rubricsIdx, -1, 'expected a "## Per-dimension rubrics" heading')

  const boundariesIdx = lines.findIndex((l) => l.trim() === '## Dimension boundaries')
  assert.notEqual(boundariesIdx, -1, 'expected a "## Dimension boundaries" heading')

  let nextH2Idx = lines.findIndex((l, i) => i > rubricsIdx && /^##\s/.test(l))
  if (nextH2Idx === -1) nextH2Idx = lines.length

  const dimHeadings = lines
    .slice(rubricsIdx + 1, nextH2Idx)
    .filter((l) => /^###\s/.test(l))
    .map((l) => l.replace(/^###\s+/, '').trim())

  assert.ok(dimHeadings.length >= 1, 'expected at least one ### heading under Per-dimension rubrics')

  for (const heading of dimHeadings) {
    assert.match(heading, DIM_SLUG_RE, `heading "${heading}" must match ${DIM_SLUG_RE}`)
  }
})
