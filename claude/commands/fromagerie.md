---
name: fromagerie
description: Large feature orchestrator — decomposes a spec into atoms + wiring DAG, executes via dual fan-out/fan-in pattern, consolidates into reviewable PRs.
argument-hint: [<spec-file-path>] [--resume <slug>]
---

Orchestrate the full lifecycle for: **$ARGUMENTS**

Reads a spec, front-loads exploration, decomposes into atoms + wiring DAG, executes via dual fan-out/fan-in, and consolidates into 1-3 PRs.

## When to use `/fromagerie` vs `/fromage`

- **`/fromage`**: Single coherent feature or fix — one worktree, one PR. Sequential, interrelated work.
- **`/fromagerie`**: Feature that decomposes into 5-30 independent work units — parallel agents, wiring phase, consolidated PRs. Requires a spec from `/spec`.

## Orchestrator Token Discipline

The orchestrator reads ONE thing: the spec. Everything else is delegated.

**MUST NOT**: Read/Grep/Glob codebase files, run build/test commands, read subagent full reports.
**SHOULD**: Read spec once, work from subagent summaries, write manifest updates after each phase.

## Context Passing

Carry forward between phases:
- **Slug**: kebab-case from spec title (<30 chars)
- **Spec summary**: <2K chars, extracted in Phase 0
- **Quality gate commands**: from spec's Quality Gates section
- **Manifest path**: `.claude/fromagerie/<slug>/manifest.json`

Everything else is on disk — exploration summaries, tokei manifests, integration manifests. Read from disk only when needed by the current phase.

## Compaction Strategy

Three compaction seams where the orchestrator aggressively drops accumulated context:

| Seam | After | DROP | KEEP |
|------|-------|------|------|
| **C1** | Phase 0 (gate approved) | Full spec text, permission manifest | Slug, spec summary (2K), manifest path, quality gates |
| **C2** | Phase 2 (atoms done) | Exploration summaries, decomposition details, atom prompts, atom results | Slug, spec summary, manifest path, wiring DAG (from disk), quality gates |
| **C3** | Phase 5 (final fan-in) | Wiring DAG, merger reports | Slug, spec path (for spec-verify), quality gates, changed files list |

At each seam, the orchestrator writes a self-summary to the manifest before dropping context:

```json
{
  "phase_summary": "<2-3 sentences: what happened, what succeeded/failed, what's next>",
  "carry_forward": ["slug", "spec_summary", "manifest_path", "quality_gates"]
}
```

On resume (or after compaction), read `phase_summary` from the manifest to reconstruct enough context to continue. This is the ONLY mechanism for cross-seam continuity — do not rely on conversation history.

---

## Phase 0 — Pre-compile

### Parse Arguments

If `$ARGUMENTS` contains `--resume <slug>`:
1. Read manifest at `.claude/fromagerie/<slug>/manifest.json`
2. Skip to the next incomplete phase
3. Report: "Resuming <slug> from phase <N>"

If `$ARGUMENTS` is empty or path doesn't exist:
1. Invoke `/spec` via Skill tool
2. Resume fromagerie with the saved spec path

### Hard Gate: Worktree Check

Run `git rev-parse --git-dir` — if output does NOT contain `/worktrees/`:
1. **Stop.** Ask: "You're on the main branch. Want me to create a worktree with `/worktree <slug>`?"
2. Only proceed after user is on a worktree OR explicitly says "continue on main".

This gate is **never skipped**.

### Read and Validate Spec

Read the spec file. Fail fast if missing: Executive Summary, Problem Statement, User Stories, Quality Gates.

Extract:
- **Spec summary** (<2K chars): what's being built, constraints, scope boundaries
- **Quality gate commands**: exact commands from Quality Gates section
- **Slug**: kebab-case from spec title
- **Libraries in scope**: for Context7 agent
- **Scope paths**: directories/files the spec targets

For specs >5K chars, write full spec to `$TMPDIR/fromagerie-spec-<slug>.md`.

### Explore (3 parallel agents)

Launch in a **single message**:

**Agent 1: culture-lsp** (sonnet) — Structural dependency analysis + **connector detection**. Must identify entry-points, hubs, utilities, leaves, AND connectors (registration point files like DI containers, routers, barrel files).

**Agent 2: culture-context7** (haiku) — Library documentation verification.

**Agent 3: culture-tokei** (haiku) — Token estimation manifest.

After all 3 return: collect summaries, note file paths for tokei manifest and LSP node list.

### Decompose

Launch `fromagerie-decomposer` (opus, plan mode) with spec, culture summaries, tokei manifest path, LSP node list path, and quality gates.

The decomposer produces THREE artifacts:
1. `seed_items[]` — compile-time dependencies for 2+ atoms
2. `atoms[]` — implementation units with `test_targets` per atom
3. `wiring[]` — DAG of wiring tasks with `depends_on` edges

