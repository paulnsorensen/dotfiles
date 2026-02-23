---
name: fromage
description: Complete Fromage Development Platform — intelligent cheese-making pipeline that adapts to task complexity. Replaces /cheese and /curdle.
argument-hint: <what you want to build or fix>
---

Execute the Fromage development pipeline for: **$ARGUMENTS**

This is the full cheese-making process — from raw milk to packaged wheel. The pipeline assesses complexity and skips phases that don't add value.

---

## Phase 0 — Assess

### Hard Gate: Worktree Check

Before anything else, check if you are in a git worktree (`git rev-parse --show-toplevel` differs from the main repo root, or `.git` is a file not a directory). If NOT in a worktree:

1. **Stop.** Do not proceed with any implementation.
2. Ask the user if they want to create one: "You're on the main branch. Want me to create a worktree with `/worktree <slug>`?"
3. Derive `<slug>` from the request (e.g., "fix login bug" → `fix-login-bug`).
4. Only proceed after the user is on a worktree OR explicitly says "continue on main".

This gate is **never skipped** regardless of complexity level.

### Classify Complexity

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
| 5. Cut | skip | optional | run | run |
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
3. When external research is needed, invoke `/research` for parallel multi-source research via agent team
4. Once requirements are clear, write spec to `.claude/specs/<slug>.md` using the spec format from `/spec`

**>>> CHECKPOINT 1: Requirements Approval <<<**

Present the spec summary to the user:
- What will be built (2-3 bullets)
- Key constraints or decisions made
- Scope boundaries — what's explicitly OUT
- Link to full spec: `.claude/specs/<slug>.md`

Use AskUserQuestion:
- Option 1: "Approve requirements — proceed to exploration"
- Option 2: "Edit requirements" (iterate on spec)
- Option 3: "Pause — I need to think"

Do NOT proceed to Culture without explicit approval.
The spec is the contract — exploration and planning flow from it.

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

The agent runs in `permissionMode: plan` (read-only) and produces a numbered implementation checklist.

**>>> CHECKPOINT 2: Plan Approval <<<**

Present the plan summary:
- Architecture decision (one line)
- Files: N to modify, N to create
- Build steps: N (X parallel, Y sequential)
- Key decisions made
- YAGNI boundaries — what we're NOT building

Use AskUserQuestion:
- Option 1: "Approve plan — start building"
- Option 2: "Modify plan" (iterate)
- Option 3: "Scrap and re-explore" (back to Culture)
- Option 4: "Pause — save plan for later"

Do NOT proceed to Cook without explicit approval.

**Skip condition**: Obvious single-step change (trivial/small complexity).

---

## Phase 5 — Cut (Sonnet, inline)

Write high-level tests based on the approved plan and spec:
- **Large tasks**: Unit tests for new modules, integration test skeleton for the feature
- **Medium tasks**: Unit tests for new functions, integration test for the feature
- **Small tasks**: Single test file covering the change

Use the project's existing test framework and conventions. If no test framework exists, skip entirely.

After writing tests, run them via `whey-drainer` to confirm the scaffolding is sound before moving to implementation:

```
Task(subagent_type="whey-drainer", model="haiku", prompt="Run the new tests. They should fail (tests-before-code). Confirm they run without syntax/import errors and report the failure summary.")
```

**Skip condition**: No test framework, trivial change, or user opts out.

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

**Post-Cook verification**: Launch `whey-drainer` to run the full test suite and confirm the implementation doesn't break anything. This keeps verbose test output out of your context:

```
Task(subagent_type="whey-drainer", model="haiku", prompt="Run all tests. Report pass/fail counts and any failures.")
```

If failures are reported, fix them inline before moving on.

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

All findings are scored 0-100. Only failures >= 75 are highlighted as critical.

**Optional security check**: For medium/large tasks with external inputs or dependencies, also launch `fromage-pasteurize` in parallel for security and dependency scanning:

```
Task(subagent_type="fromage-pasteurize", model="sonnet", prompt="Security scan of changed files: <list>. Check for OWASP issues, input validation gaps, and dependency vulnerabilities.")
```

### Wrecker-Drainer Feedback Loop

After press writes tests, run the wrecker↔drainer loop to shake out issues:

1. **Drain**: Launch `whey-drainer` to run all tests:
   ```
   Task(subagent_type="whey-drainer", model="haiku", prompt="Run all tests. For any failures, note whether each looks like a test bug (test is wrong) or a code bug (implementation is broken).")
   ```

2. **Wreck** (if failures): Pass failure details to `roquefort-wrecker` to investigate and fix:
   ```
   Task(subagent_type="roquefort-wrecker", model="haiku", prompt="Investigate these test failures from whey-drainer:\n<failure details>\n\nFor test bugs: fix the tests. For code bugs: confirm and score them (0-100). Changed files: <list>.")
   ```

3. **Re-drain**: Launch `whey-drainer` again to verify fixes:
   ```
   Task(subagent_type="whey-drainer", model="haiku", prompt="Re-run all tests. Previous iteration had <N> failures. Confirm fixes and report any remaining issues.")
   ```

4. **Iterate** up to 3 rounds. After 3 rounds, surface remaining failures to the user:
   - **Code bugs (score >= 75)**: Fix inline or ask user for guidance
   - **Test bugs (score < 50)**: Wrecker should have fixed these — escalate if stuck
   - **Ambiguous (50-74)**: Present to user for judgment

**Skip condition**: Cut phase provided sufficient coverage, no test framework, or trivial change.

---

## Phase 8 — Age (Opus agent)

Launch the `fromage-age` agent in **focused mode** for code review:

```
Task(subagent_type="fromage-age", model="opus", prompt="Focused mode review. Diff: <git diff summary>. Review through two lenses: 1) Correctness & Safety (security, bugs, silent failures) 2) Architecture & Weight (coupling, dead code, inline, undocument, complexity). Score all findings 0-100, only surface >= 75.")
```

The agent reviews against:
- Sliced Bread architecture compliance
- Engineering principles (input validation, fail-fast, loose coupling, YAGNI, real-world models, immutable patterns)
- Complexity budget enforcement
- 0-100 confidence scoring, only surfaces >= 75

**Present findings to user.** Fix agreed issues inline.

**Skip condition**: Trivial change, single-line fix.

---

## Phase 9 — Package (Sonnet, inline)

Ship it:

### Hard Gate: Tests Must Pass

Before committing, run the project's test suite. This gate is **never skipped**.

1. Launch `whey-drainer` for the final regression check:
   ```
   Task(subagent_type="whey-drainer", model="haiku", prompt="Final regression check before commit. Run all tests.")
   ```
2. If tests fail:
   - Fix failures that are caused by your changes
   - Re-run tests (up to 3 iterations)
   - If failures are pre-existing (not caused by your changes), report them to the user and ask whether to proceed
3. **Do NOT commit with failing tests** unless the user explicitly approves after seeing the failures.

### Commit and PR

1. Use the `/commit` skill to stage and commit with a conventional commit message
2. If the user wants a PR, use the `/gh` skill to push and open a PR

**Skip condition for commit/PR**: User wants manual control, work is WIP, or user says "don't commit". The test gate still runs even if commit is skipped.

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
- If tests fail in Press, run the wrecker↔drainer feedback loop (up to 3 iterations before escalating to user)
- Never proceed past a user approval gate without explicit approval
- Use `whey-drainer` for running tests and `roquefort-wrecker` for fixing them — they work as a pair in the feedback loop
