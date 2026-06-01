# Claude Code

Anthropic's CLI — the primary harness. The only one this repo can launch as an `ap` isolated closed world. Docs root: [code.claude.com/docs](https://code.claude.com/docs).

Config lives under `~/.claude/`. The repo deploys it as a Claude *plugin tree* (`~/.claude/plugins/local/global/`) plus shared user-scoped files, wired live via `~/.claude/settings.json` (`enabledPlugins` + `extraKnownMarketplaces`). See [[../architecture/agent-profile]] § the `global` install.

## Capabilities, docs, and repo wiring

| Capability | Official doc | This repo |
|---|---|---|
| Hooks | <https://code.claude.com/docs/en/hooks> | `agents/hooks/registry.yaml` → plugin `hooks/` (wiring in `plugin.json`, NOT `settings.json`). SessionStart cheese-flair hook + its `shared_assets`. |
| Sub-agents | [sub-agents](https://code.claude.com/docs/en/sub-agents) · [frontmatter fields](https://code.claude.com/docs/en/sub-agents#supported-frontmatter-fields) | `agents/registry.yaml` + `agent_definitions/` → `.claude/agents/<n>.md` only (user-scoped, priority 4, full frontmatter). The renderer does **not** also write a plugin-scoped copy — that produced duplicate `global:`-prefixed agents and was dropped. The plugin tree still carries skills/commands/hooks/`.mcp.json`, just no `agents/`. |
| MCP | [mcp](https://code.claude.com/docs/en/mcp) · per-tool globs: [settings](https://code.claude.com/docs/en/settings#available-settings) | `agents/mcp/registry.yaml` → plugin-scoped `.mcp.json`. `gate_unless: CHEESE_FLOW` skips servers the cheese-flow plugin already ships. `scope` honored (claude-only). **Per-tool `mcp__server__tool` permission globs are documented on the Settings page, not the MCP page.** |
| System prompt | [CLI flags](https://code.claude.com/docs/en/cli-reference#system-prompt-flags) · [memory cascade](https://code.claude.com/docs/en/memory) | `agents/preamble.md` injected via `--system-prompt-file` in the `cc`/`ccc`/`ccr`/`ccfresh` wrappers (`zsh/claude.zsh`). `agents/AGENTS.md` → `~/.claude/CLAUDE.md` (user cascade: managed → user → project → local, loads on top). Two docs: the `--system-prompt[-file]` / `--append-system-prompt[-file]` flags live in the CLI reference; the CLAUDE.md/AGENTS.md load order lives in the memory page. |
| Settings / config | [settings](https://code.claude.com/docs/en/settings#available-settings) | `~/.claude/settings.json` seeded once by chezmoi (`create_settings.json`); `ap install global` jq-merges `enabledPlugins`/`extraKnownMarketplaces`, preserving user keys. Schema covers permissions, hooks, env, model, statusLine + the per-tool MCP allow/deny globs. |
| Skills | [skills](https://code.claude.com/docs/en/skills#frontmatter-reference) | `skills/` (local, copied) + `_registry.yaml` (external, `npx skills add`) → `~/.claude/skills/`. |

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
- Agents render **shared-only** to `.claude/agents/<n>.md` (user-scoped, priority 4) — the renderer no longer writes a plugin-scoped (priority 5) copy. Writing both produced duplicate `global:<agent>` entries in Claude's roster (the plugin namespace) for zero benefit, since the user-scoped file already wins precedence and is the cross-harness surface. Body-less agents therefore emit no Claude file (the shared writer is body-guarded); every real registry agent has a `body_path`, so none are dropped.
- `worktree-guard.js` and other pre-tool hooks are Claude-specific (`claude/hooks/`), separate from the harness-agnostic `agents/hooks/` registry.
