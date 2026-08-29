---
name: nih-audit
model: opus
effort: high
context: fork
argument-hint: "[directory to scope, or leave blank for full codebase]"
allowed-tools: Read, Glob, Grep, Bash(sg:*), Bash(git log:*), Bash(git blame:*), Bash(jq:*), Bash(yq:*), Bash(wc:*), Bash(npm audit:*), Bash(uv pip audit:*), Bash(pip-audit:*), Bash(cargo audit:*), Bash(govulncheck:*), Agent, mcp__serena__*
description: >
  Scan for custom code that duplicates well-supported libraries, then recommend
  migrations with effort estimates. Detects hand-rolled utilities, retry logic,
  validation, date handling, and DIY parsers. Use when the user mentions
  reinventing the wheel, asks "is there a library/crate for this", wants a build
  vs buy audit, says "what are we maintaining that we shouldn't be", or "should
  we just use lodash for this". Also covers dependency health — vulnerable,
  unused, overweight, or stdlib-replaceable deps. Do NOT use for code-quality
  review (/age) or dead-code removal (/simplify or /ghostbuster).
---

# /nih-audit — Not Invented Here Audit

Find code reinventing the wheel. Recommend libraries. Score with evidence.

**Scope**: $ARGUMENTS (or repo root if blank)

## Phase 0: Detect Build System & Extract Dependencies

**Goal**: Know what's already installed so we never recommend existing deps.

Read `references/dependency-extraction.md` before starting this phase — it has
the manifest globs, per-manifest extract commands, the `depManifest` JSON shape,
and the dependency-health checks (vulnerability audits, possibly-unused,
overweight, stdlib-replaceable).

Steps: find manifest files (excluding node_modules/, vendor/, .git/, build/),
extract deps into `depManifest`, detect primary languages from manifests + file
extensions, then run dependency health. Dependency-health findings are not NIH
candidates: they skip Phases 2–3 and go straight to the Dependency Health block
of the report.

**Tool budget**: ~10 calls.

## Phase 1: Structural NIH Scanning

**Goal**: Find code that smells like reinvented wheels.

Spawn the `nih-scanner` agent:

```
Agent(
  subagent_type="nih-scanner",
  model="sonnet",
  prompt="Scan for NIH patterns.
    Languages: <detected languages>
    Scope: <$ARGUMENTS or repo root>
    depManifest: <JSON>
    Slug: <slug>",
  run_in_background=false
)
```

The scanner returns the full JSON candidate list inline in its response,
along with a summary (file count, candidate count, categories).

Parse the candidates from the response. If 0 candidates, report clean and stop.

**Tool budget**: ~30 calls (in sub-agent).

## Phase 2: Library Discovery

**Goal**: For each NIH candidate category, find the library that already does this.

Read `references/library-research.md` before dispatching lookups — it has the
category → research-query table and the exact lookup-agent prompt template.

Group candidates by category, spawn a lookup agent per category group (max 5
parallel, `run_in_background=true`), wait for all, then map the best library to
each candidate. Drop libraries already in `depManifest`, flag stdlib
alternatives (highest value), and drop candidates whose category yielded no
good alternative.

**Tool budget**: ~15 calls.

## Phase 3: Spec/Roadmap Alignment

**Goal**: Check if NIH code is intentional or if a library covers planned work too.

1. **Find and read specs**: `Glob: **/specs/*.md` across the repo, not just
   `.claude/specs/` (filter node_modules/, vendor/, .git/, build/). Read each
   spec's first 100 lines (summary, requirements, goals sections).
2. **Check for intentional NIH**: in specs, look for the candidate's concept +
   words like "intentionally", "we chose to build", "build vs buy", "don't
   use", "avoid dependency on". In code, grep candidate files only for
   `"intentionally|deliberately|don't use|avoid|instead of|rather than|we chose|NOTE:|DECISION:"`.
3. **Check library-spec alignment**: a library that handles current NIH code
   AND future planned spec features is a stronger recommendation.

These signals become the context modifiers in Phase 4 scoring.

**Tool budget**: ~10 calls.

## Phase 4: Score & Synthesize

**Goal**: Apply 4-step confidence scoring, produce actionable recommendations.

Read `references/scoring.md` before scoring — it has the full 4-step chain
(finding-type base/cap, evidence modifiers, context modifiers, and the
mandatory second independent scoring pass for every candidate) plus S/M/L
effort sizing.

Read `references/output-format.md` before writing the report — it has the
per-finding block and the full report template. Return everything inline in
the summary response; never write to `$TMPDIR` or any file. Include ALL
candidates, no threshold filtering.

**Tool budget**: ~10 calls.

## Implementation Notes

- **Parallel execution**: Spawn research agents with `run_in_background=true`. Wait for all before Phase 4.
- **Cost-aware research**: Research agents use the cost routing from the research agent (free → cheap → expensive).
- **Monorepo handling**: Phase 0 builds per-workspace dep manifests. Candidates are scoped to their workspace.
- **Wrap-up signal**: After ~60 total tool calls across all phases, synthesize from available data. Note incomplete coverage.
- **Empty results**: If Phase 1 finds 0 candidates, report clean and stop. Don't force findings.

## What This Skill Never Does

- Modify code or implement migrations — it recommends, the human decides
- Recommend GPL libraries without flagging the license risk
- Use tavily_research (15-250 credits) — regular tavily_search is sufficient
- Override explicit NIH decisions documented in specs or code comments
- Run in codebases without any manifest files (nothing to cross-reference)

## Gotchas

- **ast-grep patterns are approximate**: A `clearTimeout` + `setTimeout` combo isn't always a debounce. The orchestrator's scoring step (Phase 4) catches generic matches via the -15 modifier.
- **Serena cold start**: First scan in a session may miss results if the Serena MCP hasn't indexed the project yet. The nih-scanner has an availability check, but note failures.
- **Stdlib alternatives are the highest value**: `crypto.randomUUID()` replacing a hand-rolled UUID is a no-brainer (no new dep). Always score these highest.
- **"Already installed" is the most common false positive**: A codebase that has lodash installed but hand-rolls `deepClone` might have done so intentionally (bundle size). The spec/comment check catches this.
- **Monorepo dep scoping**: A function in `packages/api/` might be NIH in that workspace but the library is installed in `packages/web/`. Each workspace's depManifest is independent.
- **License compatibility isn't just MIT-vs-GPL**: Some projects have specific license requirements. When in doubt, flag the license and let the human decide.
