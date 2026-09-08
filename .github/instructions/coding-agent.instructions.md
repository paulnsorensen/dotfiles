---
applyTo: "**"
excludeAgent: "code-review"
---

## Copilot Implementation Guidance

Use root `AGENTS.md` as the implementation policy. Read the applicable path-scoped instruction file before editing a matching path.

- Edit the declared source of truth, not generated Copilot output.
- Keep Copilot instruction files concise and preserve their YAML frontmatter.
- Keep renderer changes in `agent-profile/` with focused tests and the matching wiki update.
- Keep shared registry changes in `agents/` or `skills/` as the source map requires.
- Keep native Copilot configuration changes in `chezmoi/private_dot_copilot/`; native plugin declarations remain in `agents/plugins/registry.yaml`.
