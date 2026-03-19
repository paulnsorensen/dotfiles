---
name: fromagerie
description: Large feature orchestrator — decomposes a spec into non-overlapping atoms, executes foundation work, dispatches parallel worktree agents, then consolidates into 1-3 reviewable PRs via the reducer.
argument-hint: [<spec-file-path>] [--resume <slug>]
---

Orchestrate the full lifecycle for: **$ARGUMENTS**

Reads a spec, front-loads permissions, runs focused culture agents, decomposes into token-sized atoms, executes via expand/reduce pattern, and consolidates into 1-3 PRs.

## When to use `/fromagerie` vs `/fromage`

- **`/fromage`**: Single coherent feature or fix — one worktree, one PR.
- **`/fromagerie`**: Feature that decomposes into 5-30 independent work units with explicit file ownership — parallel agents, multiple PRs consolidated by the reducer.

Rule of thumb: if you wrote a spec with `/spec` and it clearly spans many independent files, use `/fromagerie`. If the work is sequential and interrelated, use `/fromage`.

## Orchestrator Token Discipline

The orchestrator reads ONE thing: the spec. Everything else is delegated.

The orchestrator MUST NOT:
- Use Read, Grep, or Glob on codebase files (delegate to Culture agents)
- Run build/test commands directly (delegate to atom agents)
- Read subagent full reports (work from their returned summaries)

The orchestrator SHOULD:
- Read the spec once — it is the contract for all phase decisions
- Work from subagent summaries, not full reports
- Write manifest updates after each phase transition

## Context Passing

Each phase builds on prior phases. Carry forward:
- **Slug**: derived from spec title in Phase 0
- **Spec summary**: extracted in Phase 0 (<2K chars)
- **Quality gate commands**: extracted from spec's Quality Gates section
- **Exploration summary**: from Phase 1 Culture agents
- **Tokei manifest path**: from Phase 1 culture-tokei agent
- **Decomposition result**: from Phase 2, including foundation items and atom list with token estimates
- **Manifest path**: `.claude/fromagerie/<slug>/manifest.json`

---

## Phase 0 — Ingest

### Parse Arguments

If `$ARGUMENTS` contains `--resume <slug>`:
1. Extract slug, set `RESUME=true`
2. Read manifest at `.claude/fromagerie/<slug>/manifest.json`
3. Find the last completed phase and skip to the next incomplete phase
4. Report: "Resuming <slug> from phase <N>"

If `$ARGUMENTS` is empty or the path doesn't exist:
1. Report: "No spec found. Launching /spec to create one."
2. Invoke `/spec` via Skill tool: `Skill(skill="spec")`
3. After `/spec` completes and saves to `.claude/specs/<slug>.md`, resume fromagerie with that path
4. If user cancels spec creation, stop fromagerie

Otherwise, `$ARGUMENTS` is a spec file path.

### Hard Gate: Worktree Check

Run `git rev-parse --git-dir` — if output does NOT contain `/worktrees/`:

1. **Stop.** Do not proceed.
2. Ask: "You're on the main branch. Want me to create a worktree with `/worktree <slug>`?"
3. Only proceed after user is on a worktree OR explicitly says "continue on main".

This gate is **never skipped**.

### Read and Validate Spec

Read the spec file. Fail fast with a clear error if any of these are missing:
- Executive Summary (`## Executive Summary`)
- Problem Statement (`## Problem Statement`)
- User Stories (`## User Stories`)
- Quality Gates (`## Quality Gates`) with runnable commands

