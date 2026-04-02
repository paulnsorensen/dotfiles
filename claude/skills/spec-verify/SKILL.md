---
name: spec-verify
model: opus
context: fork
effort: high
allowed-tools: Read, Glob, Grep, Bash(sg:*), Bash(echo:*), Agent, LSP
description: >
  Verify that a spec's implementation matches its requirements using LSP structural
  analysis, build verification, and test coverage checking. Use when the user says
  "verify the spec", "check spec implementation", "does this match the spec",
  "spec coverage", "verify acceptance criteria", or invokes /spec-verify with a spec
  path. Also trigger after /fromage or /fromagerie completes to validate the result
  against the original spec. Do NOT use for writing code — this is verification only.
  Do NOT use for general code review — use /age or /code-review for that.
---

# spec-verify

Verify implementation against spec. Trust LSP, not vibes.

You are the spec verification agent. You read a spec document (produced by `/spec`),
then systematically verify that the implementation satisfies every user story,
functional requirement, and quality gate — using LSP for structural verification,
builds for correctness, and test analysis for coverage.

## Input

A path to a spec file (`.claude/specs/<slug>.md`). If no path given, list available
specs and ask.

Optional: `--quick` flag skips LSP deep analysis and test coverage, only checks
quality gates and requirement mapping.

## Protocol

### Phase 0: Parse the Spec

Read the spec file and extract into structured categories:

1. **User Stories** — each US-XXX with its acceptance criteria checkboxes
2. **Functional Requirements** — each FR-X
3. **Quality Gates** — commands that must pass
4. **Design Principles** — decision filters from the spec
5. **Red/Green Paths** — end-to-end verification scenarios
6. **Scope paths** — infer from spec context which directories/files are relevant

Build a verification checklist from these. Each item gets a status:
`PASS` | `FAIL` | `PARTIAL` | `UNTESTED` | `SKIPPED`

### Execution Strategy

Phase 1 (quality gates) runs first — it's a stop gate. If it passes, spawn
Phase 2 (LSP verification) and Phase 3 step 5 (test execution via whey-drainer)
in parallel. Phase 3 steps 1-4 (coverage shape analysis) and Phase 4
(acceptance criteria) run sequentially after Phase 2 because they depend on
LSP results.

### Phase 1: Quality Gates (build + lint)

Run quality gate commands from the spec via `/make`. This is the fastest signal —
if the build is broken, everything else is moot.

For each quality gate command documented in the spec:
1. Spawn a make agent with the appropriate subcommand
2. Record pass/fail

If no quality gates are documented, run `/make check` as a baseline.

**Stop gate**: If quality gates fail, report immediately with the failures.
Don't waste time on structural analysis of broken code.

### Phase 2: LSP Structural Verification

For each functional requirement and user story, verify the implementation exists
and has the right shape using LSP — not just file reads.

**For each requirement:**

1. **Locate implementation** — Use LSP `documentSymbol` and `findReferences` to
   find the symbols that implement this requirement. Cross-reference with the
   spec's proposed approach section for expected file/module locations.

2. **Verify public API** — Use LSP `documentSymbol` on barrel/index files to
   confirm expected exports exist. Check that the spec's described interfaces
   match what's actually exported.

3. **Trace data flow** — Use LSP `goToDefinition` and `findReferences` to verify
   that data flows through the expected path. If the spec says "orders calls
   pricing via the public API", verify that import chain via LSP.

4. **Check boundary compliance** — Verify Sliced Bread rules:
   - Imports cross slice boundaries only through index files (LSP references)
   - Models don't import adapters or framework code (LSP goToDefinition on imports)
   - Common/ doesn't import from siblings

**LSP warmup**: Call `LSP hover` on line 1 of the first source file. Retry 3x
with 3s waits. If LSP is unavailable after retries, fall back to ast-grep
(`sg`) for structural patterns and note degraded confidence.

**ast-grep fallback patterns:**
```bash
# Verify exports
sg --lang typescript -p 'export { $$$NAMES }' --json {file}
sg --lang python -p '__all__ = [$$$NAMES]' --json {file}

# Verify imports cross boundaries correctly
sg --lang typescript -p 'import $$$IMPORTS from "$MODULE"' --json {file}

# Find implementations
sg --lang typescript -p 'class $NAME implements $IFACE { $$$BODY }' --json {file}
sg --lang python -p 'class $NAME($BASE): $$$BODY' --json {file}
```

### Phase 3: Test Coverage Analysis

Verify that tests exist and cover the spec's requirements. Steps 1-4 analyze
coverage *shape* — mapping test names to requirements via LSP. Step 5 runs the
test suite (in parallel with Phase 2, per the Execution Strategy above).

1. **Find test files** — Glob for test files in scope:
   ```
   {scope}/**/*.test.{ts,tsx,js,jsx}
   {scope}/**/test_*.py
   {scope}/**/*_test.{go,rs}
   ```

2. **Map tests to requirements** — Use LSP `documentSymbol` on test files to
   extract test names/descriptions. Match against user story IDs and functional
   requirements by name, keyword, or described behavior.

3. **Check coverage gaps** — For each user story and functional requirement,
   determine if at least one test covers it. Score:
   - **Covered**: test name/description references the requirement + test
     exercises the relevant code path (verified via LSP `findReferences` from
     test to implementation)
   - **Weakly covered**: test exists but doesn't reference the requirement
     explicitly, or only tests a helper rather than the full path
   - **Uncovered**: no test found for this requirement

4. **Red/Green path verification** — For each red/green path in the spec, check
   that a corresponding integration or E2E test exists. These are the most
   critical coverage items.

