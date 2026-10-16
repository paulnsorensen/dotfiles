import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import { loadModule } from '../../claude/workflow-prelude/load.mjs'

const repo = fileURLToPath(new URL('../../', import.meta.url))
const read = (rel) => readFileSync(`${repo}${rel}`, 'utf8')
const WORKFLOWS = ['claude/workflows/cheese-board.js', 'claude/workflows/cheese-factory.js', 'claude/workflows/move-my-cheese.js']
const sandbox = loadModule('checkpoint')
const { stable, digestOf } = sandbox
// The sandbox has its own Array prototype, so a JSON round trip makes deepEqual comparable.
const matchAnswers = (...args) => JSON.parse(JSON.stringify(sandbox.matchAnswers(...args)))

const questions = [
  { id: 'S-1', question: 'Keep IN-1 in the spec lane?' },
  { id: 'S-2', question: 'Split IN-2?' },
]

test('stable sorts object keys at every depth', () => {
  assert.equal(stable({ b: 1, a: { d: [2, { z: 1, y: 2 }], c: null } }), stable({ a: { c: null, d: [2, { y: 2, z: 1 }] }, b: 1 }))
  assert.notEqual(stable({ a: 1 }), stable({ a: 2 }))
})

test('digestOf returns 16 hex digits and changes with the value', () => {
  assert.match(digestOf({ a: 1 }), /^[0-9a-f]{16}$/)
  assert.equal(digestOf({ a: 1, b: 2 }), digestOf({ b: 2, a: 1 }))
  assert.notEqual(digestOf({ a: 1 }), digestOf({ a: 2 }))
})

test('matchAnswers matches a key by id, exact text, or 1-based number and returns question order', () => {
  const r = matchAnswers(questions, { 'Split IN-2?': ' yes ', 'S-1': 'spec' })
  assert.deepEqual(r.errors, [])
  assert.deepEqual(r.answers, [
    { id: 'S-1', question: questions[0].question, answer: 'spec' },
    { id: 'S-2', question: questions[1].question, answer: 'yes' },
  ])
  assert.deepEqual(matchAnswers(questions, { 2: 'no' }).answers.map((a) => a.id), ['S-2'])
})

test('matchAnswers reports unknown keys, blank answers, duplicates, and empty or non-object input', () => {
  assert.match(matchAnswers(questions, { nope: 'x' }).errors[0], /names no open question/)
  assert.match(matchAnswers(questions, { 'S-1': '  ' }).errors[0], /non-empty string/)
  assert.match(matchAnswers(questions, { 'S-1': 'a', 1: 'b' }).errors[0], /two answers/)
  assert.deepEqual(matchAnswers(questions, {}).errors, ['answers holds no answer'])
  assert.match(matchAnswers(questions, []).errors[0], /must be an object/)
  assert.match(matchAnswers(questions, null).errors[0], /must be an object/)
})

test('all three workflows carry the protocol in the checkpoint block and move-my-cheese keeps no local copy', () => {
  for (const file of WORKFLOWS) {
    const text = read(file)
    const begin = text.indexOf('// BEGIN module checkpoint\n')
    const end = text.indexOf('// END module checkpoint')
    assert.ok(begin >= 0 && end > begin, file)
    const block = text.slice(begin, end)
    const rest = text.slice(0, begin) + text.slice(end)
    for (const name of ['stable', 'digestOf', 'matchAnswers']) {
      assert.match(block, new RegExp(`^function ${name}\\b`, 'm'), `${file} block ${name}`)
      assert.doesNotMatch(rest, new RegExp(`^function ${name}\\b`, 'm'), `${file} local ${name}`)
    }
  }
})
