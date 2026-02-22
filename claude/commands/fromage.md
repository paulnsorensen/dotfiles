---
name: fromage
description: Complete Fromage Development Platform — intelligent cheese-making pipeline that adapts to task complexity. Replaces /cheese and /curdle.
argument-hint: <what you want to build or fix>
---

Execute the Fromage development pipeline for: **{{request}}**

This is the full cheese-making process — from raw milk to packaged wheel. The pipeline assesses complexity and skips phases that don't add value.

---

## Phase 0 — Assess

Evaluate the request and classify complexity:

| Level | Signals | Examples |
|---|---|---|
| **Trivial** | Typo, config tweak, single obvious line | Fix README typo, update env var |
| **Small** | Single-file fix, clear scope | Bug fix, add alias, small refactor |
| **Medium** | Multi-file feature, some design needed | New command, API endpoint, component |
| **Large** | Architecture change, many files, design decisions | New system, major refactor, cross-cutting concern |

Announce the complexity level and which phases will run vs skip. Show a table like:

```
Complexity: Medium
| Phase | Status | Reason |
|---|---|---|
| 1. Preparing | run | Need to prime environment |
| 2. Pasteurize | run | Requirements need clarification |
| 3. Culture | run | Multi-file, need exploration |
| 4. Curdle | run | Plan needed for approval |
| 5. Cut | run | Test framework available |
| 6. Cook | run | Always runs |
| 7. Press | run | Validate implementation |
| 8. Age | run | Review multi-file changes |
| 9. Package | run | Commit and PR |
```

**Skip logic:**

| Phase | Trivial | Small | Medium | Large |
|---|---|---|---|---|
| 1. Preparing | check | check | check | check |
| 2. Pasteurize | skip | skip | run | run |
| 3. Culture | skip | skip | run | run |
| 4. Curdle | skip | skip | run | run |
| 5. Cut | skip | optional | run | defer→Press |
| 6. Cook | run | run | run | run |
| 7. Press | skip | optional | run | run |
| 8. Age | skip | skip | run | run |
| 9. Package | run | run | run | run |

The user can override any skip decision — just ask "want me to run X anyway?"

---

## Phase 1 — Preparing (Haiku agent)

Launch the `fromage-preparing` agent via the Task tool:

```
Task(subagent_type="fromage-preparing", model="haiku", prompt="Check environment readiness for task: <task summary>")
```

The agent will:
- Check if we're in a git worktree (if not, report back)
- Prime Serena: activate_project → check_onboarding → read relevant memories
- Check git status (clean tree, current branch)

**If not in a worktree**: Ask the user if they want to create one via `/worktree <slug>`. Derive slug from the request.

**Skip condition**: Already in a worktree AND Serena is already active. Just confirm status inline.

---

## Phase 2 — Pasteurize (Opus, interactive)

Interactive requirements gathering. This is a conversation, not an interrogation.

