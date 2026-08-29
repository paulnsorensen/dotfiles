---
name: worktree-triage
model: sonnet
effort: medium
allowed-tools: Bash, AskUserQuestion, Agent
description: >
  Triage WARN/DIRTY git worktrees into keep/archive/remove/stash
  recommendations. Use for /worktree-triage or "triage (stale) worktrees".
  Recommends only — never removes or commits.
---

# worktree-triage

Runs inline, not as a sub-agent — it fans out sub-agents itself and only one
nesting level exists (ADR-348-A). It recommends only: never remove, commit,
stash, or push.

1. `<skill-dir>/scripts/snapshot.sh [--path DIR]` — WARN/DIRTY worktrees with
   reasons and nested-child warnings. A parent that nests an unmerged/dirty
   child must not be removed until the child is relocated (the warning prints
   the `git worktree move` command).
2. Fan out one `worktree-content-digest` haiku agent per WARN/DIRTY worktree —
   all in a single message so they run in parallel, one worktree path each.
   Cap at 20, oldest first.
3. Verdict — exactly one per worktree, from digest + metadata:
   **REMOVE** (no unique value: old, no PR, diff already in default) ·
   **ARCHIVE** (unique work, inactive — tag before removal) ·
   **KEEP** (recent activity, open PR, or significant unique diff) ·
   **STASH** (user's choice; DIRTY only).
4. DIRTY worktrees: never auto-decide on uncommitted work. Show the digest
   context, then AskUserQuestion: Commit & archive · Stash & remove · Keep ·
   Discard & remove. More than 3 DIRTY → batch: one default action with
   per-worktree overrides.
5. Report: per-repo table (Worktree | Action | Reason-from-digest | Commits |
   Age), then for each REMOVE/ARCHIVE the output of
   `<skill-dir>/scripts/commands.sh <repo-root> <slug> <action>` as the
   recommended commands, plus any relocation warnings from step 1.
