# Copilot Instructions

## Repository Context

This is a personal dotfiles repository for a macOS developer environment. It configures zsh shell, iTerm2, VS Code, git, and Claude Code integration. It is NOT an application or library — do not apply generic software patterns.

## Engineering Principles

1. **Fail Fast and Loud** — Scripts must exit on error. No silent failures, no empty catch blocks.
2. **Idempotent** — Every script must be safe to run multiple times without side effects.
3. **YAGNI** — No abstractions without immediate need. One user, no backward compatibility.
4. **Immutable Patterns** — Prefer pure functions; avoid shared mutable state.
5. **Loose Coupling** — Configuration modules are independent. Claude skills, agents, and hooks don't cross-import.

## Complexity Budget

- **Functions**: Maximum 40 lines
- **Files**: Maximum 300 lines
- **Parameters**: Maximum 4 per function
- **Nesting**: Maximum 3 levels deep

## Code Style

- **Classes**: PascalCase
- **Functions**: snake_case (Python) / camelCase (JS)
- **Constants**: SCREAMING_SNAKE_CASE
- **Files**: kebab-case
- **Commits**: Conventional Commits format (`feat:`, `fix:`, `chore:`)

## Architecture

```
dotfiles/
  bin/          CLI tools (dots command)
  claude/       Claude Code config (agents, commands, hooks, skills, MCP)
  zsh/          Modular shell config files (sourced by zshrc)
  .github/      Copilot and workflow config
```

- `zsh/` files are sourced in order defined by `zshrc` — ordering matters
- `claude/skills/` are self-contained — each has its own SKILL.md with allowed-tools
- `claude/agents/` reference skills by name in their frontmatter
- Claude config syncs to `~/.claude/` via `dots sync`

## Tech Stack

- **Shell**: zsh (macOS), shellcheck for linting
- **Package Manager**: Homebrew (packages in `.brew`)
- **Claude Code**: Skills, agents, hooks, MCP servers
- **Testing**: bats (shell tests via `dots test`)
- **Sync**: `.sync-with-rollback` with backup/manifest tracking

## Build and Test

- `dots sync` — Sync dotfiles (symlinks, Homebrew, fonts) with rollback
- `dots test` — Run test suite (validates shell loading, git hooks, symlinks, Claude config sync)
- `shellcheck bin/* .sync .sync-with-rollback` — Lint shell scripts
- `mcp-sync` — Sync MCP servers from registry.yaml
- `plugin-sync` — Sync plugins from registry.yaml

## What NOT to Do

- Do not suggest Docker, CI/CD pipelines, or deployment workflows
- Do not add backward-compatibility layers — one user, no production data
- Do not create abstract base classes, factories, or plugin registries
- Do not suggest unit tests for shell aliases or simple config files
- Do not add `#!/usr/bin/env bash` to `.zsh` files (they are sourced, not executed)
- Do not wrap single-use logic in helper functions
