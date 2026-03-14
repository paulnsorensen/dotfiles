---
name: cheese-convoy
description: Rescue multiple PRs in parallel — each gets its own worktree agent running /move-my-cheese. The convoy rolls through the wasteland, finding all the cheese that moved.
argument-hint: <PR numbers, space-separated>
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Task, WebFetch
---

Rescue PRs **$ARGUMENTS** — the cheese convoy rides!

Each PR gets its own isolated worktree agent running the full `/move-my-cheese` workflow in parallel. No sandbox prompts, no cross-contamination, consolidated report at the end.

## Skills Used

| Phase | Skill | Why |
|---|---|---|
| Dispatch | **worktree** | Isolated worktree per PR |
| Per-PR | **move-my-cheese** | Full PR rescue workflow |
| Report | **gh** | PR status, CI re-runs |

## Phase 1 — Recon All PRs

Before dispatching, gather context on all PRs in parallel to catch issues early:

```bash
# For each PR number in $ARGUMENTS:
gh pr view <PR> --json number,title,headRefName,mergeable,mergeStateStatus,reviewDecision
gh pr checks <PR>
```

Build a dispatch table:

```
## Convoy Manifest

| PR | Title | Branch | Mergeable | CI | Action |
|----|-------|--------|-----------|------|--------|
| 59 | feat(lsp): add packages | feat/lsp-pkgs | CLEAN | pass | DISPATCH |
| 60 | feat(hooks): block inline | claude/inline-test | CLEAN | fail | DISPATCH |
| 61 | feat(packages): add mdvi | claude/md | BLOCKED | - | SKIP (ask user) |
```

**SKIP** any PR that is:
- Draft (unless user says otherwise)
- Closed or merged
- BLOCKED mergeable status — ask user before proceeding

Present the manifest and confirm before dispatching.

## Phase 2 — Dispatch Convoy

For each DISPATCH PR, launch an agent **in a worktree** with `bypassPermissions` mode:

```
# Launch ALL in a SINGLE message for true parallelism:

Agent(
  isolation="worktree",
  mode="bypassPermissions",
  prompt="Run /move-my-cheese <PR#>. Full PR rescue: recon, merge main, diagnose CI, fix failures, quality sweep (age + ricotta-reducer + cheese-responder), push fixes. Report what was wrong, what was fixed, and what needs CI re-run."
)
```

Each worktree agent:
- Gets its own isolated copy of the repo (no conflicts between agents)
- Has `bypassPermissions` mode — all tool calls (Edit, Bash, MCP) run without prompts
- Runs the complete move-my-cheese flow (Phases 1-4)
- Pushes fixes to the PR branch from within its worktree

### Why `bypassPermissions` (not `acceptEdits`)

`acceptEdits` only auto-approves Edit/Write tools. PR rescue requires Bash commands (`gh pr`, `git push`, build/test) and MCP calls (GitHub plugin for PR comments, CI re-runs). Using `acceptEdits` still triggers sandbox prompts for every `gh` heredoc, `git push`, and build command — defeating parallel automation.

`bypassPermissions` is safe here because:
- Each agent runs in an isolated worktree (filesystem isolation)
- Agents can only push to the PR's remote branch (not main/force-push)
- The convoy manifest in Phase 1 gives the user a confirm gate before agents launch
- Error recovery rules prevent destructive operations (no force-push without asking)

## Phase 3 — Collect Reports

As each agent completes, collect its report. Build a consolidated convoy report:

```
## Convoy Report

### PR #59 — feat(lsp): add packages
**Status**: Fixed and pushed
**Issues**: 2 test failures (assertion mismatch after merge)
**Fixes**: Updated test expectations, removed stale import
**Quality sweep**: age clean, ricotta-reducer removed 1 dead export
**CI**: Re-run triggered (infra flake on shellcheck)

### PR #60 — feat(hooks): block inline
**Status**: Fixed and pushed
**Issues**: Merge conflict in zsh/claude.zsh (additive — both sides added aliases)
**Fixes**: Kept both alias sets, resolved conflict
**Quality sweep**: cheese-responder addressed 2 Copilot comments (score 85, 90)
**CI**: All green after push

### PR #61 — SKIPPED (blocked mergeable status)

---

### Summary
| PR | Status | Fixes | Sweep Findings | CI |
|----|--------|-------|----------------|------|
| 59 | pushed | 2 | 1 dead export | re-run |
| 60 | pushed | 1 conflict | 2 review replies | green |
| 61 | skipped | - | - | - |
```

## Phase 4 — Cleanup

After all agents complete:
1. Report any worktrees that had changes (they persist until merged)
2. Report any PRs that still have failing CI or unresolved issues
3. Offer to re-run failed CI checks: `gh run rerun <run-id> --failed`

## Error Recovery

- If a worktree agent fails, report the failure and continue with remaining PRs
- If a PR branch is checked out in another worktree, the agent handles this (move-my-cheese Phase 2 worktree check)
- If >5 PRs are requested, warn about resource usage and confirm before dispatching
- Never force-push from any worktree agent without asking
- If an agent reports confidence < 75 on any fix, surface it in the convoy report for user decision
