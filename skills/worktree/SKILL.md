---
name: worktree
model: haiku
effort: low
allowed-tools: Bash
description: >
  Create or resume an isolated git worktree for a task slug. Use for /worktree
  or "create/resume a worktree".
---

# worktree

Run `<skill-dir>/scripts/create.sh [-o] <slug>` (no slug given → ask for one),
then `cd` to the printed path.

Base-branch judgment — the one decision the script can't make:

- default (`-m`) — the task extends the current branch's work (continuation,
  sub-task, depends on local commits).
- `-o` — the task is independent of the current branch; branches off
  `origin/<default>` so it stays untangled.
- Unclear → ask.

Don't commit/push/PR here (/wt-git), delete worktrees (ccw-sweep), or set up
project environments.
