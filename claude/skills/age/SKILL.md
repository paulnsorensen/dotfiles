---
name: age
description: >
  Staff Engineer code review orchestrator. Spawns 6 parallel review sub-agents
  (safety, arch, encap, yagni, history, spec), merges findings with history-based
  score modifiers, and produces a unified Age Report. Two modes: focused (changes)
  and comprehensive (full audit). Use when the user invokes /age, or when a command
  needs code review (fromage Phase 8, move-my-cheese, copilot-review, fromagerie).
  This is a SKILL, not an agent — it runs inline in the caller's context so the
  6 sub-agents are first-level agents, avoiding nested-agent depth issues.
  Do NOT use for implementation (fromage-cook), cleanup fixes (simplify/de-slop),
  or PR comment triage (respond/copilot-review).
model: opus
allowed-tools: Bash(git diff:*), Bash(git log:*), Bash(git status:*), Agent, Write, mcp__tilth__*
---

# age

Staff Engineer code review. Spawn 6 focused reviewers, merge findings.

## Sub-Agents

| Agent | Charter | Produces |
|-------|---------|----------|
| `fromage-age-safety` | Bugs, security, silent failures | Scored findings |
| `fromage-age-arch` | Complexity budgets, nesting, file structure | Scored findings + complexity table |
| `fromage-age-encap` | Encapsulation, leaky abstractions, boundary violations | Scored findings |
| `fromage-age-yagni` | Dead code (must be justified), speculative abstractions, AI noise | Scored findings |
| `fromage-age-history` | Git blame risk analysis | **Score modifiers** (not findings) |
| `fromage-age-spec` | Spec drift, monkey patches, missing implementations | Scored findings |

## Modes

### Focused Mode (default)

Review changes against principles, score issues. Used by `/age`, `/fromage` Phase 8, `/copilot-review`.

Input: a diff or set of changed files.

### Comprehensive Mode

Full architectural audit — business model inventory, architecture assessment, risk areas, strengths, + scored issues. Used by `/code-review`.

Input: a module, directory, or entire codebase.

## Protocol

### Step 1: Identify scope

From the arguments or calling context, extract:

- The changed file paths (or module/directory for comprehensive mode)
- Any git ref range (e.g., `HEAD~3`, `main..HEAD`)
- Whether this is focused or comprehensive mode

Run `git diff --stat` (or equivalent) to get the list of changed files if not provided.

### Step 2: Launch sub-agents in parallel

Launch ALL SIX sub-agents in a SINGLE message (one message, six Agent tool calls):

```
Agent(subagent_type="fromage-age-safety", prompt="Focused mode. Review these changed files for correctness and safety issues:\n\nFiles: <list>\nDiff:\n<diff or ref range>\n\nNavigation: direct LSP disallowed — use tilth_search (kind: symbol | callers | regex), tilth_deps, tilth_read(paths: [...]).")

Agent(subagent_type="fromage-age-arch", prompt="Focused mode. Check complexity budgets and structure for these changed files:\n\nFiles: <list>\nDiff:\n<diff or ref range>\n\nNavigation: direct LSP disallowed — use tilth_search + tilth_deps.")

Agent(subagent_type="fromage-age-encap", prompt="Focused mode. Check encapsulation and boundary compliance for these changed files:\n\nFiles: <list>\nDiff:\n<diff or ref range>\n\nNavigation: direct LSP disallowed — use tilth_deps for import edges and tilth_search kind: callers for cross-boundary usage.")

Agent(subagent_type="fromage-age-yagni", prompt="Focused mode. Find unjustified dead code, speculative abstractions, and AI noise in these changed files:\n\nFiles: <list>\nDiff:\n<diff or ref range>\n\nNavigation: direct LSP disallowed — use tilth_search kind: callers to verify dead code.")

Agent(subagent_type="fromage-age-history", prompt="Analyze git history for these changed files and provide per-file score modifiers:\n\nFiles: <list>")

Agent(subagent_type="fromage-age-spec", prompt="Focused mode. Check spec adherence for these changed files. Read .claude/specs/*.md for relevant specs:\n\nFiles: <list>\nDiff:\n<diff or ref range>")
```

Each sub-agent prompt MUST include:

