---
name: age
description: Staff Engineer code review of recent changes. Invokes the age skill to spawn 6 parallel review sub-agents. Only reports issues >= 50% confidence.
allowed-tools: Read, Grep, Glob, Bash, Agent, Write
argument-hint: "[git ref, or leave blank for staged/recent changes]"
---

Invoke the `age` skill in **focused mode** to review: $ARGUMENTS

If no argument is provided, review staged changes (`git diff --staged`) or the most recent commits on the current branch (`git log --oneline -5`).

If a git ref is provided (e.g., `HEAD~3`, `main..HEAD`, a commit SHA), review the diff for that range.

Present the Age Report directly to the user — summary, critical/important issues with concrete fixes, complexity check, and encapsulation/YAGNI/spec findings.

This is different from `/code-review` (which is a comprehensive repo/library audit) and from `/fromage` Age phase (which is pipeline-only).
