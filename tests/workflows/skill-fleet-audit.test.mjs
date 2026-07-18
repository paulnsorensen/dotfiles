import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import test from 'node:test'

import { createRuntime, loadWorkflow } from './harness.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/skill-fleet-audit.js')

const skill = (name) => ({ name, path: `/skills/${name}` })
const auditOk = (name, findings = []) => ({ skill: name, triggerSummary: `${name} triggers`, findings })

function inventoryResponder(names) {
  return () => ({ resolvedSkillsDir: '/skills', skills: names.map(skill) })
}

test('skill-fleet-audit coerces string, object, array, and null/undefined args', async () => {
  // string -> used verbatim as skillsDir
  {
    const workflow = await loadWorkflow(path)
    const { globals, trace } = createRuntime({ respond: () => ({ resolvedSkillsDir: '/skills', skills: [] }) })
    await workflow.run({ ...globals, args: '/custom/skills' })
    assert.match(trace.agents[0].prompt, /Skills directory: `\/custom\/skills`/)
  }

  // object -> skillsDir read from the object
  {
    const workflow = await loadWorkflow(path)
    const { globals, trace } = createRuntime({ respond: () => ({ resolvedSkillsDir: '/skills', skills: [] }) })
    await workflow.run({ ...globals, args: { skillsDir: '/obj/skills' } })
    assert.match(trace.agents[0].prompt, /Skills directory: `\/obj\/skills`/)
  }

  // array -> NOT treated as the options object; defaults apply, with a warning logged
  {
    const workflow = await loadWorkflow(path)
    const { globals, trace } = createRuntime({ respond: () => ({ resolvedSkillsDir: '/skills', skills: [] }) })
    await workflow.run({ ...globals, args: ['a', 'b'] })
    assert.match(trace.agents[0].prompt, /Skills directory: not given/)
    assert.match(trace.logs.join('\n'), /ignoring unusable args \(array\)/)
  }

  // null -> defaults apply, no warning (null is explicitly tolerated)
  {
    const workflow = await loadWorkflow(path)
    const { globals, trace } = createRuntime({ respond: () => ({ resolvedSkillsDir: '/skills', skills: [] }) })
    await workflow.run({ ...globals, args: null })
    assert.match(trace.agents[0].prompt, /Skills directory: not given/)
    assert.equal(trace.logs.some((l) => l.includes('ignoring unusable args')), false)
  }
})

test('skill-fleet-audit skips the cross pass with one audited skill, runs it with more than one', async () => {
  // exactly one skill -> auditResults.length is 1 -> cross must not be dispatched
  {
    const workflow = await loadWorkflow(path)
    const { globals, trace } = createRuntime({
      respond: ({ opts }) => {
        if (opts.label === 'inventory') return inventoryResponder(['alpha'])()
        if (opts.label === 'audit:alpha') return auditOk('alpha')
        throw new Error(`unexpected agent ${opts.label}`)
      },
    })
    const result = await workflow.run({ ...globals, args: undefined })
    assert.equal(trace.agents.some(({ opts }) => opts.label === 'cross'), false)
    assert.equal(result.auditedCount, 1)
  }

  // two skills -> auditResults.length is 2 -> cross IS dispatched
  {
    const workflow = await loadWorkflow(path)
    const { globals, trace } = createRuntime({
      respond: ({ opts }) => {
        if (opts.label === 'inventory') return inventoryResponder(['alpha', 'beta'])()
        if (opts.label === 'audit:alpha') return auditOk('alpha')
        if (opts.label === 'audit:beta') return auditOk('beta')
        if (opts.label === 'cross') return { findings: [] }
        throw new Error(`unexpected agent ${opts.label}`)
      },
    })
    await workflow.run({ ...globals, args: undefined })
    assert.equal(trace.agents.some(({ opts }) => opts.label === 'cross'), true)
  }
})

test('skill-fleet-audit table cells escape backslashes before pipes', async () => {
  const workflow = await loadWorkflow(path)
  const finding = { lens: 'succinctness', severity: 'low', finding: 'a\\|b', location: 'x', fix: 'y' }
  const { globals } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'inventory') return inventoryResponder(['alpha'])()
      if (opts.label === 'audit:alpha') return auditOk('alpha', [finding])
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: undefined })

  // escCell must escape the literal backslash BEFORE escaping the pipe, so a
  // cell containing both `\` and `|` renders as `a\\\|b`, not `a\\|b` (which
  // would corrupt the markdown table by leaving an unescaped column break).
  assert.equal(result.findings[0].finding, 'a\\|b')
  assert.match(result.reportMarkdown, /\| a\\\\\\\|b \|/)
})

test('skill-fleet-audit sorts findings high, then medium, then low', async () => {
  const workflow = await loadWorkflow(path)
  const findings = [
    { lens: 'succinctness', severity: 'low', finding: 'low finding', location: 'x', fix: 'y' },
    { lens: 'trigger-quality', severity: 'high', finding: 'high finding', location: 'x', fix: 'y' },
    { lens: 'internal-consistency', severity: 'medium', finding: 'medium finding', location: 'x', fix: 'y' },
  ]
  const { globals } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'inventory') return inventoryResponder(['alpha'])()
      if (opts.label === 'audit:alpha') return auditOk('alpha', findings)
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: undefined })

  assert.deepEqual(Array.from(result.findings, (f) => f.severity), ['high', 'medium', 'low'])
})

test('skill-fleet-audit worker prompts each state the audit is read-only', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'inventory') return inventoryResponder(['alpha', 'beta'])()
      if (opts.label === 'audit:alpha') return auditOk('alpha')
      if (opts.label === 'audit:beta') return auditOk('beta')
      if (opts.label === 'cross') return { findings: [] }
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  await workflow.run({ ...globals, args: undefined })

  const readOnly = /read-only audit — do not edit, create, or delete any file/
  const byLabel = (label) => trace.agents.find((a) => a.opts.label === label).prompt
  assert.match(byLabel('inventory'), readOnly)
  assert.match(byLabel('audit:alpha'), readOnly)
  assert.match(byLabel('cross'), readOnly)
})

test('skill-fleet-audit names skills whose audit crashed instead of dropping them silently', async () => {
  const workflow = await loadWorkflow(path)
  const { globals, trace } = createRuntime({
    respond: ({ opts }) => {
      if (opts.label === 'inventory') return inventoryResponder(['alpha', 'broken'])()
      if (opts.label === 'audit:alpha') return auditOk('alpha')
      if (opts.label === 'audit:broken') throw new Error('audit agent crashed')
      throw new Error(`unexpected agent ${opts.label}`)
    },
  })

  const result = await workflow.run({ ...globals, args: undefined })

  assert.equal(result.auditedCount, 1)
  assert.deepEqual(result.failedAuditNames, ['broken'])
  assert.match(trace.logs.join('\n'), /Audit failed: broken/)
})
