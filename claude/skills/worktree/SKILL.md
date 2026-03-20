---
name: worktree
model: haiku
allowed-tools: Bash(git:*), Bash(jq:*), Bash(mkdir:*), Bash(cp:*), Bash(rm:*), Bash(echo:*)
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

### 4. Seed local settings

Copy the main repo's `.claude/settings.local.json` into the worktree (preserves LSPs,
custom permissions, etc.) and merge sandbox config on top. Write to a temp file first
to avoid truncated output if jq fails on malformed input.

The overlay includes `sandbox.filesystem.allowWrite` for `~/.cache/prek` so that
prek pre-commit hooks can write their cache inside the Seatbelt sandbox.

**Note:** `ccw()` currently sets `core.hooksPath=/dev/null` which disables all
git hooks (including prek) in worktrees. The prek cache allowance is forward-looking
for when worktree hook restrictions are relaxed.

If `.claude/settings.local.json` exists at repo root:
```bash
mkdir -p .worktrees/<slug>/.claude
SANDBOX='{"sandbox":{"enabled":true,"autoAllowBashIfSandboxed":true,"filesystem":{"allowWrite":["~/.cache/prek"]}}}'
jq --argjson overlay "$SANDBOX" '. * $overlay' <REPO_ROOT>/.claude/settings.local.json \
  > .worktrees/<slug>/.claude/settings.local.json.tmp \
  && mv .worktrees/<slug>/.claude/settings.local.json.tmp \
       .worktrees/<slug>/.claude/settings.local.json
```

If no `.claude/settings.local.json` at repo root, write sandbox-only:
```bash
mkdir -p .worktrees/<slug>/.claude
echo '{"sandbox":{"enabled":true,"autoAllowBashIfSandboxed":true,"filesystem":{"allowWrite":["~/.cache/prek"]}}}' | jq . \
  > .worktrees/<slug>/.claude/settings.local.json.tmp \
  && mv .worktrees/<slug>/.claude/settings.local.json.tmp \
       .worktrees/<slug>/.claude/settings.local.json
```

### 5. Confirm

```
Worktree ready: <absolute path>
Branch: claude/<slug>
Base: <short SHA> (<branch forked from>)
```

## What You Don't Do

- Commit, push, or create PRs — use /wt-git for git operations in worktrees
- Set up full project environments — only creates the worktree and seeds settings
- Delete worktrees — use /worktree-sweep for cleanup

## Gotchas

- Worktree creation fails if the branch already exists on remote — use a unique branch name
- jq errors if settings.local.json is malformed — the tmp-file write pattern avoids corruption
- Worktree path must not contain spaces — use slugified names only
