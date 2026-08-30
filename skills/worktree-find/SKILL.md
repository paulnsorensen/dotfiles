---
name: worktree-find
model: haiku
effort: low
allowed-tools: Bash
description: >
  Locate git worktrees by branch, slug, repo, staleness, touched path, or open
  PR. Use for /worktree-find or "where's/find the worktree ...". Read-only.
---

# worktree-find

Route the criterion:

- branch / slug / repo / staleness → `ccw-find --slug|--branch|--repo <s>`,
  `--stale <days>` (AND-combined; rows are `path<TAB>branch (age)`).
- "the one touching `<path>`" → `<skill-dir>/scripts/find-touching.sh
  '<pathspec>' [ccw-find flags]`.
- "the one with the open PR for X" → `<skill-dir>/scripts/find-pr.sh
  [ccw-find flags]`, then pick the row whose PR title matches X.

Report the matches; when exactly one, end with the resume hint `cd <path>`.
Nothing matched → say what was searched (root, criteria); never guess a path.
Never modify a worktree — cleanup is ccw-sweep, teardown is ccw-rm.
