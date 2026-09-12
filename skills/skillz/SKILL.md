---
name: skillz
description: >
  Add, improve, audit, or self-update a skill or sub-agent definition so it
  runs predictably on Claude Code, Codex, OMP, and other Agent Skills hosts.
  Use for /skillz <add|improve|audit|self-update>, "improve this skill",
  "audit this agent", "new skill for X", "skill not triggering", or "fix
  trigger rate". Do NOT use for CLAUDE.md or system-prompt edits, or for
  code changes that a cheese pipeline skill owns.
disable-model-invocation: true
argument-hint: "<add|improve|audit|self-update> [<path>|<name>]"
license: MIT
metadata:
  author: paulnsorensen
  dispatches-agents: audit and self-update only
---

# skillz

Add, improve, audit, and self-update skill and agent definitions.
The product is a **predictable** definition: the same process on every run and on every harness.
Every lens asks one question of each line: *does this make the run more predictable, or is it sediment?*

The mode is the first word after the skill name.
The target is the second word.
Ask when either is missing.

## Modes

| Mode | Target | Analytics | Writes | Product |
|---|---|---|---|---|
| `add <name>` | a new skill name | no | creates `skills/<name>/` | a registered skill that passes the rubric |
| `improve <path>` | a `SKILL.md` or agent file | no | edits the target | applied fixes + residual findings |
| `audit <path>` | a `SKILL.md` or agent file | yes | none | calibrated report |
| `self-update` | this skill | yes | `references/harness-layout.md` + this skill | research delta + applied fixes |

## Shared protocol

### 1. Read and classify

Read the target and every file it links.
Classify it as **agent** (`tools:` / `disallowedTools:` or an `agents/registry.yaml` entry) or **skill** (`name:` + `description:`).
Measure the body: bytes/4 after the frontmatter block; report `~N tok` against the 5k budget.
List the deploy targets the definition reaches (this repo: Claude, OMP, and `~/.agents/skills` for Codex, Cursor, and Copilot).

### 2. Rubric

Score each lens.
Each row names the principle, the failure mode it catches, and a checkable test.
Read `references/anti-patterns.md` when a finding needs the expanded form.

| Lens | Principle → catches | Check |
|---|---|---|
| **Predictability** | Fixed protocol with checkable completion → «premature completion» | Every step ends on a done-condition an agent can verify. |
| **Invocation** | `description` = trigger conditions, front-loaded, third person → «workflow summary», «summary description» | Trigger phrases + "Do NOT use for"; no internal workflow; ≤1024 chars; first sentence carries the trigger. `references/description-optimization.md`. |
| **Portability** | Spec-core frontmatter plus additive Claude fields; user-only policy on every host → «Claude-only assumption», «sidecar missing», «`$ARGUMENTS` dependence» | `disable-model-invocation: true` pairs with `agents/openai.yaml`; args are parsed from the text after the skill name; no `${CLAUDE_SKILL_DIR}`; skills cross-referenced by `/name`; dispatch and GitHub ops name the contract before host syntax. Full matrix: `references/harness-layout.md`. |
| **Information hierarchy** | Disclose only what some runs skip; body ≤5k tok; references one level deep, each with a read trigger → «sprawl», «untriggered split», «`@file` force-load» | Relocation counts only when runs branch on the block and the `## References` entry names the trigger. `references/progressive-disclosure.md`. |
| **Leading words** | One pretrained word beats a restated triad → «duplication», «no-op weak word» | Collapse restatements; strengthen weak words (`be thorough` → `relentless`). |
| **Pruning** | Single source of truth; delete no-ops → «sediment» | No meaning in two places; no line the model obeys by default. Delete whole sentences. |
| **Tool scoping** | Read-only / write-scoped / focused; hard `disallowedTools`, not prose → «prose-only constraint» | A "read-only" claim is backed by `disallowedTools`; nothing listed that is unused. |
| **Context & fork** | Fork when output > ~500 lines or only a digest is needed → «monolithic output» | Fork matches size; a wrap-up signal exists; `model:` + `effort:` set on model-invoked skills, absent on user-only skills. |
| **Prompt quality** | Positive framing, why-over-what, one strong example, "What this never does" → «negation-heavy», «rules without reasons» | Judgment tasks use a scaffold, not always/never. `references/decision-frameworks.md`. |
| **Calibration** | Judgment agents tag confidence × severity → «judgment without calibration» | `<certain>` / `<speculative>` / `<don't know>`; don't-know never surfaces. |
| **Output format** | Summary first, tables for findings, clean-vs-issues signal → «no output format» | Format defined; summary and detail split. |
| **Usage** *(audit, self-update)* | Declared matches actual → «declared-vs-actual», «decay» | Declared tools are the used tools; error rate near baseline; usage not declining. |

### 3. Calibrate

Tag each finding with severity × confidence.
The kernel is `../session-analytics/references/calibration.md`; the defaults:

