---
name: pull
description: Pull latest changes from main and refresh Serena memories in the current worktree.
allowed-tools: Bash, mcp__serena__activate_project, mcp__serena__check_onboarding_performed, mcp__serena__onboarding, mcp__serena__list_memories, mcp__serena__read_memory
---

Pull latest changes and refresh the dev environment.

## Steps

### 1. Detect Context

Determine if we're in a worktree or on main:
- Run `git worktree list` and `git rev-parse --show-toplevel`
- Identify the **main worktree path** (first entry from `git worktree list`)
- Identify the **current worktree path** (from `--show-toplevel`)

### 2. Pull Main

- `git -C <main-worktree-path> pull --ff-only`
- If it fails (diverged history), report the error and stop — don't force anything.

### 3. Refresh Serena Memories

If in a worktree (not main):
- Copy updated files from `<main>/.serena/memories/` into `<worktree>/.serena/memories/`, overwriting shared memories but preserving any worktree-only memory files.
- Remove `<worktree>/.serena/cache/` to force a fresh index.

### 4. Re-prime Serena

1. `activate_project` for the current working directory
2. `check_onboarding_performed` — run `onboarding` if needed
3. `list_memories` — `read_memory` for relevant ones

### 5. Report

Summarize:
- What was pulled (commit range or "already up to date")
- How many memories were refreshed (if in worktree)
- Serena status (active, memories loaded)
