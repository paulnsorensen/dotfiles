# Claude Code

Anthropic's CLI — the primary harness. The only one this repo can launch as an `ap` isolated closed world. Docs root: [code.claude.com/docs](https://code.claude.com/docs).

Config lives under `~/.claude/`. The repo deploys it as a Claude *plugin tree* (`~/.claude/plugins/local/global/`) plus shared user-scoped files, wired live via `~/.claude/settings.json` (`enabledPlugins` + `extraKnownMarketplaces`). See [[../architecture/agent-profile]] § the `global` install.

## Capabilities, docs, and repo wiring

| Capability | Official doc | This repo |
|---|---|---|
| Hooks | <https://code.claude.com/docs/en/hooks> | `agents/hooks/registry.yaml` → plugin `hooks/` (wiring in `plugin.json`, NOT `settings.json`). SessionStart cheese-flair hook + its `shared_assets`. |
| Sub-agents | <https://code.claude.com/docs/en/sub-agents> | `agents/registry.yaml` + `agent_definitions/` → `.claude/agents/<n>.md` (user-scoped, priority 4) and plugin-scoped copy. Full frontmatter on the shared file. |
| MCP | <https://code.claude.com/docs/en/mcp> | `agents/mcp/registry.yaml` → plugin-scoped `.mcp.json`. `gate_unless: CHEESE_FLOW` skips servers the cheese-flow plugin already ships. `scope` honored (claude-only). |
| System prompt | <https://code.claude.com/docs/en/output-styles> | `agents/preamble.md` injected via `--system-prompt-file` in the `cc`/`ccc`/`ccr`/`ccfresh` wrappers (`zsh/claude.zsh`). `agents/AGENTS.md` → `~/.claude/CLAUDE.md` (user cascade, loads on top). |
| Settings / config | <https://code.claude.com/docs/en/settings> | `~/.claude/settings.json` seeded once by chezmoi (`create_settings.json`); `ap install global` jq-merges `enabledPlugins`/`extraKnownMarketplaces`, preserving user keys. |
| Skills | <https://code.claude.com/docs/en/skills> | `skills/` (local, copied) + `_registry.yaml` (external, `npx skills add`) → `~/.claude/skills/`. |

## Isolated settings (`ap` isolated launch)

Claude is the **only** harness where `ap launch` builds a closed world. An isolated `profiles/<name>/profile.yaml` (`isolated: true`) renders to ephemeral flags (`overlay.py:build_isolated_flags`):

- `--strict-mcp-config --mcp-config <tmp .mcp.json>` — only the profile's MCPs.
- `--setting-sources ""` — strips the inherited user `settings.json`.
- `--tools <csv>` — hard tool whitelist.
- `--append-system-prompt-file <profile>/CLAUDE.md` — if `system_prompt` declared.
- `--settings <tmp settings.json>` — `permissions` + `enabledPlugins`.

Gotcha: with `--setting-sources ""` there's no inherited allowlist, so the tool surface is exactly the `tools` whitelist + `permissions_deny`. Add the MCP's own tools to `tools` or rely on the closed `--mcp-config`. Shipped isolated profiles: `review`, `todo`, `fe`, `spec`, `notion`, `rtkonly`, `plugin`.

## Quirks

- Docs host is `code.claude.com/docs`, not `docs.claude.com` (that's the API/Agent-SDK surface).
- User-scoped agent files (priority 4) win over plugin-scoped (priority 5) — the repo writes both, and the user-scoped one must carry full metadata.
- `worktree-guard.js` and other pre-tool hooks are Claude-specific (`claude/hooks/`), separate from the harness-agnostic `agents/hooks/` registry.
