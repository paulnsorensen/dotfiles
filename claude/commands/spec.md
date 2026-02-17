---
name: spec
description: Discovery dialogue to architect a feature and produce a specification
argument-hint: <what you want to build>
---

Facilitate a discovery dialogue to architect: {{request}}

This is upstream of implementation — collaborative design thinking that produces a spec artifact.

## Dialogue Style

This is a **fluid conversation**, not an interrogation:
- Weave questions naturally into discussion
- Research (Serena, web) organically as questions arise
- Think out loud: "I'm wondering if..."
- Acknowledge uncertainty: "I'm not sure about X yet, let's explore"
- Periodically summarize: "Here's where we are..."

## Soft Phases (Not Gates)

### 1. Understand the Ask

Parse the user's description and clarify:
- What problem are we solving? Who has it?
- What does success look like?
- Any constraints or non-goals?

Don't fire all questions at once — weave them into natural dialogue.

### 2. Research & Explore

As the conversation develops:
- Use Serena (`find_symbol`, `get_symbols_overview`) to map relevant existing code
- Web search for patterns, prior art, API docs when helpful
- Check Serena memories for relevant context
- Surface constraints and dependencies conversationally, not as data dumps

### 3. Design Dialogue

Iterate toward a design:
- Propose options with tradeoffs
- Mark uncertain items with `[?]`
- Mark needs-decision items with `[TBD]`
- Capture decisions as they emerge
- Periodically check: "Does this direction feel right?"

### 4. Crystallize

When the conversation feels complete:
- Draft the spec artifact
- Present for review: "Does this capture our discussion?"
- Refine based on feedback

### 5. Persist

Save and optionally publish:
- Write to `.claude/specs/<slug>.md`
- Offer: "Want me to create a GitHub Issue from this?"
- If yes: `gh issue create --title "<title>" --body-file .claude/specs/<slug>.md`

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
What problem are we solving? Who has it?

## Goals
- [ ] Goal 1
- [ ] Goal 2

## Non-Goals
What we're explicitly NOT doing.

## Context

### Existing Landscape
What already exists? (from research)

### Constraints
Technical, business, or timeline constraints.

### Dependencies
What we depend on. What depends on us.

## Proposed Approach

### Option A: <Name> (Recommended)
Description and tradeoffs.

### Option B: <Name>
Description and why not chosen.

## Implementation Notes
- Key files/modules to touch
- Patterns to follow
- Pitfalls to avoid

## Open Questions
- [ ] Question 1 [TBD]
- [ ] Question 2

## Assumptions
- Assumption 1 (if wrong, reconsider X)
- Assumption 2

## Acceptance Criteria
- [ ] Criterion 1
- [ ] Criterion 2
```

## Uncertainty Markers

| Marker | Meaning | Example |
|--------|---------|---------|
| `[?]` | Uncertain, needs validation | "Use Redis for caching [?]" |
| `[TBD]` | Needs decision before implementing | "Auth method [TBD]" |
| `[BLOCKED]` | Can't proceed without answer | "API endpoint URL [BLOCKED]" |

## When NOT to Use /spec

- Simple changes → `/cheese` directly
- Bug fixes → just fix it
- User already has clear spec → skip to implementation
- Pure research → `/onboard` or `/code-review`

## When to Use /spec

- New features where scope is unclear
- Architectural decisions with tradeoffs
- Features touching multiple systems
- When "I don't know the full picture" is true
- Cross-team initiatives needing documentation

Begin the discovery dialogue for: {{request}}
