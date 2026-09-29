import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow } from './harness.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/milknado-fleet.js')

for (const args of [undefined, '', {}, { roadmap_slug: '   ' }]) {
  test(`milknado-fleet rejects an empty roadmap slug before dispatching agents: ${JSON.stringify(args)}`, async () => {
    const workflow = await loadWorkflow(path)
    const { globals, trace } = createRuntime()

    const result = await workflow.run({ ...globals, args })

    assert.match(result.error, /No roadmap slug provided/)
    assert.equal(trace.agents.length, 0)
  })
}

test('milknado-fleet partition brief bootstraps from the deployed worker config', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'detect-root') return { root: '/repo' }
      if (opts.label === 'roadmap-import') {
        return { roadmap_node_id: 1, goal_node_ids: [2], goal_slugs: ['lb-scheme'], goal_descriptions: ['LB scheme'] }
      }
      // Stop after Partition; the fleet returns an error once every partition is null.
      throw new Error(`fixture stops at ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: 'gke-milestone-b' })

  assert.match(result.error, /All partitions failed/)
  const partition = trace.agents.find((call) => call.opts.label === 'partition-lb-scheme')
  assert.ok(partition, 'partition agent dispatched')
  // The worker toml is a deployed ~/.claude asset, not a file in the target repo.
  assert.match(partition.prompt, /cp "\$HOME\/\.claude\/workflows\/milknado-fleet-worker\.toml" \/repo\/\.worktrees\/uf-lb-scheme\/milknado\.toml/)
  assert.doesNotMatch(partition.prompt, /\/repo\/claude\/workflows/)
  // milknado init takes the project root as a positional argument.
  assert.match(partition.prompt, /milknado init \/repo\/\.worktrees\/uf-lb-scheme\n/)
  assert.doesNotMatch(partition.prompt, /milknado init --project-root/)
})
