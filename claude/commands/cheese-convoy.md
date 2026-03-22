---
name: cheese-convoy
description: Rescue and consolidate open PRs in parallel. Auto-discovers open PRs when no args given. Groups related PRs into fewer consolidated PRs (reducer pattern) to reduce CI waste and merge conflicts, then dispatches worktree agents running /move-my-cheese. Use when asked to "rescue PRs", "fix my PRs", "convoy", or "consolidate PRs".
argument-hint: [<PR numbers, space-separated>] [--all] [--no-consolidate] [--no-combine] [--include-drafts]
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Task, WebFetch
---

Rescue and consolidate PRs — the cheese convoy rides!

If PR numbers are provided, rescue those. If no PR numbers are given, auto-discover your open PRs (authored by you) for the current repo. Groups related PRs into fewer consolidated PRs before dispatching parallel worktree agents.

## Skills Used

| Phase | Skill | Why |
|---|---|---|
| Discover | **gh** | List open PRs when no args given |
| Recon | **gh** | Batch PR status via helpers |
| Combine | **gh** | Close superseded PRs |
| Consolidate | **sub-agent** (opus) | Group PRs by slice boundary into 1-3 groups |
| Dispatch | **worktree** | Isolated worktree per group |
| Per-group | **move-my-cheese** | Full PR rescue workflow |
| Report | **gh** | PR status, CI re-runs |

## Phase 0 — Discover (when no PR numbers)

Parse `$ARGUMENTS` to separate PR numbers (integers) from flags (tokens starting with `--`).
If no integers are found — including flags-only invocations like `--all` — auto-discover open PRs.

### Query

Use GitHub MCP (sandbox-safe, no bash approval):
```
list_pull_requests(state="open", sort="updated", direction="desc")
```

**CLI fallback** (if MCP unavailable):
```bash
gh pr list --state open --author @me --json number,title,headRefName,mergeable,updatedAt
```

### Filter

- Default: PRs authored by the current user only
- `--all` flag: include PRs from all authors
- Exclude: Draft PRs (unless `--include-drafts` flag)
- Exclude: PRs with "WIP" in the title
- Exclude: Closed or merged PRs

### Present and Confirm

```
Found N open PRs. Rescue all?

| PR | Title | Branch | Updated |
|----|-------|--------|---------|
| 59 | feat(lsp): add packages | feat/lsp-pkgs | 2h ago |
| 60 | feat(hooks): block inline | claude/inline-test | 1d ago |
| 62 | feat(agents): upgrade convoy | claude/convoy | 3d ago |

A. Rescue all
B. Select specific PRs: [space-separated numbers]
C. Cancel
```

Proceed to Phase 1 with the confirmed PR list.

Set `$PR_NUMBERS` to the confirmed space-separated list of PR integers (e.g., `59 60 62`). This variable is used throughout Phases 1–4.

**Skip**: When `$ARGUMENTS` contains PR numbers — parse them out, set `$PR_NUMBERS`, and skip to Phase 1.

## Phase 1 — Batch Recon

Gather context on ALL PRs in two batch calls (one approval each, not N):

```bash
# Metadata + files touched for all PRs at once
gh-pr-batch $PR_NUMBERS

# CI status for all PRs at once
gh-pr-checks-batch $PR_NUMBERS
```

**Fallback** (if helpers unavailable): Use GitHub MCP `pull_request_read` per PR — MCP calls don't need bash approval.

Build a dispatch table from the results:

```
## Convoy Manifest

| PR | Title | Branch | Mergeable | CI | Files | Approvals | Action |
|----|-------|--------|-----------|------|-------|-----------|--------|
| 59 | feat(lsp): add packages | feat/lsp-pkgs | CLEAN | pass | 3 | 2 | DISPATCH |
| 60 | feat(hooks): block inline | claude/inline-test | CLEAN | fail | 5 | 0 | DISPATCH |
| 61 | feat(packages): add mdvi | claude/md | BLOCKED | - | 2 | 1 | SKIP (ask) |
```

**SKIP** any PR that is:
- Draft (unless user says otherwise)
- Closed or merged
- BLOCKED mergeable status — ask user before proceeding

## Phase 1.5 — Combination Analysis

Before consolidation, detect PRs that are outright duplicates (one supersedes another).

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
| < 0.2 | **INDEPENDENT** — proceed to consolidation analysis |

### Combination Workflow

