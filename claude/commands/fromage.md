---
name: fromage
description: Complete Fromage Development Platform — intelligent cheese-making pipeline that adapts to task complexity. Replaces /cheese and /curdle.
argument-hint: <what you want to build or fix>
---

Execute the Fromage development pipeline for: **$ARGUMENTS**

Full cheese-making process — raw milk to packaged wheel. Assesses complexity and skips phases that don't add value.

## Context Passing

Each phase builds on prior phases. When launching agents, always include:
- **Slug**: kebab-case task identifier derived in Phase 0 (used for spec files, branch names)
- **Spec summary**: from Phase 2, or the original request if spec was skipped
- **Exploration findings**: from Phase 3, if it ran (entry points, blast radius, key files)
- **Plan steps**: from Phase 4, scoped to the agent's chunk
- **Changed files**: accumulated list, updated after each Cook/Press cycle
- **Design skill**: from Phase 4 plan or `--skill` flag (skill file content injected into Cook)

## Orchestrator Token Discipline

"Orchestrator" means the Claude session executing this `/fromage` command — not a separate agent. It has full tool access.

The orchestrator reads ONE thing: the spec. Everything else is delegated.

The orchestrator MUST NOT:
- Use Read, Grep, or Glob on codebase files (delegate to Culture/Cook agents)
- Run build/test commands directly (delegate to whey-drainer)
- Read subagent full reports (work from their returned summaries)

The orchestrator SHOULD:
- Read the spec (`.claude/specs/<slug>.md`) — this is the contract that drives all phase decisions. One read, justified.
- Work from subagent summaries, not full reports
- Keep its own context focused on phase orchestration decisions

EXCEPTION: Reading small config files (<2K chars) for phase gating decisions is acceptable (e.g., checking if a test framework exists).

## Spec Distribution

After reading the spec, the orchestrator pre-digests it for downstream agents:

1. Write the full spec to `$TMPDIR/fromage-spec-<slug>.md` (temp copy for agents)
2. Extract a **spec summary** (<2K chars): what's being built (bullets), constraints, scope boundaries (what's OUT)

Distribution:
- **Curdle**: gets the full spec temp file path in its prompt — reads it itself. Curdle is the planner; it needs every constraint and boundary.
- **Culture**: gets the spec summary inline in prompt (enough to scope exploration)
- **Cook**: gets relevant plan steps + spec summary (plan is the primary input)
- **Press/Age**: gets spec summary + changed files list (enough to evaluate against)

If the spec is <5K chars, pass it inline to all agents (no temp file needed). If >5K chars, always use the summary + temp file pattern.

## Agent Turn Limits

Always set `max_turns` when spawning Task agents:

| Agent | max_turns | Rationale |
|-------|-----------|-----------|
| fromage-preparing | 15 | Env check, fast |
| fromage-culture | 40 | Exploration, bounded |
| fromage-curdle | 30 | Planning, should be decisive |
| fromage-cook | 80 | Implementation, largest scope |
| fromage-press | 50 | Testing + feedback loops |
| fromage-age | 30 | Review, read-only |
| whey-drainer | 15 | Just runs tests |
| roquefort-wrecker | 25 | Writes + runs tests |
| research (any) | 15 | Should find answer fast or bail |

If an agent hits its limit, it returns partial results. The orchestrator decides whether to spawn a continuation agent or proceed with what it has.

## Progress Tracking

After complexity classification in Phase 0, call `TaskCreate` for each phase that will **run** (not skipped). This gives the user a persistent at-a-glance view of pipeline progress.

- Create tasks using the subject and `activeForm` from the table below
- At the start of each phase, `TaskUpdate` that phase's task → `in_progress`
- At each `--- Phase N complete ---` transition, `TaskUpdate` → `completed`
- Phases gated by "ask": create the task as `pending`. If the user declines, `TaskUpdate` → `deleted`

| Phase | Subject | activeForm |
|---|---|---|
| 0 | Assess complexity | Assessing complexity |
| 1 | Prepare environment | Preparing environment |
| 2 | Gather requirements | Gathering requirements |
| 3 | Explore codebase | Exploring codebase |
| 4 | Plan implementation | Planning implementation |
| 5 | Write test scaffolds | Writing test scaffolds |
| 6 | Implement changes | Implementing changes |
| 7 | Adversarial testing | Running adversarial tests |
| 8 | Code review | Reviewing changes |
| 9 | Package and ship | Packaging and shipping |

---

## Phase 0 — Assess

### Hard Gate: Worktree Check

