# GitHub Copilot CLI

GitHub's coding-agent CLI. Config lives under `~/.copilot/` and (project-scoped) `.github/`. Docs root: [docs.github.com/en/copilot](https://docs.github.com/en/copilot/how-tos/copilot-cli).

`ap`'s copilot renderer (`renderers/copilot.py`) writes project-scoped agent/skill/hook artifacts under `.github/` and merges MCP servers into `~/.copilot/mcp-config.json`. The MCP config is also templated by chezmoi (`private_dot_copilot/mcp-config.json.tmpl`, env-rendered API keys).

## Capabilities, docs, and repo wiring

| Capability | Official doc | This repo |
|---|---|---|
| Hooks | <https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-hooks> | `agents/hooks/registry.yaml` → `.github/hooks/<n>.json` (when copilot is in the hook's `harnesses`). |
| Sub-agents | <https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/create-custom-agents-for-cli> | `agents/registry.yaml` → `.github/agents/<n>.agent.md`. Model overrides ignored. |
| MCP | <https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-mcp-servers> | `agents/mcp/registry.yaml` → `~/.copilot/mcp-config.json` (`mcpServers` schema; stdio/HTTP/SSE). |
| System prompt / instructions | <https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-custom-instructions> | Repo-wide `.github/copilot-instructions.md`, plus path-specific / agent / `AGENTS.md`. (The repo's `agents/preamble.md` wiring targets Claude/Codex/opencode; Copilot reads `AGENTS.md`.) |
| Settings / config | <https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference> | `~/.copilot/` layout + `settings.json`. (`config.json` holds auto-managed trusted-folders/permissions — see [configure-copilot-cli](https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/configure-copilot-cli).) |
| Skills | <https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-skills> | `skills/` → `.github/skills/<n>/`. Copilot reads `.github/skills`, `.claude/skills`, `.agents/skills`, or `~/.copilot/skills`. |

## Isolated settings

Not available. Copilot CLI has no closed-world launch flags; `ap` isolated launches are Claude-only.

## Quirks

- Skill/agent/hook artifacts are **project-scoped** (`.github/`), unlike the other harnesses' user-scoped (`~/.<harness>/`) deploys — so they land per-repo.
- Copilot resolves skills from multiple roots including `.claude/skills` and `.agents/skills`, so some shared skill dirs are picked up without a Copilot-specific copy.
