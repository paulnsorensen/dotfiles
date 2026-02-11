---
name: worktree
description: Create an isolated git worktree for a Claude Code task, keeping main clean.
allowed-tools: Bash
argument-hint: "<task-slug>"
---

Create an isolated git worktree for task: $ARGUMENTS

## Instructions

### 1. Parse Arguments

Extract the **task slug** from `$ARGUMENTS`. This becomes:
- **Branch name**: `claude/<slug>`
- **Worktree path**: `.worktrees/<slug>/`

If no slug is provided, ask the user for one.

### 2. Validate Prerequisites

- Confirm we're in a git repo (`git rev-parse --is-inside-work-tree`)
- Store the repo root (`git rev-parse --show-toplevel`)

### 3. Create or Resume Worktree

**If `.worktrees/<slug>/` already exists:**
- `cd` into it (Bash working directory persists between commands)
- Print the path and confirm resuming work

**If it doesn't exist:**
- Create the branch and worktree: `git worktree add .worktrees/<slug> -b claude/<slug>`
- `cd` into `.worktrees/<slug>/`
- Print the absolute path and confirm ready to work

### 4. Confirm

Report:
```
Worktree ready: <absolute path>
Branch: claude/<slug>
Base: <short SHA and branch we forked from>
```
