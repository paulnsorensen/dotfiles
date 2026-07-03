---
name: skill-improver
model: opus
effort: high
description: >
  Audit and improve agent and skill definitions — calibration, tool scoping,
  context budget, activation quality, and output format. Use when the user says
  "improve this skill", "audit this agent", "optimize this agent", "review agent
  definition", "fix trigger rate", "skill not activating", or invokes /skill-improver
  with a path. Also trigger when an agent is producing poor results and needs prompt
  tuning, or when a skill isn't triggering reliably. Covers: confidence and severity
  calibration, tool scoping, sub-agent delegation, fork vs inline, context budgets,
  and activation optimization. Do NOT use for creating new skills from scratch —
  use /skill-creator for that.
allowed-tools: Read, Glob, Grep, Agent, Bash
---

# skill-improver

Audit agent and skill definitions against best practices, then produce
calibrated improvement recommendations. This skill eats its own cooking — it
uses the same confidence/severity calibration it recommends for others.

## Why This Exists

LLM agent prompts have predictable failure modes: over-broad tool access causes
the model to waste time on irrelevant actions, unbounded output pollutes the
orchestrator's context window, and self-reported confidence scores are pattern
matching on rubric descriptions rather than calibrated probabilities.

This skill codifies what we've learned into a repeatable audit.

## Input

A path to an agent definition (`agents/*.md`) or skill definition (`skills/*/SKILL.md`).
If no path is given, ask.

This skill runs inline (no `context: fork`) at opus tier — set explicitly in frontmatter.

## Protocol

### Phase 1: Read and Classify

1. Read the target file
2. Determine type: **agent** (has `tools:`/`disallowedTools:` frontmatter) or **skill** (has `name:`/`description:` in SKILL.md frontmatter)
3. Read any referenced files (sub-skills, reference docs) to understand the full picture

### Phase 1.5: Gather Usage Analytics

Before auditing, gather empirical data from session logs. This step is
**best-effort** — skip if the database doesn't exist or queries return empty.

1. Run ingestion to ensure fresh data:

   ```bash
   python3 ~/Dev/dotfiles/skills/session-analytics/scripts/ingest.py
   ```

2. Fan out **one parallel `duckdb-expert` spawn per owned domain** (read-only) —
   this skill owns three domain packs co-located under its own `references/`:

   | Domain pack | Spawn prompt |
   |-------------|--------------|
   | `skill-usage` | "Run analytics pack skill-improver/references/skill-usage.md for target {name}. harness=all" |
   | `agent-orchestration` | "Run analytics pack skill-improver/references/agent-orchestration.md for target {name}. harness=all" |
   | `drift-regression` | "Run analytics pack skill-improver/references/drift-regression.md for target {name}. harness=all" |

   Each spawn reads its pack's queries plus the canonical schema from
   `session-analytics/references/canonical-schema.md`, and returns one ~2 KB
   digest. This is the platform's one-domain-per-spawn contract — do not collapse
   to a single all-domains spawn.

3. Collect the three digests for use in Dimension 7.

If ingestion fails (duckdb not installed, no JSONL logs), skip to Phase 2 and
omit Dimension 7 from the report. Never block the audit on analytics.

### Phase 2: Audit Against Dimensions

Evaluate the definition against each dimension below. For each finding, use the
calibration process (Phase 3) before including it in the report.

#### Dimension 1 — Confidence & Severity Calibration

Agents that make judgments (review, triage, audit) need calibrated findings —
but on two qualitative axes, not one number. LLM absolute numeric self-scores
are poorly calibrated (models anchor to round numbers and conflate "important"
with "certain"); relative/qualitative judgments track human assessment far
better, so rank and tag rather than score.

