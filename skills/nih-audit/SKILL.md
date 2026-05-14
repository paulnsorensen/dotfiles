---
name: nih-audit
model: opus
effort: high
context: fork
argument-hint: "[directory to scope, or leave blank for full codebase]"
allowed-tools: Read, Glob, Grep, Bash(sg:*), Bash(git log:*), Bash(git blame:*), Bash(jq:*), Bash(yq:*), Bash(wc:*), Agent, LSP
description: >
  Scan a codebase for custom code that duplicates what open-source libraries
  already do, then recommend which libraries to adopt. Detects hand-rolled
  utility functions, custom retry logic, manual validation, DIY date handling,
  home-grown argument parsers, and other reinvented wheels. Cross-checks against
  installed dependencies and open specs. Returns scored migration recommendations
  with effort estimates. Use this skill when the user mentions reinventing the
  wheel, asks if there's a library for something they built, wants a build vs buy
  audit, says "what are we maintaining that we shouldn't be", asks about library
  alternatives for custom code, wonders if their utils/ folder has redundant
  implementations, or wants to find dependency opportunities. Also use when the
  user asks to compare their custom implementation against existing packages, or
  says things like "should we just use lodash for this" or "is there a crate
  that does what our helper does". Do NOT use for security vulnerability scanning
  (/audit), code quality review (/age), or dead code removal (/simplifier).
---

# /nih-audit — Not Invented Here Audit

Find code reinventing the wheel. Recommend libraries. Score with evidence.

**Scope**: $ARGUMENTS (or repo root if blank)

## Phase 0: Detect Build System & Extract Dependencies

**Goal**: Know what's already installed so we never recommend existing deps.

### 0.1 Find Manifest Files

```
Glob: **/package.json
Glob: **/Cargo.toml
Glob: **/pyproject.toml
Glob: **/go.mod
Glob: **/Gemfile
Glob: **/requirements.txt
Glob: **/composer.json
Glob: **/build.gradle
Glob: **/pom.xml
Glob: **/mix.exs
```

Filter out manifests inside node_modules/, vendor/, .git/, build/.

### 0.2 Extract Dependencies

For each manifest, extract dependency names into a flat set:

| Manifest | Extract command |
|----------|----------------|
| package.json | `jq -r '(.dependencies + .devDependencies) // {} \| keys[]'` |
| Cargo.toml | `yq -r '.dependencies \| keys[]'` or parse `[dependencies]` section |
| pyproject.toml | `yq -r '.project.dependencies[]'` or `[tool.poetry.dependencies]` |
| go.mod | `grep '^require' + parse module paths` |
| requirements.txt | line-by-line package names |

Store as `depManifest`:

```json
{
  "workspaces": {
    ".": { "ecosystem": "node", "deps": ["express", "zod", "uuid"] }
  },
  "primaryLanguages": ["typescript"]
}
```

### 0.3 Detect Primary Languages

Infer from manifest types + file extensions in scope. This determines which
ast-grep patterns the scanner will run.

**Tool budget**: ~5 calls.

---

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

---

## Phase 2: Library Discovery

**Goal**: For each NIH candidate category, find the library that already does this.

### 2.1 Group Candidates by Category

Deduplicate candidates that share a category. Group into research queries:

| Category | Research query shape |
|----------|---------------------|
| RETRY | "best retry/backoff library for {language}" |
| UUID | "recommended UUID library for {language}" |
| VALIDATION | "best validation library for {language}" |
| DATE | "best date/time library for {language}" |
| DEBOUNCE | "debounce/throttle library for {language}" |
| CLONE | "deep clone library for {language}" |
| ARGPARSE | "argument parsing library for {language}" |
| STRING | "string manipulation library for {language}" |
| HTTP | "HTTP client library for {language}" |
| SERIALIZATION | "serialization library for {language}" |
| ERROR | "error handling library for {language}" |
| CRYPTO | "password hashing library for {language}" |
| SECURITY | "HTML sanitization library for {language}" |
| FORMAT | "number/currency formatting library for {language}" |
| COMPARE | "deep equality library for {language}" |

### 2.2 Spawn Library Lookup Agents

