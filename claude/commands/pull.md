---
name: pull
description: Pull latest changes from main into the current worktree.
allowed-tools: Bash
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

### 3. Report

Summarize:
- What was pulled (commit range or "already up to date")
