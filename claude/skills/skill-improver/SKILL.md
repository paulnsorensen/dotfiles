---
name: skill-improver
description: >
  Audit and improve agent and skill definitions for better calibration, tool scoping,
  context management, and output quality. Use when the user says "improve this skill",
  "audit this agent", "optimize this agent", "review agent definition", or invokes
  /skill-improver with a path. Also trigger when creating new agents or skills that
  need quality review before deployment, or when an agent is producing poor results
  and needs prompt tuning. Covers: calibrated confidence scoring, tool allow/disallow
  scoping, sub-agent delegation patterns, fork vs inline decisions, context budgets,
  and output format standardization.
---

# skill-improver

Audit agent and skill definitions against best practices, then produce scored
improvement recommendations. This skill eats its own cooking — it uses the same
4-step calibrated confidence scoring it recommends for others.

## Why This Exists

LLM agent prompts have predictable failure modes: over-broad tool access causes
the model to waste time on irrelevant actions, unbounded output pollutes the
orchestrator's context window, and self-reported confidence scores are pattern
matching on rubric descriptions rather than calibrated probabilities.

This skill codifies what we've learned into a repeatable audit.

## Input

A path to an agent definition (`agents/*.md`) or skill definition (`skills/*/SKILL.md`).
If no path is given, ask.

## Protocol

### Phase 1: Read and Classify

1. Read the target file
2. Determine type: **agent** (has `tools:`/`disallowedTools:` frontmatter) or **skill** (has `name:`/`description:` in SKILL.md frontmatter)
3. Read any referenced files (sub-skills, reference docs) to understand the full picture

### Phase 2: Audit Against Dimensions

Evaluate the definition against each dimension below. For each finding, use the
4-step scoring process (Phase 3) before including it in the report.

#### Dimension 1 — Confidence Scoring

Agents that make judgments (review, triage, audit) need calibrated scoring.
The pattern that works:

**Step 1: Classify claim type** — Each category gets a base score and hard cap.
Category priors predict accuracy better than the model's self-assessed number.
Style nits cap at 60; bugs start at 50 and can reach 100.

**Step 2: Evidence grounding** — Modifiers based on verification quality.
LSP-verified (+20-25), grep-confirmed (+20), specific file:line (+15),
generic observation (-15), misread code (hard cap 0).

**Step 3: Context modifiers** — Signals that adjust severity. Git hotspot (+10),
pre-existing issue (-15), public API boundary (-10), review state (+10).

**Step 4: Re-assess borderline items** — Items near the surfacing threshold get
scored independently a second time. If scores diverge >15 points, the finding is
ambiguous — don't surface it. This catches false confidence from pattern matching.

Key insight: ordering between findings is more reliable than absolute magnitude.
"A is more important than B" is trustworthy. "A is exactly 82" is not.

Check: Does the agent have scoring? Does it use category priors? Does it ground
evidence? Does it re-assess borderline items? Is there a surfacing threshold?

Reference implementations:
- `claude/agents/fromage-age.md` — review findings
- `claude/agents/fromage-fort.md` — PR comment triage
- `claude/agents/ricotta-reducer.md` — simplification audit

#### Dimension 2 — Tool Scoping

Over-broad tool access degrades agent quality in two ways: the model wastes
tokens considering irrelevant tools, and it may take unintended actions.

**Three-tier model** — every agent should fall into one of these tiers:

| Tier | Tools | Use case | Frontmatter |
|------|-------|----------|-------------|
| Read-only | Grep, Glob, Read, Bash | Reviewers, auditors, explorers | `disallowedTools: [Edit, Write, NotebookEdit]` |
| Write-scoped | + Edit, Write | Implementers, fixers | Exclude tools not needed (WebSearch, LSP, etc.) |
| Focused sub-agent | 2-4 tools max | Pipeline sub-tasks | Disallow 5-8 unused tools explicitly |

Over-broad tool access degrades behavior in two ways: models waste tokens
considering irrelevant tools, and they're more likely to take irreversible
actions when stuck if write tools are available — even when a read-only path
exists. Prose constraints ("this is a read-only agent") are weaker than hard
`disallowedTools` blocks. If an agent says "read-only" in its body but doesn't
set `disallowedTools`, that's a finding.

**Skill access** (`skills: [...]`):
- Skills listed = skills the agent MUST use instead of raw equivalents
- Missing skill = the agent will fall back to bash/grep/manual approaches
- Over-listing = extra context in the prompt for unused capabilities