When PRs should be combined:
1. Pick the **target PR** — use `totalCommits` and `updatedAt` from `gh-pr-batch` output (highest commit count wins; break ties by most recent `updatedAt`)
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
add_issue_comment(number=<absorbed>, body="Superseded by #<target>. Changes merged into the target PR.")
```

### Skip Combination

Skip combination analysis if:
- Only 1 DISPATCH PR remains after filtering
- User passes `--no-combine` or explicitly says to skip

## Phase 1.6 — Consolidation Analysis

After combination removes duplicates, analyze whether remaining DISPATCH PRs
should be consolidated into fewer PRs. This reduces CI runs and prevents merge
conflicts when multiple PRs touch related files in the same slice.

### When to Run

| Condition | Action |
|---|---|
| 3+ DISPATCH PRs remain | Run consolidation analysis |
| 1-2 DISPATCH PRs remain | Skip — dispatch independently |
| `--no-consolidate` flag | Skip |

### Consolidation Sub-Agent (opus, effort:high)

Spawn an opus sub-agent for the grouping decision. This is architectural judgment —
mapping PR file lists to Sliced Bread slice boundaries, weighing review state
loss vs CI efficiency savings.

```
Agent(
  model="opus",
  prompt="""
You are analyzing whether to consolidate multiple PRs into fewer groups before
rescue. This is a judgment task — weigh CI savings against review state loss.

## PR Manifest
{dispatch_table_with_files_and_approvals}

## Repository Structure
{output of: ls -d */ src/*/ 2>/dev/null | head -30}

## Grouping Rules (Sliced Bread)

Group PRs using this priority:
1. **Slice boundary** (primary): PRs touching files in the same domain slice belong together
2. **File proximity** (secondary): PRs touching adjacent directories group together
3. **Logical cohesion** (tertiary): PRs implementing related features group together

Constraints:
- Never exceed 3 groups — if you'd want more, group by closest concern
- Each group must have a clear **target PR** (most commits, most recent update)
- PRs with existing approvals are expensive to consolidate (approvals are lost)

## Cost/Benefit Analysis

For each proposed group, report:
- **CI savings**: N fewer CI runs (each PR = 1 CI run; each group = 1 CI run)
- **Conflict prevention**: which PRs would conflict with each other on merge to main
- **Review cost**: total approvals lost across absorbed PRs
- **Recommendation**: CONSOLIDATE, KEEP_SEPARATE, or ASK_USER (when trade-off is close)

## Output Format

Return a structured grouping plan:

### Group 1: <short title>
- Target PR: #<N> (<title>)
- Absorbed PRs: #<N>, #<N>
- Files: <combined file list>
- Slice: <which domain slice>
- CI savings: <N> runs saved
- Approvals lost: <N>
- Conflict risk if kept separate: high|medium|low
- Recommendation: CONSOLIDATE

### Group 2: <short title>
- Target PR: #<N> (standalone)
- Files: <file list>
- Slice: <which domain slice>
- Recommendation: KEEP_SEPARATE (different slice, no overlap)

### Ungrouped (independent)
- PR #<N>: <reason it stays solo>
""",
  mode="default"
)
```

### Present and Confirm

After the sub-agent returns, present the consolidation plan:

```
## Consolidation Plan

### Option A: Consolidate (recommended)
- Group 1: PRs #59, #62 → "feat(lsp): add packages and config"
  (both touch zsh/lsp.zsh, claude/plugins/) — saves 1 CI run, 0 approvals lost
- Group 2: PR #60 → standalone (different slice)
- Benefit: 2 CI runs instead of 3, no merge conflicts between groups

### Option B: Keep separate
- Rescue each PR independently (3 CI runs)
- Risk: PRs #59 and #62 may conflict when both merge to main

A. Consolidate
B. Keep separate
C. Custom grouping: [specify]
```

**Do NOT proceed without approval.**

### After Approval

For each consolidated group:
1. Mark the **target PR** — the one `/move-my-cheese` runs on
2. Mark **absorbed PRs** — their unique commits get cherry-picked into the target
3. Update the dispatch table: one entry per group (not per PR)

For `KEEP_SEPARATE` groups: dispatch as individual PRs (no change from current behavior).

## Phase 2 — Dispatch Convoy

For each dispatch entry (group or standalone PR), launch an agent **in a worktree** with `bypassPermissions` mode.

**CRITICAL**: The agent prompt MUST tell it to invoke `/move-my-cheese <PR#>` via the Skill tool. Do NOT hand-roll a subset of the workflow — `/move-my-cheese` is the complete PR rescue flow (recon, merge, diagnose, fix, quality sweep, push). Writing your own reduced prompt drops phases and produces inferior results.

### Standalone PR (no consolidation)

```
# Launch ALL in a SINGLE message for true parallelism:

Agent(
  isolation="worktree",
  mode="bypassPermissions",
  prompt="Use the Skill tool to invoke skill='move-my-cheese' with args='<PR#>'. This runs the full PR rescue workflow. After the skill completes, report: what was wrong, what was fixed, quality sweep findings, and CI status."
)
```

