---
name: worktree-sweep
description: Scan ~/Dev for stale git worktrees and safely clean them up. Shows safety status (merged, uncommitted changes, unpushed commits) before removing anything.
argument-hint: "[--dry-run] [--auto] [--triage] [--path DIR]"
---

Run the worktree sweep script to find and clean up stale worktrees across ~/Dev.

Pass through any arguments: $ARGUMENTS

Default (no args) runs interactive mode. Use `--dry-run` to preview, `--auto` to auto-remove safe ones.

If $ARGUMENTS contains `--triage`, spawn the `worktree-triage` agent to deeply analyze WARN/DIRTY worktrees and recommend keep/archive/remove for each. Run `ccw-sweep --dry-run` first, then pass the results to the triage agent.

Otherwise, run the sweep script directly:

```bash
ccw-sweep $ARGUMENTS
```

Report the results to the user in a concise summary.
