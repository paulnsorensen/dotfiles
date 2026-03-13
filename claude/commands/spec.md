---
name: spec
description: >
  Discovery dialogue to architect a feature and produce a spec with user stories,
  quality gates, and implementation paths. Use when scope is unclear, features touch
  multiple systems, or architectural tradeoffs need exploration. Produces a spec
  artifact that feeds directly into /fromage for implementation. Also trigger when
  the user says "spec this out", "plan this feature", "write requirements for",
  "PRD for", or "what would it take to build".
argument-hint: <what you want to build>
---

Facilitate a discovery dialogue to architect: $ARGUMENTS

This is upstream of implementation — collaborative design thinking that produces a spec artifact ready for `/fromage` execution.

## Dialogue Style

This is a **fluid conversation**, not an interrogation — but with structure for speed:
- Weave questions naturally into discussion
- Offer **lettered options** (A/B/C/D) so the user can respond quickly ("1A, 2C")
- Think out loud: "I'm wondering if..."
- Acknowledge uncertainty: "I'm not sure about X yet, let's explore"
- Periodically summarize: "Here's where we are..."
- Research and code exploration happen *during* the dialogue, not as a separate phase

## The Loop

The conversation follows a question-research-question loop. Minimum **3 rounds**, maximum **6 rounds** before generating the spec.

### Round Structure

Each round has up to three beats:

**Beat 1 — Ask** (every round)
Ask 2-4 clarifying questions with lettered options. Group related questions together.

```
1. What problem are we solving?
   A. Users can't find X
   B. Performance degrades under Y
   C. Missing integration with Z
   D. Other: [please specify]

2. Who has this problem?
   A. End users
   B. Internal team
   C. Both
```

The user responds with "1A, 2C" for fast iteration.

**Beat 2 — Research** (rounds 2+, as needed)
Between rounds, use skills to verify and deepen understanding:

- **`/research`** — Verify assumptions against current docs, check prior art, confirm APIs haven't changed. Spawn as a subagent so it runs in the background while you formulate next questions.
- **`/lookup`** — Assess the shape of existing code. What modules exist? What's the public API surface? What patterns are already established? Routes to LSP, Serena, ast-grep, or Context7 as appropriate.
- **`/trace`** — When you need structural code patterns: "what implements this interface?", "which adapters call this port?"
- **`/serena`** — For cross-reference tracing and symbol navigation when you need to understand call chains or dependency direction.

Surface findings conversationally: "I checked and we already have a `FooAdapter` that does half of this — want to extend it or build fresh?"

**Beat 3 — Summarize** (every 2 rounds)
Periodically check alignment: "Here's where we are so far... Does this direction feel right?"

### Round Progression

| Round | Focus | Skills |
|-------|-------|--------|
| 1 | Problem, users, success criteria, constraints | Light code reading to ground questions in reality |
| 2 | Scope, non-goals, existing landscape | `/lookup`, `/research` |
| 3 | Design options, tradeoffs, quality gates | `/lookup`, `/trace` |
| 4+ | Refinement, edge cases, acceptance criteria | `/research` as needed |

Round 1 doesn't need formal skill invocations, but **do read relevant code** before asking questions. Grounding questions in what actually exists ("I see you already have a `FooAdapter` — is the pain that it doesn't cover X, or that it's too coupled to Y?") produces better answers than abstract interrogation.

On the **last round**, if you're still uncertain about anything, ask: "I have a few open items — want to continue refining or should I generate the spec with `[TBD]` markers?"

### Question the Premise

Before diving into *how* to build something, ask whether it should be built at all. The best spec conversations sometimes end with "actually, a smaller change solves this." Watch for signals:

- User says "I'm not sure if this is overengineering" → make that a question, not a footnote
- The existing code already does 80% of what's asked → surface that and ask if the remaining 20% justifies new architecture
- The request assumes a solution → back up to the problem: "What's actually hurting today?"

Frame these as lettered options too:
```
Your YAGNI principle is relevant here. What's driving this work?
   A. I hit a real bug or failure that the current structure made hard to fix
   B. I'm about to add new capabilities and want a cleaner extension point
   C. The file is over my complexity budget and I want to get ahead of it
   D. Mostly a craftsmanship itch — I want it to feel right
```

