---
name: tool-efficiency
model: opus
effort: high
description: >
  Audit how a tool, command, or MCP server is actually used across coding-agent
  sessions and produce calibrated recommendations — tool-vs-task fit, error
  forensics, permission friction, MCP health, and token economics. Use when the
  user says "tool efficiency", "am I using X efficiently", "audit tool usage",
  "why does X keep failing", "permission friction", "is this MCP worth it",
  "tool error rate", or invokes /tool-efficiency. Do NOT use for auditing a skill
  or agent definition (that is /skill-improver) or for one-off interactive log
  queries (that is /session-analytics).
allowed-tools: Read, Agent, Bash
---

# tool-efficiency

Audit how a tool / command / MCP server behaves in practice across sessions,
then produce calibrated recommendations. Judgment skill — it scores findings
with the shared confidence × severity model, it does not just report numbers.

## Input

A target: a tool name (`Bash`, `Read`, `Edit`), a command prefix (`git`,
`cargo`), or an MCP server (`serena`, `tilth`). If none given, ask. Optionally a
harness filter (`all` default, or `claude`/`codex`/`opencode`).

## Owned domains

This skill owns five analytics packs under `references/`:

| Domain | Pack | What it surfaces |
|--------|------|------------------|
| tool-usage | `tool-usage.md` | Frequency, project spread, tool-vs-task fit |
| error-forensics | `error-forensics.md` | Error rate vs baseline, recurring failures |
| permission-friction | `permission-friction.md` | Denials, allowlist gaps, compound-command friction |
| mcp-health | `mcp-health.md` | Per-MCP call volume, error rate, idle servers |
| token-economics | `token-economics.md` | Token/cost where logged — degrades to "insufficient signal" |

## Protocol

1. **Ingest** — `python3 ~/Dev/dotfiles/skills/session-analytics/scripts/ingest.py`
   (1-hour TTL, fast if cached). Best-effort; skip the analytics if it fails.
2. **Fan out** — spawn **one parallel `duckdb-expert` per relevant domain**
   (one-domain-per-spawn; never a single all-domains spawn):

   ```
   spawn duckdb-expert "Run analytics pack tool-efficiency/references/<domain>.md for target {TARGET}. harness={HARNESS}"
   ```

   Pick the domains that fit the target: MCP targets → `mcp-health` +
   `error-forensics`; a Bash command → `tool-usage` + `permission-friction` +
   `error-forensics`; broad audit → all five.
3. **Collect** the ~2 KB digests.
4. **Calibrate** each finding with the shared model in
   `../session-analytics/references/calibration.md` — confidence
   (`<certain>`/`<speculative>`/`<don't know>`) × severity
   (blocker/high/medium/low). `<don't know>` never surfaces.
5. **Report** (below).

## Report

```
## Tool Efficiency Report: {TARGET}

### Summary
- Target: <tool/command/MCP>  ·  Harness: <filter>
- Domains run: <list>
- Findings: N surfaced, N below the bar

### Recommendations (surfaced)
| # | Severity | Confidence | Domain | Issue | Recommendation |
|---|----------|------------|--------|-------|----------------|

### Detail
For each surfaced finding: What / Why (with the metric that evidences it) / How.

### Below the Bar
N findings were `<don't know>` or insufficient-signal (not shown).
```

## What this skill never does

- Score with a 0-100 number — it uses the shared qualitative model.
- Surface `<don't know>` findings or fabricate when a domain returns empty.
- Run more than one domain per `duckdb-expert` spawn.
- Modify tools, settings, or allowlists — it recommends; the human decides.

## Gotchas

- `token-economics` is `<don't know>` on most logs (no token fields) — say
  "insufficient signal", do not invent a cost.
- Permission denials and stop-hooks are claude-dominant; on codex/opencode treat
  their absence as missing signal, not as zero friction.