- The changed file paths
- The diff content or git ref range
- Mode (focused or comprehensive)
- Navigation reminder: direct `LSP` is disallowed — sub-agents use tilth primitives; planning-level type inference escalates to `/explore`

### Step 3: Merge findings

Once all six sub-agents return:

1. **Apply history modifiers** — Take the per-file modifiers from `fromage-age-history` and adjust scores from all other agents' findings. A bug in a hotspot file gets the file's modifier applied. Re-check the >= 50 threshold after adjustment.

2. **Deduplicate** — Same file:line AND same category = true duplicate, keep the higher-scored finding. Same file:line but different categories = both surface (different concerns). When a history modifier pushes a finding across the 50 threshold, note the adjustment in the output.

3. **Sort by score** — Highest first.

4. **Build comprehensive sections** (comprehensive mode only):
   - Business Model Inventory (from encap + arch structural analysis)
   - Architecture Assessment (from arch + encap)
   - Risk Areas (from all agents)
   - Strengths (synthesized)

### Step 4: Write report and present

Write the full merged report to `$TMPDIR/fromage-age-<slug>.md`.

Present findings to the user or return a structured summary to the calling command (max 2000 chars):

```
## Age Summary
**Assessment**: <one-sentence: "Clean implementation" or "N issues found, M critical">
**Findings >= 50**:
| # | Score | Category | File:Line | Issue |
|---|-------|----------|-----------|-------|
| 1 | 95 | BUG | path:42 | Null check missing |
**Complexity**: all pass | N files over budget
**Nesting**: clean | N smells (depth 2: N, depth 3+: N)
**Encapsulation**: clean | N leaks
**YAGNI**: clean | N unjustified items
**Spec adherence**: aligned | N divergences | no applicable specs
**Below threshold**: N findings scored < 50
**Full report**: $TMPDIR/fromage-age-<slug>.md
```

## Report Formats (for the temp file)

### Focused Mode

```
## Age Report — Code Review

### Summary
<One-sentence assessment>

### Findings (score >= 50)
| # | Score | Category | Source | File:Line | Issue | Fix |
|---|-------|----------|--------|-----------|-------|-----|
(Source = which sub-agent: safety/arch/encap/yagni/spec)

### Complexity Check
| File | Lines | Longest Function | Max Nesting | Max Params | Status |
|---|---|---|---|---|---|

### Nesting Smells (if any)
| File:Line | Depth | Recommended Fix |
|-----------|-------|-----------------|

### History Context
<File risk profile and modifier table from history agent>

### Below Threshold
N findings scored < 50 (not shown)
```

### Comprehensive Mode

```
## Age Report — Comprehensive Review

### Business Model Inventory
- {Model1} — {description, purity status}

### Architecture Assessment
- Data flow: {how data moves}
- Boundaries: {where business logic meets infrastructure}
- Dependency direction: {correct or inverted?}
- Public API surface: {clean or leaky?}

### Risk Areas
- {risk 1}

### Strengths
- {what's working well}

### Findings (score >= 50)
| # | Score | Category | Source | File:Line | Issue | Fix |
|---|-------|----------|--------|-----------|-------|-----|

### Complexity Check
| File | Lines | Longest Function | Max Nesting | Max Params | Status |
|---|---|---|---|---|---|

### Nesting Smells (if any)
| File:Line | Depth | Recommended Fix |
|-----------|-------|-----------------|

### History Context
<File risk profile and modifier table from history agent>

### Below Threshold
N findings scored < 50 (not shown)
```

Categories: `BUG`, `SECURITY`, `SILENT_FAILURE`, `COMPLEXITY`, `NESTING`, `STRUCTURE`, `LEAK_DEPENDENCY`, `LEAK_BYPASS`, `LEAK_ABSTRACTION`, `LEAK_MUTATION`, `LEAK_SURFACE`, `DEAD_CODE`, `SPECULATIVE`, `PASSTHROUGH`, `AI_NOISE`, `DEFENSIVE`, `SPEC_DRIFT`, `MONKEY_PATCH`, `SPEC_MISSING`, `SCOPE_CREEP`

## Rules

- **Parallel launch** — all six sub-agents in a single message for true concurrency
- **Apply history modifiers** — this is the key merge step
- **Write only to $TMPDIR** — never modify source files; writing the report to $TMPDIR is the only write
- **Wrap-up after merge** — don't re-review what the sub-agents already found