Check: Are tools appropriately constrained for the tier? Does the agent have
`disallowedTools` matching its stated role? Is anything listed that isn't used?
Is anything missing that the agent needs? Do skill delegations match the task?

#### Dimension 3 — Context Management

Every token in an agent's context competes with the task at hand. Agents that
produce or consume too much context degrade their own performance and their
orchestrator's.

**Fork vs inline** — fork (sub-agent) when:
- Output would exceed ~500 lines (build logs, full test runs, large diffs)
- Only a summary is needed by the caller, not the raw content
- The task is independent and idempotent (can be re-run if it fails)

Run inline when the result is concise, immediately needed, and action-relevant.

**Sub-agent delegation** — agents that need to choose between strategies
(research from multiple sources, review from multiple angles) should spawn
parallel sub-agents rather than sequentially trying each approach. The research
agent pattern: spawn N focused sub-agents, synthesize results.

**Context degradation thresholds** (from LLM research):

| Context size | Observed behavior |
|---|---|
| < 20K tokens | Strong instruction following, full recall |
| 20K–60K tokens | Moderate degradation, especially mid-context instructions |
| 60K–100K tokens | Noticeable instruction drift, increased repetition |
| > 100K tokens | Models increasingly ignore early system prompt instructions |

**Output budgets**:
- Agent prompt definition: aim for <500 lines (~1500 tokens). Beyond that, use
  reference files read on demand (progressive disclosure).
- Agent working context: budget 20K–40K tokens for active work.
- Agent output to orchestrator: <2K chars for summaries. Write detailed reports
  to temp files (`$TMPDIR/`), return a pointer.
- Inline skill output: should fit in the conversation without scrolling.

**Model selection** — document rationale in the agent, not just the choice:
- `opus` — judgment-heavy tasks (review, architecture, complex reasoning)
- `sonnet` — implementation, exploration, most general-purpose work
- `haiku` — focused fetch tasks, simple transforms, token-constrained sub-agents

Check: Does the agent manage its output size? Should it fork? Does it use
sub-agents where parallel work would help? Is the model appropriate and
documented? Is the prompt file under 500 lines? Does the agent have a wrap-up
signal to prevent runaway execution (e.g., "after ~60 tool calls, wrap up")?

#### Dimension 4 — Prompt Quality

**Structure**: Structured prompts (sections, tables, explicit rules) outperform
freeform prose for instruction following. But structure has diminishing returns —
a 50-row table of rules gets skimmed the same way a wall of text does.

**Why over what**: Explaining *why* a rule exists makes the model better at
edge cases. "Never use `find`" is brittle. "Use `fd` instead of `find` because
fd respects .gitignore and is faster on large repos" transfers to novel situations.

**Examples**: One good example is worth ten rules. Two examples establish a
pattern. Three confirm it. More than three for the same concept is diminishing
returns.