### Consolidated Group (target + absorbed PRs)

```
Agent(
  isolation="worktree",
  mode="bypassPermissions",
  prompt="Use the Skill tool to invoke skill='move-my-cheese' with args='<target PR#>'. After rescue completes, cherry-pick unique commits from the absorbed PR branches (<branch list>) that aren't already in the target. Resolve any cherry-pick conflicts (prefer the target's intent). Then report: what was wrong, what was fixed, what was cherry-picked from each absorbed PR, quality sweep findings, and CI status."
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

### Group 1: feat(lsp) — PRs #59 + #62 (consolidated)
**Target PR**: #62
**Status**: Fixed and pushed (absorbed #59 changes)
**Issues**: Merge conflict in zsh/lsp.zsh (additive — both sides added aliases)
**Fixes**: Kept both alias sets, resolved conflict, cherry-picked 2 commits from #59
**Quality sweep**: fromage-fort addressed 2 Copilot comments (score 85, 90)
**CI**: All green after push
**Absorbed**: PR #59 → closed (superseded by #62)

### PR #60 — feat(hooks): block inline (standalone)
**Status**: Fixed and pushed
**Issues**: 2 test failures (assertion mismatch after merge)
**Fixes**: Updated test expectations, removed stale import
**Quality sweep**: age clean, ricotta-reducer removed 1 dead export
**CI**: Re-run triggered (infra flake on shellcheck)

### PR #61 — SKIPPED (blocked mergeable status)

---

### Summary
| Entry | PRs | Status | Fixes | Sweep | CI |
|-------|-----|--------|-------|-------|------|
| Group 1 | #59+#62 | consolidated+pushed | 1 conflict + 2 cherry-picks | 2 review replies | green |
| #60 | #60 | pushed | 2 | 1 dead export | re-run |
| #61 | #61 | skipped | - | - | - |
```

**Wrap-up signal**: If dispatching 5+ agents, collect results in batches. After all agents return, produce the consolidated report within ~10 tool calls. Write detailed per-group reports to `$TMPDIR/convoy-report-<PR#>.md` and return only the summary table to the conversation.

## Phase 4 — Cleanup

After all agents complete:
1. **Close absorbed PRs** from consolidation (if not already closed by the worktree agent):
   ```
   update_pull_request(pullNumber=<absorbed>, state="closed")
   add_issue_comment(number=<absorbed>, body="Consolidated into #<target>. Changes cherry-picked into the target PR.")
   ```
2. **Close superseded PRs** from Phase 1.5 combination (if not already closed)
3. Report any worktrees that had changes (they persist until merged)
4. Report any PRs that still have failing CI or unresolved issues
5. Offer to re-run failed CI checks: `gh run rerun <run-id> --failed`

## Error Recovery

- If a worktree agent fails, report the failure and continue with remaining groups
- If a PR branch is checked out in another worktree, the agent handles this (move-my-cheese Phase 2 worktree check)
- If >5 PRs are requested, warn about resource usage and confirm before dispatching
- Never force-push from any worktree agent without asking
- If an agent reports confidence < 70 on any fix, surface it in the convoy report for user decision
- If combination analysis can't determine overlap (e.g., `gh-pr-batch` fails), fall back to dispatching all PRs independently
- If consolidation sub-agent fails or times out, fall back to dispatching all PRs independently (no consolidation)
- If cherry-pick during consolidated rescue fails with conflicts, the worktree agent resolves or reports — never silently drop absorbed PR commits

## What You Don't Do

- **Decompose specs** — that's `/fromagerie` (decomposer + reducer for new feature atoms)
- **Create new PRs from scratch** — convoy rescues existing PRs, it doesn't author new code
- **Rewrite PR branches** — rescue means fix-and-push, not rebase-and-force-push
- **Review code quality in depth** — `/move-my-cheese` Phase 3b handles quality sweep per PR
- **Consolidate atom worktrees** — that's `fromagerie-reducer`. Convoy consolidates *existing PRs*

## Gotchas

- Consolidation loses GitHub review approvals on absorbed PRs — always surface the approval count in the consolidation plan so the user can make an informed decision
- The opus consolidation sub-agent only sees file paths, not file contents — it maps to slices by directory structure, not by reading code. Ambiguous slice membership (files in `common/` or `adapters/`) may produce suboptimal groupings
- Cherry-picking absorbed PR commits into the target can introduce conflicts that `/move-my-cheese` didn't anticipate — the worktree agent must handle these, not silently skip
- `--no-consolidate` and `--no-combine` are separate flags: `--no-combine` skips Phase 1.5 (duplicate detection), `--no-consolidate` skips Phase 1.6 (grouping into fewer PRs)