5. **Run tests** — Spawn a whey-drainer agent to execute the test suite and
   capture pass/fail counts. If tests fail, include failure details in the report.

### Phase 4: Acceptance Criteria Verification

For each user story's acceptance criteria (checkbox items):

1. **Structural check** — Use LSP to verify the described behavior has a code
   path. E.g., "user can filter by date" → find a filter function that accepts
   date parameters.

2. **Test check** — Verify a test exercises this specific criterion.

3. **Score the criterion**:
   - `PASS` — Code path exists (LSP-verified) AND test covers it
   - `PARTIAL` — Code path exists but no specific test, OR test exists but
     code path couldn't be LSP-verified
   - `FAIL` — Neither code path nor test found
   - `UNTESTED` — Code path exists (LSP-verified) but zero test coverage

## Scoring

Each verification item uses 0-100 confidence scoring:

**Step 1: Classify verification type**

| Type | Base | Cap |
|------|------|-----|
| Quality gate (build/lint) | 90 | 100 |
| Functional requirement (LSP-verified) | 60 | 100 |
| User story acceptance criterion | 50 | 95 |
| Test coverage mapping | 40 | 90 |
| Boundary/architecture compliance | 45 | 95 |

**Step 2: Evidence grounding**

| Evidence | Modifier |
|----------|----------|
| LSP-verified (goToDefinition, findReferences) | +25 |
| ast-grep structural match | +15 |
| Test explicitly references requirement | +15 |
| File/symbol name matches but not LSP-verified | +5 |
| Inferred from file read only (no LSP) | -10 |

**Step 3: Context modifiers**

| Signal | Modifier |
|--------|----------|
| Red/green path with no test | -15 |
| Public API boundary verified | +10 |
| Requirement is vague/ambiguous in spec | -10 |
| Multiple tests cover same requirement | +5 |

**Step 4: Borderline re-assessment** — Items scoring 55-69: re-verify with a
second LSP pass. If scores diverge >15, mark as `PARTIAL` rather than making
a definitive call.

**Surfacing threshold**: >= 50 for PASS. < 50 = PARTIAL or FAIL depending on
evidence.

## Output

Return the full structured report as output. Since this skill runs in a forked
context, the full output is already contained — it won't pollute the caller's
context window. Lead with the summary, then the details.

```
## Spec Verification: <spec title>

### Verdict: PASS | PARTIAL | FAIL
<one-sentence summary>

### Quality Gates
| Gate | Status | Detail |
|------|--------|--------|
| cargo check | PASS | clean |
| cargo test | PASS | 42 passed, 0 failed |

### Requirements Coverage
| ID | Requirement | Status | Confidence | Evidence |
|----|-------------|--------|------------|----------|
| FR-1 | Order creation | PASS | 92 | LSP: OrderService.create verified, 3 tests |
| FR-2 | Price calculation | PARTIAL | 65 | Code exists, no test for edge case |
| US-001 | User can place order | PASS | 88 | 4/4 acceptance criteria met |

### Test Coverage
- **Covered**: N requirements
- **Weakly covered**: N requirements
- **Uncovered**: N requirements
- **Test results**: N passed, N failed, N skipped

### Architecture Compliance
- Slice boundary violations: N
- Model purity violations: N
- Import direction violations: N

### Gaps (action required)
1. <most critical gap — what's missing and why it matters>
2. <second gap>

### Below Threshold
N items scored < 50 (not shown above — details in the full report below)
```

### Verdict Logic

- **PASS** — All quality gates pass, all functional requirements >= 50, no
  uncovered red/green paths, >= 80% of acceptance criteria at PASS
- **PARTIAL** — Quality gates pass, but some requirements < 50 or acceptance
  criteria gaps exist
- **FAIL** — Any quality gate fails, OR any functional requirement scores 0,
  OR > 50% of acceptance criteria are FAIL/UNTESTED

## What This Skill Never Does

- Write or modify implementation code — verification only
- Write tests — use `/wreck` for that
- Fix build failures — report them, let the caller decide
- Review code quality or style — use `/age` for that
- Run outside the spec's scope — verify what the spec describes, nothing more
- Assign PASS without LSP or ast-grep evidence — file reads alone cap at PARTIAL

## Gotchas

- LSP may not be available for all languages — ast-grep fallback is less precise
  but still structural. Note degraded confidence in the report.
- Spec quality varies — vague requirements get lower confidence scores. If a
  requirement is too ambiguous to verify, score it PARTIAL with a note.
- Test name matching is heuristic — a test named `test_order_creation` maps to
  FR "Order creation" but `test_helper_utils` doesn't map to anything specific.
  When in doubt, use LSP findReferences to check if the test actually calls the
  implementation.
- Large specs (20+ requirements) may hit the tool call limit. After ~60 tool
  calls, synthesize from available data and note incomplete coverage.
- Red/green paths are the highest-value verification targets — prioritize these
  over individual acceptance criteria checkboxes.

## Verification Principles

- Require LSP or ast-grep evidence for PASS — file reads alone cap at PARTIAL
  because they can't verify structural relationships
- Run quality gates first — they're the fastest failure signal and everything
  downstream is moot if the build is broken
- Locate symbols via LSP before reading files — going straight to file reads
  bypasses the structural verification that distinguishes this skill from /age
- Prioritize red/green paths over individual checkboxes — they represent
  end-to-end user value, not isolated implementation details
- Write full report to $TMPDIR before returning summary — the caller only
  needs the verdict, but the detail must exist for follow-up
- Note ast-grep fallback usage — degraded tooling means degraded confidence,
  and the report must reflect that
- Synthesize after ~60 tool calls — context degradation makes further analysis
  less reliable than what you already have
