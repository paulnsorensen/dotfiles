---
name: worktree-session
model: sonnet
effort: medium
description: >
  Creates or resumes an isolated editing session in a Git worktree.
  Use when the user says "create an isolated worktree", "resume a worktree session",
  "move this task into a worktree", "delegate in a worktree", or "start a worktree session".
  Also use for /worktree-session.
  Do NOT use for worktree searches (/worktree-find), cleanup triage (/worktree-triage),
  or Git-only operations (/wt-git).
argument-hint: "<task or existing worktree> [base branch]"
---

# worktree-session

Select the session boundary before creating a checkout.
A Git worktree or shell directory change does not change the current session's permissions.

## Inputs

Parse the text after the skill name as the task, target checkout, and requested base.
Determine whether the user wants child work, another conversation, or a move of the current task.
Ask only when the request leaves a material choice unresolved.
Derive a short task slug when the request identifies the task.

## Flow

1. Inspect the current session's checkout, branch, write permissions, and available session tools.
   Inspect the target's branch and dirty state when resuming.
   Stop on a permission denial.
2. Select the existing checkout for resumption.
   Preserve its tracked, untracked, and staged changes.
   For new work, use local commits for dependent tasks and the remote default branch for independent tasks.
   Resolve the requested base commit before launch.
   Confirm that the selected mechanism starts from that commit.
   Report blocked when the mechanism cannot use the requested base.
   Uncommitted changes do not transfer to a new checkout.
   Ask before proceeding when the task depends on changes that the selected mechanism cannot transfer.
3. Read the matching reference before selecting a launcher.
   In T3, read [T3 routing](references/t3.md).
   Outside T3, read [native and CLI routing](references/native-cli.md).
   Prefer a supported harness-native session mechanism.
   Use a CLI launcher only when it starts a separate session in the selected checkout.
   If neither exists, report the missing capability without creating an unused checkout.
4. Start or select the destination through that mechanism.
   Retain its task or session identifier.
   A launch acknowledgment is pending, not proof that the destination can edit.
5. Verify from the destination session: checkout path, expected branch, preserved changes, and authorized write access.
   For new work, also verify the starting base commit.
   Use host permission metadata when it establishes access.
   Otherwise, request an authorized, reversible write probe from the destination.
   Remove only that probe.
   Keep the parent within its existing permissions.
   Report pending when destination verification is unavailable.
6. Return the result below.
   Continue destination work only after verification passes.

## Output

Report:

- State: `ready`, `pending`, or `blocked`.
- Mechanism and task or session identifier, when available.
- Destination checkout, branch, and base for new work.
- Dirty-change preservation and destination write-access evidence.
- Remaining operator action or missing capability.

Only destination evidence permits `ready`.
A plan, checkout path, or successful `cd` does not.

## Discipline

Keep session ownership and checkout creation separate.
Signals of a broken boundary include an out-of-root write, a permission-expansion request, or checkout creation without a session route.
Stop and report the unsupported transition.

## What this skill never does

- Expand write roots or restart the parent to reach another checkout.
- Launch a top-level conversation when the request only asks for child work.
- Commit, stash, reset, clean, delete, or copy user changes to manufacture a usable base.
- Switch providers without approval.
- Publish changes or provision project environments.

## References

- [T3 routing](references/t3.md) — read when the active session runs inside T3.
- [Native and CLI routing](references/native-cli.md) — read when the active session runs outside T3.