For each category group (max 5 parallel), spawn a general-purpose agent with
focused MCP access. Library lookup primarily uses Context7 for API surface
and `gh` CLI for repo stats — not a full /briesearch call.

```
Agent(
  subagent_type="general-purpose",
  model="sonnet",
  prompt="Find well-maintained open-source libraries for: <category description>
    Language: <lang>
    Already installed (DO NOT recommend): <depManifest deps>

    Use ONLY these tools (do NOT use WebSearch or WebFetch):
    - mcp__context7__resolve-library-id and mcp__context7__query-docs
    - `gh search repos` / `gh repo view` for GitHub stats

    For each library found, return:
    - Name and latest version
    - License (flag GPL, prefer MIT/Apache-2.0/BSD)
    - Weekly downloads or crates.io downloads
    - GitHub stars
    - Last commit date
    - Contributor count
    - Whether it's stdlib, micro-library, or framework
    - One-sentence API example showing how it replaces the NIH code",
  run_in_background=true
)
```

### 2.3 Collect and Deduplicate

Wait for all research agents. For each candidate:

- Map the best library recommendation to the candidate
- Drop recommendations for libraries already in depManifest
- Flag stdlib alternatives (no new dep needed — highest value)
- Note if the category yielded no good alternatives (candidate drops out)

**Tool budget**: ~15 calls.

---

## Phase 3: Spec/Roadmap Alignment

**Goal**: Check if NIH code is intentional or if a library covers planned work too.

### 3.1 Find and Read Specs

Search for spec directories across the repo, not just `.claude/specs/`:

```
Glob: **/specs/*.md
```

Filter out specs inside node_modules/, vendor/, .git/, build/.

Read each spec's first 100 lines (summary, requirements, goals sections).

### 3.2 Check for Intentional NIH

For each candidate, search for signals that NIH was deliberate:

**In specs**: Look for mentions of the candidate's concept + words like
"intentionally", "we chose to build", "build vs buy", "don't use",
"avoid dependency on".

**In code**: Search candidate files for comments indicating intent:

```
Grep: "intentionally|deliberately|don't use|avoid|instead of|rather than|we chose|NOTE:|DECISION:"
```

Scoped to files containing NIH candidates only.

### 3.3 Check Library-Spec Alignment

For each recommended library, check if it covers features described in specs
that aren't built yet. A library that handles current NIH code AND future
planned features is a stronger recommendation.

### 3.4 Apply Scoring Modifiers

| Signal | Modifier |
|--------|----------|
| Spec explicitly chose NIH | -30 |
| Code comment explains NIH choice | -20 |
| Library covers planned spec features | +10 |
| No spec or comment context | +0 |

**Tool budget**: ~10 calls.

---

## Phase 4: Score & Synthesize

**Goal**: Apply 4-step confidence scoring, produce actionable recommendations.

### 4.1 Confidence Scoring

For each candidate with a library recommendation, apply the full 4-step chain:

#### Step 1: Classify the finding type

| Type | Base | Cap | When |
|------|------|-----|------|
| REPLACE_WITH_STDLIB | 55 | 100 | stdlib function does the same thing |
| REPLACE_WITH_MICRO_LIB | 45 | 95 | small focused library (<5 deps) |
| REPLACE_WITH_FRAMEWORK | 35 | 85 | large framework (lodash, Django, etc.) |
| EXTRACT_TO_EXISTING_DEP | 50 | 95 | already-installed dep has this feature |

#### Step 2: Evidence grounding

| Evidence | Modifier |
|----------|----------|
| LSP-verified usage count (exact caller list) | +15 |
| Library has >10K weekly downloads + MIT/Apache | +20 |
| ast-grep pattern match + code read confirms NIH | +15 |
| NIH code has recent bug fixes (git blame) | +10 |
| NIH code >100 LOC for what library does in 1 call | +10 |
| Generic pattern match, code does more than pattern suggests | -15 |
| Recommended library is unmaintained (last commit >1yr) | hard cap at 40 |

#### Step 3: Context modifiers

