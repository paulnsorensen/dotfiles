---
name: skill-improver
model: opus
effort: high
description: >
  Audit and improve an existing agent or skill definition. Use when the user says
  "improve this skill", "audit this agent", "optimize this agent", "review agent
  definition", "fix trigger rate", "skill not activating", or invokes /skill-improver
  with a path; also when an agent produces poor results and needs prompt tuning, or a
  skill isn't triggering reliably. Do NOT use for creating new skills from scratch —
  use /skill-creator for that.
allowed-tools: Read, Glob, Grep, Agent, Bash
---

# skill-improver

Audit an agent or skill definition, then emit a calibrated improvement report.
This skill eats its own cooking — it audits against the same framework it embodies
and calibrates its own findings the way it tells others to.

**Predictability is the root virtue.** A good skill drives the agent through the
same *process* every run (not the same output). Every lens below serves it: the
audit asks, for each part of the target, *does this make the skill more
predictable, or is it sediment?* Framework vocabulary (**leading words** in bold)
comes from the skill-authoring consensus — Anthropic's progressive-disclosure
model, Matt Pocock's `writing-great-skills`, and Jesse Vincent's `writing-skills`.

## Input

A path to an agent definition (`agents/*.md`) or a skill (`skills/*/SKILL.md`).
If none is given, ask. Runs inline at opus tier (set in frontmatter).

## Protocol

### Phase 1 — Read & classify

Read the target and any files it points at. Classify: **agent** (has
`tools:`/`disallowedTools:`) or **skill** (`name:`/`description:` frontmatter).

### Phase 2 — Analytics (optional branch)

Empirical usage data, best-effort — skip if the DB or logs are absent and note the
dropped Usage lens in the report. Never block the audit on it.

1. `python3 ~/Dev/dotfiles/skills/session-analytics/scripts/ingest.py`
2. Fan out **one `duckdb-expert` spawn per owned domain** (read-only) — this skill
   owns three packs under `references/`. Each spawn: *"Run analytics pack
   skill-improver/references/<pack>.md for target {name}. harness=all"* and returns
   one ~2 KB digest. Do not collapse to a single all-domains spawn.

   | Pack | Reveals |
   |------|---------|
   | `skill-usage` | invocations, declared-vs-actual tool use, permission friction |
   | `agent-orchestration` | undeclared spawns, fork behavior, error rate |
   | `drift-regression` | declining usage, single-project concentration, hook interruptions |

3. Carry the digests into the **Usage** lens below. If ingestion fails, drop that
   lens and note it in the report.

### Phase 3 — Audit against the rubric

Score the target against each lens. Each lens states its principle, the **failure
mode** it catches, and a checkable test. Detail and before/after examples live in
`references/anti-patterns.md` (read it when a finding needs the expanded form).

| Lens | Principle → catches | Check |
|------|--------------------|-------|
| **Predictability** | Fixed protocol with checkable completion criteria → «premature completion» | Every step ends on a done-condition an agent can verify. No "produce a change list" vagueness. |
| **Invocation** | `description` = trigger conditions only, front-loaded, third person → «description-as-workflow-summary», «summary description» | Description lists trigger phrases + a "Do NOT use for", and states no internal workflow (a workflow summary makes agents skip the body — Vincent, A/B-tested). Model-invocation earns its always-on context load. |
| **Information hierarchy** | Progressive disclosure is a *branch* test — inline what every run needs, disclose only what some runs reach; body < 500 lines → «sprawl», «@-link force-load» | Relocating a block saves context only if runs branch on it (an every-run block relocated just adds navigation). Cross-reference skills by name, never `@file` (force-loads immediately). |
| **Leading words** | Anchor behavior with compact pretrained concepts → «duplication», «no-op weak word» | A triad spelled at three sites or "fast, deterministic, low-overhead" collapses into one word. Strengthen weak words (`be thorough` → `relentless`), don't restate. |
| **Pruning** | Single source of truth; every line still relevant; delete no-ops → «sediment», «no-op» | No meaning lives in two places. No line the model already obeys by default. Delete whole sentences that fail the no-op test, don't trim them. |
| **Tool scoping** | Three-tier (read-only / write-scoped / focused); hard `disallowedTools`, not prose → «prose-only tool constraints», «unbounded tool access» | Tools match the tier. A "read-only" claim in prose is backed by `disallowedTools: [Edit, Write, NotebookEdit]`. Nothing listed that's unused. |
| **Context & fork** | Fork when output > ~500 lines or only a summary is needed; inline when concise → «monolithic output» | Output is bounded; fork/inline matches size; there's a wrap-up signal. `model:` is set *and* justified. |
| **Prompt quality** | Positive framing, why-over-what, one strong example, explicit "What You Don't Do" → «negation-heavy rules», «rules without reasons», «scope creep» | Rules state the desired behavior (not only "never X"); each earns a why; pipeline agents carry a "What You Don't Do"; ≤ 3 examples per concept. Judgment tasks use a scaffold, not rigid always/never (`references/decision-frameworks.md`). |
| **Calibration** | Judgment agents (review/triage/audit) tag findings confidence × severity → «judgment without calibration» | Separates confidence from severity; uses `<certain>`/`<speculative>`/`<don't know>`, not an invented number; don't-know never surfaces. (Model imported — see References.) |
| **Output format** | Scannable: summary first, tables for findings, below-bar count → «no output format» | Format is defined; summary and detail are split; there's a clear clean-vs-issues signal. |
| **Usage** *(if analytics ran)* | Actual behavior matches declarations → «declared-vs-actual mismatch», «decay» | Declared tools are the used tools; error rate near baseline; usage healthy, not declining. |

