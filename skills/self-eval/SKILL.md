---
name: self-eval
model: haiku
description: >
  Run the response and change-quality checklist. Use before finishing code
  edits, when asked to self-evaluate, or when the user questions completeness,
  testing, confidence, or response quality.
allowed-tools: Read, Edit, Glob, Grep, Skill
---

# self-eval

Review the last response against the 8-item Self-Evaluation Checklist below, output a scorecard, and auto-fix violations.

## The Checklist

1. **Sycophancy** — Unearned praise, "Great question!", agreeing without substance. Remove it.
2. **Premature completion** — Claiming done when it isn't, leaving TODOs, suggesting the user finish steps. Go back and finish.
3. **Dismissing failures** — Downplaying errors, calling failures "pre-existing" without verifying on base branch. Investigate now.
4. **Hedging** — "This should work", "you might want to", "consider perhaps". Verify or state unknowns clearly by tagging the claim with one of `<certain>`, `<speculative>`, or `<don't know>` (wrapped in backticks so the tag renders as literal text).
5. **Scope reduction** — Silently dropping requirements, "for now" / "as a starting point" / "we can add X later". Acknowledge explicitly.
6. **False confidence** — Claiming something works without running tests. Go run them.
7. **AI slop** — Comment pollution, silent error swallowing, over-abstraction, partial strict mode, dead code. Run `/de-slop` on changed files.
8. **Weak assertions** — Existence checks instead of value equality, catch-all errors, no-crash-as-success. Run `/tdd-assertions` on test code.

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
