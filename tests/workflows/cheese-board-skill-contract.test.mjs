import assert from 'node:assert/strict'
import { existsSync, readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import test from 'node:test'

// The skill drives the cheese-board resume loop. The repo path is read directly, so a missing file fails.
const SKILL = resolve(import.meta.dirname, '../../skills/cheese-board/SKILL.md')
const REGISTRY = resolve(import.meta.dirname, '../../chezmoi/.chezmoidata/claude.yaml')

test('cheese-board skill exists and names the resume contract', () => {
  assert.ok(existsSync(SKILL), `missing ${SKILL}`)
  const text = readFileSync(SKILL, 'utf8')
  assert.match(text, /^name: cheese-board$/m)
  for (const needle of ['AskUserQuestion', 'needs-input', 'state', 'digest', 'answers', 'recommended']) {
    assert.ok(text.includes(needle), `SKILL.md must mention ${needle}`)
  }
})

test('cheese-board skill is selected in the Claude skills registry', () => {
  assert.match(readFileSync(REGISTRY, 'utf8'), /^ {4}- cheese-board$/m)
})
