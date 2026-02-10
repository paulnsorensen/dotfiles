---
name: copilot-setup
description: Generate GitHub Copilot agent and review instructions for a repository, aligned with your architectural principles.
argument-hint: "[repo path or leave blank for current directory]"
---

Generate GitHub Copilot configuration files for the current repository. These files instruct both the Copilot coding agent and code review agent to follow our engineering principles and project conventions.

## Instructions

### 1. Detect Project Type

Check for indicator files in the project root:

| Indicator | Type | Language Extensions |
|-----------|------|---------------------|
| `package.json` | node | `*.ts`, `*.tsx`, `*.js`, `*.jsx` |
| `pyproject.toml` or `setup.py` or `uv.lock` | python | `*.py` |
| `Cargo.toml` | rust | `*.rs` |
| `go.mod` | go | `*.go` |
| `Gemfile` | ruby | `*.rb` |
| `.brew` or `zshrc` or `zsh/` dir | dotfiles | `*.sh`, `*.zsh` |

A project can match multiple types. If none match, generate only the global instructions.

### 2. Detect Existing Tooling

Check for these and note which are present (used to tell code review what CI already handles):

| File/Config | Tool |
|-------------|------|
| `.eslintrc*` or `eslint.config.*` | ESLint |
| `.prettierrc*` or `prettier.config.*` | Prettier |
| `ruff.toml` or `[tool.ruff]` in pyproject.toml | Ruff |
| `mypy.ini` or `[tool.mypy]` in pyproject.toml | mypy |
| `rustfmt.toml` or `.rustfmt.toml` | rustfmt |
| `clippy.toml` or `.clippy.toml` | Clippy |
| `.golangci.yml` or `.golangci.yaml` | golangci-lint |
| `.rubocop.yml` | RuboCop |
| `shellcheck` in any CI config | ShellCheck |

### 3. Check for Existing Files

Before writing, check if `.github/copilot-instructions.md` or any `.github/instructions/*.instructions.md` files already exist. If they do, **ask the user** whether to overwrite or skip.

### 4. Create Directory Structure

Ensure `.github/instructions/` directory exists.

### 5. Generate Global Instructions

Write `.github/copilot-instructions.md` with the content below. Adapt the tech stack and build/test commands sections based on what you detected in the project (read `package.json` scripts, `pyproject.toml` scripts, `Makefile` targets, `Cargo.toml`, etc.).

```markdown
# Copilot Instructions

## Engineering Principles

1. **Input Validation** - Trust nothing from external sources. Validate at system boundaries (user input, external APIs, file I/O). Internal code trusts internal code.
2. **Fail Fast and Loud** - Handle errors where they occur. No silent failures, no swallowed exceptions, no empty catch blocks. If something fails, the caller should know immediately.
3. **Loose Coupling** - Separate business logic from infrastructure. Core models and domain logic must not import HTTP frameworks, ORMs, or I/O libraries. Use dependency injection or protocols/interfaces at boundaries.
4. **YAGNI** - Build only what is needed now. No abstract base classes with one implementation, no plugin systems with one plugin, no configuration options that are never varied. If it is needed later, it can be written later.
5. **Real-World Models** - Name things after business concepts, not technical abstractions. `Order`, not `DataProcessor`. `PricingRule`, not `StrategyHandler`.
6. **Immutable Patterns** - Minimize state mutation. Prefer pure functions, return new values instead of mutating arguments, use immutable data structures where the language supports them.

## Complexity Budget

- **Functions**: Maximum 40 lines
- **Files**: Maximum 300 lines
- **Parameters**: Maximum 4 per function
- **Nesting**: Maximum 3 levels deep

If a function or file exceeds these limits, decompose it.

## Code Style

- **Classes**: PascalCase
- **Functions**: snake_case (Python, Ruby, Rust) / camelCase (JS/TS, Go exported)
- **Constants**: SCREAMING_SNAKE_CASE
- **Files**: kebab-case
- **Commits**: Conventional Commits format (`feat:`, `fix:`, `chore:`, etc.)

## Architecture

Follow vertical slice architecture:
- Each domain concept gets its own module/directory
- Public API is exposed through an index/barrel file only
- Do not reach into another slice's internals — import from its public API
- Core models stay pure: no ORM decorators, no framework imports, no I/O
- `common/` or `shared/` is a leaf — it imports nothing from sibling domains
- One-directional dependencies only; use events for reverse communication

**Growth pattern:**
1. Start with one file per concept
2. Extract a sibling file when the original gets crowded
3. When a file needs helpers, it becomes a facade with a subdirectory

## What NOT to Do

- Do not add docstrings to private methods or small helpers with clear names
- Do not create abstract base classes, factories, or registries unless there are multiple concrete implementations today
- Do not add error handling for conditions that cannot occur in the current system
- Do not add backwards-compatibility shims — change the code directly
- Do not wrap functions that add no logic — call the original directly
- Do not add type annotations to every local variable — annotate function signatures and let inference handle the rest

## Tech Stack

{REPLACE_WITH_DETECTED_STACK}

## Build, Test, and Lint Commands

{REPLACE_WITH_DETECTED_COMMANDS}
```

Replace the `{REPLACE_WITH_DETECTED_STACK}` and `{REPLACE_WITH_DETECTED_COMMANDS}` placeholders with actual values discovered from the project. If you cannot determine them, remove those sections entirely rather than guessing.

### 6. Generate Code Review Instructions

