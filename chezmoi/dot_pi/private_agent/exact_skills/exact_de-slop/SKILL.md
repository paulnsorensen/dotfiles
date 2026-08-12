---
name: de-slop
description: >
  Detect and fix AI-generated code anti-patterns ("slop") across Rust, Python,
  TypeScript, Go, and Shell. Use whenever you generate or edit code, when the
  user says "de-slop", "clean up AI code", "remove AI slop", or during /simplify
  and /cook flows. Also trigger proactively as a pre-commit checklist on
  AI-written changes. Do NOT use for correctness or bug review — use /age or
  /code-review.
model: sonnet
effort: medium
allowed-tools: Read, Edit, Grep, Glob, Bash(rg:*), Bash(sg:*)
---

# de-slop

Fix AI-generated code anti-patterns. Don't audit — just fix and explain.

AI coding assistants pattern-match from training data full of beginner code,
tutorial examples, and over-documented libraries. The result is code that
*looks* professional but violates the engineering principles that matter:
fail fast, YAGNI, loose coupling, real-world naming.

This skill teaches you what to catch and how to fix it.

## When to apply

- **After generating code** — review your own output before presenting it
- **During /simplify** — run before and after the simplifier pass
- **In /cook** — part of the implementation hygiene checklist
- **Pre-commit** — prek hooks catch common slop in staged changes
- **On demand** — user says "de-slop", "clean up AI code", etc.

## Protocol

1. **Detect language** of the code being reviewed
2. **Read the relevant reference** from `references/` (only the languages present)
3. **Scan for patterns** — both cross-language and language-specific
4. **Fix directly** — rewrite the code to be idiomatic
5. **Explain briefly** — one line per fix, what changed and why

## Cross-Language Patterns

These apply to every language. They're the most common AI tells.

### 1. Comment pollution

AI explains *what* code does instead of *why*. Every function gets a docstring.
Every line gets a narration comment.

**Fix:** Delete comments that restate the code. Keep only comments that explain
non-obvious intent, business rules, or "why not the obvious approach."

### 2. Defensive error handling everywhere

Try/catch wrapping every operation, swallowing errors silently, returning
empty defaults instead of propagating failures.

**Fix:** Let errors propagate to where they can be handled meaningfully.
A function that returns `{}` on failure is worse than one that throws —
the caller silently gets corrupted data.

### 3. Over-abstraction

Abstract base classes, interfaces, factory functions, and plugin systems
for problems with exactly one concrete implementation.

**Fix:** Delete the abstraction. Write the concrete implementation directly.
Three similar lines of code is better than a premature abstraction. Extract
only when there are 3+ real consumers.

### 4. Verbose names that describe types, not domain

`user_data_dictionary`, `list_of_user_objects`, `current_item_being_processed`.
These names couple to the data structure and add noise.

**Fix:** Name after the domain concept: `users`, `items`, `user`.
A name should tell you what the thing *represents*, not what container it lives in.

### 5. Unnecessary type annotations

Annotating local variables where the type is immediately obvious from the
right-hand side. Function signatures deserve annotations; `const x: number = 5` doesn't.

