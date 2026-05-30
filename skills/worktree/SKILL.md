---
name: worktree
model: haiku
allowed-tools: Bash(ccw-init:*), Bash(cd:*)
description: >
  Create or resume an isolated git worktree for a task. Use for worktree setup
  requests and /worktree invocations; requires a task slug.
---

# worktree

Create or resume an isolated git worktree for a task.

## Protocol

### 1. Get the slug

The task slug is provided as an argument. If none was given, ask the user for one.

### 2. Run the helper

```bash
ccw-init <slug>
```

This single command handles everything:

- Validates git repo
- Creates worktree at `.worktrees/<slug>/` on branch `claude/<slug>` (or resumes if exists)
- Symlinks Claude project permissions from main repo
- Disables pre-commit hooks (prek can't write cache inside Seatbelt sandbox)
- Seeds `.claude/settings.local.json` with sandbox config + permissions

It outputs JSON to stdout with: `path`, `branch`, `base_sha`, `base_branch`, `created`.

### 3. Confirm

Parse the JSON output and report:

```
Worktree ready: <path>
Branch: <branch>
Base: <base_sha> (<base_branch>)
```

Then `cd` into the worktree path.

## What You Don't Do

- Commit, push, or create PRs — use /wt-git for git operations in worktrees
- Set up full project environments — only creates the worktree and seeds settings
- Delete worktrees — use /worktree-sweep for cleanup

## Gotchas

- Worktree creation fails if the branch already exists on remote — use a unique branch name
- Worktree path must not contain spaces — use slugified names only