Write `.github/instructions/code-review.instructions.md`:

```markdown
---
applyTo: "**"
excludeAgent: "coding-agent"
---

## Code Review Focus

Focus reviews on these categories, in priority order:

1. **Security** - Flag hardcoded secrets, SQL injection, XSS, command injection, path traversal, and insecure deserialization
2. **Silent failures** - Flag empty catch blocks, swallowed errors, missing error propagation, or functions that return null/undefined on failure without signaling
3. **Coupling violations** - Flag domain/model code that imports infrastructure (HTTP, DB, file I/O, framework decorators)
4. **Complexity violations** - Flag functions over 40 lines, files over 300 lines, functions with more than 4 parameters, nesting deeper than 3 levels
5. **Architectural violations** - Flag cross-slice internal imports, mutable shared state, God classes/modules

## What NOT to Comment On

{REPLACE_WITH_CI_TOOLS_LIST}
- Import ordering — handled by tooling
- Formatting and whitespace — handled by tooling
- Missing docstrings on internal or private functions
- Style preferences that are consistent with the rest of the codebase
- Nitpicks with no functional impact

## Review Style

- Only comment when confidence is high
- If a pattern is used consistently elsewhere in the codebase, do not flag it as wrong
- Suggest specific fixes, not vague improvements
- One comment per issue — do not repeat the same feedback on multiple occurrences
```

Replace `{REPLACE_WITH_CI_TOOLS_LIST}` with lines like `- Linting — handled by ESLint in CI` for each tool detected in step 2. If no tools were detected, remove that placeholder and keep the generic lines.

### 7. Generate Language-Specific Instructions

For each detected project type, generate a corresponding instructions file:

**Python** → `.github/instructions/python.instructions.md`:
```markdown
---
applyTo: "**/*.py"
---
- Use type hints on all function signatures and return types
- Use `uv` for dependency management, not pip directly
- Use pytest for tests, not unittest
- Use Ruff for linting and formatting
- Prefer dataclasses or Pydantic models over raw dicts for structured data
- Use `from __future__ import annotations` for forward references
- Raise specific exceptions, never bare `raise` or `raise Exception`
```

**Node/TypeScript** → `.github/instructions/typescript.instructions.md`:
```markdown
---
applyTo: "**/*.{ts,tsx,js,jsx}"
---
- Use TypeScript strict mode
- Prefer `interface` over `type` for object shapes that may be extended
- Use `const` by default, `let` only when reassignment is necessary, never `var`
- Prefer named exports over default exports
- Use async/await over raw Promises or callbacks
- Handle errors explicitly — no unhandled promise rejections
- Prefer immutable array methods (map, filter, reduce) over mutating loops
```

**Rust** → `.github/instructions/rust.instructions.md`:
```markdown
---
applyTo: "**/*.rs"
---
- Use `thiserror` for library errors, `anyhow` for application errors
- Prefer `impl Trait` in argument position over generics when there is one caller
- Use `clippy::pedantic` level lints
- Prefer owned types in public APIs unless borrowing is clearly beneficial
- Use `#[must_use]` on functions that return values meant to be consumed
```

**Go** → `.github/instructions/go.instructions.md`:
```markdown
---
applyTo: "**/*.go"
---
- Always handle errors — never use `_` to discard an error
- Use table-driven tests
- Prefer returning errors over panicking
- Use context.Context as the first parameter for functions that do I/O
- Keep interfaces small — one or two methods
- Define interfaces where they are used, not where they are implemented
```

**Shell/Dotfiles** → `.github/instructions/shell.instructions.md`:
```markdown
---
applyTo: "**/*.{sh,zsh,bash}"
---
- Use `set -euo pipefail` at the top of scripts
- Quote all variable expansions: `"$var"`, not `$var`
- Use `[[ ]]` over `[ ]` for conditionals
- Use functions for any logic that repeats or exceeds 10 lines
- Use `local` for function variables
- Prefer `printf` over `echo` for portable output
```

Only generate files for detected project types. Do not generate language files for types not present.

### 8. Generate Coding Agent Instructions

Write `.github/instructions/coding-agent.instructions.md`:

```markdown
---
applyTo: "**"
excludeAgent: "code-review"
---

## Coding Agent Guidelines

When implementing changes:

- Read existing code before modifying it — understand the patterns in use
- Follow the existing code style of the file you are editing
- Keep changes minimal and focused on the issue at hand
- Do not refactor surrounding code unless the issue requires it
- Do not add docstrings to helper functions or private methods with clear names
- Do not introduce new dependencies without explicit approval
- Write tests for new functionality — match the existing test patterns in the project
- Prefer editing existing files over creating new ones

## Architecture Rules

- New domain concepts go in their own module under the appropriate domain directory
- Public API is exposed through index/barrel files only
- Do not create abstract classes, interfaces, or factories unless there are 2+ concrete implementations
- Core models must not import infrastructure code
```

### 9. Update .gitattributes (Optional)

If `.gitattributes` does not already exist, ask the user if they want one created with `linguist-generated` markers for generated files.

### 10. Print Summary

After writing all files, print a summary:

```
Copilot configuration generated:
  Project types detected: python, node
  CI tools detected: ESLint, Prettier, Ruff
  Files created:
    .github/copilot-instructions.md          (global)
    .github/instructions/code-review.instructions.md
    .github/instructions/coding-agent.instructions.md
    .github/instructions/python.instructions.md
    .github/instructions/typescript.instructions.md
```
