---
name: ralph
description: Run a ralph-loop for iterative convergence on a task. Cheaper than manual back-and-forth.
argument-hint: <task to converge on>
---

Use the ralph-loop plugin to iteratively converge on the given task. Ralph loops are self-referential — each iteration evaluates the previous output and refines it until a convergence criterion is met.

## Why Use This

Manual back-and-forth ("fix this", "now fix that", "one more thing") burns tokens on re-reading context each turn. A ralph loop batches the iteration into a single autonomous loop, reducing total token spend.

## When to Use

- Refactoring that needs multiple passes (each pass reveals more to clean up)
- Code review fixes where you expect several rounds of feedback
- Writing that needs iterative refinement (docs, specs, commit messages)
- Any task where "almost right" needs polishing to "right"

## When NOT to Use

- Simple one-shot tasks (use `/cheese` instead)
- Tasks requiring human judgment at each step
- Exploratory work where the goal isn't clear yet (use `/duck` first)

For the request: "{{request}}", start a ralph loop to converge on the best result.
