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
- Prefer editing existing files over creating new ones

## Dotfiles-Specific Rules

- Shell scripts must use `set -euo pipefail` at the top
- Quote all variable expansions: `"$var"`, never bare `$var`
- New zsh config files must be sourced from `zshrc` at the correct load order point
- New Claude skills go in `claude/skills/<name>/SKILL.md` with frontmatter
- New Claude agents go in `claude/agents/<name>.md` with frontmatter
- New MCP servers go in `claude/mcp/registry.yaml`, not hardcoded JSON
- Run `dots sync` after any changes to files that get symlinked to `~/.claude/`

## Architecture Rules

- Claude skills are self-contained — each defines its own `allowed-tools`
- Skills reference tools by their correct domain (trace for ast-grep, scout for rg/fd, serena for symbols)
- Hooks are JavaScript (pre-tool) or shell (lifecycle) — do not mix
- `common/` is a leaf — it imports nothing from siblings