Warn (but don't fail) if these sections are absent — they improve decomposition quality:
- Business Context (`## Business Context`)
- Design Principles (`## Design Principles`)
- Key Patterns (`## Key Patterns`)

Extract:
- **Spec summary** (<2K chars): what's being built (bullets), constraints, scope boundaries
- **Quality gate commands**: the exact commands from the Quality Gates section
- **Slug**: kebab-case from the spec title (<30 chars)
- **Libraries in scope**: external dependencies mentioned in the spec (for Context7 agent)
- **Scope paths**: directories/files the spec targets (for LSP and Tokei agents)

For specs >5K chars, write the full spec to `$TMPDIR/fromagerie-spec-<slug>.md` for agent distribution.

### Front-Load Permissions

Enumerate all bash commands the pipeline will need:

```json
{
  "permissions": {
    "allow": [
      "Bash(git push:*)",
      "Bash(git worktree:*)",
      "Bash(git merge:*)",
      "Bash(git checkout:*)",
      "Bash(git branch:*)",
      "Bash(git cherry-pick:*)",
      "Bash(gh pr create:*)",
      "Bash(gh pr view:*)",
      "Bash(tokei:*)",
      "<quality-gate-commands-from-spec>"
    ]
  }
}
```

Present this manifest to the user:

```
## Permission Manifest

The pipeline needs these bash permissions to run autonomously:
- git: push, worktree, merge, checkout, branch, cherry-pick
- gh: pr create, pr view
- tokei (token estimation)
- Quality gates: <list from spec>

Approve? These will be written to .claude/settings.local.json.
```

On approval: merge these permissions into `.claude/settings.local.json` (preserve existing entries, add new ones). Use `worktree-settings.sh` as the base and overlay pipeline-specific permissions.

### Create Manifest

```bash
mkdir -p .claude/fromagerie/<slug>
python3 -c "
import json, datetime
manifest = {
  'slug': '<slug>',
  'spec_path': '<spec_path>',
  'created': datetime.datetime.utcnow().isoformat() + 'Z',
  'phase': 'ingest',
  'quality_gates': <quality_gate_commands>,
  'foundation': {'items': []},
  'atoms': [],
  'reducer': {'status': 'pending', 'pr_branches': [], 'pr_metadata': []},
}
print(json.dumps(manifest, indent=2))
" > .claude/fromagerie/<slug>/manifest.json
```

---

## Phase 1 — Explore

Launch exactly **3 focused culture sub-agents** in a **single message** for true parallelism:

### Agent 1: culture-lsp (sonnet)

Structural dependency analysis via LSP.

```
Agent(
  subagent_type="culture-lsp",
  run_in_background=True,
  prompt="""
Analyze the structural dependencies for fromagerie spec: {slug}

## Spec Summary
{spec_summary}

## Scope Paths
{scope_paths}

## Slug
{slug}

Build the dependency graph, identify entry points, hubs, and blast radius for the files in scope.
"""
)
```

### Agent 2: culture-context7 (haiku)

Library documentation verification.

```
Agent(
  subagent_type="culture-context7",
  run_in_background=True,
  prompt="""
Verify library documentation for fromagerie spec: {slug}

## Libraries in Scope
{libraries_list}

## Usage Context
{how_each_library_is_used}

## Slug
{slug}

Check each library for API correctness, deprecations, and simpler alternatives.
"""
)
```

### Agent 3: culture-tokei (haiku)

Token estimation manifest.

```
Agent(
  subagent_type="culture-tokei",
  run_in_background=True,
  prompt="""
Measure token sizes for fromagerie spec: {slug}

## Scope Paths
{scope_paths}

## Slug
{slug}

Run tokei and write the size manifest with per-file token estimates.
"""
)
```

After all 3 agents return:
1. Collect inline summaries from LSP and Context7 agents (keep in orchestrator context)
2. Note the tokei manifest path: `$TMPDIR/fromagerie-tokei-<slug>.json`
3. Pass LSP node list path and tokei manifest path to Phase 2

Update manifest: `"phase": "explore"`.

---

## Phase 2 — Decompose

Launch `fromagerie-decomposer` (opus, plan mode) with:
- Spec (inline if <5K, temp file path otherwise)
- Culture exploration summaries (LSP structural findings + Context7 library findings)
- Tokei manifest path: `$TMPDIR/fromagerie-tokei-<slug>.json`
- LSP node list path: `$TMPDIR/fromagerie-culture-lsp-<slug>-nodes.json`
- Quality gate commands

The decomposer will:
1. Read the tokei manifest for per-file token estimates
2. Use LSP/Serena to verify file dependencies
3. Enforce hard constraints: <50K tokens per atom, 2-3 files per atom
4. Output foundation items + parallel atoms with token budget validation table

### Validation (hard constraints)

After decomposer returns, validate:

**Overlap check:**
```python
all_files = []
for atom in atoms:
    for f in atom['files']:
        if f in all_files:
            FAIL: "File overlap detected: {f}. Re-decomposing."
        all_files.append(f)
```

**Token budget check:**
- Every atom must have `estimated_tokens < 50,000`
- Every atom must have 1-3 files

If any validation fails: re-run decomposer with the violation highlighted. Maximum 2 retries, then stop and report.

If atom count > 10: warn — "Feature may be too large for a single /fromagerie run. Consider splitting the spec."

Update manifest with full decomposition result (including `estimated_tokens` per atom).

---

## Phase 3 — Gate

Present the full decomposition plan as visible output:

```
## Fromagerie Plan: <slug>

### Foundation (sequential, ~<N> min)
1. <description> — files: [<list>] — commit boundary: <label>
2. ...

### Atoms (parallel, wall-clock ~<max_atom_time> min)
| # | Description | Files | Est. Tokens | Budget | Complexity | Est. Time |
|---|---|---|---|---|---|---|
| 1 | <desc> | 2 files | 12,500 | 25% | small | ~2 min |
| 2 | <desc> | 3 files | 38,000 | 76% | medium | ~5 min |
...

**Token budget**: all atoms <50K tokens (sonnet model)
**PR consolidation**: reducer will consolidate into 1-3 PRs after atom completion
**Total estimated time**: <foundation_time> + <max_atom_time> min wall-clock
```

Then ask with lettered options:

```
A. Approve — start execution
B. Modify — I want to change the decomposition
C. Re-decompose — needs different atom boundaries
D. Pause — hold off
```

**Do NOT proceed without approval.**

On deny with guidance: re-run Phase 2 with user's guidance appended to the decomposer prompt.

Update manifest: `"phase": "gate_approved"`.

---

## Phase 4 — Foundation

If foundation items are small (total estimated tokens < 50K across all items):
- Execute directly on the current worktree using Edit/Write tools
- Run quality gates after each item
- Commit via `/commit` skill

If foundation items are large (total estimated tokens >= 50K):
- Use the **expand/reduce loop**: opus plans splits → sonnet agents execute in parallel worktrees → opus reduces

### Expand/Reduce for Foundation (large only)

```
# Opus plans: split foundation into token-sized chunks
plan = opus_plan(foundation_items, tokei_data)

# Sonnet agents execute in parallel worktrees
agents = []
for chunk in plan.chunks:
    assert chunk.estimated_tokens < 50_000
    agents.append(Agent(
        isolation="worktree",
        mode="bypassPermissions",
        run_in_background=True,
        prompt="Execute foundation chunk: {chunk.description}\nFiles: {chunk.files}\n..."
    ))

# Wait for all, then opus reduces (merge back, fix integration)
results = wait_all(agents)
# Merge foundation worktree branches back to orchestrator's branch
```

### After Foundation (either path)

For each foundation item:
1. If gates fail: **STOP**. Report the failure. Do not proceed to Phase 5.
2. Commit via `/commit` skill (conventional commit format)
3. Update manifest with commit SHA

Push to branch: `git push origin HEAD`
Foundation must be pushed before atoms dispatch — worktree agents branch from HEAD.

Update manifest: `"phase": "foundation_complete"`, include commit SHAs.

---

## Phase 5 — Dispatch

Launch ALL atom agents in a **single message** for true parallelism.

Each atom agent:

```
Agent(
  isolation="worktree",
  mode="bypassPermissions",
  run_in_background=True,
  model="sonnet",
  prompt="""
You are executing atom #{N} of a /fromagerie decomposition for spec: {slug}

## File Assignment (HARD CONSTRAINT)
You may ONLY modify these files:
{file_list}

Do NOT create, modify, or delete any file not on this list.

## Token Budget
Estimated tokens for your files: {estimated_tokens} / 50,000

## Your Plan Steps
{atom_plan_steps}

## Spec Summary
{spec_summary}

## Quality Gates
{quality_gate_commands}

## Exploration Context
{exploration_summary}

## Workflow
1. Cook: Implement your plan steps (fromage-cook agent patterns)
2. Press: Run quality gates — fix all failures before continuing
3. Age: Self-review via fromage-age (sonnet-class, architecture + complexity only, >= 75 confidence)
4. De-slop: Use Skill tool to invoke skill='de-slop' on changed files
5. Commit: Use Skill tool to invoke skill='commit' (conventional format)
6. Write PR metadata: Create a file `pr-metadata.json` in the worktree root with:
   ```json
   {"title": "<conventional PR title>", "body": "<summary of this atom's changes>"}
   ```

## IMPORTANT: Do NOT push or create PRs
The orchestrator handles git push and PR creation. Your job ends at committing
and writing pr-metadata.json. Do not run `git push`, `gh pr create`, or any
GitHub CLI commands.

## Safety Guardrails
- If a change touches a file not on your list, skip it and note it in pr-metadata.json body
- If quality gates fail after 3 rounds, stop and report failures — do not commit
"""
)
```

**Why no push/PR in atoms**: `bypassPermissions` only suppresses Edit/Write approval dialogs — it does NOT auto-approve Bash commands. The Bash allowlist (`permissions.allow`) is a separate mechanism. In sandboxed environments (Conductor, fresh sessions), atoms lack the allowlist entries for `git push` / `gh pr create`. Moving push+PR to the orchestrator (which runs in the user's session with full permissions) eliminates this failure mode entirely.

Update manifest: `"phase": "dispatched"`, mark each atom status as `"running"`.

---

## Phase 6 — Reduce & Publish

Wait for background agent completion notifications.

### 6a. Collect Atom Results

As each atom agent reports back:
1. Parse its report: status (success/failure), worktree path, error summary
2. Derive branch name: `git -C <worktree-path> rev-parse --abbrev-ref HEAD`
3. Update manifest: atom status, worktree path, branch name, error field
4. Report progress: "Atom 3/6 complete — code ready in worktree"

### Retry Logic

For failed atoms: retry ONCE with the error context appended:

```
Agent(
  isolation="worktree",
  mode="bypassPermissions",
  run_in_background=True,
  model="sonnet",
  prompt="""<original atom prompt>

## Retry Context
Previous attempt failed with:
{error_summary}

Address this failure before proceeding with the workflow.
"""
)
```

After retries: mark `"retry_count": 1`. Do not retry a second time — move on.

### 6b. Launch Reducer

After all atoms are collected (including retries), launch the **fromagerie-reducer** (opus):

```
Agent(
  subagent_type="fromagerie-reducer",
  prompt="""
Consolidate atom worktrees into 1-3 reviewable PRs for: {slug}

## Manifest Path
.claude/fromagerie/{slug}/manifest.json

## Spec Summary
{spec_summary}

## Atom Worktree Paths
{list of worktree paths for successful atoms}

## Target Branch
{orchestrator_branch}

Read each atom's diff and pr-metadata.json, group into 1-3 PRs by Sliced Bread
boundaries, cherry-pick into consolidated branches, fix integration issues, and
write PR metadata files.
"""
)
```

The reducer will:
1. Analyze all atom diffs
2. Group into 1-3 PRs by slice boundary / logical cohesion
3. Cherry-pick into consolidated branches
4. Fix integration issues (deduped imports, type mismatches)
5. Run quality gates
6. Write PR metadata to `.claude/fromagerie/<slug>/pr-<N>-metadata.json`

### 6c. Publish PRs (orchestrator-owned)

After the reducer returns, the **orchestrator** creates PRs from the consolidated branches.

For each consolidated PR:
1. Read PR metadata from `.claude/fromagerie/<slug>/pr-<N>-metadata.json`
2. Push the consolidated branch: `git push -u origin <branch>`
3. Create the PR using `gh pr create --head <branch> --title <title> --body-file <path>`:
   - Write body to a temp file, pass via `--body-file` to avoid shell-escaping issues
4. Update manifest: PR number, PR URL
5. Report: "PR 1/2 — #74 created: <title>"

### 6d. Optional Convoy

If the reducer produced 2+ PRs and any have CI issues, offer to run `/cheese-convoy`:

```
Reducer produced {N} PRs. Want me to run /cheese-convoy on them?
```

If user approves: `Skill(skill="cheese-convoy", args="<PR# PR# ...>")`

Update manifest: `"reducer": {"status": "completed", "pr_branches": [...], "pr_metadata": [...]}`.

---

## Final Report

```
## Fromagerie Complete: <slug>

### Atom Results
| # | Description | Status | Tokens Used |
|---|---|---|---|
| 1 | <desc> | success | 12,500 |
| 2 | <desc> | failed | — |
...

### Consolidated PRs
| PR | Title | Atoms | Files | Integration Fixes |
|----|-------|-------|-------|-------------------|
| #74 | feat(orders): add fulfillment | A1, A3 | 4 | 2 |
| #75 | feat(pricing): add tiers | A2 | 2 | 0 |

### Manual Actions Needed
- Atom #2 failed after retry: {error_summary} — review and run /fromage manually
- <any other items requiring user follow-up>

Manifest: .claude/fromagerie/<slug>/manifest.json
```

---

## Manifest Schema

```json
{
  "slug": "feature-name",
  "spec_path": ".claude/specs/feature-name.md",
  "created": "2026-03-14T10:00:00Z",
  "phase": "dispatched",
  "quality_gates": ["dots test"],
  "foundation": {
    "items": [
      {
        "description": "Add shared types",
        "files": ["src/domains/common/types.ts"],
        "estimated_tokens": 5000,
        "commit_sha": "abc123",
        "status": "completed"
      }
    ]
  },
  "atoms": [
    {
      "id": 1,
      "description": "Implement order slice",
      "files": ["src/domains/orders/index.ts"],
      "estimated_tokens": 12500,
      "complexity": "small",
      "status": "completed",
      "worktree_path": "/path/to/.worktrees/atom-1",
      "branch": "fromagerie/slug/atom-1",
      "retry_count": 0,
      "error": null
    }
  ],
  "reducer": {
    "status": "completed",
    "pr_branches": ["fromagerie/slug/pr-1", "fromagerie/slug/pr-2"],
    "pr_metadata": [
      {
        "branch": "fromagerie/slug/pr-1",
        "title": "feat(orders): add fulfillment",
        "atoms": [1, 3],
        "pr_number": 74,
        "pr_url": "https://github.com/..."
      }
    ]
  }
}
```

---

## Phase Transitions

One-line status between phases:
```
--- Phase 0 complete --- Spec ingested, permissions approved. Moving to Explore...
--- Phase 1 complete --- 3 culture agents (LSP, Context7, Tokei), tokei manifest ready. Moving to Decompose...
--- Phase 2 complete --- 2 foundation items, 5 atoms (all <50K tokens, no overlap). Moving to Gate...
--- Phase 4 complete --- 2 foundation commits pushed. Moving to Dispatch...
--- Phase 5 complete --- 5 atoms dispatched. Waiting for completion...
--- Phase 6 complete --- Reducer consolidated into 2 PRs. Publishing...
```

---

## Error Recovery

- **No spec argument**: invoke `/spec`, resume after save
- **Overlap detected**: re-run decomposer with conflict noted (max 2 retries, then stop)
- **Token budget exceeded**: re-run decomposer with violation noted (max 2 retries, then stop)
- **Foundation gate failure**: stop execution, report, do not dispatch atoms
- **Atom fails**: retry once with error context, then mark failed and continue
- **All atoms fail**: report and stop, no reducer launch
- **Reducer fails**: fall back to per-atom PRs (create one PR per successful atom, like v1)
- **Resume**: `--resume <slug>` reads manifest and skips completed phases
- **Never proceed past Phase 3 gate without explicit user approval**
- **Never claim green on partial work** — report partial/failed atoms honestly in the final report