Check if you are in a git worktree: run `git rev-parse --git-dir` — if output contains `/worktrees/`, you're in one. If NOT:

1. **Stop.** Do not proceed.
2. Ask: "You're on the main branch. Want me to create a worktree with `/worktree <slug>`?"
3. Only proceed after user is on a worktree OR explicitly says "continue on main".

This gate is **never skipped**.

### Derive Slug

Generate a kebab-case slug from the request (<30 chars). Examples:
- "add dark mode support" → `add-dark-mode`
- "fix login timeout bug" → `fix-login-timeout`

The slug is used for: spec file (`.claude/specs/<slug>.md`), worktree branch, PR title context.

### Parse Flags

If `$ARGUMENTS` contains `--skill <name>`:
1. Extract the skill name and remove the flag from the arguments
2. Verify `claude/skills/<name>/SKILL.md` exists (error if not found)
3. Carry the skill name through all subsequent phases
4. This overrides any skill detected by Curdle

### Classify Complexity

| Level | Signals | Examples |
|---|---|---|
| **Trivial** | Typo, config tweak, single obvious line | Fix README typo, update env var |
| **Small** | Single-file fix, clear scope | Bug fix, add alias, small refactor |
| **Medium** | Multi-file feature, some design needed | New command, API endpoint, component |
| **Large** | Architecture change, many files, design decisions | New system, major refactor, cross-cutting concern |

Announce complexity and show which phases run vs skip:

| Phase | Trivial | Small | Medium | Large |
|---|---|---|---|---|
| 1. Preparing | run | run | run | run |
| 2. Pasteurize | skip | skip | run | run |
| 3. Culture | skip | skip | run | run |
| 4. Curdle | skip | skip | run | run |
| 5. Cut | skip | ask | run | run |
| 6. Cook | run | run | run | run |
| 7. Press | skip | ask | run | run |
| 8. Age | skip | skip | run | run |
| 9. Package | run | run | run | run |

**ask** = ask user before running. User can also override any skip → run.

---

## Phase 1 — Preparing (Haiku)

Launch `fromage-preparing` (haiku). It primes Serena (activate_project, check_onboarding, read memories) and reports git state. Worktree status was already verified in Phase 0 — this phase focuses on environment readiness.

**Skip**: Serena already active and git state is clean — confirm inline.

---

## Phase 2 — Pasteurize (Opus, interactive)

Interactive requirements gathering — a conversation, not an interrogation.

1. Parse the request: what's clear vs ambiguous
2. Ask clarifying questions naturally (don't dump a list)
3. Invoke `/research` when external research is needed
4. Write spec to `.claude/specs/<slug>.md`

**>>> CHECKPOINT 1: Requirements <<<**

Present: what's being built (2-3 bullets), constraints, scope boundaries (what's OUT).

AskUserQuestion: Approve / Edit / Pause. Do NOT proceed without approval — the spec is the contract.

**Skip**: Self-evident task or user provides a complete spec.

---

## Phase 3 — Culture (Sonnet, parallel)

Launch 2-3 `fromage-culture` agents (sonnet), each targeting a different aspect. Every agent applies the full trace checklist (data transformations, state changes, cross-cutting concerns, configuration) to their assigned scope:

- **Aspect A**: Entry points and existing patterns relevant to the change
- **Aspect B**: Blast radius — what existing code will be affected
- **Aspect C** (large only): Architecture boundaries and integration points

After agents return, pass their summaries and full report temp file paths to Curdle. The planner can read the full reports if it needs deeper context.

**Skip**: Single-file change, config tweak, obvious modification path.

---

## Phase 4 — Curdle (Opus)

Launch `fromage-curdle` (opus, permissionMode: plan) with exploration results and spec. Produces a numbered implementation checklist.

**>>> CHECKPOINT 2: Plan <<<**

Present: architecture decision (one line), files to modify/create, build steps (parallel vs sequential), YAGNI boundaries.

AskUserQuestion: Approve / Modify / Re-explore / Pause. Do NOT proceed without approval.

**Skip**: Obvious single-step change (trivial/small).

---

## Phase 5 — Cut (Sonnet, inline)

Write tests based on the plan. Scale: large = unit + integration skeleton, medium = unit + integration, small = single test file.

Run via `whey-drainer` (haiku) to confirm scaffolding — tests should fail (tests-before-code).

**Skip**: No test framework, trivial change, or user opts out.

---

## Phase 6 — Cook (Sonnet, inline + parallel)

Implementation. **Never skipped.**

