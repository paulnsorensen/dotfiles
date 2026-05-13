---
name: lint
model: haiku
description: >
  Run project linters (shellcheck, yamllint, jsonlint, prettier, eslint, clippy, etc.)
  and report findings. Use when the user says "lint", "check code quality", "run linters",
  "lint shell scripts", or wants to validate syntax/style in a project.
  Supports multi-language projects: shell, YAML, JSON, TOML, JavaScript, Python, Rust.
  Aggregates findings into a summary report with file/line references for easy fixing.
---

# lint

Run all configured linters in a project and report findings grouped by category.

## Capabilities

This skill:

- **Detects available linters** from `prek.toml`, `eslintrc`, `pylintrc`, `.shellcheckrc`, etc.
- **Runs linters** appropriate to changed files (shellcheck for .sh, yamllint for .yaml, etc.)
- **Aggregates findings** into a structured report
- **Suggests fixes** for common issues (trailing whitespace, formatting, security)
- **Respects exclusions** from `.gitignore` and linter config

## When to Use

- Before committing: `just lint` or `/lint`
- CI/CD validation: integrate into pipeline
- Code review: spot-check style/security issues
- Post-generation: clean up AI-generated code

## Protocol

### 1. Detect the Project

Scan for linter configuration files:

| File | Linter | Scope |
|------|--------|-------|
| `prek.toml` | prek (multi-tool) | Built-in hooks: trailing-whitespace, YAML, JSON, TOML, shellcheck |
| `.shellcheckrc` | shellcheck | Shell scripts (.sh, .zsh, .bash) |
| `.yamllint` | yamllint | YAML files (.yaml, .yml) |
| `eslintrc.json`, `.eslintrc.cjs` | eslint | JavaScript/TypeScript |
| `pyproject.toml` (tool.pylint) | pylint | Python |
| `Cargo.toml` (clippy config) | clippy | Rust |
| `.editorconfig` | editorconfig-checker | General formatting |

### 2. Run Linters

**Priority order** (fail fast if core linters fail):

1. **Syntax checks** (JSON, YAML, TOML, shell syntax)
2. **Built-in linters** (prek hooks, shellcheck, yamllint)
3. **Language-specific linters** (eslint, clippy, pylint)
4. **Formatters** (prettier, black, rustfmt —check only, don't auto-fix)

**Filtering:**

- Run only linters that match file types changed (e.g., only shellcheck for .sh files)
- Skip linters with missing config files (unless they're built-in)
- Respect `.gitignore` and linter exclusions

### 3. Report Findings

Group findings by linter and severity:

```
📋 LINT REPORT

❌ Critical (must fix):
  shellcheck (zsh/core.zsh:42):
    SC2155: Declare and assign separately
    Fix: export VAR=$(cmd) → export VAR; VAR=$(cmd)

⚠️  Warnings (should fix):
  yamllint (prek.toml:8):
    line-length: line too long (105 > 100)

✅ Passed:
  JSON validation
  TOML syntax
  Trailing whitespace
```

**Report structure:**

- File path and line number for each finding
- Linter name and error code (for searching solutions)
- Plain English description of the issue
- Suggested fix (when obvious)
- Summary counts: Critical, Warning, Passed

### 4. Exit Codes

- `0` — All linters passed
- `1` — Warnings found (non-blocking)
- `2` — Errors found (blocking)

## Common Recipes (for justfile)

```just
# Run all linters
lint:
    /lint

# Run linters and auto-fix where possible
lint-fix:
    shellcheck --fix **/bin/* || true
    prettier --write . || true
    black . || true
    cargo clippy --fix || true

# Strict lint (fail on warnings)
lint-strict:
    /lint --strict
```

## Anti-patterns

- Don't auto-fix without user approval (report first, suggest fixes)
- Don't run formatters (prettier, black) that change files — use check-only mode
- Don't ignore security findings from shellcheck (SC2115, etc.)
- Don't suppress linter warnings with comments — fix the underlying issue
- Don't run linters on vendored code or generated files
