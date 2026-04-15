# Local Copilot plugins

Use this directory only when this repo needs a real GitHub Copilot CLI plugin.

Plugins are the supported surface for reusable Copilot-native components such as
agents, skills, hooks, MCP servers, and LSP servers.

This repo does not define a house plugin layout yet. If a local plugin is added
here later, follow the current Copilot CLI plugin requirements for that plugin
source tree.

Install a local plugin with:

```bash
copilot plugin install ./.copilot/plugins/my-plugin
copilot plugin list
```

Keep human guides under `../docs/` and repo-managed MCP config in
`../mcp-config.json`.
