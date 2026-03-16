---
applyTo: "claude/**"
---

## Claude Code Configuration

This directory contains all Claude Code configuration: skills, agents, hooks, MCP servers, and plugins.

### File Types

- `claude/skills/*/SKILL.md` — Skill definitions with YAML frontmatter (name, allowed-tools, model, description)
- `claude/agents/*.md` — Agent definitions with YAML frontmatter (skills list, model)
- `claude/hooks/*.js` — Pre-tool hooks (JavaScript, `module.exports` pattern)
- `claude/hooks/*.sh` — Lifecycle hooks (shell, runs at session events)
- `claude/mcp/registry.yaml` — MCP server registry (source of truth)
- `claude/plugins/registry.yaml` — Plugin registry
- `claude/settings.json` — Permissions, environment, hooks, enabled plugins

### Code Intelligence Tool Division

Three complementary tools — changes must respect their boundaries:

| Tool | Domain | Skill |
|---|---|---|
| ast-grep (`sg`) | Structural pattern matching (code shapes) | trace |
| Serena MCP | Semantic navigation (symbol lookup, cross-refs) | serena |
| LSP plugins | Type inference, diagnostics | lsp |

Do not attribute one tool's capabilities to another in descriptions or docs.

### Conventions

- Skills define their own `allowed-tools` — do not add tool permissions to `settings.json` for skill-gated tools
- Agent `skills:` arrays reference skill names, not tool names
- Hook filenames match their purpose: `block-*.js` for pre-tool enforcement, `post-*.sh`/`pre-*.sh` for lifecycle
- MCP changes go through `registry.yaml` + `mcp-sync`, never direct JSON editing
- All config syncs to `~/.claude/` via `dots sync` — the pre-commit hook verifies this
