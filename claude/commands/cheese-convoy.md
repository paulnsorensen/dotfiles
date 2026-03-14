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
| Recon | **gh** | Batch PR status via helpers |
| Combine | **gh** | Close superseded PRs |
| Dispatch | **worktree** | Isolated worktree per PR |
| Per-PR | **move-my-cheese** | Full PR rescue workflow |
| Report | **gh** | PR status, CI re-runs |

## Phase 1 — Batch Recon

Gather context on ALL PRs in two batch calls (one approval each, not N):

```bash
# Metadata + files touched for all PRs at once
gh-pr-batch $ARGUMENTS

# CI status for all PRs at once
gh-pr-checks-batch $ARGUMENTS
```

**Fallback** (if helpers unavailable): Use GitHub MCP `pull_request_read` per PR — MCP calls don't need bash approval.

Build a dispatch table from the results:

```
## Convoy Manifest

| PR | Title | Branch | Mergeable | CI | Files | Action |
|----|-------|--------|-----------|------|-------|--------|
| 59 | feat(lsp): add packages | feat/lsp-pkgs | CLEAN | pass | 3 | DISPATCH |
| 60 | feat(hooks): block inline | claude/inline-test | CLEAN | fail | 5 | DISPATCH |
| 61 | feat(packages): add mdvi | claude/md | BLOCKED | - | 2 | SKIP (ask) |
```

**SKIP** any PR that is:
- Draft (unless user says otherwise)
- Closed or merged
- BLOCKED mergeable status — ask user before proceeding

## Phase 1.5 — Combination Analysis

Before dispatching, analyze file overlap between DISPATCH PRs to detect PRs that should be combined rather than rescued separately.

### Overlap Detection

Using the `files` arrays from `gh-pr-batch` output:
1. Build a file → PR mapping from all DISPATCH PRs
2. Find files touched by 2+ PRs (overlap set)
3. Score overlap: `shared_files / min(pr_a_files, pr_b_files)`

### Combination Decision

| Overlap Score | Action |
|---|---|
| >= 0.5 (50%+ files shared) | **COMBINE** — high conflict risk, merge into one PR |
| 0.2–0.5 | **WARN** — present overlap to user, ask whether to combine |
| < 0.2 | **INDEPENDENT** — safe to rescue separately |

### Combination Workflow

When PRs should be combined:
1. Pick the **target PR** — the one with the most commits or most recent activity
2. Present the combination plan to the user for approval:
   ```
   ## Combination Plan

   PRs #60 and #62 overlap on 4/5 files (80%) — recommend combining:
   - Target: PR #62 (more recent, 5 commits)
   - Absorb: PR #60 (3 commits, all changes covered by #62)
   - Action: Dispatch only #62, close #60 with comment
   ```
3. After user confirms:
   - If target PR already contains all changes from the absorbed PR: close absorbed PR with a comment (`Superseded by #<target>. Changes covered in the target PR.`)
   - If target PR is missing some changes: dispatch a worktree agent for the target that also cherry-picks unique commits from the absorbed PR, then close the absorbed PR
4. Remove absorbed PRs from the dispatch table

**Close superseded PRs** using GitHub MCP:
```
update_pull_request(pullNumber=<absorbed>, state="closed")
add_issue_comment(issueNumber=<absorbed>, body="Superseded by #<target>. Changes merged into the target PR.")
```

### Skip Combination

Skip combination analysis if:
- Only 1 DISPATCH PR remains after filtering
- User passes `--no-combine` or explicitly says to skip

Present the manifest and confirm before dispatching.

## Phase 2 — Dispatch Convoy

For each DISPATCH PR, launch an agent **in a worktree** with `bypassPermissions` mode.

**CRITICAL**: The agent prompt MUST tell it to invoke `/move-my-cheese <PR#>` via the Skill tool. Do NOT hand-roll a subset of the workflow — `/move-my-cheese` is the complete PR rescue flow (recon, merge, diagnose, fix, quality sweep, push). Writing your own reduced prompt drops phases and produces inferior results.