- **Severity by lens** — Predictability, Invocation, Portability, Tool scoping, Calibration → `high`; Information hierarchy, Context & fork, Pruning → `high`/`medium`; Leading words, Output format, Usage → `medium`.
- **Confidence** — a cited line plus a concrete failure, a reference that does it right, or analytics data → `<certain>`; a checkable but unverified observation → `<speculative>`; a misread → `<don't know>`, dropped.
- **Re-derive** — re-read the target and re-derive each `<speculative>` finding once without the first pass. Drop it when it does not reproduce.
- Order by severity, then `<certain>` first.

## Mode: add

1. Confirm the name: kebab-case, ≤64 chars, directory name equals `name:`, and no collision in `skills/`, `~/.claude/skills`, `~/.agents/skills`.
2. Collect from the argument or ask: purpose in one sentence, ≥5 trigger phrases, anti-triggers, invocation policy (model-invoked or user-only), and the harness set.
3. Write the skill from `references/harness-layout.md § Template`.
   Keep the body ≤2k tok at birth.
   Create a reference only for a block that some runs skip.
   Add `agents/openai.yaml` when the skill is user-only.
   Set `model` + `effort` only when the skill is model-invoked.
4. Register the name in `chezmoi/.chezmoidata/claude.yaml` under `claude.skills`; that list feeds every harness.
5. Run `improve` on the new file once, then `dots sync`.

Done means: the file exists, the registry names it, `dots sync` exits 0, and the Invocation lens passes.

## Mode: improve

1. Run the shared protocol without analytics.
2. Apply every `<certain>` finding of severity medium or higher.
   Show `<speculative>` findings and any protocol-semantic change to the user first; apply those only on approval.
3. Keep the target's voice and protocol semantics. Tighten; do not redesign.
4. Re-measure the body. Report before/after tokens and the residual findings.
5. Run `dots sync` when the target lives under this repo's `skills/` or `agents/`.

Done means: the rubric passes with no `<certain>` finding above `low`, the body is ≤5k tok, and the repo gate (`just check` here) exits 0.

## Mode: audit

1. Run the analytics ceremony in `references/analytics-ceremony.md` (three `duckdb-expert` spawns, best-effort).
2. Run the shared protocol with the Usage lens.
3. Emit the report below. Write nothing else.
4. Close with `Run /skillz improve <path> to apply.`

Done means: the report lists every surfaced finding with a cited line, and the below-bar count is stated.

## Mode: self-update

1. Dispatch `researcher` (or `/briesearch`) with the `## Sources` list from `references/harness-layout.md`.
   Ask for changes since its `Checked:` date: frontmatter fields, discovery paths, invocation policy, argument handling, and body budgets for Claude Code, the Agent Skills spec, Codex, OMP, Pi, Zed, and the `skills` CLI.
2. Diff the digest against the reference.
   Update the matrix, the rules, the template, and the `Checked:` date.
   Record each rejected claim with its reason under `## Rejected`.
3. Run `audit` on `skills/skillz/SKILL.md`, then `improve` on it.
4. Run `dots sync`, then `just check`.

Done means: `Checked:` is today, every source in the list was queried, and this skill passes its own rubric.

## Report

```markdown
## skillz <mode>: <name>

- Type: agent | skill · Invocation: model | user-only · Tools: <N allowed, N disallowed> · Body: ~N tok (before → after for improve)
- Harnesses reached: <list> · Findings: N surfaced, N below the bar

| # | Severity | Confidence | Lens | Issue (line) | Fix | Applied |
|---|---|---|---|---|---|---|

### Detail (per surfaced finding)
**What** · **Why** (the principle) · **How** (exact section) · **Reference** (a definition that does it right)

### Recommended hooks
Only for a rule that must hold every time; pick from `references/hooks-catalog.md`. Omit when none.

### Below the bar
N findings were `<don't know>` or trivial (not shown).
```

## What this skill never does

- `audit` never writes; `improve` never redesigns; `add` never registers a skill whose description fails the Invocation lens.
- It never surfaces `<don't know>`.
- It never exempts itself; a finding against `skillz` is filed like any other.

## Gotchas

- Generic findings on simple skills: every finding cites a line or a named pattern.
- Over-indexing on missing `disallowedTools` when the host default already constrains the tool list.
- The `<speculative>` re-derivation is the first step skipped under time pressure and the one that catches the most false positives.
- `disable-model-invocation` alone leaves Codex free to auto-invoke; the sidecar is the fix, not more prose.
- A hook is for a rule that must hold every time, not for every finding.

## References

Read on demand:

- `references/harness-layout.md` — Portability lens fires, `add`, or `self-update`; the frontmatter matrix, rules, template, sidecar, and sources.
- `references/analytics-ceremony.md` — `audit` and `self-update`; the `duckdb-expert` fan-out.
- `references/anti-patterns.md` — a finding needs the expanded failure mode.
- `references/progressive-disclosure.md` — Information hierarchy fires.
- `references/description-optimization.md` — Invocation fires.
- `references/decision-frameworks.md` — Prompt quality flags rigid rules on a judgment task.
- `references/hooks-catalog.md` — a finding needs 100%-of-the-time enforcement.
- `references/skill-usage.md`, `references/agent-orchestration.md`, `references/drift-regression.md` — the analytics packs.
- `../session-analytics/references/calibration.md` — the confidence × severity kernel.
