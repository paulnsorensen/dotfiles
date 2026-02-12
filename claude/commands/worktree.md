---
name: worktree
description: Create an isolated git worktree for a Claude Code task, keeping main clean.
allowed-tools: Bash, mcp__serena__activate_project, mcp__serena__check_onboarding_performed, mcp__serena__onboarding, mcp__serena__list_memories, mcp__serena__read_memory
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

### 4. Seed Serena

If `.serena/` exists at the repo root but not in the worktree, copy it over (minus `cache/`):
```bash
cp -r <repo_root>/.serena <worktree>/.serena && rm -rf <worktree>/.serena/cache
```

### 5. Prime Serena

1. `activate_project` for the worktree path
2. `check_onboarding_performed` — run `onboarding` if needed
3. `list_memories` — `read_memory` for any relevant ones

### 6. Confirm

Report:
```
Worktree ready: <absolute path>
Branch: claude/<slug>
Base: <short SHA and branch we forked from>
Serena: active (memories loaded)
```
