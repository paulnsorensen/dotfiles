import assert from 'node:assert/strict'
import test from 'node:test'
import { loadModule } from '../../claude/workflow-prelude/load.mjs'

const load = (remaining, total = 100, min = 10) =>
  loadModule('budget', { globals: { LIMITS: { minBudget: min }, budget: { total, remaining: () => remaining } } })

test('floorReached_defaultsToLimitsMinBudget', () => {
  assert.equal(load(5).floorReached(), true)
  assert.equal(load(10).floorReached(), false)
  assert.equal(load(50, 100, 60).floorReached(), true)
})

test('floorReached_explicitFloorOverridesLimits', () => {
  assert.equal(load(5).floorReached(3), false)
  assert.equal(load(5).floorReached(6), true)
})

test('floorReached_unknownBudget_isNeverReached', () => {
  assert.equal(load(0, 0).floorReached(), false)
  assert.equal(load(0, null).floorReached(1e9), false)
})

test('floorReason_namesStageRemainingAndFloor', () => {
  assert.equal(load(5).floorReason('Plate'), 'budget floor reached before Plate: 5 remaining, below 10')
  assert.equal(load(5).floorReason('Plate', 99), 'budget floor reached before Plate: 5 remaining, below 99')
})

test('defaultLimits_holdSharedMinBudget', () => {
  const { DEFAULT_LIMITS } = load(5)
  assert.equal(DEFAULT_LIMITS.minBudget, 50000)
  assert.ok(Number.isInteger(DEFAULT_LIMITS.agentCap) && DEFAULT_LIMITS.agentCap > 0)
})
