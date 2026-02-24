---
name: fromage
description: Complete Fromage Development Platform — intelligent cheese-making pipeline that adapts to task complexity. Replaces /cheese and /curdle.
argument-hint: <what you want to build or fix>
---

Execute the Fromage development pipeline for: **$ARGUMENTS**

Full cheese-making process — raw milk to packaged wheel. Assesses complexity and skips phases that don't add value.

---

## Phase 0 — Assess

### Hard Gate: Worktree Check

Check if you are in a git worktree (`.git` is a file, not a directory). If NOT:

1. **Stop.** Do not proceed.
2. Ask: "You're on the main branch. Want me to create a worktree with `/worktree <slug>`?"
3. Only proceed after user is on a worktree OR explicitly says "continue on main".

This gate is **never skipped**.

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
| 5. Cut | skip | optional | run | run |
| 6. Cook | run | run | run | run |
| 7. Press | skip | optional | run | run |
| 8. Age | skip | skip | run | run |
| 9. Package | run | run | run | run |

User can override any skip decision.

---

## Phase 1 — Preparing (Haiku)

Launch `fromage-preparing` (haiku). It checks worktree status, primes Serena, and reports git state.

**Skip**: Already in a worktree AND Serena active — confirm inline.

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

Launch 2-3 `fromage-culture` agents (sonnet), each targeting a different aspect:

- **Aspect A**: Entry points, existing patterns, data flow and transformations
- **Aspect B**: Blast radius — affected code, state changes, side effects
- **Aspect C** (large only): Architecture, cross-cutting concerns, configuration

After agents return, **read all identified key files** yourself for full planning context.

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

Launch `fromage-age` (opus) in focused mode. Reviews through three dimensions:

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
