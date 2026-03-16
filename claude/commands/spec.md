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

## Beat 0 — Defend the Why (mandatory gate)

Before any design or scoping work, run through these framing questions. These are **non-negotiable** — if the user can't defend their answers, push back. Present as lettered options where possible.

1. **Job to Be Done** — "What's the job this feature does for the user? Not what it *is*, but what it *lets them accomplish*."
2. **Why Now** — "Why build this now instead of next month or never? What's changed?"
3. **What This Unlocks** — "If we build this, what becomes possible that wasn't before? What's the second-order effect?"
4. **Who Has This Problem** — "Who specifically feels this pain today? How do they work around it?"
5. **Do Nothing Option** — "What happens if we don't build this? Is the status quo actually intolerable?"

If the user can't answer #1-3 convincingly, **pause and explore further** before proceeding. A vague JTBD means we're building the wrong thing. Surface this tension directly: "I'm not convinced yet — can you help me understand X?"

After framing, summarize the "why" in 2-3 sentences. This becomes the spec's Problem Statement.

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

**Beat 2 — Research Burst** (round 2, then as needed)

In Round 2, launch a **parallel evidence-gathering sweep** — spawn 3-4 agents simultaneously, each scanning a different source. Each agent writes findings to a temp markdown file that you synthesize afterward.

| Agent | Source | What to Find |
|-------|--------|-------------|
| `/research` | Web + docs | Prior art, competitor approaches, relevant blog posts, library options |
| `/lookup` → `/trace` | Codebase | Existing patterns, public API surface, architectural boundaries |
| `/serena` | Cross-refs | Call chains, dependency direction, blast radius of the change |
| Context7 / octocode | External code | How other projects solved similar problems, real-world examples |

After agents return, **synthesize key patterns** before continuing the conversation:
- What do 2+ sources agree on? (strong signal)
- Where do sources contradict? (needs user input)
- What surprising findings emerged? (surface these)

Present synthesis conversationally: "I ran research in parallel — here's what I found across 4 sources: [patterns]. The interesting tension is between X and Y. Which direction feels right?"

In later rounds, use individual skills as needed:
- **`/research`** — Verify specific assumptions, check APIs
- **`/lookup`** — Targeted code exploration
- **`/trace`** — Structural code patterns: "what implements this interface?"
- **`/serena`** — Cross-reference tracing and symbol navigation

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
   E. Actually... maybe we don't need to build this at all
```

Always include an explicit **"do nothing"** option. Sometimes the best spec is the one that concludes "the status quo is fine" or "a smaller change solves this." That's a valid outcome — it saves real engineering time.

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

Target a **2-minute read** (~800 words of prose, excluding code/tables). Ruthlessly prioritize signal over documentation theater. If a section has nothing meaningful to say, omit it rather than filling space.

```markdown
---
title: <Feature Name>
created: <ISO date>
status: draft
stakeholders: []
related: []
---

# <Feature Name>

## Executive Summary
3-5 sentences: what we're building, why, and the key design decision.
A busy person reading only this section should understand the feature.

## Business Context
What business or engineering goal does this serve? Ground the feature in
what the product/system does in the real world.
- **Domain**: What is the business domain? (e.g., "we provide inference APIs")
- **Primary entities**: What are the key business objects? (e.g., users, subscriptions, deployments)
- **This feature's role**: How does this feature serve the business goal?
- **Success looks like**: What changes in the real world when this ships?

## Problem Statement
What problem are we solving? Who has it? Why now?
(Drawn from Beat 0 framing answers — JTBD, why now, what this unlocks)

## Design Principles
3-5 principles specific to THIS feature (not global engineering principles).
Each principle is a decision filter — when in doubt during implementation, consult these.
- **Principle 1**: e.g., "Prefer accuracy over speed — a slow correct answer beats a fast wrong one"
- **Principle 2**: e.g., "Users should never see raw error codes — always translate to actionable guidance"
- **Principle 3**: e.g., "Backward compatibility with existing CLI flags is non-negotiable"

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
**Evidence**: [cite research findings — e.g., "3 competitor implementations use this pattern", "our codebase already has FooAdapter doing 80% of this"]

### Option B: <Name>
Description and why not chosen.
**Evidence**: [cite specific reason with evidence — not just "less good", but "adds 2 new dependencies for marginal benefit" or "competitor X tried this and reverted"]

### Option C: Do Nothing
What happens if we don't build this? Is the status quo actually intolerable?
(This option is always included. Sometimes it wins.)

## Risks & Mitigations
What could go wrong and how we'd handle it:
- **Risk**: <what could fail> → **Mitigation**: <how we prevent or recover>
- **Risk**: <what could fail> → **Mitigation**: <how we prevent or recover>

## Implementation Notes
- Key files/modules to touch (from /lookup findings)
- Patterns to follow
- Pitfalls to avoid

## Key Patterns (from research)
Synthesized findings from the parallel research burst:
- **Pattern 1**: What 2+ sources agreed on [Evidence: source A, source B]
- **Pattern 2**: How other projects solved this [Evidence: GitHub examples]
- **Tension**: Where sources disagreed and the decision we made

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
