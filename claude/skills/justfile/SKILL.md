---
name: justfile
description: >
  Create or migrate to a justfile (casey/just command runner) for any project.
  Use this skill when the user asks to add a justfile, replace a Makefile,
  set up project commands, create task runners, or mentions "just" in the
  context of build/dev workflows. Also trigger when you see a project with
  a Makefile that would benefit from just's simpler syntax, or when setting
  up a new project that needs common dev commands (build, test, lint, fmt).
  Covers Rust, Python, TypeScript/JavaScript, Go, and Ruby ecosystems.
  Do NOT use for CI pipeline configuration, Dockerfiles, or actual build system setup (cargo, webpack, etc.).
---

# justfile

Generate idiomatic justfiles for any project. Replace Makefiles and ad-hoc
shell scripts with a clean, discoverable command runner.

## Why just over Make

- No `.PHONY` hacks — all recipes are commands, not file targets
- No tab-indentation gotchas — any whitespace works
- First-class parameters, dotenv loading, OS detection, and modules
- `just --list` gives instant discoverability with doc comments
- Shebang recipes let you write Python/Ruby/Node inline

## Protocol

### 1. Detect the project

Scan the project root for ecosystem markers:

| File | Ecosystem | Reference |
|------|-----------|-----------|
| `Cargo.toml` | Rust | `references/rust.md` |
| `pyproject.toml`, `setup.py`, `uv.lock` | Python | `references/python.md` |
| `package.json` | TypeScript/JS | `references/typescript.md` |
| `go.mod` | Go | `references/go.md` |
| `Gemfile` | Ruby | `references/ruby.md` |

Read the relevant reference file for language-specific recipes.

If multiple markers exist (e.g., a Rust backend + TypeScript frontend), combine
patterns. Use modules (`mod frontend`, `mod backend`) for true monorepos.

**Multi-ecosystem naming:** When a project has multiple languages (e.g., Tauri
with Rust + TypeScript), use ecosystem suffixes to disambiguate overlapping
concerns:
- `test-rust`, `test-ts` (not generic `test` that hides what runs)
- `fmt-rust`, `fmt-ts` (each ecosystem's formatter)
- `lint-rust` (clippy), `lint-ts` (eslint/biome)
- Aggregate recipes combine them: `test: test-rust test-ts`, `fmt: fmt-rust fmt-ts`
- Shared recipes that span both ecosystems keep plain names: `dev`, `build`, `clean`

### 2. Check for existing build files

Look for `Makefile`, `Taskfile.yml`, `Rakefile`, `package.json` scripts, or
shell scripts in `scripts/` or `bin/`. If found:

- **Migrate**: Translate existing targets to just recipes (see migration table below)
- **Preserve**: Keep any complex logic that just can't replace (e.g., Make's
  file-target dependency tracking for actual build artifacts)
- **Remove**: Delete the old file only after confirming with the user

### 3. Write the justfile

Place `justfile` in the project root. Follow these conventions:

**Structure order:**
1. Settings (`set dotenv-load`, `set shell`, etc.)
2. Variables (version, binary name, etc.)
3. Default recipe (first recipe — either `default: check` or `@just --list`)
4. Core recipes grouped by concern: build, test, lint/fmt, run, deploy
5. Utility recipes (clean, docs, etc.)
6. Private helpers (`_prefixed` or `[private]`)

**Recipe naming:**
- Use kebab-case: `test-coverage`, `build-release`
- Use verbs: `build`, `test`, `lint`, `deploy` (not `builder`, `tests`)
- Group with prefixes for large files: `db-migrate`, `db-seed`, `db-reset`
- Default recipe should be the most common action or `--list`

**Doc comments:**
Every public recipe gets a comment on the line above it — this is what
`just --list` displays:

```just
# Run the full test suite
test *args:
    cargo test {{args}}
```

