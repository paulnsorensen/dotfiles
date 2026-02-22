---
name: worktree
model: haiku
allowed-tools: Bash(git:*), mcp__serena__activate_project, mcp__serena__check_onboarding_performed, mcp__serena__onboarding, mcp__serena__list_memories, mcp__serena__read_memory
description: >
  Create an isolated git worktree for a Claude Code task, keeping main clean.
  Use when asked to create or resume a worktree, set up an isolated branch for
  a task, or when the /worktree command is invoked. Requires a task slug.
---

# worktree

Create or resume an isolated git worktree for a task.

## Protocol

### 1. Get the slug

The task slug is provided as an argument. If none was given, ask the user for one.

The slug becomes:
- **Branch**: `claude/<slug>`
- **Path**: `.worktrees/<slug>/`

### 2. Validate prerequisites

```bash
git rev-parse --is-inside-work-tree
git rev-parse --show-toplevel   # store as REPO_ROOT
```

### 3. Create or resume

**Already exists** (`.worktrees/<slug>/`):
- `cd` into it
- Confirm resuming

**Doesn't exist**:
```bash
git worktree add .worktrees/<slug> -b claude/<slug>
```
- `cd` into `.worktrees/<slug>/`
- Confirm ready

### 4. Seed Serena

If `.serena/` exists at repo root but not in the worktree:
```bash
cp -r <REPO_ROOT>/.serena .worktrees/<slug>/.serena
rm -rf .worktrees/<slug>/.serena/cache
```

### 5. Prime Serena

1. `activate_project` for the worktree path
2. `check_onboarding_performed` — run `onboarding` if needed
3. `list_memories` — `read_memory` for any relevant ones

### 6. Confirm

```
Worktree ready: <absolute path>
Branch: claude/<slug>
Base: <short SHA> (<branch forked from>)
Serena: active (memories loaded)
```