```
# Launch ALL in a SINGLE message for true parallelism:

Agent(
  isolation="worktree",
  mode="bypassPermissions",
  prompt="Use the Skill tool to invoke skill='move-my-cheese' with args='<PR#>'. This runs the full PR rescue workflow. After the skill completes, report: what was wrong, what was fixed, quality sweep findings, and CI status."
)
```

For combined PRs (target absorbing another), modify the agent prompt:
```
Agent(
  isolation="worktree",
  mode="bypassPermissions",
  prompt="Use the Skill tool to invoke skill='move-my-cheese' with args='<target PR#>'. After rescue, cherry-pick commits from the absorbed PR branch (<branch>) that aren't already in the target. Then report: what was wrong, what was fixed, what was cherry-picked, quality sweep findings, and CI status."
)
```

Each worktree agent:
- Invokes `/move-my-cheese` which handles the complete flow (Phases 1-4 including quality sweep)
- Gets its own isolated copy of the repo (no conflicts between agents)
- Has `bypassPermissions` mode — all tool calls (Edit, Bash, MCP) run without prompts
- Pushes fixes to the PR branch from within its worktree

### Why `bypassPermissions` (not `acceptEdits`)

`acceptEdits` only auto-approves Edit/Write tools. PR rescue requires Bash commands (`gh pr`, `git push`, build/test) and MCP calls (GitHub plugin for PR comments, CI re-runs). Using `acceptEdits` still triggers sandbox prompts for every `gh` heredoc, `git push`, and build command — defeating parallel automation.

`bypassPermissions` is contained here because:
- Each agent runs in an isolated worktree (filesystem containment)
- The convoy manifest in Phase 1 gives the user a confirm gate before agents launch
- Prompt instructions restrict push targets (see below) — this is procedural, not enforced by the sandbox
- Error recovery rules prevent destructive operations

**Branch restriction (procedural guardrail):** Worktree agents MUST only push to the PR's branch (`git push origin HEAD:<pr-branch>`). NEVER push to main, master, or any branch other than the PR branch. NEVER force-push. These are prompt-level restrictions — `bypassPermissions` does not enforce them mechanically, so they must be explicit.

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
**Status**: Closed (superseded by #62)
**Reason**: 80% file overlap — changes absorbed into #62

### PR #62 — feat(agents): upgrade cheese-convoy
**Status**: Fixed and pushed (absorbed #60 changes)
**Issues**: Merge conflict in zsh/claude.zsh (additive — both sides added aliases)
**Fixes**: Kept both alias sets, resolved conflict, cherry-picked 2 commits from #60
**Quality sweep**: fromage-fort addressed 2 Copilot comments (score 85, 90)
**CI**: All green after push

### PR #61 — SKIPPED (blocked mergeable status)

---

### Summary
| PR | Status | Fixes | Sweep Findings | CI |
|----|--------|-------|----------------|------|
| 59 | pushed | 2 | 1 dead export | re-run |
| 60 | closed | superseded by #62 | - | - |
| 62 | pushed | 1 conflict + 2 cherry-picks | 2 review replies | green |
| 61 | skipped | - | - | - |
```

## Phase 4 — Cleanup

After all agents complete:
1. **Close superseded PRs** that were identified in Phase 1.5 (if not already closed)
2. Report any worktrees that had changes (they persist until merged)
3. Report any PRs that still have failing CI or unresolved issues
4. Offer to re-run failed CI checks: `gh run rerun <run-id> --failed`

## Error Recovery

- If a worktree agent fails, report the failure and continue with remaining PRs
- If a PR branch is checked out in another worktree, the agent handles this (move-my-cheese Phase 2 worktree check)
- If >5 PRs are requested, warn about resource usage and confirm before dispatching
- Never force-push from any worktree agent without asking
- If an agent reports confidence < 75 on any fix, surface it in the convoy report for user decision
- If combination analysis can't determine overlap (e.g., `gh-pr-batch` fails), fall back to dispatching all PRs independently