**Parameters:**
- Use defaults for optional args: `test filter=""`
- Use variadic for passthrough: `run *args`
- Use `+args` (1+ required) sparingly

**Settings to always include:**

```just
set dotenv-load := true
```

Add `set shell := ["bash", "-uc"]` only if recipes need bash-specific features
(arrays, process substitution). The default `/bin/sh` is fine for most recipes.

### 4. Update project docs

After creating the justfile:

**CLAUDE.md** — Add a "Key Commands" or "Common Tasks" section:
```markdown
## Key Commands

This project uses [just](https://github.com/casey/just) as its command runner.
Run `just` to see all available recipes.

- `just` — List all available commands
- `just test` — Run tests
- `just lint` — Run linters
- `just fmt` — Format code
```

Only list the 4-6 most important recipes. Point to `just --list` for the rest.

**README.md** — Add a "Development" or "Getting Started" section:
```markdown
## Development

### Prerequisites
- [just](https://github.com/casey/just) — `brew install just` / `cargo install just`

### Quick Start
```bash
just install   # Install dependencies
just test      # Run tests
just           # See all available commands
```
```

Don't duplicate the full recipe list — `just --list` is self-documenting.

## Makefile Migration Table

| Makefile | justfile |
|----------|----------|
| `.PHONY: target` | (not needed) |
| `$(VAR)` | `{{var}}` |
| `$(shell cmd)` | `` `cmd` `` |
| `-include .env` | `set dotenv-load := true` |
| `ifeq ($(OS),Darwin)` | `if os() == "macos" { ... }` |
| `ifndef VAR` / `$(or ...)` | `env_var_or_default("VAR", "default")` |
| `make -C subdir` | `mod subdir` |
| `$(MAKE) target` | `just target` |
| `.DEFAULT_GOAL := help` | First recipe is default |
| `@cmd` (suppress echo) | `@cmd` (same) |
| Tab indentation | Any whitespace |
| `%:` pattern rules | Not applicable — just has no file targets |

## Key Syntax Reference

**Variables:**
```just
VERSION := "1.0.0"
GIT_HASH := `git rev-parse --short HEAD`
DB_URL := env_var_or_default("DATABASE_URL", "postgres://localhost/dev")
OPEN := if os() == "macos" { "open" } else { "xdg-open" }
```

**Recipe attributes:**
```just
[confirm("Deploy to production?")]
deploy: build test

[macos]
open-docs:
    open target/doc/index.html

[linux]
open-docs:
    xdg-open target/doc/index.html

[private]
_setup:
    mkdir -p tmp/
```

**Modules (monorepo):**
```just
mod api        # looks for api/justfile or api.just
mod web
mod? local     # optional — no error if missing

# Usage: just api::test, just web::build
```

**Shebang recipes (multi-line scripts):**
```just
analyze:
    #!/usr/bin/env python3
    import json
    data = json.load(open("results.json"))
    print(f"Total: {len(data)}")
```

## Anti-patterns

- Don't recreate Make's file-target system — just is a command runner, not a build system
- Don't use `set positional-arguments` unless you have a strong reason — `{{arg}}` is clearer
- Don't put secrets in justfiles — use dotenv or env vars
- Don't write 200-line justfiles — use modules (`mod`) to split by concern
- Don't duplicate CI pipeline steps 1:1 — group them into meaningful recipes like `check` or `ci`

## What You Don't Do

- Design CI pipelines or GitHub Actions workflows
- Create Dockerfiles or container configs
- Replace actual build systems (cargo, webpack, go build) — just wraps them
- Remove existing Makefiles without user confirmation

## Gotchas

- `just` binary may not be on PATH — check with `which just` before generating recipes
- Shebang recipes need explicit `#!/usr/bin/env` for portability across systems
- `dotenv-load` exposes all env vars to all recipes — avoid for secrets-heavy projects
- Module paths are relative to the justfile location, not the working directory
- `set positional-arguments` changes how `$1` works inside recipes — document when used
