---
name: onboard
description: Quick codebase orientation. Spawns cheese-factory to map architecture, entry points, and domain models.
argument-hint: "[path or leave blank for current repo]"
---

Orient in this codebase: $ARGUMENTS

## Instructions

Launch the `cheese-factory` agent:

```
Task(subagent_type="cheese-factory", model="sonnet", prompt="Codebase orientation for: <$ARGUMENTS or current repo>. Map vital signs, entry points, domain models, architecture shape, and key dependencies. Return a concise one-screen orientation map.")
```

When the agent returns, present the orientation map to the user.

## What This Is NOT

- Not a code review (use `/code-review` or `/age`)
- Not a security audit (use `/audit`)
- Not a planning session (use `/fromage`)
- Not persistent — does not save to `.claude/review/`
