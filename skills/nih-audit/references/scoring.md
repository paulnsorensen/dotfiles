# Phase 4 Detail: Confidence Scoring and Effort Sizing

For each candidate with a library recommendation, apply the full 4-step chain.

## Step 1: Classify the finding type

| Type | Base | Cap | When |
|------|------|-----|------|
| REPLACE_WITH_STDLIB | 55 | 100 | stdlib function does the same thing |
| REPLACE_WITH_MICRO_LIB | 45 | 95 | small focused library (<5 deps) |
| REPLACE_WITH_FRAMEWORK | 35 | 85 | large framework (lodash, Django, etc.) |
| EXTRACT_TO_EXISTING_DEP | 50 | 95 | already-installed dep has this feature |

## Step 2: Evidence grounding

| Evidence | Modifier |
|----------|----------|
| Serena-verified usage count (exact caller list) | +15 |
| Library has >10K weekly downloads + MIT/Apache | +20 |
| ast-grep pattern match + code read confirms NIH | +15 |
| NIH code has recent bug fixes (git blame) | +10 |
| NIH code >100 LOC for what library does in 1 call | +10 |
| Generic pattern match, code does more than pattern suggests | -15 |
| Recommended library is unmaintained (last commit >1yr) | hard cap at 40 |

## Step 3: Context modifiers

These include the Phase 3 spec/roadmap modifiers:

| Signal | Modifier |
|--------|----------|
| Spec explicitly chose NIH | -30 |
| Code comment explains NIH choice | -20 |
| Library covers planned spec features | +10 |
| No spec or comment context | +0 |
| NIH code is in a git hotspot (many recent changes) | +10 |
| NIH code is isolated (1 file, clear boundary) | +5 |
| NIH code is deeply coupled (referenced from >10 files) | -5 |

## Step 4: Second independent scoring pass

For EVERY candidate (not just borderlines):

1. Clear your mental state — do not look at the first score
2. Re-read the NIH code and the library's API fresh
3. Score independently using the same steps 1-3
4. Report BOTH scores in the finding (Pass 1: NN, Pass 2: NN)
5. Final score = average of both passes
6. If scores diverge by >20 points, flag as "ambiguous" but still include

## Effort Sizing

| Criteria | Size |
|----------|------|
| 1 file, <50 LOC, <=3 call sites | **S** |
| 2-5 files, <200 LOC, <=10 call sites | **M** |
| >5 files, >200 LOC, or >10 call sites | **L** |
