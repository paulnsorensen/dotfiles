---
name: worktree-sweep
description: Scan ~/Dev for stale git worktrees and safely clean them up. Shows safety status (merged, uncommitted changes, unpushed commits) before removing anything.
argument-hint: "[--dry-run] [--auto] [--path DIR]"
---

Run the worktree sweep script to find and clean up stale worktrees across ~/Dev.

Pass through any arguments: $ARGUMENTS

Default (no args) runs interactive mode. Use `--dry-run` to preview, `--auto` to auto-remove safe ones.

```bash
ccw-sweep $ARGUMENTS
```

Report the results to the user in a concise summary.
