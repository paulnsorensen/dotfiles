// module: budget; provides: floorReached; requires: none
// True when the budget is known and less than LIMITS.minBudget remains. Both names resolve at call time.
const floorReached = () => Boolean(budget.total && budget.remaining() < LIMITS.minBudget)