This isn't about blocking work — it's about making sure the spec solves the right problem.

### Quality Gates Question (required, round 3)

Always ask about quality gates — these are project-specific:

```
What commands must pass for this feature to be considered done?
   A. cargo test && cargo clippy
   B. npm test && npm run typecheck
   C. pytest && mypy
   D. Other: [specify your commands]

Should we include integration/E2E verification?
   A. Yes, specific paths: [specify]
   B. Unit tests are sufficient
   C. Manual verification checklist
```

## Crystallize

When the conversation feels complete (after 3+ rounds):
- Draft the spec artifact
- Present for review: "Does this capture our discussion?"
- Refine based on feedback

## Persist

Save and optionally publish:
- Write to `.claude/specs/<slug>.md`
- Offer: "Want me to create a GitHub Issue from this?"
- If yes: `gh issue create --title "<title>" --body-file .claude/specs/<slug>.md`
- Offer: "Ready to start implementation with `/fromage`?"

## Spec Artifact Format

```markdown
---
title: <Feature Name>
created: <ISO date>
status: draft
stakeholders: []
related: []
---

# <Feature Name>

## Problem Statement
What problem are we solving? Who has it? Why now?

## Goals
- [ ] Goal 1
- [ ] Goal 2

## Non-Goals
What we're explicitly NOT doing.

## Context

### Existing Landscape
What already exists? (from /lookup and /research findings)

### Constraints
Technical, business, or timeline constraints.

### Dependencies
What we depend on. What depends on us.

## Quality Gates

Commands that must pass for every user story:
- `<command>` — <what it checks>
- `<command>` — <what it checks>

## User Stories

### US-001: <Title>
**Description:** As a <user>, I want <feature> so that <benefit>.

**Acceptance Criteria:**
- [ ] Specific, verifiable criterion
- [ ] Another criterion (not "works correctly" — be precise)

### US-002: <Title>
**Description:** As a <user>, I want <feature> so that <benefit>.

**Acceptance Criteria:**
- [ ] ...

## Functional Requirements
- FR-1: The system must...
- FR-2: When a user does X, the system must...

## Proposed Approach

### Option A: <Name> (Recommended)
Description, tradeoffs, and why this is recommended.

### Option B: <Name>
Description and why not chosen.

## Implementation Notes
- Key files/modules to touch (from /lookup findings)
- Patterns to follow
- Pitfalls to avoid

## Areas for Further Exploration
Items that need deeper investigation during /fromage execution:
- [ ] Area 1 — what needs drill-down and why
- [ ] Area 2

## Success Metrics
How we measure this feature is working:
- Metric 1 (quantitative if possible)
- Metric 2

### Red/Green Paths
End-to-end verification scenarios:
- **Green:** User does X → system responds with Y → state becomes Z
- **Red:** User does X without auth → system returns 401 → no state change

## Open Questions
- [ ] Question 1 [TBD]
- [ ] Question 2 [?]
- [ ] Question 3 [BLOCKED]

## Assumptions
- Assumption 1 (if wrong, reconsider X)
- Assumption 2 (if wrong, reconsider Y)
```

## Uncertainty Markers

| Marker | Meaning | Example |
|--------|---------|---------|
| `[?]` | Uncertain, needs validation | "Use Redis for caching [?]" |
| `[TBD]` | Needs decision before implementing | "Auth method [TBD]" |
| `[BLOCKED]` | Can't proceed without answer | "API endpoint URL [BLOCKED]" |

## Writing User Stories for AI Execution

The spec feeds into `/fromage`. User stories should be:
- **Small** — completable in one focused agent session
- **Independent** — no story should block another if possible
- **Verifiable** — acceptance criteria a machine can check, not "works correctly"
- **Explicit** — include file paths, module names, patterns from `/lookup` findings

## When NOT to Use /spec

- Simple changes → `/fromage` directly
- Bug fixes → just fix it
- User already has clear spec → skip to implementation
- Pure research → `/research` or `/onboard`

## When to Use /spec

- New features where scope is unclear
- Architectural decisions with tradeoffs
- Features touching multiple systems
- When "I don't know the full picture" is true
- Cross-team initiatives needing documentation

Begin the discovery dialogue for: $ARGUMENTS
