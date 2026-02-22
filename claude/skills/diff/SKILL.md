---
name: diff
model: haiku
allowed-tools: Bash(git diff:*), Bash(git status:*), Bash(git log:*), Bash(rg:*), Bash(sg:*), Bash(delta), Read
description: >
  Quick pre-commit smoke test of staged or unstaged changes. Scans for blockers
  (secrets, debug statements, commented code, silent failures) and warnings
  (oversized functions/files, deep nesting, domain leakage). Use when asked to
  review staged changes, run a pre-commit check, or when the /diff command is invoked.
---

# diff

Quick smoke test. Catch the obvious, skip the nitpicks.

## Protocol

### 1. Get the Diff

```bash
# Default: staged changes
git diff --staged

# If no staged changes, show unstaged
git diff

# If a ref is provided, diff against it
git diff {ref}
```

If there are no changes at all, say so and stop.

### 2. Scan for Red Flags

Check the diff for these categories only — in priority order:

**Blockers (must fix before commit):**
- Hardcoded secrets, API keys, tokens, passwords
- `console.log` / `print` / `fmt.Println` debug statements left in
- Commented-out code blocks (delete or keep, don't commit commented code)
- TODO/FIXME/HACK without a ticket reference
- Empty catch/except blocks (silent failures)
- Missing error handling on new I/O operations (file, network, DB)

**Warnings (worth a second look):**
- New dependencies added (pairs with block-install hook)
- Functions exceeding 40 lines
- Files exceeding 300 lines
- Nesting deeper than 3 levels
- Core model/domain files importing infrastructure

### 3. Report

If clean:
```
Staged changes look clean. {N} files, {additions}+/{deletions}-.
Ready to commit.
```

If issues found:
```
## Pre-commit Check: {N} files

### Blockers
- {file}:{line} — {issue}

### Warnings
- {file}:{line} — {issue}

{Blockers} must be fixed. {Warnings} are your call.
```

### 4. Do NOT

- Suggest refactoring
- Comment on style or formatting
- Flag patterns that are consistent with the codebase
- Recommend architectural changes
- Add docstrings or comments
- Run tests (that's a separate step)

This is a quick gate, not a code review. For thorough review, use `/review`.
