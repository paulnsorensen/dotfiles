---
name: worktree-sweep
description: Scan ~/Dev for stale git worktrees and safely clean them up. Shows safety status (merged, uncommitted changes, unpushed commits) before removing anything.
argument-hint: "[--dry-run] [--auto] [--triage] [--path DIR]"
---

Run the worktree sweep script to find and clean up stale worktrees across ~/Dev.

Pass through any arguments: $ARGUMENTS

Default (no args) runs interactive mode. Use `--dry-run` to preview, `--auto` to auto-remove safe ones.

If $ARGUMENTS contains `--triage`, invoke the `worktree-triage` skill to analyze WARN/DIRTY worktrees and recommend keep/archive/remove for each. The skill runs `ccw-sweep --dry-run` itself, then fans out one read-only `worktree-content-digest` haiku sub-agent per WARN/DIRTY worktree (in parallel) to ground each verdict in the worktree's real contents. It recommends only — it never removes anything.

Otherwise, run the sweep script directly:

```bash
ccw-sweep $ARGUMENTS
```

Report the results to the user in a concise summary.
