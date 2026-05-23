# [Decision/Project Title — phrased as "Use X for Y" or "How we will Z"]

**Status:** Draft | In Review | Approved | Superseded by #NNN
**Authors:** [names]
**Date:** YYYY-MM-DD
**Decision-makers:** [names]   **Consulted:** [names]   **Informed:** [names]

## Context (1–2 paragraphs, your words, no AI)

What's true today? What changed recently that makes this worth writing?
Include one concrete metric, quote from a real user, or specific system
behavior. Do not start with the SQCA opener ("In recent quarters…") —
that's a slop tell.

## Problem (1 paragraph, your words)

What's broken? Phrase it as a question if possible. One paragraph,
specific to *this* system. Avoid the word "scalability" without a
number; avoid "complexity" without a named example.

## Goals (3–5 bullets, your words, measurable)

- Specific, measurable, time-bound where possible. e.g.
  "Reduce P95 profile-load from 2.1s to <1s by EOQ" not "improve
  performance."
- ...

## Non-Goals (3–5 bullets, your words)

Things that could reasonably be goals but are explicitly chosen not to
be. NOT negated goals ("system shouldn't crash") but plausible scope
we're declining.

- ...

## Proposed Design (you write the skeleton; AI may help flesh out)

Overview (one paragraph). Then the substantive sub-sections: data
model, APIs, control flow, deployment. Include one diagram (Mermaid)
that you drew.

```mermaid
%% Your diagram here. If you can't draw it, the design isn't done.
```

## Alternatives Considered (your words; at least 3; one must be "do nothing")

Each alternative gets: one-sentence summary, one trade-off it made,
one specific reason we rejected it. If you can swap two alternatives
without changing the rationale, you have not written real
alternatives — go again.

### Alternative A

### Alternative B

### Alternative C — Do nothing

## Risks & Mitigations (your words; specific, not generic)

At least one risk must be one a stranger could not have written.
"Generic AI risk: 'might increase load.' Real risk: 'the Redis cluster
shares a node pool with billing; a hot key in this feature could
starve invoice generation, which last failed in incident I-2031.'"

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| ... | ... | ... | ... |

## Open Questions

Bullet list. Encouraged — signals honesty.

- ...

## Rollout

Phased plan. What ships in week 1, week 2, etc. Include the rollback
plan and how you'll know it's working.

## Appendix

Diagrams, schema, links, prior art. Where AI-generated prose, if any,
lives — clearly marked as such.
