import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow } from './harness.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/ultracook-fleet.js')

for (const args of [undefined, '', {}, { roadmap_slug: '   ' }]) {
  test(`ultracook-fleet rejects an empty roadmap slug before dispatching agents: ${JSON.stringify(args)}`, async () => {
    const workflow = await loadWorkflow(path)
    const { globals, trace } = createRuntime()

    const result = await workflow.run({ ...globals, args })

    assert.match(result.error, /No roadmap slug provided/)
    assert.equal(trace.agents.length, 0)
  })
}
