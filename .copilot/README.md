# .copilot

Repository-local GitHub Copilot CLI material for this dotfiles repo.

## Supported structure

- `docs/` — human documentation and practical workflow notes.
- `mcp-config.json` — repo-managed Copilot CLI MCP template for this repo.

## Current workflow

Current MCPs: `code-review-graph`, `context7`, `tavily`.

1. Edit `.copilot/mcp-config.json` for repo-managed MCP definitions.
2. Set `CONTEXT7_API_KEY` and `TAVILY_API_KEY` in repo `.env` or your shell, then run `dots sync` to render `~/.copilot/mcp-config.json` via `.copilot/.sync`.
3. Inspect the rendered config with `copilot --config-dir ~/.copilot mcp list` and `copilot --config-dir ~/.copilot mcp get <server>`.
4. Keep human guidance under `.copilot/docs/`.

## Boundaries

- Human docs do not belong in repo-level `skills/`, `agents/`, or `hooks/` folders.
- `tilth` is a companion CLI you run directly. This repo does not treat it as a Copilot plugin.
- API-key-backed MCP entries are rendered into `~/.copilot/mcp-config.json` during sync; secrets stay out of the repo copy.
- If Copilot-native plugins are needed later, add one under `.copilot/plugins/` (create the directory then) and install with `copilot plugin install <path>`.
