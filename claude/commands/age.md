---
name: age
description: Staff Engineer code review of recent changes. Spawns fromage-age for review against Sliced Bread architecture, engineering principles, and complexity budgets. Only reports issues >= 75% confidence.
allowed-tools: Read, Grep, Glob, Bash
argument-hint: "[git ref, or leave blank for staged/recent changes]"
---

Run the fromage-age agent on: $ARGUMENTS

Use the fromage-age agent (subagent_type: fromage-age) to review recent changes. The agent is read-only (Write/Edit disallowed) and performs a Staff Engineer-level review against Sliced Bread architecture, engineering principles, and complexity budgets.

If no argument is provided, review staged changes (`git diff --staged`) or the most recent commits on the current branch (`git log --oneline -5`).

If a git ref is provided (e.g., `HEAD~3`, `main..HEAD`, a commit SHA), review the diff for that range.

Present the agent's Age Report directly to the user — summary, critical/important issues with concrete fixes, architecture assessment, and complexity check.

This is different from `/code-review` (which is a comprehensive repo/library audit) and from `/fromage` Age phase (which is pipeline-only).