**Small/trivial**: Implement directly inline.

**Medium/large**: Launch parallel `fromage-cook` agents (sonnet), split by independent modules. Each gets their chunk, relevant files, and engineering principles.

### Wave Splitting

When dispatching Cook agents for medium/large tasks:
- Count the files each plan step touches
- If a single Cook agent would need to touch roughly 8+ files, split into multiple Cook agents (one per independent group) — this is a heuristic, not a hard limit; adjust based on file sizes and complexity
- Each Cook agent gets a fresh context window — this is the primary mechanism for preventing token accumulation
- Set `max_turns: 80` on each Cook Task invocation
- If a Cook agent hits max_turns, spawn a continuation agent for remaining items with the completed items noted in its prompt

### Research Discipline

When a Cook or Culture agent encounters an unfamiliar library/API:

1. **Codebase first**: Grep the codebase for existing usage patterns, or use `/trace` (ast-grep) for structural matches
2. **Context7 second**: Query library docs via Context7 MCP
3. **Package README third**: Use octocode to read the package README
4. **NEVER**: Read library source code. If the answer isn't in steps 1-3, return what you have and flag it as needing research.

Research agents spawned during Cook get `max_turns: 15`.

### Design Skill Injection

If a design skill was specified (via Curdle plan's "Design Skill" section or `--skill` flag):
1. Read `claude/skills/<skill-name>/SKILL.md`
2. Include the skill's markdown body in each Cook agent's prompt
3. Prefix with: "Apply the following design skill guidelines to your implementation:"

If no design skill applies, skip this step.

After cooks return, verify integration. Run `whey-drainer` (haiku) for regression check. Fix failures before moving on.

**Engineering principles**: Input validation at boundaries, fail fast and loud, loose coupling, YAGNI, real-world naming, immutable patterns, complexity budget (40 lines/fn, 300 lines/file, 4 params, 3 nesting).

---

## Phase 7 — Press (Sonnet)

Launch `fromage-press` (sonnet) for adversarial testing — chaos inputs, boundary assault, dependency failures, then happy path. All findings scored 0-100, >= 75 highlighted.

**Optional**: For tasks with external inputs, also launch `fromage-pasteurize` (sonnet) in parallel for security scanning.

### Wrecker-Drainer Feedback Loop

1. **Drain**: `whey-drainer` (haiku) runs all tests, classifies failures as test bugs vs code bugs
2. **Wreck** (if failures): `roquefort-wrecker` (haiku) investigates — fixes test bugs, scores code bugs
3. **Re-drain**: `whey-drainer` verifies fixes
4. **Iterate** up to 3 rounds. After 3: code bugs >= 75 get fixed or escalated, test bugs escalated if stuck, ambiguous (50-74) presented to user.

**Skip**: Cut phase had sufficient coverage, no test framework, or trivial change.

---

## Phase 8 — Age (Opus)

Launch `fromage-age` (opus) in focused mode. Include the list of changed file paths in the prompt — the agent uses `git blame` and `git log` for historical context.

Reviews through three dimensions:

1. **Correctness & Safety** — security, bugs, silent failures
2. **Architecture & Weight** — coupling, dead code, complexity, inline/undocument
3. **Historical Context** — git blame patterns, recurring issues from prior changes

All findings scored 0-100, only >= 75 surfaced.

**Validation pass** (medium/large): For findings scored 75-89, launch a haiku agent to verify against actual code context. Discard findings that don't survive scrutiny. Findings >= 90 skip validation.

Present findings to user. Fix agreed issues inline.

**Skip**: Trivial change, single-line fix.

---

## Phase 9 — Package (inline)

### Hard Gate: Tests Must Pass (never skipped)

1. `whey-drainer` (haiku) for final regression check
2. Failures: fix your changes, re-run (up to 3 iterations). Pre-existing failures: report and ask user.
3. **Do NOT commit with failing tests** unless user explicitly approves.

### Commit and PR

1. `/commit` to stage and commit with conventional commit message
2. `/gh` to push and open a PR (if user wants one)

**Skip for commit/PR**: User wants manual control, WIP, or says "don't commit". Test gate still runs.

---

## Phase Transitions

One-line status between phases:
```
--- Phase 3 complete --- 7 key files, moderate blast radius. Moving to Curdle...
```

---

## Error Recovery

- Agent fails: retry once with refined prompt
- Unexpected results: pause and ask user
- Test failures in Press: wrecker-drainer loop (3 rounds max)
- Never proceed past a user approval gate without explicit approval