### Validate Decomposition

**Atom overlap check**: No file appears in more than one atom. Foundation files not in any atom.
**Token budget check**: Every atom `estimated_tokens < 50,000`, 1-3 files each.
**Wiring DAG check**: No cross-branch overlap (wiring tasks sharing files must have a dependency edge).
**Barrel file check**: Any atom creating a new slice includes the barrel file.

If validation fails: re-run decomposer with violation highlighted. Max 2 retries.

### Front-Load Permissions

Present permission manifest to user (git, gh, tokei, quality gates). On approval, merge into `.claude/settings.local.json`.

### Gate — User Approval

Present the full plan:

```
## Fromagerie Plan: <slug>

### Seed (sequential)
1. <description> — files: [<list>]

### Atoms (parallel, wall-clock ~<max_atom_time>)
| # | Description | Files | Tokens | Budget | Test Targets |
|---|---|---|---|---|---|

### Wiring DAG
| # | Type | File | Depends On | Tokens |
|---|---|---|---|---|
| W1 | barrel_export | orders/index.ts | — | 1,500 |
| W2 | di_registration | app/container.ts | W1 | 2,000 |

### Review Pipeline
spec-verify → age → de-slop (precedence order), then fix pass

A. Approve — start execution
B. Modify — change the decomposition
C. Re-decompose — different boundaries
D. Pause — hold off
```

**Do NOT proceed without approval.**

Create manifest at `.claude/fromagerie/<slug>/manifest.json`.

Update manifest: `"phase": "gate_approved"`.

### ═══ COMPACTION SEAM C1 ═══
Drop: full spec text, permission manifest, decomposition details.
Keep: slug, spec summary (2K), manifest path, quality gates.

---

## Phase 1 — Seed

Seed items are minimal: only shared types/protocols that atoms literally cannot compile without.

If total seed tokens < 50K: execute inline with Edit/Write. Otherwise: split into chunks and dispatch parallel cook agents.

For each seed item:
1. Implement the change
2. Run quality gates — if fail, **STOP**
3. Commit via `/commit` skill

Push to branch: `git push origin HEAD` (atoms branch from HEAD).

Update manifest: `"phase": "seed_complete"`, include commit SHAs.

---

## Phase 2 — Fan Out (Atoms)

Launch ALL atom agents in a **single message**. If >5 atoms, dispatch in waves of 5.

Each atom agent:

```
Agent(
  isolation="worktree",
  mode="bypassPermissions",
  run_in_background=True,
  prompt="""
You are executing atom #{N} for spec: {slug}

## File Assignment (HARD CONSTRAINT)
You may ONLY modify these files: {file_list}
Exception: `pr-metadata.json` in the worktree root.

## Token Budget
Estimated tokens: {estimated_tokens} / 50,000

## Plan Steps
{atom_plan_steps}

## Test Targets
Run ONLY these tests after implementation: {test_targets}
Do NOT run the full test suite.
Fallback if no test targets: compile check only ({fallback_command})

## Spec Summary
{spec_summary}

## Workflow
1. Cook: Implement plan steps
2. Targeted test: Run test_targets only — fix failures
3. De-slop: Skill(skill='de-slop') on changed files
4. Commit: Skill(skill='commit')
5. Write pr-metadata.json with title and body

## Do NOT push or create PRs
The orchestrator handles that.

## Do NOT run press or age
Phase 6 handles full-diff review.
"""
)
```

Collect results as atoms complete. For failed atoms: retry ONCE with error context. Mark `retry_count: 1`, do not retry twice.

Update manifest: atom statuses, worktree paths, branch names.

### ═══ COMPACTION SEAM C2 ═══
Drop: exploration summaries, decomposition details, atom dispatch prompts, atom return summaries.
Keep: slug, spec summary (2K), manifest path (has atom branches), quality gates.
Read from disk when needed: wiring DAG from integration manifest.

---

## Phase 3 — Fan In (Merge)

Read atom branches from manifest. Launch `fromagerie-merger`:

```
Agent(
  subagent_type="fromagerie-merger",
  prompt="""
Merge atom worktrees for: {slug}

## Manifest Path
.claude/fromagerie/{slug}/manifest.json

## Atom Branches
{list of branches for successful atoms}

## Target Branch
{orchestrator_branch}

Merge mechanics ONLY. Cherry-pick commits, resolve conflicts, dedup imports.
Do NOT review integration, do NOT fix type mismatches beyond conflict resolution.
"""
)
```

After merger returns: verify branch has all atom commits. If merger fails, fall back to per-atom PRs.

---

## Phase 4 — Fan Out (Wiring DAG)

