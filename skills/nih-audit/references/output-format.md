# Phase 4 Detail: Report Format

Build the full report in memory. Do NOT write to `$TMPDIR` or any file — return
everything inline in the summary response.

## Per-finding block

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

## Full report template

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

### Dependency Health
- Vulnerabilities: N (tools run: `npm audit`; skipped: `cargo audit` not installed)
- Possibly unused: N | Overweight: N | Stdlib-replaceable: N

| Dep | Issue | Calibration | Action |
|---|-------|-------------|--------|
| lodash | 0 imports in source | `<certain>` | Remove |
| axios | used for 2 GET calls | `<speculative>` | Replace with `fetch` |

### All Findings (sorted by score, descending)

| # | Score | P1 | P2 | Category | NIH Code | Replace With | Effort |
|---|-------|----|----|----------|----------|-------------|--------|
| 1 | 92 | 90 | 94 | UUID | src/utils/uuid.ts:12 | crypto.randomUUID() (stdlib) | S |
| 2 | 42 | 45 | 39 | COLOR | theme/generate.sh:68 | pastel (cargo) | S |

### Specs Consulted
- spec-name: <relevant finding or "no NIH justifications">

<detailed findings inline — one ### Finding block per candidate, ALL included>
```
