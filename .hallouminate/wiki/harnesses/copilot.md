# GitHub Copilot CLI

GitHub's coding-agent CLI. Config lives under `~/.copilot/` and (project-scoped) `.github/`. Docs root: [docs.github.com/en/copilot](https://docs.github.com/en/copilot/how-tos/copilot-cli).

`ap`'s copilot renderer (`renderers/copilot.py`) writes project-scoped agent/skill/hook artifacts into a `.github/` layout. It no longer mutates live `~/.copilot/mcp-config.json`; durable MCP defaults belong to the chezmoi template (`private_dot_copilot/mcp-config.json.tmpl`, env-rendered API keys) or Copilot's own runtime state.

## Capabilities, docs, and repo wiring

| Capability | Official doc | This repo |
|---|---|---|
| Hooks | <https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-hooks> | `agents/hooks/registry.yaml` → `.github/hooks/<n>.json` (when copilot is in the hook's `harnesses`). |
| Sub-agents | <https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/create-custom-agents-for-cli> | `agents/registry.yaml` → `.github/agents/<n>.agent.md`. Model overrides ignored. |
| MCP | <https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-mcp-servers> | Chezmoi template / user-owned `~/.copilot/mcp-config.json` (`mcpServers` schema; stdio/HTTP/SSE). `agents/mcp/registry.yaml` still feeds isolated/profile renders where a renderer owns the target, but non-isolated `ap install global` does not mutate this live file. |
| System prompt / instructions | [precedence](https://docs.github.com/en/copilot/concepts/prompting/response-customization) · [how-to](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-custom-instructions) | Repo-wide `.github/copilot-instructions.md`, plus path-specific `*.instructions.md` (`applyTo` frontmatter) / agent / `AGENTS.md`. **Precedence: Personal > Repository (path-specific → repo-wide → agent) > Organization** — the `response-customization` concept page is the canonical precedence doc; the how-to page lists the instruction types but has no precedence section. (The repo's `agents/preamble.md` wiring targets Claude/Codex/opencode; Copilot reads `AGENTS.md`.) |
| Settings / config | <https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference> | `~/.copilot/` layout + `settings.json`. (`config.json` holds auto-managed trusted-folders/permissions — see [configure-copilot-cli](https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/configure-copilot-cli).) |
| Skills | <https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-skills> | `skills/` → `.github/skills/<n>/`. Copilot reads `.github/skills`, `.claude/skills`, `.agents/skills`, or `~/.copilot/skills`. |

## Isolated settings

Not available. Copilot CLI has no closed-world launch flags; `ap` isolated launches are Claude-only.

## Quirks

- Skill/agent/hook artifacts target Copilot's **project-scoped** `.github/` layout (its read convention), unlike the other harnesses' user-scoped `~/.<harness>/` deploys. But the live deploy runs `ap install global` with `target_default: $HOME` (`profiles/global`), so the renderer — which writes `.github/…` relative to its target — lands them under `$HOME` (`~/.github/`), *not* the current repo.
- Copilot resolves skills from multiple roots including `.claude/skills` and `.agents/skills`, so some shared skill dirs are picked up without a Copilot-specific copy.
