---
name: prompt-analytics
model: opus
effort: high
description: >
  Analyze prompt patterns, skill-routing behavior, and knowledge gaps across
  coding-agent sessions and produce calibrated recommendations. Use for
  /prompt-analytics, "analyze my prompts", or "is routing working".
allowed-tools: Read, Bash
---

# prompt-analytics

Judgment skill: score findings with the shared confidence × severity model.
Target: a skill/router name for `routing-accuracy`, a keyword/topic for
`knowledge-gaps`, `%` for a broad `prompt-analysis` sweep. Ask if unclear.

Run `<skill-dir>/scripts/analyze.sh <domain> <target> [harness]` for each
relevant domain: `prompt-analysis`, `routing-accuracy`, `knowledge-gaps`, or
`all`.

Then calibrate with `../session-analytics/references/calibration.md`. Two
domains are explicitly weaker signal — honor that: `routing-accuracy` has no
intent ground-truth (correlational at best — never claim the *right* skill
fired) and `knowledge-gaps` is medium-signal (a recurring topic is not proof
of a missing skill). Their findings lean `<speculative>`; demote to
`<don't know>` when data is thin.

Report format:

```
## Prompt & Routing Report: {TARGET}
### Summary        — target · harness · domains run · N surfaced / N below bar
### Recommendations — | # | Severity | Confidence | Domain | Issue | Recommendation |
### Detail         — per finding: What / Why (the metric) / How
### Below the Bar  — count only
```

Never: a 0-100 score; treating correlation as causation; rewriting prompts or
skill descriptions (recommend only — the human decides).
