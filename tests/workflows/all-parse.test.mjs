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

test('ultracook worker config retains its required execution keys', async () => {
  const source = await readFile(resolve(root, 'claude/workflows/ultracook-fleet-worker.toml'), 'utf8')

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
