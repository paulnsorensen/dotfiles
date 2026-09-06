---
applyTo: "{agents,agent-profile,chezmoi,claude,skills}/**"
---

## Configuration Source Map

Use root `AGENTS.md` for repository policy and the source-of-truth table. Use the wiki pages named by the Copilot router for rationale.

- `agents/mcp/registry.yaml` owns shared MCP declarations.
- `agents/hooks/registry.yaml` owns shared hook declarations.
- `agents/registry.yaml` and `agents/agent_definitions/` own sub-agent metadata and bodies.
- `skills/_registry.yaml` and `skills/` own external and local skill sources.
- `claude/plugins/registry.yaml` owns Claude-native plugin declarations and `claude/` owns plugin content.
- `chezmoi/.chezmoidata/claude.yaml` owns Claude-native registry data.
- `chezmoi/.chezmoidata/codex.yaml` and `chezmoi/private_dot_codex/` own Codex configuration.
- `chezmoi/private_dot_copilot/` owns chezmoi-managed Copilot files.
- `agent-profile/` owns `ap` renderers and their tests.

Copilot renderer output uses `.github/agents/`, `.github/skills/`, and `.github/hooks/`. Treat those files as generated when `ap` creates them.

When a renderer changes output paths or behavior, update the matching wiki page and regression test in the same change. Use `dots sync` only for deployment after source edits.