Read integration manifest from `.claude/fromagerie/<slug>/manifest.json`.

Dispatch wiring tasks in **topological order** of the DAG:
1. Find all wiring tasks with no unmet dependencies → dispatch in parallel
2. Wait for completion
3. Find newly unblocked tasks → dispatch next wave
4. Repeat until DAG is exhausted

Each wiring agent uses the dedicated `fromage-wire` agent type. Wiring agents run on the orchestrator's branch (no worktree isolation) because they touch connector files that may overlap — the DAG's dependency edges enforce sequential access to shared files.

```
Agent(
  subagent_type="fromage-wire",
  mode="acceptEdits",
  run_in_background=True,
  prompt="""
You are performing integration wiring for: {slug}

## Wiring Task
Type: {type} (barrel_export | di_registration | route_wiring | event_subscription | config_entry)
File: {file}
Description: {description}

## Spec Summary
{spec_summary}
"""
)
```

For failed wiring tasks: retry ONCE. If still failing, mark incomplete in manifest.

Update manifest: wiring task statuses.

---

## Phase 5 — Fan In (Final)

Launch `fromagerie-merger` again to merge wiring commits onto the main branch:

```
Agent(
  subagent_type="fromagerie-merger",
  prompt="""
Final merge of wiring commits for: {slug}

## Target Branch
{orchestrator_branch}

## Wiring Commits
{list of wiring commit SHAs or branches}

Merge mechanics only. If conflicts arise with atom code, STOP and report —
this indicates a decomposer error (wiring touched implementation).
"""
)
```

If final merger reports conflicts: **STOP**, report to user. Do not auto-resolve — wiring conflicts mean the decomposition was wrong.

### ═══ COMPACTION SEAM C3 ═══
Drop: wiring DAG, merger reports, wiring task details.
Keep: slug, spec path (for spec-verify), quality gates, list of all changed files.

---

## Phase 6 — E2E + Review

### 6a. Quality Gates

Run full quality gates from spec via `whey-drainer` (haiku). If gates fail: fix and re-run (max 3 rounds). If still failing: report to user.

### 6b. Review Pipeline (precedence order)

Run in this order. Each agent sees the full diff (seed + atoms + wiring).

**Step 1** — Launch in parallel (neither spawns conflicting sub-agents):
- `fromage-press` (sonnet) — adversarial testing on full diff
- `spec-verify` (opus, forked) — contract verification against spec

**Step 2** — After press + spec-verify return:
- `fromage-age` (opus) — architecture review on full diff

**Step 3** — After age returns:
- `/de-slop` — syntactic AI pattern cleanup

### 6c. Synthesize and Fix

Collect all findings. Precedence for conflicts on same code:
1. **spec-verify** (contract violations) — highest
2. **age** (architectural issues)
3. **de-slop** (syntactic patterns) — lowest

Deduplicate by file path. Build the synthesis in this format before passing to the fix agent:

```
## Findings for {slug} — {N} total, {M} actionable (>= 70)

### By File
#### src/domains/orders/order.ts
| # | Source | Score | Category | Issue | Fix |
|---|--------|-------|----------|-------|-----|
| 1 | spec-verify | 92 | contract | Missing validation | Add input check |
| 2 | age | 78 | complexity | Nested beyond 3 | Extract helper |

### Conflicts (same file:line, different sources)
- order.ts:42 — spec-verify (92) wins over de-slop (71): keep strict validation
```

Pass combined findings to a single Cook agent:

```
Agent(
  mode="acceptEdits",
  prompt="""
Fix the following findings from the review pipeline for: {slug}

## Findings (deduplicated, by file)
{findings_table}

## Precedence
If findings conflict: spec-verify > age > de-slop.

Fix all findings scored >= 70. Report any you disagree with (score + reasoning).
"""
)
```

After fix pass: re-run quality gates via `whey-drainer`. If failing after 3 total rounds: escalate to user with the combined findings report.

---

## Phase 7 — Package

### PR Slicing

Launch `fromagerie-slicer` to analyze the final branch and decide PR grouping:

```
Agent(
  subagent_type="fromagerie-slicer",
  prompt="""
Decide PR grouping for: {slug}

## Branch
{orchestrator_branch}

## Spec Summary
{spec_summary}

## Changed Files
{all_changed_files}

Analyze the diff, group into 1-3 PRs by Sliced Bread boundaries.
Write PR metadata files.
"""
)
```

### Publish PRs (orchestrator-owned)

For each PR the slicer defined:
1. Read metadata from `.claude/fromagerie/<slug>/pr-<N>-metadata.json`
2. Push branch: `git push -u origin <branch>`
3. Create PR: `gh pr create --head <branch> --title <title> --body-file <path>`
4. Update manifest with PR number and URL

### Optional Convoy

