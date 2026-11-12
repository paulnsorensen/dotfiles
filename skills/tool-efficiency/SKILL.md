---
name: tool-efficiency
model: opus
effort: high
description: >
  Audit how a tool, command, or MCP server is actually used across coding-agent
  sessions and produce calibrated fix recommendations. Use for /tool-efficiency,
  "am I using X efficiently", or "why does X keep failing".
allowed-tools: Read, Bash
---

# tool-efficiency

Judgment skill: score findings with the shared confidence × severity model,
don't just report numbers. Target: a tool name, a Bash command prefix, or an
MCP server; `%` scans everything. Ask if none given.

Run `<skill-dir>/scripts/analyze.sh <domain> <target> [harness]` for each
relevant domain — pick by target:

- MCP server → `mcp-health` + `error-forensics` + `fix-recommendations`
- Bash command → `tool-usage` + `permission-friction` + `error-forensics`
- "how do I fix X" / high error rate → `error-forensics` + `fix-recommendations`
- broad audit → `all` (also runs `token-economics`)

The script calls the public `agent-session-analytics` package for SQL and
Markdown tables. Its default database follows package freshness rules.
An explicit `SESSIONS_DB` must name a package-compatible database.
A package failure is an error, not insufficient signal.

`SESSIONS_COHORT=retained|benchmark|all` selects the report cohort.
The default `retained` excludes sessions with benchmark path markers.
It keeps sessions with unknown provenance and does not exclude child sessions.
Path markers are heuristic, not verified provenance.
The report prints all three cohort counts before the report.
`SESSIONS_SINCE` and `SESSIONS_UNTIL` set one half-open UTC window.
Use `YYYY-MM-DDTHH:MM:SSZ` for each bound.
The default covers all history through one captured current UTC end.
The same window applies to target, baseline, and audit counts.
Error rates use calls with results; missing results remain visible.

Then calibrate each finding with
`../session-analytics/references/calibration.md` — confidence
(`<certain>`/`<speculative>`/`<don't know>`) × severity
(blocker/high/medium/low); `<don't know>` never surfaces.

Report format:

```
## Tool Efficiency Report: {TARGET}
### Summary        — target · harness · domains run · N surfaced / N below bar
### Recommendations — | # | Severity | Confidence | Domain | Issue | Recommendation |
### Detail         — per finding: What / Why (the metric) / How
### Below the Bar  — count only
```

Never: a 0-100 score; surfacing `<don't know>`; fabricating on empty domains;
applying fixes (recommend only — hand to /cure or /harness-doctor's
settings-prune mode).

Gotchas: `token-economics` usually lacks token fields — "insufficient
signal", never invent a cost. Denials/stop-hooks are Claude-dominant — on
codex/omp their absence is missing signal, not zero friction.