**Confidence** — how sure you are the finding is real. Tag each one:
`<certain>` (verified by reading the code, running it, or citing a source),
`<speculative>` (pattern-match or inference — surface it, but say so),
`<don't know>` (can't tell — do NOT surface; drop or raise as an open question).
Evidence drives the tag: tool-verified / specific file:line + concrete failure →
`<certain>`; generic observation → `<speculative>`; misread or unverifiable →
`<don't know>`.

**Severity** — how much it matters if real: `blocker` (broken as written) /
`high` / `medium` / `low` (style, polish). Orthogonal to confidence: a
`<certain>` style nit is low; a `<speculative>` correctness risk can be high.

**Re-assess borderline** — for any `<speculative>` finding you're about to
surface, re-derive the reasoning once more without looking at the first pass.
If it doesn't reproduce, drop to `<don't know>`. Never average two divergent
reads into a vague "maybe" — divergence means you don't actually know.

Key insight: tiers and tags are more reliable than absolute magnitude.
"A is more severe than B" and "certain vs speculative" are trustworthy.
"A is exactly 82" is invented precision.

Check: Does the agent separate confidence from severity? Does it use the
`<certain>`/`<speculative>`/`<don't know>` tags instead of an invented number?
Does it ground evidence? Does it re-assess borderline items? Is the surfacing
rule clear (don't-know never surfaces)?

Reference implementations:

- `/age` — severity tiers (Blocker/High/Medium/Low) with per-finding confidence
- age voice kernel — `certain | speculative | don't know`

#### Dimension 2 — Tool Scoping

**Three-tier model** — every agent should fall into one of these tiers:

| Tier | Tools | Use case | Frontmatter |
|------|-------|----------|-------------|
| Read-only | Grep, Glob, Read, Bash | Reviewers, auditors, explorers | `disallowedTools: [Edit, Write, NotebookEdit]` |
| Write-scoped | + Edit, Write | Implementers, fixers | Exclude tools not needed (WebSearch, mcp__serena__*, etc.) |
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

**Context degradation** — performance drops as context grows, and information
buried mid-context suffers most (primacy/recency bias). This is well-established
directionally (Lost in the Middle, RULER, NoLiMa); the token buckets below are
illustrative rules of thumb, not measured thresholds:

| Context size | Rule-of-thumb behavior |
|---|---|
| < 20K tokens | Strong instruction following, full recall |
| 20K–60K tokens | Moderate degradation, especially mid-context instructions |
| 60K–100K tokens | Noticeable instruction drift, increased repetition |
| > 100K tokens | Early system-prompt instructions increasingly ignored |

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

**Frontmatter controls** (skills only):

- `context: fork` — runs the skill in an isolated subagent context. Use when
  the skill reads 30+ files, produces verbose reports, or needs isolated context.
  Do NOT use on guideline-only skills (no task = subagent returns nothing useful).
- `allowed-tools` — restricts tools to only what the skill needs. Same
  principle as agent tool scoping but via frontmatter.

Check: Does the agent manage its output size? Should it fork? Does it use
sub-agents where parallel work would help? Is the model appropriate and
documented? Is the prompt file under 500 lines? Does the agent have a wrap-up
signal to prevent runaway execution (e.g., "after ~60 tool calls, wrap up")?
For skills: is `context: fork` appropriate? Are `allowed-tools` constrained?

#### Dimension 4 — Prompt Quality

**Structure**: Structured prompts (sections, tables, explicit rules) outperform
freeform prose for instruction following. But structure has diminishing returns —
a 50-row table of rules gets skimmed the same way a wall of text does.

**Why over what**: Explaining *why* a rule exists makes the model better at
edge cases. "Never use `find`" is brittle. "Use `fd` instead of `find` because
fd respects .gitignore and is faster on large repos" transfers to novel situations.

**Positive over negative framing**: "Use named exports" beats "Don't use default
exports." LLMs struggle with negation, so positive framing materially reduces
rule violations (magnitude varies by model and rule; Anthropic's prompting
guidance recommends stating the desired behavior). Flag rules that rely heavily
on "don't", "never", "avoid" without providing the positive alternative.

**Examples**: One good example is worth ten rules. Two examples establish a
pattern. Three confirm it. More than three for the same concept is diminishing
returns.

**Role framing**: A single opening sentence that establishes the agent's identity
and purpose ("You are the Age phase — long maturation where cheese develops
complex character") is more effective than a paragraph of role description.

**Negative constraints** ("What You Don't Do"): Explicit sections listing what
the agent must NOT do significantly reduce scope creep and overlap with adjacent
pipeline phases. Every pipeline agent should have one. Example: an implementation
agent's "What You Don't Do" might list "Make design decisions... Add tests...
Review code quality" — all belong to other phases.

**Decision scaffolds for judgment tasks**: Skills that use "always/never" for
judgment tasks should use a structured reasoning scaffold (Classify → Ground → Context → Reassess) or
degrees-of-freedom patterns instead. Match constraint level to risk: high
freedom for low-risk, exact steps for fragile operations.
See `references/decision-frameworks.md` for the full pattern catalog.

**Gotchas section**: Every skill should capture known failure modes. These are
the highest-value content per token — they directly prevent repeated failures.

Check: Is the prompt well-structured? Does it explain why? Are there examples?
Is the role framing concise? Are there walls of text that could be tables?
Does the agent have an explicit "What You Don't Do" section? Does it have a
Gotchas section? Do judgment tasks use decision scaffolds instead of rigid rules?
Does the skill's workflow align with a recognized pattern (sequential workflow,
iterative refinement, context-aware tool selection, or domain-specific intelligence)?

#### Dimension 5 — Output Format

Agents that produce reports need standardized, scannable output. The patterns
that work:

- **Summary first**: one-sentence assessment, then details
- **Tables for findings**: score, category, location, issue, fix — scannable in
  under 2 minutes
- **Below-threshold count**: "N findings scored < 50 (not shown)" — tells the
  reader you looked but filtered
- **Temp file for details**: full report to `$TMPDIR/`, summary to orchestrator

Check: Is the output format defined? Is it scannable? Does it separate summary
from detail? Is there a clear "clean" vs "issues found" signal?

#### Dimension 6 — Activation & Triggering (skills only)

Skills have an undertriggering problem — they often fail to activate when they
should. Community testing reports baseline auto-activation rates that vary widely
(roughly 20–55% depending on description quality and environment; not an official
Anthropic figure). The `description` field is not a summary for humans; it's a
trigger specification for the model's routing decision.

**Description structure** — effective descriptions follow a three-part pattern:
`[Core capability]. [Secondary capabilities]. Use when [trigger1], [trigger2],
or when user mentions "[keyword1]", "[keyword2]".`

Check for:

- **Trigger phrases**: Does the description list specific user phrases that
  should activate it? ("improve this skill", "audit this agent", etc.)
- **Pushy enough**: Anthropic recommends descriptions be assertive to combat
  undertriggering. Passive descriptions ("A tool for X") underperform active
  ones ("Use this when X, Y, or Z").
- **Third-person voice**: Descriptions are injected into the system prompt.
  First-person ("I analyze...") breaks the framing.
- **Negative triggers**: For skills with adjacent domains, explicit "Do NOT
  use for X" prevents false activations.
- **Keyword coverage**: Does the description mention all reasonable phrasings
  a user might try? Missing synonyms = missed activations.

**Frontmatter fields** — check for appropriate use of:

- `context: fork` — runs in isolated subagent context. Use when the skill
  reads 30+ files or produces verbose reports. Skills with only guidelines
  (no task) should NOT fork — the subagent gets no actionable prompt.
- `agent` — specifies subagent type when `context: fork` is set (Explore,
  Plan, general-purpose, or custom). Should match the skill's workload.
- `allowed-tools` — restricts which tools the skill can use. Grants access
  without per-use approval. Use to constrain skills to their actual needs.
- `disable-model-invocation: true` — requires explicit `/skill-name` to trigger.
  Appropriate for destructive or infrequently-needed skills.
- `effort` — overrides model effort level (low/medium/high). Use `effort: high`
  for research-heavy skills, `effort: low` for simple formatting tasks. Supported
  for both skills and subagents (per code.claude.com/docs).
- `user-invocable: false` — hides from `/` menu. Use for background knowledge
  Claude should know but users shouldn't invoke directly.

Check: Is the description a trigger spec or just a summary? Does it list
trigger phrases? Is it pushy enough? Are frontmatter fields appropriate?
Would `/skill-creator` description optimization improve trigger rate?

#### Dimension 7 — Usage Analytics (data-driven)

Static analysis reveals what the definition *says*. Usage analytics reveals what
*actually happens* when the skill runs. This dimension reads the three fanned-out
digests from Phase 1.5 (`skill-usage`, `agent-orchestration`, `drift-regression`).
Skip entirely if analytics data was unavailable.

**What to look for:**

- **Zero or low invocations** — Skill exists but isn't used. Cross-reference
  with Dimension 6 (activation). A well-described skill with zero invocations
  is a stronger signal than a poorly-described one with zero invocations.

- **Declared-vs-actual tool mismatch** — `allowed-tools` lists Read but the
  skill never reads files in practice. Or the skill triggers Bash calls that
  aren't in `allowed-tools`. Mismatches reveal stale declarations or missing
  permissions.

- **Undeclared agent spawns** — Skill spawns agent types it doesn't document.
  Either the agent spawns are intentional (add them to docs) or unintended
  (scope creep from the model).

- **High error rate vs baseline** — If tools error >2x the baseline rate during
  skill windows, the skill is fighting the environment. Common causes: wrong
  tool for the job, missing permissions, stale file paths.

- **Permission friction** — Repeated denials in skill windows mean the skill
  triggers tools not in the user's allowlist. Either add to allowlist docs
  or change the skill's approach.

- **Hook interruptions** — Stop hooks blocking continuation during skill
  execution reveal conflicts between the skill's behavior and the user's
  guard rails.

- **Declining usage** — Skill was active, now rarely used. Something changed —
  a better alternative, workflow shift, or the problem it solved was fixed.
  Worth flagging for the user to decide if the skill should be retired.

- **Single-project concentration** — Skill used in only one project may be
  too specialized for its current scope, or could be generalized.

Check: Does actual tool usage match declarations? Is the error rate elevated?
Are there permission or hook conflicts? Is usage healthy or declining?

### Phase 3: Calibrate Each Finding (confidence × severity)

For each recommendation, assign a confidence tag and a severity tier — the same
calibration this skill recommends for others. Walk the walk.

#### Step 1: Default severity by type

Each category has a default severity tier; adjust for the specific case.

| Type | Description | Default severity |
|------|-------------|------------------|
| `SCORING` | Missing or miscalibrated confidence/severity calibration | high |
| `TOOLS` | Tool access too broad or too narrow | high |
| `CONTEXT` | Context pollution, missing fork/delegation, wrong model | high |
| `PROMPT` | Ambiguous instructions, missing examples, wall of text | medium |
| `OUTPUT` | Missing or unclear output format | medium |
| `ACTIVATION` | Poor description, missing triggers, wrong frontmatter fields | high |
| `ENFORCEMENT` | Critical rule as instruction-only, missing companion hooks | high |
| `ANALYTICS` | Usage data contradicts definition (tool mismatch, friction, decay) | medium |

#### Step 2: Confidence by evidence

| Evidence quality | Confidence |
|------------------|------------|
| Cites a specific line + concrete failure, or backed by analytics data, or names a reference impl that does it right | `<certain>` |
| References a CLAUDE.md rule / pattern, or a checkable but unverified observation | `<speculative>` (raise once verified) |
| Generic observation with no specific reference | `<speculative>` at most |
| Misreads the definition or overlooks existing handling | `<don't know>` — drop it |

#### Step 3: Adjust severity for context

| Signal | Effect |
|--------|--------|
| Agent is judgment-heavy (review, triage, audit) and lacks calibration | raise |
| Agent produces unbounded output with no size constraint | raise |
| Agent is a focused sub-agent (context management less critical) | lower |
| Issue is stylistic preference rather than functional impact | lower (often to low) |

#### Step 4: Surfacing rule

Surface a finding only if it is `<certain>` or `<speculative>`. For each
`<speculative>` finding, re-read the full definition file and re-derive the
reasoning once without looking at your first pass; if it doesn't reproduce, drop
it to `<don't know>`. `<don't know>` findings never surface — count them in the
below-bar tally. Order the report by severity (blocker → low); within a tier,
`<certain>` before `<speculative>`.

### Phase 4: Report

```
## Skill Improvement Report: <name>

### Summary
- Type: agent | skill
- Model: <model>
- Tools: <N allowed, N disallowed>
- Prompt size: <N lines>
- Findings: N total (N surfaced, N below the bar / don't-know)

### Recommendations (surfaced)

| # | Severity | Confidence | Category | Issue | Recommendation |
|---|----------|------------|----------|-------|----------------|
| 1 | blocker | `<certain>` | SCORING | No confidence calibration on judgment agent | Add confidence/severity tags (see /age pattern) |
| 2 | high | `<certain>` | TOOLS | Edit/Write allowed on read-only reviewer | Add to disallowedTools |
| 3 | high | `<speculative>` | CONTEXT | Unbounded output, no summary/detail split | Write details to $TMPDIR, return summary |

### Detailed Recommendations

For each surfaced finding, expand with:
- **What**: the specific issue
- **Why**: why it matters (with reference to a pattern or principle)
- **How**: concrete fix, ideally with the exact frontmatter or section to add/change
- **Reference**: link to an agent/skill that does it right

### Recommended Hooks (if applicable)

For findings where enforcement matters more than guidance, suggest a companion
hook from `references/hooks-catalog.md`:

| Finding # | Hook Type | What It Enforces |
|-----------|-----------|-----------------|
| (only include findings where a hook would help — not every finding needs one) |

If no findings warrant hooks, omit this section.

### Below the Bar
N findings were `<don't know>` or speculative-trivial (not shown)
```

### After the Report

If the audit reveals activation or trigger issues, suggest the user run
`/skill-creator` to generate eval queries and measure trigger rate before/after
applying changes. Static audit identifies problems; eval-driven iteration
validates fixes.

## Anti-Patterns to Check

These are the most common issues across agent/skill definitions, ordered by
how often they appear and how much impact they have:

1. **Judgment without calibration** — Agent makes pass/fail decisions but has no
   confidence/severity framework. Every reviewer, auditor, and triage agent needs
   confidence tags (`<certain>`/`<speculative>`/`<don't know>`) plus severity tiers.

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

9. **PR skills without health checks** — Skills that respond to PR review
   comments but don't check CI status or merge conflicts first. Build failures
   and merge conflicts should be fixed before processing review comments —
   comments may be moot if the build is broken. Reference: `/respond` checks
   `get_check_runs` and `mergeable_state` in Phase 0.

The remaining anti-patterns (freeform instructions, missing "why", over-specified
role, passive descriptions, negation-heavy rules, critical-rule-as-instruction-only,
always/never for judgment, missing Gotchas) are lower-frequency and covered by
the dimension audit sections above.

## Reference Files

Read these before making changes to the relevant dimension:

- `../session-analytics/references/calibration.md` — the shared confidence ×
  severity model (imported, not redefined here)
- `references/skill-usage.md`, `references/agent-orchestration.md`,
  `references/drift-regression.md` — this skill's owned analytics packs (Phase 1.5)
- `references/description-optimization.md` — Trigger optimization with before/after examples
- `references/decision-frameworks.md` — Structured reasoning scaffold, degrees of freedom, example-driven spec
- `references/hooks-catalog.md` — JS hook examples for activation, validation, enforcement

## What This Skill Never Does

- Rewrite the agent/skill — it produces a report, the human decides
- Add features or expand scope — it only recommends tightening
- Surface unknowns — `<don't know>` recommendations stay in the below-bar count
- Ignore its own calibration — it uses the same confidence/severity model it audits for

## Gotchas

- Tends to produce generic findings on simple skills — every finding must cite a
  specific line or pattern, not just "could be improved"
- Over-indexes on missing `disallowedTools` even when the agent's tool list is
  naturally constrained by platform defaults
- Step 4 (borderline re-assessment) is the step most likely to get skipped under
  time pressure — it's also the step that catches the most false positives
- Not every finding needs a companion hook — only recommend hooks for rules that
  must hold 100% of the time
- Description tuning helps trigger rate but plateaus well short of reliable; for
  critical skills, pair it with a companion hook. (Reported figures — e.g. ~50%
  from tuning vs higher with a forced-eval hook — come from small community tests,
  not an Anthropic benchmark; treat them as directional.)