**Fix:** Remove annotations where inference handles it. Keep them on function
signatures (they're the public contract) and where the inferred type would be
unclear.

### 6. Dead code and unused imports

AI imports entire module sets "just in case" and leaves commented-out
alternative implementations.

**Fix:** Delete unused imports and dead code. No `// Alternative approach:`
blocks. If it's not called, it's not code.

### 7. Cargo-cult boilerplate

Patterns copied without understanding: `if __name__ == "__main__":` in every
Python file, `"use strict"` in TypeScript, `context.TODO()` in non-concurrent
Go paths.

**Fix:** Remove boilerplate that serves no purpose in context. Apply patterns
only where they're needed.

### 8. Test bloat

AI generates many shallow tests covering the same code path with slightly
different inputs ("write empty bytes succeeds", "write binary data succeeds",
"write special characters succeeds" — all testing the same thing).

**Fix:** Consolidate into parameterized tests. One test per behavior, not one
test per input variation. 35 tests for a 119-line implementation is a smell —
aim for focused tests that cover actual edge cases and error paths.

### 9. Lint suppression as band-aid

AI silences compiler/linter warnings with suppression comments instead of fixing
the underlying issue: `#[allow(dead_code)]`, `# noqa`, `// @ts-ignore`,
`//nolint`, `// eslint-disable`.

**High-confidence smells (almost always slop):**

- Rust: `#[allow(clippy::unwrap_used)]`, `#[allow(clippy::dbg_macro)]`, `#[allow(clippy::print_stdout)]`, `#[allow(clippy::panic)]`, `#[allow(clippy::todo)]`
- Python: `# noqa: E501` (line too long), `# pylint: disable=missing-docstring`
- TypeScript: `// @ts-ignore` (error suppression without `@ts-expect-error`)
- Go: `//nolint` (generic suppression without specific lint name)
- Shell: `# shellcheck disable=SCxxxx` (broad suppression instead of fixing the script)

**Fix:** Remove the suppression, read the warning, fix the root cause. If the
suppression is truly needed, scope it narrowly and add a comment explaining why.
See language references for specific patterns (Rust has the deepest taxonomy).

### 10. Partial strict mode in shell scripts

AI writes `set -e` but omits `-u` (undefined variables) and `-o pipefail`
(pipeline error propagation). This is especially dangerous in scripts that
pipe through `jq`/`yq`/`grep` — a failure in the left side of the pipe is
silently ignored.

**Fix:** Always use `set -euo pipefail` in bash scripts. All three flags
together. `set -e` alone is a half-measure.

### 11. Convention blindness

AI reimplements what the repo already has (HTTP wrappers, utils, config
mechanisms) and applies textbook idioms instead of the codebase's own —
generic from-scratch solutions in a codebase that already solved the problem.

**Fix:** Search the repo for an existing utility/convention before writing a
new one. Match the surrounding style, not a generically "correct" one.

### 12. Copy-paste instead of reuse

The same logic reimplemented slightly differently across files — the model
can't see the original past its context window. The biggest measured shift in
AI-assisted code: duplicated lines overtook refactored/moved lines in commits
for the first time in 2024 (GitClear, 211M-line dataset).

**Fix:** Before adding similar logic, find the existing implementation and
extract or reuse it. Rising duplication is the primary quantitative slop signal.

### 13. Fake modularity

A new `utils.py`/`helpers.ts` created for a single function, or a God class
spread across several files — structure that looks decomposed but doesn't
separate concerns (the "modular mirage").

**Fix:** A new file needs 3+ functions AND a distinct responsibility.
Otherwise the function goes in the file that uses it.

### 14. Placeholder and apology comments

Prompt residue left in committed code: `// ... rest of the code`,
`// quick hack, good enough for now`, `// Replace this with your actual
implementation`, `// In a real implementation ...`.

**Fix:** Delete them — implement the real thing or remove the stub. These are
directly greppable, the highest-precision AI tell.

### 15. Phantom edge-case handling

Code handling inputs that cannot occur, inflating complexity for near-zero
risk reduction. Distinct from #2 — that's swallowing real errors; this is
handling imaginary ones.

**Fix:** Require a concrete failure scenario before keeping an edge-case
branch. If nobody can name the input that reaches it, delete it.

## Language References

Read these only for languages present in the code being reviewed:

| Language | Reference |
|----------|-----------|
| Rust | `references/rust.md` |
| Python | `references/python.md` |
| TypeScript/JavaScript | `references/typescript.md` |
| Go | `references/go.md` |
| Shell/Bash | `references/shell.md` |

## Output format

When fixing code, explain each change concisely:

```
De-slopped 4 patterns:
- Removed 3 docstrings that restated function names
- Replaced try/except swallowing with error propagation (fail fast)
- Deleted unused imports (os, sys, logging)
- Renamed `user_data_dictionary` → `users`
```

Don't over-explain. The fix speaks for itself.

## What You Don't Do

- Add features or expand scope — only fix anti-patterns in existing code
- Write tests — delegate to /press or /tdd-assertions
- Review architecture — use /age or /xray for design-level concerns
- Refactor beyond removing the specific slop pattern

## Gotchas

- Tends to over-delete comments — some "what" comments are needed in unfamiliar codebases
- May flag intentional defensive error handling as "silent swallowing" — check intent before removing
- Language reference files must be read before fixing — patterns differ across languages
- `unwrap()` in Rust test code is idiomatic, not slop — only flag in production code
- Lint suppressions in FFI, generated code, and `#[cfg(test)]` are often legitimate — check context before removing
- `#[allow(clippy::pedantic)]` at crate level is a style choice, not slop

- Hallucinated dependency names ("slopsquatting") are security territory — flag a new dep that doesn't resolve in the registry, but route vetting to /age or a security review

## Sources

- GitClear "AI Copilot Code Quality" 2025 — the only primary empirical dataset (211M lines): duplication vs refactor trends
- OX Security "Army of Juniors" (2025) — 10-pattern taxonomy from a 300+-repo review (vendor research)
- sloplint + slop-guard (GitHub) — encodable ast-grep rules for comment and file-proliferation slop
- Per-language lint taxonomies backing the reference files: clippy, ruff, typescript-eslint, ShellCheck
