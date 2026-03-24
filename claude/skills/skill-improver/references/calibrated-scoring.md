# Calibrated Confidence Scoring — Reference Guide

The 4-step method for making LLM confidence ratings actually useful.

## The Problem

LLM self-reported confidence is pattern matching on rubric descriptions, not
calibrated probability. Models are systematically overconfident on style opinions
and underconfident on real bugs — the exact opposite of what's useful for triage.

Scores cluster around defined thresholds because the model reads "75 = important"
and anchors to that number whenever it thinks something matters.

## The Solution: 4-Step Chain-of-Thought Calibration

Based on research (Kadavath et al. 2022, Xiong et al. 2024) showing that
structured decomposition improves LLM calibration by 15-25%.

### Step 1: Classify Claim Type

Assign each finding a **category** with a **base score** and **hard cap**.

Why this works: category priors predict accuracy better than the model's
self-assessed score. A BUG claim has ~65-70% precision regardless of whether
the model says it's 80% or 90% confident. A STYLE claim has ~40% precision
even when the model says 95%.

The hard cap prevents style nits from ever reaching "critical" regardless of
how many modifiers stack up. The base score prevents real bugs from starting
too low.

**Template** (customize categories for your domain):
```
| Type | Description | Base score | Cap |
|------|-------------|------------|-----|
| HIGH_IMPACT | Correctness issues, security, data loss | 50 | 100 |
| MEDIUM_IMPACT | Structural issues, coupling, complexity | 40 | 95 |
| LOW_IMPACT | Style, documentation, minor cleanup | 20 | 60 |
```

### Step 2: Evidence Grounding

Adjust from the base score based on how verifiable the finding is.

Why this works: forces the model to check its claims before scoring them.
A finding verified via LSP or grep is categorically different from "this
looks like it might be an issue."

**Template** (customize verification methods for your domain):
```
| Evidence quality | Modifier |
|------------------|----------|
| Verified via tool (LSP, grep, test) — concrete proof | +20 to +25 |
| Cites specific location with accurate reference | +15 |
| References a stated rule or convention | +10 |
| Generic observation without verification | -10 to -15 |
| Misreads the code or cites nonexistent constructs | hard cap at 0 |
```

### Step 3: Context Modifiers

Apply domain-specific signals that adjust severity.

Why this works: the same finding in different contexts has different
importance. A bug in a hotspot file (many recent changes, many authors)
is more dangerous than one in stable code. A pre-existing issue not
introduced by this change is less urgent than a newly introduced one.

**Template** (customize for your domain):
```
| Signal | Modifier |
|--------|----------|
| High-risk context (hotspot, critical path) | +10 to +15 |
| Low-risk context (stable code, internal-only) | -5 to -10 |
| Pre-existing (not introduced by current change) | -15 or hard cap |
```

### Step 4: Re-Assess Borderline Items

For items near the surfacing threshold, score independently a second time
without looking at the first score.

Why this works: multi-sample self-consistency (Xiong et al. 2024) is the
most effective single technique for improving calibration. If two independent
assessments agree, the finding is robust. If they diverge by >15 points,
the model is genuinely uncertain — which is valuable information.

**Rules:**
- Define your borderline zone: typically threshold-15 to threshold-1
- Re-read the full source file (not just the excerpt) before rescoring
- If scores diverge >15 points → don't surface (ambiguous)
- If both scores land >= threshold → surface with confidence
- Never average divergent scores (45 and 85 ≠ 65 "maybe")

## Key Principles

1. **Ordering > magnitude**: "A is more important than B" is trustworthy.
   "A is exactly 82" is not. Use scores for ranking, not as probabilities.

2. **Category priors > self-assessment**: The type of claim predicts accuracy
   better than the model's confidence number.

3. **Full context improves calibration**: Reading the full file (not just the
   diff hunk) before rescoring improves accuracy by 15-20 percentage points
   for borderline items.

4. **Don't average disagreement**: Two divergent scores mean genuine ambiguity.
   Averaging them into a middling score hides this information.

## Adapting for New Agents

To add calibrated scoring to a new agent:

1. **Identify the agent's judgment types** — what categories of findings/claims
   does it produce? (bugs, style, coupling, etc.)
2. **Set base scores and caps** — higher base for higher-impact categories,
   caps that prevent low-impact items from reaching "critical"
3. **Define evidence grounding** — what verification tools does this agent have?
   LSP, grep, test execution, API calls?
4. **Add context modifiers** — what domain signals adjust severity?
5. **Set the borderline zone** — typically threshold-15 to threshold-1 for re-assessment
6. **Define the surfacing threshold** — typically 75, but can be 50 for agents
   where false negatives are costlier than false positives

## Reference Implementations

| Agent | Domain | Threshold | Categories |
|-------|--------|-----------|------------|
| fromage-age | Code review | >= 50 | BUG, SECURITY, COUPLING, COMPLEXITY, DEAD_CODE, INLINE |
| fromage-fort | PR comment triage | >= 50 (FIX) | BUG, CONVENTION, STYLE, SCOPE_CREEP |
| ricotta-reducer | Code simplification | >= 50 | DELETE, INLINE, DECOUPLE, UNDOCUMENT |
