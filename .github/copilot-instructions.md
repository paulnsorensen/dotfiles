# Copilot Instructions

Copilot uses this file for repository-wide routing. It also reads root `AGENTS.md` and applicable files under `.github/instructions/`.

Treat root `AGENTS.md` as the repository policy and source-ownership authority. Do not copy its policy into this file. Do not override it with generic application guidance.

## Start here

- Read `AGENTS.md` before changing configuration, harness wiring, registries, `ap`, chezmoi, or sync behavior.
- Read `.hallouminate/wiki/harnesses/copilot.md` for Copilot behavior and native configuration.
- Read `.hallouminate/wiki/harnesses/index.md` for cross-harness source and output mapping.
- Read `.hallouminate/wiki/architecture/agents-dir.md` for shared registry ownership.
- Read `.hallouminate/wiki/architecture/agent-profile.md` for `ap` renderer behavior.
- Read `.hallouminate/wiki/operations/sync-and-chezmoi.md` for deployment behavior.

## Edit source, not output

- Shared MCP, hook, agent, and skill sources live in `agents/` and `skills/`.
- Copilot agent, skill, and hook output lives under `.github/` when a renderer creates it.
- Copilot MCP defaults live in `chezmoi/private_dot_copilot/mcp-config.json.tmpl`; runtime state remains user-owned.
- Renderer behavior lives in `agent-profile/`; renderer tests live beside that package.
- Claude-native configuration data lives in `chezmoi/.chezmoidata/claude.yaml`.

Use the source-of-truth table in `AGENTS.md` for every edit. Regenerate and deploy through the documented command instead of hand-editing rendered output.

## Copilot-specific guidance

- Keep repository-wide Copilot guidance here and path-specific guidance in `.github/instructions/*.instructions.md`.
- Preserve each instruction file's YAML frontmatter and `applyTo` glob.
- Copilot has no isolated closed-world launcher in this repository. Do not claim that it provides one.
- Keep changes concise because Copilot combines these files with `AGENTS.md` and other instruction layers.
