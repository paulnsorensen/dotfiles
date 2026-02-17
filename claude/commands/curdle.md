---
name: curdle
description: Complete Cheddar Flow - full 6-step workflow with Explore, Plan, Code, Test, Review, and Commit.
---

Execute the complete Cheddar Flow development workflow for the given request. This is the full fermentation - thorough and comprehensive. You do the thinking directly; sub-agents only for mechanical work.

## Preamble

If not already in a worktree, run `/worktree <slug>` first (derives slug from request).
If already isolated, just prime Serena: `activate_project` → `check_onboarding` → `read_memory` for relevant ones.

## The Six Stages

### 1. Explore

Read relevant files in parallel using Read, Grep, and Glob directly. Map the architecture — entry points, domain models, adapters, and configuration. Prefer parallel tool calls to speed this up.

### 2. Plan

Write a detailed implementation strategy inline. Cover:
- What changes are needed and where
- Order of operations
- Edge cases to handle
- What NOT to build (YAGNI boundaries)

### 3. Code

Implement the plan directly. Follow YAGNI discipline — build only what's needed now.

### 4. Test

Launch the roquefort-wrecker sub-agent via the Task tool to validate the implementation:
- Invalid inputs first (boundary conditions, nulls, empty strings)
- Happy path coverage
- Edge cases identified during planning

### 5. Review

Self-review the changes against the full engineering principles:

- **Input Validation** — Trust nothing from external sources. Validate at system boundaries.
- **Fail Fast and Loud** — No silent failures. Specific error messages. Handle errors where they occur.
- **Loose Coupling** — Business logic free of infrastructure imports. Dependencies point inward.
- **YAGNI** — No premature abstractions. No speculative code. No single-use wrappers.
- **Real-World Models** — Domain-driven naming. Consistent terminology. Business concepts, not technical jargon.
- **Immutable Patterns** — Minimize mutation. Pure functions where possible.
- **Complexity budget** — 40 lines/fn, 300 lines/file, 4 params/fn, 3 levels nesting.
- **No genAI bloat** — Strip unnecessary docs, dead code, over-documentation.

If issues found, fix them before proceeding.

### 6. Ship

Use the `/commit-push-pr` skill to commit, push, and open a PR.
If `/commit-push-pr` is unavailable, fall back to `/commit`.

## When to Use /curdle

- New features
- Significant refactoring
- Security-sensitive changes
- Code handling external input
- Anything going to production
- When you want rich commit history

For the request: "{{request}}", execute the complete Cheddar Flow workflow.