**Role framing**: A single opening sentence that establishes the agent's identity
and purpose ("You are the Age phase — long maturation where cheese develops
complex character") is more effective than a paragraph of role description.

**Negative constraints** ("What You Don't Do"): Explicit sections listing what
the agent must NOT do significantly reduce scope creep and overlap with adjacent
pipeline phases. Every pipeline agent should have one. Example from fromage-cook:
"Make design decisions... Add tests... Review code quality" — all belong to
other phases.

Check: Is the prompt well-structured? Does it explain why? Are there examples?
Is the role framing concise? Are there walls of text that could be tables?
Does the agent have an explicit "What You Don't Do" section?

#### Dimension 5 — Output Format

Agents that produce reports need standardized, scannable output. The patterns
that work:

- **Summary first**: one-sentence assessment, then details
- **Tables for findings**: score, category, location, issue, fix — scannable in
  under 2 minutes
- **Below-threshold count**: "N findings scored < 75 (not shown)" — tells the
  reader you looked but filtered
- **Temp file for details**: full report to `$TMPDIR/`, summary to orchestrator

Check: Is the output format defined? Is it scannable? Does it separate summary
from detail? Is there a clear "clean" vs "issues found" signal?

### Phase 3: Score Each Finding (4-Step Calibration)

For each improvement recommendation, apply the same 4-step scoring this skill
recommends for others. Walk the walk.

#### Step 1: Classify the recommendation type

| Type | Description | Base score | Cap |
|------|-------------|------------|-----|
| `SCORING` | Missing or miscalibrated confidence scoring | 45 | 100 |
| `TOOLS` | Tool access too broad or too narrow | 40 | 90 |
| `CONTEXT` | Context pollution, missing fork/delegation, wrong model | 40 | 95 |
| `PROMPT` | Ambiguous instructions, missing examples, wall of text | 35 | 85 |
| `OUTPUT` | Missing or unclear output format | 30 | 80 |

#### Step 2: Evidence grounding

| Evidence quality | Modifier |
|------------------|----------|
| Cites specific line in the definition + concrete failure scenario | +20 |
| Names a reference implementation that does it right | +15 |
| References a CLAUDE.md rule or established pattern | +10 |
| Generic observation without specific reference | -10 |
| Misreads the definition or overlooks existing handling | hard cap at 0 |

#### Step 3: Context modifiers

| Signal | Modifier |
|--------|----------|
| Agent is judgment-heavy (review, triage, audit) and lacks scoring | +15 |
| Agent produces unbounded output with no size constraint | +10 |
| Agent is a focused sub-agent (context management less critical) | -10 |
| Issue is stylistic preference rather than functional impact | -15 |

#### Step 4: Re-assess borderline recommendations

For any recommendation scoring 65-79: re-read the full definition file, then
score independently a second time without looking at your first score. If the
two scores diverge by >15 points, don't surface — the recommendation is
ambiguous. If both scores land >= 75, surface it.

### Phase 4: Report

```
## Skill Improvement Report: <name>

### Summary
- Type: agent | skill
- Model: <model>
- Tools: <N allowed, N disallowed>
- Prompt size: <N lines>
- Findings: N total (N scored >= 75, N below threshold)

### Recommendations (score >= 75)

| # | Score | Category | Issue | Recommendation |
|---|-------|----------|-------|----------------|
| 1 | 95 | SCORING | No confidence scoring on judgment agent | Add 4-step calibration (see fromage-age pattern) |
| 2 | 85 | TOOLS | Edit/Write allowed on read-only reviewer | Add to disallowedTools |
| 3 | 80 | CONTEXT | Unbounded output, no summary/detail split | Write details to $TMPDIR, return summary |

### Detailed Recommendations

For each finding >= 75, expand with:
- **What**: the specific issue
- **Why**: why it matters (with reference to a pattern or principle)
- **How**: concrete fix, ideally with the exact frontmatter or section to add/change
- **Reference**: link to an agent/skill that does it right

### Below Threshold
N findings scored < 75 (not shown)
```

## Anti-Patterns to Check

These are the most common issues across agent/skill definitions, ordered by
how often they appear and how much impact they have:

1. **Judgment without scoring** — Agent makes pass/fail decisions but has no
   confidence framework. Every reviewer, auditor, and triage agent needs the
   4-step calibration.

2. **Prose-only tool constraints** — Agent says "read-only" in its body but
   doesn't set `disallowedTools: [Edit, Write, NotebookEdit]` in frontmatter.
   Prose constraints are weaker than hard blocks — models with write tools
   available are more likely to take irreversible actions when stuck.

3. **Unbounded tool access** — Agent has all tools available when it only needs
   3-4. Especially common in agents cloned from a general-purpose template.

4. **Monolithic output** — Agent dumps everything into the conversation instead
   of writing details to a temp file and returning a summary. Pollutes the
   orchestrator's context window.

5. **Missing model directive** — No `model:` in frontmatter. Defaults to
   whatever the parent uses, which may be wrong (opus for a haiku-appropriate
   fetch task, or haiku for a judgment-heavy review).

6. **No output format** — Agent has no defined output structure. Results vary
   wildly between invocations. Structured output (tables) reduces unverifiable
   claims because you need a `file:line` to fill the cell.

7. **No "What You Don't Do" section** — Pipeline agents without explicit
   negative constraints have the most scope-creep and overlap risk with
   adjacent phases.

8. **No wrap-up signal** — Long-running agents without a tool-call limit
   (e.g., "after ~60 tool calls, wrap up") can run indefinitely, consuming
   context until performance degrades.

9. **Freeform instructions** — Wall of prose instead of structured sections with
   tables. The model skims long paragraphs the same way humans do.

10. **Missing "why"** — Rules without rationale. "Never use grep" without
    explaining that scout provides better alternatives. Why-based instructions
    transfer to edge cases; bare rules don't.

11. **Over-specified role** — Three paragraphs of character description before
    getting to the actual task. One sentence is enough.

## What This Skill Never Does

- Rewrite the agent/skill — it produces a report, the human decides
- Add features or expand scope — it only recommends tightening
- Score below 75 — unsure recommendations stay below the threshold
- Ignore its own scoring rules — it uses the same 4-step process it audits for
