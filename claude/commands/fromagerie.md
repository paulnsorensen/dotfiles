---
name: fromagerie
description: Large feature orchestrator — decomposes a spec into non-overlapping atoms, executes foundation work, dispatches parallel worktree agents, then triggers /cheese-convoy on the resulting PRs.
argument-hint: <spec-file-path> [--resume <slug>]
---

Orchestrate the full lifecycle for: **$ARGUMENTS**

Reads a spec, front-loads exploration, decomposes into atoms, executes foundation work, dispatches parallel agents, and lands PRs via convoy.

## When to use `/fromagerie` vs `/fromage`

- **`/fromage`**: Single coherent feature or fix — one worktree, one PR.
- **`/fromagerie`**: Feature that decomposes into 5-30 independent work units with explicit file ownership — parallel agents, multiple PRs, one convoy.

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
- **Decomposition result**: from Phase 2, including foundation items and atom list
- **Manifest path**: `.claude/fromagerie/<slug>/manifest.json`

---

## Phase 0 — Ingest

### Parse Arguments

If `$ARGUMENTS` contains `--resume <slug>`:
1. Extract slug, set `RESUME=true`
2. Read manifest at `.claude/fromagerie/<slug>/manifest.json`
3. Find the last completed phase and skip to the next incomplete phase
4. Report: "Resuming <slug> from phase <N>"

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

For specs >5K chars, write the full spec to `$TMPDIR/fromagerie-spec-<slug>.md` for agent distribution.

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
  'convoy': {'status': 'pending', 'pr_numbers': []}
}
print(json.dumps(manifest, indent=2))
" > .claude/fromagerie/<slug>/manifest.json
```

---

## Phase 1 — Explore

Launch Culture agents (sonnet, parallel) in a **single message**. Scale by spec size:

| Spec Size | Agents | Aspects |
|---|---|---|
| Small (< 3 user stories) | 2 | A, B |
| Medium (3-6 user stories) | 3 | A, B, C |
| Large (7+ user stories) | 4-5 | A, B, C, D, (E) |

**`fromage-culture` agents (codebase exploration):**
- **Aspect A**: Entry points, existing patterns, and file ownership relevant to the spec's scope
- **Aspect B**: Blast radius — what existing code will be affected or extended
- **Aspect C** (medium+): Architecture boundaries and public API surfaces

**Separate research subagents (large specs only, run in parallel with Culture):**
- **Aspect D**: **External prior art** — spawn a `/research` agent to scan how other projects solved similar problems. Write findings to `$TMPDIR/fromagerie-culture-<slug>-prior-art.md`.
- **Aspect E**: **Dependency and API landscape** — spawn a `/fetch` agent to assess external libraries and APIs this feature interacts with. Write to `$TMPDIR/fromagerie-culture-<slug>-deps.md`.

Each `fromage-culture` agent prompt includes the spec summary. Full report written to `$TMPDIR/fromagerie-culture-<slug>-<N>.md`.

After agents return:
1. **Synthesize cross-agent patterns** — what do 2+ agents agree on? Where do they contradict?
2. Collect inline summaries (keep in orchestrator context)
3. Pass temp file paths to Phase 2 (decomposer reads full reports if needed)

Update manifest: `"phase": "explore"`.

---

## Phase 2 — Decompose

Launch `fromagerie-decomposer` (opus, plan mode) with:
- Spec (inline if <5K, temp file path otherwise)
- Culture exploration summaries + full report paths
- Quality gate commands
- Instruction to output: foundation items (ordered, with file lists and commit boundaries) + parallel atoms (with file lists and complexity tags)

### Overlap Validation (hard constraint)

After decomposer returns, validate that no file appears in more than one atom:

```python
# Pseudocode — implement as python3 one-liner or inline check
all_files = []
for atom in atoms:
    for f in atom['files']:
        if f in all_files:
            FAIL: "File overlap detected: {f} in atom {a} and atom {b}. Re-decomposing."
        all_files.append(f)
```

If overlap detected: re-run decomposer with the conflict highlighted. Maximum 2 retries, then stop and report.

If atom count > 10: warn — "Feature may be too large for a single /fromagerie run. Consider splitting the spec."

Update manifest with full decomposition result.

---

## Phase 3 — Gate

Present the full decomposition plan as visible output:

```
## Fromagerie Plan: <slug>

### Foundation (sequential, ~<N> min)
1. <description> — files: [<list>] — commit boundary: <label>
2. ...

### Atoms (parallel, wall-clock ~<max_atom_time> min)
| # | Description | Files | Complexity | Est. Time |
|---|---|---|---|---|
| 1 | <desc> | <N> files | medium | ~5 min |
| 2 | <desc> | <N> files | small | ~2 min |
...

