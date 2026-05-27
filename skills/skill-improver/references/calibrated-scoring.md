# Calibration — Reference Guide

Two qualitative axes for making agent findings honest and reproducible:
**confidence** (is this real?) and **severity** (how much does it matter?).
This replaces single-number 0-100 scoring.

## Why not a 0-100 score

LLM self-reported numeric confidence is pattern matching on rubric text, not
calibrated probability. Models anchor to round numbers ("75 = important") and are
systematically overconfident on style, underconfident on real bugs. Research on
LLM-as-judge (Zheng et al. 2024) finds absolute numeric scoring less robust and
less human-aligned than relative/qualitative judgment. A points total invents
precision the model does not have — so rank and tag, don't score.

## Axis 1 — Confidence (epistemic)

Tag every finding with how sure you are it is real:

- `<certain>` — verified by reading the code, running it, or citing a source.
  Defensible if challenged.
- `<speculative>` — pattern-match or inference; plausible but unverified. Surface
  it, but say so.
- `<don't know>` — can't tell without more work. Do NOT surface as a finding;
  raise it as an open question or drop it.

Evidence drives the tag (this subsumes the old "evidence grounding" step):

| Evidence | Confidence |
|----------|------------|
| Verified via tool (LSP, grep, test), or specific accurate location + concrete failure | `<certain>` |
| References a stated rule/convention, or a checkable but unverified observation | `<speculative>` (raise to `<certain>` once verified) |
| Generic impression, or you may have misread | `<don't know>` (drop) |
| Misreads the code / cites nonexistent constructs | drop entirely |

## Axis 2 — Severity (priority)

How much it matters if real — orthogonal to confidence. Use the `/age` tiers:

- `blocker` — the definition is broken as written; it will misbehave.
- `high` — significant functional impact.
- `medium` — worth fixing, not urgent.
- `low` — style, docs, polish.

Category priors set a **default severity** (a class of issue has a typical
impact); adjust for the specific case. Context raises it (a judgment agent with
no calibration, unbounded output) or lowers it (a focused sub-agent, pure style).

A `<certain>` style nit is `low`; a `<speculative>` correctness risk can be
`high`. Don't let one axis bleed into the other.

## Re-assess borderline (self-consistency)

For any `<speculative>` finding you are about to surface, re-derive the reasoning
once more without looking at the first pass — re-read the full file, not just an
excerpt. Multi-sample self-consistency is the most effective single calibration
technique (Xiong et al. 2024). If the second pass does not reproduce it, drop to
`<don't know>`. Never split the difference into a vague "maybe": divergence is
information — it means you don't actually know.

## Surfacing rule

- `<certain>` or `<speculative>`, and severity worth a reader's time → surface,
  tagged with both axes.
- `<don't know>` → never surfaced; count it in the below-bar tally.
- Order the report by severity (blocker → low). Within a tier, `<certain>` before
  `<speculative>`.

## Key principles

1. **Ordering > magnitude.** "A matters more than B" is trustworthy; "A is exactly
   82" is not. Relative judgment is better calibrated than absolute (Zheng 2024).
2. **Category priors > self-assessment.** The *type* of finding predicts impact
   better than a confidence number ever did — it now sets default severity.
3. **Full context improves calibration.** Read the whole file before re-assessing
   a borderline item; excerpt-only judgments are weaker (Kadavath et al. 2022).
4. **Don't average disagreement.** Two divergent reads mean genuine ambiguity —
   that is a `<don't know>`, not a midpoint.

## Adapting for a new agent

1. Identify the finding categories the agent produces.
2. Give each a default severity tier (impact-based).
3. Define what counts as `<certain>` evidence for this agent — which verification
   tools does it have (LSP, grep, tests)?
4. List the context signals that raise or lower severity.
5. State the surfacing rule and the `<speculative>` re-assess step.

## Reference implementations

| Where | Pattern |
|-------|---------|
| `/age` | severity tiers (Blocker / High / Medium / Low), per-finding confidence |
| age voice kernel (`skills/age/references/voice.md`) | `certain | speculative | don't know` vocabulary |

Agents still emitting 0-100 scores (e.g. fromage-fort, ricotta-reducer) predate
this model and would themselves raise a `SCORING` finding under it.
