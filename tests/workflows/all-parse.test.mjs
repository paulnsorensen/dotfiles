import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { mkdtemp, readFile, readdir } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { promisify } from 'node:util'
import test from 'node:test'

import { loadWorkflow } from './harness.mjs'

const root = resolve(import.meta.dirname, '../..')
const execFileAsync = promisify(execFile)
const workflowSourceDirectory = resolve(root, 'claude/workflows')
const workflowPaths = (await readdir(workflowSourceDirectory, { withFileTypes: true }))
  .filter((entry) => entry.isFile() && entry.name.endsWith('.js'))
  .map((entry) => resolve(workflowSourceDirectory, entry.name))
  .sort()

test('every shipped workflow loads with its meta export', async () => {
  for (const path of workflowPaths) {
    const workflow = await loadWorkflow(path)
    assert.equal(typeof workflow.meta.name, 'string', path)
    assert.equal(typeof workflow.run, 'function', path)
  }
})

// The Workflow runtime injects a fixed global surface (agent, parallel,
// pipeline, phase, log, workflow, args, budget) plus the standard ES built-ins
// the vm realm provides — and nothing else. These host globals exist in Node
// but NOT in that sandbox, so a workflow that reaches for one throws at run
// time (console is the exception: it exists in the realm but is not part of the
// documented surface — the sanctioned output path is log()). This guards the
// interface contract, not the SDK binary: it codifies the documented surface +
// the vm sandbox the offline harness models, which is as close to "Claude's
// shipped interface" as this repo can see.
const HOST_GLOBALS_OUTSIDE_RUNTIME = [
  'process', 'require', 'module', 'exports', '__dirname', '__filename',
  'Buffer', 'setTimeout', 'setInterval', 'setImmediate', 'clearTimeout',
  'clearInterval', 'queueMicrotask', 'fetch', 'crypto', 'TextEncoder',
  'TextDecoder', 'structuredClone', 'console',
]

// Blank out comments and string/template literals so the scan only sees code
// identifiers — prompt prose like "raw fetch bodies" or "the process started"
// must not count as a reference.
function stripCommentsAndStrings(source) {
  let out = ''
  let state = 'code'
  for (let i = 0; i < source.length; i++) {
    const c = source[i]
    const next = source[i + 1]
    if (state === 'code') {
      if (c === '/' && next === '/') { state = 'line'; i++; continue }
      if (c === '/' && next === '*') { state = 'block'; i++; continue }
      if (c === "'") { state = 'single'; continue }
      if (c === '"') { state = 'double'; continue }
      if (c === '`') { state = 'template'; continue }
      out += c
      continue
    }
    if (state === 'line') { if (c === '\n') { state = 'code'; out += '\n' }; continue }
    if (state === 'block') { if (c === '*' && next === '/') { state = 'code'; i++ }; continue }
    if (c === '\\') { i++; continue }
    if (state === 'single' && c === "'") state = 'code'
    else if (state === 'double' && c === '"') state = 'code'
    else if (state === 'template' && c === '`') state = 'code'
  }
  return out
}

test('no workflow reaches for a global outside the Workflow runtime surface', async () => {
  for (const path of workflowPaths) {
    const code = stripCommentsAndStrings(await readFile(path, 'utf8'))
    for (const name of HOST_GLOBALS_OUTSIDE_RUNTIME) {
      const reference = new RegExp(`(?<![.\\w$])${name}(?![\\w$])`)
      assert.doesNotMatch(code, reference,
        `${path}: references \`${name}\`, which the Workflow sandbox does not provide — use log() for output and agent()/parallel()/pipeline() for work`)
    }
  }
})

test('every workflow declares the meta fields the runtime requires', async () => {
  for (const path of workflowPaths) {
    const { meta } = await loadWorkflow(path)
    for (const field of ['name', 'description']) {
      assert.equal(typeof meta[field], 'string', `${path}: meta.${field} must be a string`)
      assert.ok(meta[field].trim().length, `${path}: meta.${field} must be non-empty`)
    }
  }
})

test('milknado worker config retains its required execution keys', async () => {
  const source = await readFile(resolve(root, 'claude/workflows/milknado-fleet-worker.toml'), 'utf8')

  for (const key of ['execution_agent', 'quality_gates', 'concurrency_limit', 'db_path', 'worktree_pattern']) {
    assert.match(source, new RegExp(`^${key}\\s*=`, 'm'), key)
  }
  assert.match(source, /--dangerously-skip-permissions/)
})


test('workflow smoke wiring invokes the wrapper, CI runs smoke, and the old parse guard is gone', async () => {
  const [justfile, ci] = await Promise.all([
    readFile(resolve(root, 'justfile'), 'utf8'),
    readFile(resolve(root, '.github/workflows/test.yml'), 'utf8'),
  ])

  assert.match(justfile, /^smoke:\n\s+\.\/tests\/workflows-test\.sh$/m)
  assert.doesNotMatch(justfile, /workflows-parse\.sh/)
  assert.match(ci, /- name: Run smoke tests\n\s+run: just smoke/)
  await assert.rejects(readFile(resolve(root, 'tests/workflows-parse.sh')), { code: 'ENOENT' })
})

test('workflow wrapper skips cleanly when node is unavailable', async () => {
  const nodeFreePath = await mkdtemp(join(tmpdir(), 'workflow-no-node-'))
  const { stdout } = await execFileAsync('/bin/bash', [resolve(root, 'tests/workflows-test.sh')], {
    env: { PATH: nodeFreePath },
  })

  assert.match(stdout, /node not on PATH — skipping workflow tests/)
})