**Complexity key**: small ~2 min, medium ~5 min, large ~10 min
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

Execute foundation items on the current worktree (not isolated).

For each foundation item:
1. Implement the changes (inline, using Edit/Write tools)
2. Run quality gates: pass commands from spec to `whey-drainer` (haiku)
3. If gates fail: **STOP**. Report the failure. Do not proceed to Phase 5.
4. Commit via `/commit` skill (Skill tool — conventional commit format)
5. Update manifest with commit SHA

After all foundation items:
- Push to branch: `git push origin HEAD`
- Foundation must be pushed before atoms dispatch — worktree agents branch from HEAD

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
  max_turns=60,
  prompt="""
You are executing atom #{N} of a /fromagerie decomposition for spec: {slug}

## File Assignment (HARD CONSTRAINT)
You may ONLY modify these files:
{file_list}

Do NOT create, modify, or delete any file not on this list.

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
6. PR: Create PR with `gh pr create` — title, body summarizing this atom's changes

## Safety Guardrails
- Never push to main or master
- Never force-push
- Only push to your atom branch
- If a change touches a file not on your list, skip it and note it in your PR description
- If quality gates fail after 3 rounds, stop and report failures — do not create a PR
"""
)
```

**Why `bypassPermissions`**: Atom agents need Bash (`git push`, `gh pr create`, build/test commands) and MCP calls without prompts. Each runs in an isolated worktree (filesystem containment). Safety is procedural: file list constraint + branch restriction in the prompt.

Update manifest: `"phase": "dispatched"`, mark each atom status as `"running"`.

---

## Phase 6 — Collect

Wait for background agent completion notifications.

As each atom agent reports back:
1. Parse its report: status (success/failure), PR number (if created), error summary
2. Update manifest: atom status, PR number, error field
3. Report progress: "Atom 3/6 complete — PR #74 created"

### Retry Logic

For failed atoms: retry ONCE with the error context appended:

```
Agent(
  isolation="worktree",
  mode="bypassPermissions",
  run_in_background=True,
  prompt="""<original atom prompt>

## Retry Context
Previous attempt failed with:
{error_summary}

Address this failure before proceeding with the workflow.
"""
)
```

After retries: mark `"retry_count": 1`. Do not retry a second time — move on.

Update manifest with final statuses. Determine the convoy list (successful atom PR numbers).

---

## Phase 7 — Convoy

Collect successful PR numbers from manifest.

If all atoms failed: report and stop.

```
All atoms failed. Manual intervention required.
Failed atoms: {list with error summaries}
Manifest: .claude/fromagerie/<slug>/manifest.json
```

If any atoms succeeded: invoke `/cheese-convoy` via the Skill tool:

```
Skill(skill="cheese-convoy", args="<PR# PR# ...>")
```

After convoy completes, update manifest: `"convoy": {"status": "completed", "pr_numbers": [...]}`.

### Final Report

```
## Fromagerie Complete: <slug>

### Atom Results
| # | Description | Status | PR |
|---|---|---|---|
| 1 | <desc> | success | #74 |
| 2 | <desc> | failed | — |
...

### Convoy
{convoy_result_summary}

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
  "quality_gates": ["cargo test", "cargo clippy"],
  "foundation": {
    "items": [
      {
        "description": "Add shared types",
        "files": ["src/domains/common/types.ts"],
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
      "complexity": "medium",
      "status": "completed",
      "pr_number": 72,
      "pr_url": "https://github.com/...",
      "retry_count": 0,
      "error": null
    }
  ],
  "convoy": {
    "status": "pending",
    "pr_numbers": []
  }
}
```

---

## Phase Transitions

One-line status between phases:
```
--- Phase 1 complete --- 3 culture agents, 12 key files mapped. Moving to Decompose...
--- Phase 2 complete --- 2 foundation items, 5 atoms (no overlap). Moving to Gate...
--- Phase 4 complete --- 2 foundation commits pushed. Moving to Dispatch...
```

---

## Error Recovery

- **Overlap detected**: re-run decomposer with conflict noted (max 2 retries, then stop)
- **Foundation gate failure**: stop execution, report, do not dispatch atoms
- **Atom fails**: retry once with error context, then mark failed and continue
- **All atoms fail**: report and stop, no convoy dispatch
- **Convoy fails**: report convoy result, leave PRs open for manual action
- **Resume**: `--resume <slug>` reads manifest and skips completed phases
- **Never proceed past Phase 3 gate without explicit user approval**
- **Never claim green on partial work** — report partial/failed atoms honestly in the final report
