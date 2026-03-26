---
name: ghostbuster
model: opus
effort: high
context: fork
argument-hint: "[directory to scope, or leave blank for full codebase]"
allowed-tools: Read, Glob, Grep, Bash(git log:*), Bash(git diff:*), Bash(git blame:*), Bash(wc:*), Agent, LSP
description: >
  Dead code forensics and spec cross-reference. Finds unreachable functions,
  orphaned implementations, specs pointing at deleted code, and transitive dead
  code chains. Categorizes as DEAD (safe to delete), ZOMBIE (in spec but unwired),
  GHOST (spec references nonexistent code), or DORMANT (entry point is dead,
  taking dependents with it). Use when the user says "find dead code", "what's
  unused", "clean up unused functions", "are there stale specs", "what code can
  I delete", "check for orphaned implementations", "spec drift", "what's
  incomplete", "find zombie code", or asks about code that was started but never
  finished. Also use when reviewing a module and wanting to know what's wired up
  vs what's just sitting there. Do NOT use for code quality review (/age),
  NIH/reinvented-wheel detection (/nih-audit), or security scanning (/audit).
---

# /ghostbuster — Dead Code Forensics

Find what's expired. Cross-reference against specs. Triage the remains.

**Scope**: $ARGUMENTS (or repo root if blank)

## Phase 1: Discovery

Detect languages from file extensions in scope. Build a file inventory:

```
Glob: {scope}/**/*.{ts,tsx,js,jsx,py,rs,go,sh,bash}
```

Filter out test files, node_modules/, vendor/, target/, dist/, build/.

## Phase 2: Spec & Doc Collection

Search broadly — specs and documentation both reference code symbols:

```
Glob: **/specs/**/*.md
Glob: **/.claude/specs/*.md
Glob: **/SPEC.md
Glob: **/spec.md
Glob: **/CLAUDE.md
Glob: **/README.md
Glob: **/CONTRIBUTING.md
Glob: **/docs/**/*.md
```

Read each file and extract symbol references (backtick-wrapped identifiers,
code blocks, prose references to functions/types/endpoints). Build a lookup
of `{symbol → [file:line]}`.

## Phase 3: Dead Code Scan

Spawn the `ghostbuster` agent:

```
Agent(
  subagent_type="ghostbuster",
  model="sonnet",
  prompt="Run dead code forensics.
    Scope: <$ARGUMENTS or repo root>
    Languages: <detected languages>
    Slug: <slug>",
  run_in_background=false
)
```

The agent writes the full JSON report to `$TMPDIR/ghostbuster-{slug}.json` and returns
a structured summary (max 2000 chars). Read the full report for detailed findings.

## Phase 4: Synthesize & Present

Parse the agent's findings. Present the full report to the user:

### Category explanations with examples

For each category found, give one concrete example from the findings:

**DEAD** — Code with zero callers and no spec mention.
> Example: `src/utils/legacy-parser.ts:parseLegacyFormat` — 0 references,
> untouched since August. Safe to delete.

**ZOMBIE** — Spec says it should exist, but nothing calls it at runtime.
> Example: `src/domains/billing/invoice-export.ts:exportToQuickbooks` —
> mentioned in billing-integrations.md but has 0 callers. Incomplete
> implementation or abandoned?

**GHOST** — Spec references a symbol that doesn't exist in the codebase.
> Example: `.claude/specs/billing-integrations.md:67` references
> `validateTaxRules` — deleted 6 months ago. Stale spec.

**DORMANT** — Code has callers, but the root of the call chain is dead.
> Example: `src/utils/tax-formatter.ts:formatTaxLine` — only caller is
> `validateTaxRules` which is itself dead. Entire chain can go.

### Actionable summary

Group findings by recommended action:
1. **Delete now** — DEAD findings with confidence >= 75
2. **Human triage** — ZOMBIE findings (spec vs reality mismatch)
3. **Update specs** — GHOST findings (stale references)
4. **Delete chain** — DORMANT findings (list the full chain)

### Offer next steps

- "Delete the DEAD code? I can remove the N files/functions with confidence >= 75."
- "Update the specs to remove GHOST references?"
- "Run `/xray` on ZOMBIE modules to understand what's missing?"

## What This Skill Never Does

- Auto-delete code without user confirmation
- Judge whether dead code is intentional (feature flags, emergency rollback paths)
- Modify specs — it flags mismatches, the human decides
- Scan for code quality issues — that's /age or /simplifier
- Detect reinvented wheels — that's /nih-audit

## Gotchas

- Dynamic dispatch (trait impls, interface implementations, duck typing) can hide callers — confidence is capped at 95 for this reason
- Recently touched code (< 2 weeks) gets a confidence penalty — it may be WIP
- Shell functions sourced via `. script.sh` won't appear in LSP — Grep-only for shell
- Specs use varied formats for symbol references — the agent casts a wide net but may miss prose-only references