### Phase 4 — Calibrate each finding

Assign confidence × severity — the same model this skill audits for. The full
kernel is imported (see References); the working defaults:

- **Severity by lens** — Predictability, Invocation, Tool scoping, Calibration →
  `high`; Information hierarchy, Context & fork, Pruning → `high`/`medium`;
  Leading words, Output format, Usage → `medium`. Adjust for the case: raise for a
  judgment-heavy agent lacking calibration or unbounded output; lower for a focused
  sub-agent or a pure style nit.
- **Confidence by evidence** — cites a specific line + concrete failure, or a
  reference impl that does it right, or analytics data → `<certain>`; a checkable
  but unverified observation → `<speculative>`; a misread or unverifiable claim →
  `<don't know>`, dropped.
- **Surfacing** — surface only `<certain>` or `<speculative>`. For each
  `<speculative>`, re-read the target and re-derive once *without* looking at the
  first pass; if it doesn't reproduce, drop to `<don't know>`. Order by severity
  (blocker → low); within a tier, `<certain>` first.

### Phase 5 — Report

```
## Skill Improvement Report: <name>

### Summary
- Type: agent | skill · Model: <model> · Tools: <N allowed, N disallowed> · Size: <N lines>
- Findings: N total (N surfaced, N below the bar / don't-know)

### Recommendations (surfaced)

| # | Severity | Confidence | Lens | Issue | Fix |
|---|----------|------------|------|-------|-----|
| 1 | blocker | `<certain>` | Calibration | No confidence tags on a judgment agent | Add confidence × severity (see /age) |
| 2 | high | `<certain>` | Invocation | Description summarizes the workflow | Cut to triggers-only |

### Detailed recommendations
Per surfaced finding: **What** (the issue) · **Why** (the principle it violates) ·
**How** (exact frontmatter/section to change) · **Reference** (a def that does it right).

### Recommended hooks (if applicable)
Only for findings where enforcement must hold 100% of the time — pick from
`references/hooks-catalog.md`. Omit the section if none apply.

### Below the bar
N findings were `<don't know>` or speculative-trivial (not shown).
```

After the report: if the audit found activation/trigger issues, suggest
`/skill-creator` to generate eval queries and measure trigger rate before/after —
static audit finds problems; eval-driven iteration validates the fix.

## What this skill never does

- Rewrite the target — it reports; the human decides.
- Expand scope — it only recommends tightening.
- Surface unknowns — `<don't know>` stays in the below-bar count.
- Exempt itself — it passes its own rubric or files the finding against itself.

## Gotchas

- Generic findings on simple skills — every finding must cite a specific line or
  named pattern, not "could be improved".
- Over-indexes on missing `disallowedTools` even when the platform default already
  constrains the tool list.
- The `<speculative>` re-derivation (Phase 4) is the first step skipped under time
  pressure — and the one that catches the most false positives.
- Not every finding needs a hook — recommend one only for a rule that must hold
  every time.
- Progressive disclosure saves context only for *branchy* runs. Relocating content
  an every-run path reads just moves the sprawl and adds navigation cost — prune it
  instead. This skill's own body is the worked example.

## References

Read on demand, when a lens fires:

- `../session-analytics/references/calibration.md` — the confidence × severity
  kernel (imported single source of truth, not redefined here).
- `references/anti-patterns.md` — expanded failure-mode catalog + diagnostic checklist.
- `references/description-optimization.md` — trigger optimization, before/after.
- `references/decision-frameworks.md` — reasoning scaffolds, degrees of freedom.
- `references/hooks-catalog.md` — companion hooks for enforcement findings.
- `references/skill-usage.md`, `references/agent-orchestration.md`,
  `references/drift-regression.md` — the analytics packs (Phase 2).
