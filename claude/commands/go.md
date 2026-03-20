---
name: go
description: Re-prime MCPs after compaction or at conversation start.
---

Re-prime the development environment.

## Steps

1. **Check git state**: `git status` for orientation
2. **Report readiness** to user

## When to Use

- After context compaction
- After `/clear`
- At the start of any long session

**Note:** `/worktree` and `/fromage` handle setup automatically. Use `/go` only for recovery scenarios above.
