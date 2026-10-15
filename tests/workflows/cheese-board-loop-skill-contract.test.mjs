import assert from 'node:assert/strict'
import { existsSync, readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import test from 'node:test'

// The skill drives the cheese-board resume loop. The repo path is read directly, so a missing file fails.
const SKILL = resolve(import.meta.dirname, '../../skills/cheese-board-loop/SKILL.md')
const REGISTRY = resolve(import.meta.dirname, '../../chezmoi/.chezmoidata/claude.yaml')

test('cheese-board-loop skill exists and names the resume contract', () => {
  assert.ok(existsSync(SKILL), `missing ${SKILL}`)
  const text = readFileSync(SKILL, 'utf8')
  assert.match(text, /^name: cheese-board-loop$/m)
  for (const needle of ['AskUserQuestion', 'needs-input', 'state', 'digest', 'answers', 'recommended']) {
    assert.ok(text.includes(needle), `SKILL.md must mention ${needle}`)
  }
})

test('cheese-board-loop skill batches AskUserQuestion calls and reuses the stamp', () => {
  const text = readFileSync(SKILL, 'utf8')
  assert.match(text, /1 to 4 questions per call/)
  assert.match(text, /2 to 4 options per question/)
  assert.match(text, /groups of up to 4/)
  assert.match(text, /"Other"/)
  assert.match(text, /Reuse the original `stamp` without change/)
})

test('cheese-board-loop skill is selected in the Claude skills registry', () => {
  assert.match(readFileSync(REGISTRY, 'utf8'), /^ {4}- cheese-board-loop$/m)
})