If 2+ PRs and CI issues, offer `/cheese-convoy`.

---

## Final Report

```
## Fromagerie Complete: <slug>

### Results
| Phase | Status | Detail |
|-------|--------|--------|
| Seed | complete | 2 commits |
| Atoms | 5/6 succeeded | A4 failed after retry |
| Wiring | 4/4 complete | — |
| Review | pass | spec-verify: PASS, age: 2 fixes, de-slop: 1 fix |

### PRs
| PR | Title | Files |
|----|-------|-------|
| #74 | feat(orders): add fulfillment | 6 |

### Manual Actions Needed
- Atom #4 failed: {error_summary}

Manifest: .claude/fromagerie/<slug>/manifest.json
```

---

## Error Recovery

| Failure | Recovery |
|---------|----------|
| No spec argument | Invoke `/spec`, resume after save |
| Overlap/budget violation | Re-run decomposer (max 2 retries) |
| Seed gate failure | STOP, report, do not dispatch atoms |
| Atom fails | Retry once, then mark failed |
| All atoms fail | STOP, no merger/wiring |
| Wiring agent fails | Retry once, mark incomplete if still failing |
| Phase 5 conflicts | STOP — decomposer error, report to user |
| Phase 6 fix fail (3 rounds) | Escalate with findings report |
| Merger fails | Fall back to per-atom PRs |
| Resume | `--resume <slug>` skips completed phases |

**Never proceed past Phase 0 gate without explicit user approval.**
**Never claim green on partial work.**

---

## What the Orchestrator Never Does

- **Read codebase files** — subagents explore, the orchestrator routes
- **Run build/test commands** — whey-drainer and atom agents handle verification
- **Write implementation code** — cook agents and fromage-wire agents implement
- **Make decomposition decisions after Phase 0** — the plan is locked at gate approval
- **Retry more than once** — atoms and wiring get one retry, then mark failed
- **Auto-resolve Phase 5 conflicts** — wiring conflicts indicate decomposer error, escalate to user

## Gotchas

- **Context death after C2**: The orchestrator has no memory of atom details after compaction seam C2. The wiring DAG must be self-contained on disk — if it references atom internals not captured in the manifest, wiring agents will fail.
- **Wiring DAG cycles**: If the decomposer produces a cyclic DAG, topological dispatch deadlocks. The decomposer should merge cyclic tasks, but if one slips through, detect it in Phase 4 and merge the cycle into a single task before dispatch.
- **bypassPermissions doesn't bypass Bash**: Atom agents in worktrees can Edit/Write freely but cannot `git push` or `gh pr create` without Bash allowlist entries. The orchestrator must handle all push/PR operations.
- **Nesting depth limit**: Claude Code supports 1 level of sub-agent nesting. Phase 6 agents (spec-verify, age) that spawn their own sub-agents count as that level. The orchestrator cannot nest further — this is why spec-verify runs forked, not as a sub-agent that spawns sub-agents.
- **Parallel wiring race conditions**: Wiring tasks dispatched in the same DAG wave run on the same branch. If two tasks accidentally touch the same file (decomposer error), the second commit may silently overwrite the first. The DAG overlap validation in Phase 0 prevents this, but if it slips through, Phase 6 quality gates catch the missing wiring.
- **Stale worktrees**: Atom worktrees persist after Phase 3 merge. The orchestrator does NOT clean them up — use `/worktree-sweep` after the pipeline completes.

---

## Manifest Schema

```json
{
  "slug": "feature-name",
  "spec_path": ".claude/specs/feature-name.md",
  "created": "2026-03-14T10:00:00Z",
  "phase": "gate_approved",
  "quality_gates": ["dots test"],
  "seed": {
    "items": [
      {"description": "Add shared types", "files": ["src/common/types.ts"],
       "estimated_tokens": 5000, "commit_sha": "abc123", "status": "completed"}
    ]
  },
  "atoms": [
    {"id": 1, "description": "Implement order slice", "files": ["src/orders/order.ts"],
     "estimated_tokens": 12500, "test_targets": {"command": "vitest run src/orders/order.test.ts"},
     "status": "completed", "worktree_path": "/path", "branch": "fromagerie/slug/atom-1",
     "retry_count": 0, "error": null}
  ],
  "wiring": [
    {"id": "W1", "type": "barrel_export", "file": "src/orders/index.ts",
     "depends_on": [], "estimated_tokens": 1500, "status": "completed"}
  ],
  "review": {
    "spec_verify": "PASS",
    "age_findings": 2,
    "deslop_findings": 1,
    "fix_rounds": 1
  },
  "prs": [
    {"branch": "fromagerie/slug/pr-1", "title": "feat(orders): add fulfillment",
     "pr_number": 74, "pr_url": "https://github.com/..."}
  ]
}
```
