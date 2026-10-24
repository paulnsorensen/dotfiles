// module: budget; provides: DEFAULT_LIMITS, floorReached, floorReason; requires: none
// The LIMITS values that every workflow shares. A workflow spreads these into its own LIMITS.
const DEFAULT_LIMITS = { minBudget: 50000, agentCap: 1000 }

// True when the budget is known and less than the floor remains. budget and LIMITS resolve at call time.
const floorReached = (floor = LIMITS.minBudget) => Boolean(budget.total && budget.remaining() < floor)

// The text that names the stage a budget floor stopped.
const floorReason = (stage, floor = LIMITS.minBudget) => `budget floor reached before ${stage}: ${budget.remaining()} remaining, below ${floor}`