| Signal | Modifier |
|--------|----------|
| Spec explicitly chose NIH | -30 |
| Code comment explains NIH choice | -20 |
| Library covers planned spec features | +10 |
| NIH code is in a git hotspot (many recent changes) | +10 |
| NIH code is isolated (1 file, clear boundary) | +5 |
| NIH code is deeply coupled (referenced from >10 files) | -5 |

#### Step 4: Second independent scoring pass

For EVERY candidate (not just borderlines):

1. Clear your mental state — do not look at the first score
2. Re-read the NIH code and the library's API fresh
3. Score independently using the same steps 1-3
4. Report BOTH scores in the finding (Pass 1: NN, Pass 2: NN)
5. Final score = average of both passes
6. If scores diverge by >20 points, flag as "ambiguous" but still include

### 4.2 Effort Sizing

| Criteria | Size |
|----------|------|
| 1 file, <50 LOC, <=3 call sites | **S** |
| 2-5 files, <200 LOC, <=10 call sites | **M** |
| >5 files, >200 LOC, or >10 call sites | **L** |

### 4.3 Build Detailed Report

Build the full report in memory. Do NOT write to `$TMPDIR` or any file — return
everything inline in the summary response.

For EVERY finding (no threshold filtering — show all candidates):

```
### Finding #N: <Title> (Score: NN) [AMBIGUOUS if passes diverge >20]

**NIH Code**: `file:line-line` (N LOC)
**Category**: CATEGORY
**Pattern**: <what was detected>

**Recommended Alternative**: `library-name` (version)
- License: MIT/Apache-2.0/BSD
- Downloads: N/week | Stars: N | Last commit: YYYY-MM-DD
- Contributors: N

**Code Touchpoints**:
- `file:line` — implementation (DELETE or REPLACE)
- `file:line` — import (UPDATE)
- ...

**Effort**: S/M/L (N files, N call sites)

**Migration Path**:
1. Install: `npm install library` / `cargo add library` / etc.
2. Replace: specific code change description
3. Clean up: remove old files/tests

**Scoring**:
- Pass 1: NN (base NN + evidence NN + context NN)
- Pass 2: NN (base NN + evidence NN + context NN)
- Final: NN (average)

**Why do it**: <concrete benefits — maintenance burden removed, bugs already
fixed upstream, stdlib means zero new deps, covers planned features, etc.>

**Why not**: <concrete reasons to keep NIH — trivial code not worth a dep,
hot path where you need control, intentional design choice, library adds
transitive deps you don't want, coupling risk, etc.>
```

### 4.4 Return Full Report

Return everything inline — no temp files. Include the summary table, specs
consulted, and the full detailed findings (one ### Finding block per
recommendation above threshold):

```
## NIH Audit: <scope>

### Summary
- Files scanned: N
- NIH candidates found: N
- Already using best option: N (filtered out)
- Ambiguous (scoring passes diverge >20): N

### All Findings (sorted by score, descending)

| # | Score | P1 | P2 | Category | NIH Code | Replace With | Effort |
|---|-------|----|----|----------|----------|-------------|--------|
| 1 | 92 | 90 | 94 | UUID | src/utils/uuid.ts:12 | crypto.randomUUID() (stdlib) | S |
| 2 | 42 | 45 | 39 | COLOR | theme/generate.sh:68 | pastel (cargo) | S |

### Specs Consulted
- spec-name: <relevant finding or "no NIH justifications">

<detailed findings inline — one ### Finding block per candidate, ALL included>
```

**Tool budget**: ~10 calls.

---

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
- **LSP cold start**: First scan in a session may miss results due to LSP warmup. The nih-scanner has a warmup protocol, but note failures.
- **Stdlib alternatives are the highest value**: `crypto.randomUUID()` replacing a hand-rolled UUID is a no-brainer (no new dep). Always score these highest.
- **"Already installed" is the most common false positive**: A codebase that has lodash installed but hand-rolls `deepClone` might have done so intentionally (bundle size). The spec/comment check catches this.
- **Monorepo dep scoping**: A function in `packages/api/` might be NIH in that workspace but the library is installed in `packages/web/`. Each workspace's depManifest is independent.
- **License compatibility isn't just MIT-vs-GPL**: Some projects have specific license requirements. When in doubt, flag the license and let the human decide.
