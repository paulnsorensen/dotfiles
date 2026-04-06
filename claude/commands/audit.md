---
name: audit
description: Security and dependency health audit. Spawns fromage-pasteurize for vulnerability scanning, unused deps, and OWASP checks. Only surfaces findings >= 50 confidence.
argument-hint: "[focus area or leave blank for full audit]"
---

Audit this codebase for security and dependency health: $ARGUMENTS

## Instructions

1. Launch the `fromage-pasteurize` agent:

```
Task(subagent_type="fromage-pasteurize", model="sonnet", prompt="Full security and dependency audit. Focus: <$ARGUMENTS or 'full codebase'>. Scan for vulnerabilities, unused/overweight deps, stdlib alternatives, OWASP issues, and secrets. Score all findings 0-100, only surface >= 50.")
```

1. When the agent returns, present the Pasteurize Report to the user.

2. If there are actionable findings (score >= 50), ask:
   - Which findings to address now vs later
   - Whether to create issues/tasks for deferred items

Do NOT modify any files. This is an analysis command.
