# Serena retirement

Serena is no longer installed, configured, or exposed as an MCP in this dotfiles repository. Tilth is now the sole code-intelligence MCP; its symbol and caller queries replace Serena-specific routing and tool grants.[^1]

The removal also deletes the managed Serena package, chezmoi configuration, cleanup script, project-config skill, and Copilot template entry. Existing wiki references to Serena describe historical configurations and must not be treated as current routing guidance.[^2]

[^1]: agents/mcp/registry.yaml; agents/preamble.md; chezmoi/.chezmoidata/claude.yaml
[^2]: packages/packages.yaml; chezmoi/private_dot_copilot/mcp-config.json.tmpl; skills/serena-project-config/SKILL.md
