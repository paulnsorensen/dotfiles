---
name: prompt-analytics
model: opus
effort: high
description: >
  Analyze how prompts and skill routing behave across coding-agent sessions and
  produce calibrated recommendations — prompt-pattern analysis, routing accuracy,
  and knowledge gaps. Use when the user says "analyze my prompts", "prompt
  patterns", "is routing working", "which skill should have fired", "knowledge
  gaps", "what do I keep asking", or invokes /prompt-analytics. Do NOT use for auditing a
  single skill/agent definition (that is /skill-improver), tool/MCP efficiency
  (that is /tool-efficiency), or one-off interactive log queries (that is
  /session-analytics).
allowed-tools: Read, Agent, Bash
---

# prompts

Analyze prompt and routing behavior across sessions, then produce calibrated
recommendations. Judgment skill — scores findings with the shared
confidence × severity model.

## Input

A target framing for the analysis: a skill/router name for routing accuracy, a
keyword/topic for knowledge gaps, or `all` for a broad prompt-pattern sweep. If
unclear, ask. Optional harness filter (`all` default).

## Owned domains

Three analytics packs under `references/`:

| Domain | Pack | What it surfaces |
|--------|------|------------------|
| prompt-analysis | `prompt-analysis.md` | Recurring user-prompt shapes, repeated asks, session openers |
| routing-accuracy | `routing-accuracy.md` | Did the right skill fire? (correlational — no ground truth) |
| knowledge-gaps | `knowledge-gaps.md` | Topics that recur without a resolving skill/tool (medium signal) |

## Protocol

1. **Ingest** — `python3 ~/Dev/dotfiles/skills/session-analytics/scripts/ingest.py`
   (1-hour TTL). Best-effort.
2. **Fan out** — spawn **one parallel `duckdb-expert` per relevant domain**
   (one-domain-per-spawn):

   ```
   spawn duckdb-expert "Run analytics pack prompt-analytics/references/<domain>.md for target {TARGET}. harness={HARNESS}"
   ```

3. **Collect** the digests.
4. **Calibrate** with `../session-analytics/references/calibration.md`. Two of
   these domains are explicitly weaker signal — honor that: `routing-accuracy`
   has no intent ground-truth (correlational at best) and `knowledge-gaps` is
   medium-signal. Findings from them lean `<speculative>`; demote to
   `<don't know>` when the data is thin.
5. **Report** (below).

## Report

```
## Prompt & Routing Report: {TARGET}

### Summary
- Target: <skill/topic/all>  ·  Harness: <filter>
- Domains run: <list>
- Findings: N surfaced, N below the bar

### Recommendations (surfaced)
| # | Severity | Confidence | Domain | Issue | Recommendation |
|---|----------|------------|--------|-------|----------------|

### Detail
For each surfaced finding: What / Why (with the metric) / How.

### Below the Bar
N findings were `<don't know>` or insufficient-signal (not shown).
```

## What this skill never does

- Score with a 0-100 number — uses the shared qualitative model.
- Treat correlation as causation: routing-accuracy lacks ground truth and must
  say so.
- Run more than one domain per `duckdb-expert` spawn.
- Rewrite prompts or skill descriptions — it recommends; the human decides.

## Gotchas

- `routing-accuracy` infers intent from what fired next; it cannot prove the
  *right* skill fired. Always tag its findings `<speculative>` at most.
- `knowledge-gaps` is medium-signal — a recurring topic isn't proof of a missing
  skill. Degrade to "insufficient signal" rather than over-claim.
