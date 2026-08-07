---
name: worktree
model: haiku
effort: low
allowed-tools: Bash(wt:*), Bash(cd:*)
description: >
  Create or resume an isolated git worktree for a Claude Code task, keeping main
  clean. Use when asked to "create a worktree", "resume a worktree", set up an
  isolated branch for a task, or when /worktree is invoked. Requires a task slug.
---

# worktree

Create or resume an isolated git worktree for a task.

## Protocol

### 1. Get the slug

The task slug is provided as an argument. If none was given, ask the user for one.

### 2. Decide the base branch

Two modes (`wtm`/`wto` are the interactive-shell aliases for these — this
skill calls `wt` directly since Bash-tool commands aren't an interactive
shell):

- **`-m`** (or the flagless default) — branch off the current branch. Use
  when the task extends what's already happening here: continuing
  in-progress work, splitting a large feature into sub-tasks, or the new
  work depends on local commits/changes that aren't upstream yet.
- **`-o`** — branch off `origin/<default-branch>` (fetches first). Use when
  the task is independent of the current branch: an unrelated fix or
  feature, or the current branch already has committed work or an open PR
  for something else — starting from origin keeps the new task from being
  entangled with it.

If it's unclear which the task is, ask the user.

### 3. Run the helper

```bash
wt <slug>       # -m: branch off the current branch (default) — extends current work
wt -o <slug>    # branch off origin/<default-branch> (fetches first) — independent task
```

This single command handles everything:

- Validates git repo
- Creates worktree at `.worktrees/<slug>/` on branch `claude/<slug>` (or resumes if exists)
- Symlinks Claude project permissions from main repo
- Disables pre-commit hooks (prek can't write cache inside Seatbelt sandbox)
- Seeds `.claude/settings.local.json` with sandbox config + permissions

It outputs JSON to stdout with: `path`, `branch`, `base_sha`, `base_branch`, `created`.

### 4. Confirm

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
- Delete worktrees — use ccw-sweep for cleanup

## Gotchas

- Worktree creation fails if the branch already exists on remote — use a unique branch name
- Worktree path must not contain spaces — use slugified names only
