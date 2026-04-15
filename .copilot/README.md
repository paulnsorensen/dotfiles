# .copilot

Repository-local GitHub Copilot CLI material for this dotfiles repo.

## Supported structure

- `docs/` — human documentation and practical workflow notes.
- `mcp-config.json` — declarative Copilot CLI MCP configuration for this repo.
- `plugins/` — local Copilot plugin source trees, if this repo ever needs real plugin-native agents, skills, hooks, MCP, or LSP wiring.

## Current workflow

1. Edit `.copilot/mcp-config.json` for repo-managed MCP config.
2. Run `dots sync` to link it into `~/.copilot/mcp-config.json` via `.copilot/.sync`.
3. Inspect the repo copy with `copilot mcp list --config-dir .copilot` and `copilot mcp get --config-dir .copilot code-review-graph`.
4. Keep human guidance under `.copilot/docs/`.

## Boundaries

- Human docs do not belong in repo-level `skills/`, `agents/`, or `hooks/` folders.
- `tilth` is a companion CLI you run directly. This repo does not treat it as a Copilot plugin.
- If Copilot-native hooks, skills, or agents are needed later, add a real plugin under `.copilot/plugins/` and install it with `copilot plugin install <path>`.
