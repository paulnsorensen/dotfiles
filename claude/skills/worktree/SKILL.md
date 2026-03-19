---
name: worktree
model: haiku
allowed-tools: Bash(git:*), Bash(jq:*), Bash(mkdir:*), Bash(cp:*), Bash(rm:*), Bash(echo:*), mcp__serena__activate_project, mcp__serena__check_onboarding_performed, mcp__serena__onboarding, mcp__serena__list_memories, mcp__serena__read_memory
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

### 4. Disable pre-commit hooks

Prek writes to `~/.cache/prek/` which is outside the Seatbelt sandbox write paths.
Worktrees are ephemeral branches where pre-commit hooks aren't meaningful.

```bash
git -C .worktrees/<slug> config core.hooksPath /dev/null
```

### 5. Seed local settings

Copy the main repo's `.claude/settings.local.json` into the worktree (preserves LSPs,
custom permissions, etc.) and merge sandbox config on top. Write to a temp file first
to avoid truncated output if jq fails on malformed input.

If `.claude/settings.local.json` exists at repo root:
```bash
mkdir -p .worktrees/<slug>/.claude
SANDBOX='{"sandbox":{"enabled":true,"autoAllowBashIfSandboxed":true}}'
jq --argjson overlay "$SANDBOX" '. * $overlay' <REPO_ROOT>/.claude/settings.local.json \
  > .worktrees/<slug>/.claude/settings.local.json.tmp \
  && mv .worktrees/<slug>/.claude/settings.local.json.tmp \
       .worktrees/<slug>/.claude/settings.local.json
```

If no `.claude/settings.local.json` at repo root, write sandbox-only:
```bash
mkdir -p .worktrees/<slug>/.claude
echo '{"sandbox":{"enabled":true,"autoAllowBashIfSandboxed":true}}' | jq . \
  > .worktrees/<slug>/.claude/settings.local.json.tmp \
  && mv .worktrees/<slug>/.claude/settings.local.json.tmp \
       .worktrees/<slug>/.claude/settings.local.json
```

### 6. Seed Serena

If `.serena/` exists at repo root but not in the worktree:
```bash
cp -r <REPO_ROOT>/.serena .worktrees/<slug>/.serena
rm -rf .worktrees/<slug>/.serena/cache
```

### 7. Seed hookify rules

Copy hookify rules into the worktree's `.claude/` directory. Source from `claude/hookify/` (committed rules) first, then any local-only rules in `.claude/` (skip files that already exist):

```bash
mkdir -p .worktrees/<slug>/.claude
# Committed rules (source of truth)
for rule in <REPO_ROOT>/claude/hookify/hookify.*.local.md; do
  [ -f "$rule" ] || continue
  basename="$(basename "$rule")"
  [ -f ".worktrees/<slug>/.claude/${basename}" ] && continue
  cp "$rule" ".worktrees/<slug>/.claude/${basename}"
done
# Local-only rules (not in repo)
for rule in <REPO_ROOT>/.claude/hookify.*.local.md; do
  [ -f "$rule" ] || continue
  basename="$(basename "$rule")"
  [ -f ".worktrees/<slug>/.claude/${basename}" ] && continue
  cp "$rule" ".worktrees/<slug>/.claude/${basename}"
done
```

### 8. Prime Serena

1. `activate_project` for the worktree path
2. `check_onboarding_performed` — run `onboarding` if needed
3. `list_memories` — `read_memory` for any relevant ones

### 9. Confirm

```
Worktree ready: <absolute path>
Branch: claude/<slug>
Base: <short SHA> (<branch forked from>)
Serena: active (memories loaded)
```
