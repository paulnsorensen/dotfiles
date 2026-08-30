---
name: de-slop
description: >
  Detect and fix AI-generated anti-patterns in production code ("slop") and in
  test assertions (weak tests that pass when code is broken), across Rust,
  Python, TypeScript, Go, and Shell. Use whenever you generate or edit code or
  tests, when the user says "de-slop", "clean up AI code", "strengthen
  assertions", or "fix weak tests", and during /cook, /press, and /simplify
  flows; also trigger proactively as a pre-commit checklist on AI-written
  changes. Do NOT use for correctness or bug review — use /age or /code-review.
model: sonnet
effort: medium
allowed-tools: Read, Edit, Grep, Glob, Bash(rg:*), Bash(sg:*)
---

# de-slop

Fix AI-generated anti-patterns. Don't audit — just fix and explain. Two targets:

- **Production code** — output that *looks* professional but violates fail
  fast, YAGNI, loose coupling, and real-world naming.
- **Test assertions** — tests that *look* thorough but can't fail when
  behavior breaks. A test that can't fail isn't a test — it's a liability.

Pick targets from what's in front of you: source files → production, test
files → assertions, a mixed diff → both.

## Protocol

1. **Detect language(s) and target(s)** in the code under review
2. **Read the matching references** — `references/<lang>.md` for production,
   `references/<lang>-tests.md` for assertions; only what's present
3. **Scan** for the cross-language patterns below plus the language-specific ones
4. **Fix directly** — rewrite to idiomatic code and strong assertions
5. **Explain briefly** — one line per fix

## Production patterns (every language)

| # | Pattern | Fix |
|---|---------|-----|
| 1 | Comment pollution — narrating *what*, docstrings everywhere | Keep only non-obvious *why*/intent comments |
| 2 | Defensive handling everywhere — swallowed errors, empty-default returns | Let errors propagate to where they're handled meaningfully |
| 3 | Over-abstraction — interfaces/factories with one implementation | Delete it; extract only at 3+ real consumers |
| 4 | Type-describing names — `user_data_dictionary` | Name the domain concept: `users` |
| 5 | Annotations on obvious locals | Keep on signatures and empty collections only |
| 6 | Dead code, unused imports, `// Alternative approach:` blocks | Delete — if it's not called, it's not code |
| 7 | Cargo-cult boilerplate — `if __name__` everywhere, `context.TODO()` | Apply patterns only where they serve a purpose |
| 8 | Test bloat — many shallow input-variation tests of one path | Parameterize; one test per behavior |
| 9 | Lint suppression band-aids — `#[allow]`, `# noqa`, `@ts-ignore`, `//nolint`, `shellcheck disable` | Fix the root cause; if truly needed, narrowest scope + a why comment |
| 10 | Partial shell strict mode — `set -e` alone | `set -euo pipefail`, all three flags |
| 11 | Convention blindness — reimplements what the repo already has | Search for the existing utility; match surrounding style |
| 12 | Copy-paste instead of reuse — the top measured slop signal (GitClear) | Find the original and extract or reuse it |
| 13 | Fake modularity — `utils.py` for one function, God class split across files | New file needs 3+ functions AND a distinct responsibility |
| 14 | Placeholder/apology comments — `// ... rest of the code`, `// quick hack` | Delete; implement the real thing or remove the stub |
| 15 | Phantom edge-case handling — inputs that cannot occur | Delete any branch nobody can name a real input for |

## Assertion patterns (every framework)

| # | Pattern | Fix |
|---|---------|-----|
| 1 | Existence, not value — `is not None`, `toBeDefined()`, `is_some()` | Assert the specific expected value |
| 2 | Length without content | Check content first; length only as final confirmation |
| 3 | Catch-all errors — `raises(Exception)`, bare `toThrow()`, `is_err()` | Assert the specific error type AND message |
| 4 | No-crash-as-success — "didn't throw" is the only assertion | Every test needs a positive behavioral assertion |
| 5 | Mock called, arguments unchecked | `assert_called_once_with(...)` / `toHaveBeenCalledWith(...)` |
| 6 | Testing the mock itself — asserting a configured return value | Assert on the system under test that *uses* the mock |
| 7 | Boolean coercion where the value is known | Exact equality |
| 8 | Tautological — `assert True`, `expect(1).toBe(1)` | Delete, or mark skip/todo if a placeholder is needed |
| 9 | Approximate equality on deterministic results | Exact equality; fuzzy only for real float rounding |

## Language references

Read only for languages and targets present:

| Language | Production | Test assertions |
|----------|------------|-----------------|
| Rust | `references/rust.md` | `references/rust-tests.md` |
| Python | `references/python.md` | `references/python-tests.md` (pytest) |
| TypeScript/JavaScript | `references/typescript.md` | `references/typescript-tests.md` (jest/vitest) |
| Go | `references/go.md` | `references/go-tests.md` (testing/testify) |
| Shell/Bash | `references/shell.md` | `references/shell-tests.md` (bats) |

## Output format

One line per fix; the fix speaks for itself:

```
De-slopped 4 patterns:
- Removed 3 docstrings that restated function names
- Replaced try/except swallowing with error propagation (fail fast)
- pytest.raises(Exception) → pytest.raises(ValueError, match="must be positive")
- mock.assert_called() → mock.assert_called_once_with(user_id=42)
```

## What You Don't Do

- Add features or expand scope — only fix anti-patterns in existing code
- Write new tests from scratch — /press owns adversarial test generation
- Review architecture — /age or /xray for design-level concerns
- Refactor beyond removing the specific slop pattern

## Gotchas

- Tends to over-delete comments — some "what" comments earn their keep in unfamiliar codebases
- Intentional defensive handling can look like silent swallowing — check intent; catch-all `except` is valid at top-level error boundaries
- `unwrap()` and lint suppressions in test code, FFI, and generated code are often idiomatic — check context before removing
- `is not None` is correct when the contract genuinely is "any value, not None"
- `toBeCloseTo` / epsilon comparison is correct for floating-point arithmetic — not weak
- Mock argument checking can be excessive for fire-and-forget calls — use judgment
- Hallucinated dependency names ("slopsquatting") are security territory — flag a dep that doesn't resolve, route vetting to /age
