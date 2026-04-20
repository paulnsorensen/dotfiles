---
name: self-eval
model: haiku
description: >
  Run the Self-Evaluation Checklist against your last response or recent changes.
  Use this skill when the user says "self-eval", "self-evaluate", "check my response",
  "quality check", "evaluate response", or when you want to proactively verify response
  quality before finishing. Also trigger when the user expresses doubt about your output
  ("did you actually test that?", "are you sure?", "that seems incomplete"). This skill
  cross-references with /de-slop and /tdd-assertions for items that have dedicated tooling.
allowed-tools: mcp__tilth__*
---

# self-eval

Review the last response against the Self-Evaluation Checklist in your instructions, output a scorecard, and auto-fix violations.

The checklist itself lives in your global instructions (CLAUDE.md) under "Self-Evaluation Checklist". This skill provides the execution protocol — it does not duplicate the checklist content.

## Protocol

### 1. Gather context

Determine what to evaluate:

- **Last response**: re-read your most recent assistant message
- **Recent changes**: if code was written or modified, identify the changed files

### 2. Score each item

Evaluate all 8 checklist items. Output a compact scorecard:

```
## Self-Evaluation

| # | Check              | Result | Notes |
|---|-------------------|--------|-------|
| 1 | Sycophancy         | PASS   |       |
| 2 | Premature complete | FAIL   | Left TODO on line 42 |
| 3 | Dismissing failures| PASS   |       |
| 4 | Hedging            | PASS   |       |
| 5 | Scope reduction    | WARN   | Dropped retry logic, acknowledged |
| 6 | False confidence   | PASS   |       |
| 7 | AI slop            | DEFER  | Running /de-slop |
| 8 | Weak assertions    | DEFER  | Running /tdd-assertions |
```

Use **PASS**, **FAIL**, **WARN** (acknowledged deviation), or **DEFER** (delegating to specialized skill).

### 3. Delegate to specialized skills

- **Item 7 (AI slop)**: If code was written or modified, invoke `/de-slop` on the changed files. Mark DEFER until results return, then update to PASS/FAIL.
- **Item 8 (Weak assertions)**: If test code was written or modified, invoke `/tdd-assertions` on test files. Mark DEFER until results return, then update to PASS/FAIL.
- **Pre-commit check**: If changes are staged, suggest `/diff` for smoke testing.

Only invoke these if the item is relevant — no code changes means items 7-8 are automatic PASS.

### 4. Auto-fix violations

For each FAIL:

- Fix the violation directly (remove sycophancy, finish incomplete work, strengthen assertions, etc.)
- Re-score the item after fixing
- If the fix requires significant rework, explain what changed

### 5. Final output

After fixes, output the updated scorecard with a one-line summary:

- **All PASS**: "Clean. Ready to ship."
- **Fixes applied**: "Fixed N violations. Review changes above."
- **Unresolvable**: "N items need user input." (explain what and why)

## What You Don't Do

- Refactor beyond removing the specific violation
- Add new tests — delegate to /tdd-assertions
- Rewrite working code for style preferences
- Expand scope of prior changes

## Gotchas

- Self-evaluating your own evaluation creates recursion — limit to one pass
- /de-slop and /tdd-assertions may not be available in sub-agent contexts
- Auto-fixing a violation can introduce a new one — re-check after each fix
- Not all checklist items apply to every response — skip items that don't match the task type