1. Parse the request and identify what's clear vs ambiguous
2. For ambiguous areas, ask clarifying questions (weave naturally, don't dump a list)
3. When external research is needed, delegate to `/research` skill via Task tool:
   ```
   Task(subagent_type="general-purpose", prompt="Use the research skill: <specific question>")
   ```
4. Once requirements are clear, write spec to `.claude/specs/<slug>.md` using the spec format from `/spec`

**Skip condition**: Task is self-evident (trivial/small) OR user provides a complete spec up front.

---

## Phase 3 — Culture (Sonnet agents, parallel)

Launch 2-3 `fromage-culture` agents in parallel via the Task tool, each targeting a different aspect:

```
Task(subagent_type="fromage-culture", model="sonnet", prompt="Explore <aspect>: <details>. Task context: <spec summary>")
```

Split exploration by:
- **Aspect A**: Entry points and existing patterns relevant to the change
- **Aspect B**: Blast radius — what existing code will be affected
- **Aspect C** (large tasks only): Architecture and cross-cutting concerns

After agents return, **read all identified key files** yourself to have full context for planning.

**Skip condition**: Single-file change, config tweak, or obvious modification path.

---

## Phase 4 — Curdle (Opus agent)

Launch the `fromage-curdle` agent with all exploration context:

```
Task(subagent_type="fromage-curdle", model="opus", prompt="Create execution plan. Exploration results: <results>. Spec: <spec>. Key files: <files read>")
```

The agent produces a numbered implementation checklist.

**Present the plan to the user for approval.** Use AskUserQuestion:
- Option 1: "Approve plan"
- Option 2: "Modify plan" (then iterate)
- Option 3: "Scrap and re-plan"

Do NOT proceed to Cook without explicit approval.

**Skip condition**: Obvious single-step change (trivial/small complexity).

---

## Phase 5 — Cut (Sonnet, inline)

Write high-level tests based on the approved plan and spec:
- **Medium tasks**: Unit tests for new functions, integration test for the feature
- **Small tasks**: Single test file covering the change
- **Large tasks**: Defer to Press phase (tests after implementation is more practical)

Use the project's existing test framework and conventions. If no test framework exists, skip entirely.

**Skip condition**: No test framework, trivial change, large task (defer to Press), or user opts out.

---

## Phase 6 — Cook (Sonnet, inline + parallel agents)

Implementation phase. **Never skipped.**

**For small/trivial tasks**: Implement directly inline. Follow the plan (if one exists) or just make the change.

**For medium/large tasks with independent chunks**: Launch parallel `fromage-cook` agents:

```
Task(subagent_type="fromage-cook", model="sonnet", prompt="Implement chunk: <chunk details>. Plan step(s): <steps>. Context: <relevant files>")
```

Split work by independent modules/files. Each cook agent gets:
- The specific chunk to implement
- Relevant file contents
- Engineering principles to follow

After all cooks return, verify integration — make sure the pieces fit together.

**Engineering principles for all implementation**:
1. Input validation at system boundaries
2. Fail fast and loud — no silent failures
3. Loose coupling — business logic free of infrastructure
4. YAGNI — only what's needed now
5. Real-world naming — business concepts, not technical jargon
6. Immutable patterns where possible
7. Complexity budget: 40 lines/fn, 300 lines/file, 4 params/fn, 3 levels nesting

---

## Phase 7 — Press (Sonnet agent)

Launch the `fromage-press` agent for adversarial testing:

```
Task(subagent_type="fromage-press", model="sonnet", prompt="Test implementation. Changed files: <list>. Spec: <spec summary>. Plan: <plan summary>")
```

The agent follows roquefort-wrecker's adversarial philosophy:
1. Invalid inputs first (chaos testing)
2. Edge cases (boundary assault)
3. Integration paths (dependency failures)
4. Happy path (boring but necessary)

**Fix failures inline** after the agent reports. Re-run tests to confirm fixes.

**Skip condition**: Cut phase provided sufficient coverage, no test framework, or trivial change.

---

## Phase 8 — Age (Opus agent)

Launch the `fromage-age` agent for code review:

```
Task(subagent_type="fromage-age", model="opus", prompt="Review changes. Diff: <git diff summary>. Architecture: Sliced Bread. Principles: <list>")
```

The agent reviews against:
- Sliced Bread architecture compliance
- Engineering principles (input validation, fail-fast, loose coupling, YAGNI, real-world models, immutable patterns)
- Complexity budget enforcement
- Only reports issues with >= 80% confidence

**Present findings to user.** Fix agreed issues inline.

**Skip condition**: Trivial change, single-line fix.

---

## Phase 9 — Package (Sonnet, inline)

Ship it:

1. Use the `/commit` skill to stage and commit with a conventional commit message
2. If the user wants a PR, use the `/gh` skill to push and open a PR

**Skip condition**: User wants manual control, work is WIP, or user says "don't commit".

---

## Phase Transitions

Between phases, provide a brief status update:

```
--- Phase 3 → Culture complete ---
Found 7 key files across 2 slices. Blast radius: moderate (3 existing files affected).
Moving to Phase 4 (Curdle) — creating execution plan...
```

Keep transitions tight — one or two sentences max.

---

## Error Recovery

- If an agent fails or returns poor results, retry once with refined prompt
- If a phase produces unexpected results, pause and ask the user
- If tests fail in Press, fix and re-run (up to 3 iterations before escalating to user)
- Never proceed past a user approval gate without explicit approval
