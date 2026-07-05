---
name: worktree-triage
description: >
  Triage WARN/DIRTY worktrees into keep / archive / remove / stash recommendations,
  fanning out one read-only haiku content-digest sub-agent per worktree so the
  verdict rests on real contents (unique commits, uncommitted diff, untracked
  files), not just metadata. Use when asked to "triage worktrees", "what's in
  these stale worktrees", or when /worktree-sweep --triage runs. Recommends only —
  never removes, commits, or stashes anything itself.
model: sonnet
effort: medium
allowed-tools: Bash, AskUserQuestion, Agent
---

# worktree-triage

Analyze the worktrees that `ccw-sweep` couldn't auto-clean (WARN/DIRTY) and recommend an action for each, grounded in their actual contents.

This is an **inline skill, not a sub-agent**, because it fans out sub-agents itself — Claude Code allows only one level of nesting, so the fan-out must originate from an inline orchestrator (see ADR-348-A). It **recommends only**: it never removes, commits, stashes, or pushes a worktree.

## Protocol

### 1. Snapshot the current state

```bash
ccw-sweep --dry-run        # add --path DIR if the user scoped a directory
```

`ccw-sweep` is now nested-aware: it lists any nested unmerged/dirty children under each parent and prints the `git worktree move` relocation hint. Carry those nested warnings into your report — a parent flagged this way must not be removed until its child is relocated.

### 2. Fan out content digests (in parallel)

For **each WARN or DIRTY worktree**, dispatch one `worktree-content-digest` haiku sub-agent. Send them **in a single message with multiple `Agent` calls** so they run concurrently. Give each agent exactly one worktree path (and the repo's default branch if you know it). Each returns a 2–3 line digest — unique commits, uncommitted diff summary, and whether untracked files look throwaway vs. worth keeping. The heavy diff bodies stay in the sub-agents' windows, not yours.

Cap analysis at 20 worktrees; if more, prioritize the oldest first.

### 3. Build the verdict table

Fold each digest's substance together with the metadata from step 1 (age, PR state, merge status, nested warnings) into exactly one category per worktree:

- **REMOVE** — dead, abandoned, or fully incorporated into the default branch. No unique value. Signals: old (>14 days), no PR, small/empty unique diff, content already in the default branch.
- **ARCHIVE** — unique work worth preserving but not actively needed. Tag before removal. Signals: meaningful commits, no PR, moderate age, unique diff content.
- **KEEP** — active WIP or a valuable unmerged feature. Signals: recent activity (<3 days), significant unique diff, dirty tree with real changes, open PR.
- **STASH** — user chose to stash uncommitted work (DIRTY only).

### 4. Interview on DIRTY worktrees

For any worktree with uncommitted/staged changes or significant unique untracked content, you MUST ask the user before recommending — never auto-decide on uncommitted work. Show context first, then ask via `AskUserQuestion`:

```
<slug> has uncommitted work:
- <N> modified, <N> untracked files
- Last commit: <relative time>
- Key changes: <from the digest>
- <N> commits ahead of <default>
```

Options: **Commit & archive** · **Stash & remove** · **Keep** · **Discard & remove**. If more than 3 worktrees are DIRTY, batch them: show all contexts, ask for a default action with per-worktree overrides.

### 5. Emit the report

```
## Worktree Triage Report

### <repo-name>

| Worktree | Action | Reason (from digest) | Commits | Age |
|----------|--------|----------------------|---------|-----|
| slug-1 | REMOVE | abandoned, diff already in main | 2 | 14d |
| slug-2 | ARCHIVE | adds auth refactor not in main | 8 | 9d |
| slug-3 | KEEP | active spec work, dirty tree | 3 | 0d |

### Recommended Commands

# REMOVE
git -C <repo> worktree remove .worktrees/<slug-1> && git -C <repo> branch -D claude/<slug-1>

# ARCHIVE (tag then delete)
git -C <repo> tag archive/<slug-2> claude/<slug-2>
git -C <repo> worktree remove .worktrees/<slug-2> && git -C <repo> branch -D claude/<slug-2>

# RELOCATE NESTED (do before removing the parent)
git worktree move <parent>/.worktrees/<child> <repo>/.worktrees/<child>
```

## Rules

- NEVER remove, commit, stash, or modify any worktree yourself — recommend and emit commands only.
- One `worktree-content-digest` agent per WARN/DIRTY worktree, dispatched in parallel.
- Skip repos with no WARN/DIRTY worktrees entirely.
- ALWAYS interview the user for DIRTY worktrees; be decisive on WARN ones (each gets exactly one recommendation).
- Surface every nested-worktree warning from `ccw-sweep` and recommend relocating the child before the parent is removed.
