# Claude Code

Anthropic's CLI — the primary harness. Claude is the only harness where `ap` isolated launch can use Claude-native closed-world flags; Codex and opencode isolate through different wrapper mechanisms. Docs root: [code.claude.com/docs](https://code.claude.com/docs).

Config lives under `~/.claude/`. The repo deploys it as a Claude *plugin tree* (`~/.claude/plugins/local/global/`) plus shared user-scoped files, wired live via `~/.claude/settings.json` (`enabledPlugins` + `extraKnownMarketplaces`). See [[../architecture/agent-profile]] § the `global` install.

## Capabilities, docs, and repo wiring

| Capability | Official doc | This repo |
|---|---|---|
| Hooks | <https://code.claude.com/docs/en/hooks> | `agents/hooks/registry.yaml` → plugin `hooks/` (wiring in `plugin.json`, NOT `settings.json`). SessionStart cheese-flair hook + its `shared_assets`. |
| Sub-agents | [sub-agents](https://code.claude.com/docs/en/sub-agents) · [frontmatter fields](https://code.claude.com/docs/en/sub-agents#supported-frontmatter-fields) | `agents/registry.yaml` + `agent_definitions/` → `.claude/agents/<n>.md` only (user-scoped, priority 4, full frontmatter). The renderer does **not** also write a plugin-scoped copy — that produced duplicate `global:`-prefixed agents and was dropped. The plugin tree still carries skills/commands/hooks/`.mcp.json`, just no `agents/`. |
| MCP | [mcp](https://code.claude.com/docs/en/mcp) · per-tool globs: [settings](https://code.claude.com/docs/en/settings#available-settings) | `agents/mcp/registry.yaml` → plugin-scoped `.mcp.json`. `gate_unless: CHEESE_FLOW` skips servers the cheese-flow plugin already ships. `scope` honored (claude-only). **Per-tool `mcp__server__tool` permission globs are documented on the Settings page, not the MCP page.** |
| System prompt | [CLI flags](https://code.claude.com/docs/en/cli-reference#system-prompt-flags) · [memory cascade](https://code.claude.com/docs/en/memory) | `agents/preamble.md` injected via `--system-prompt-file` in the `cc`/`ccc`/`ccr` wrappers (`zsh/claude.zsh`). `agents/AGENTS.md` → `~/.claude/CLAUDE.md` (user cascade: managed → user → project → local, loads on top). Two docs: the `--system-prompt[-file]` / `--append-system-prompt[-file]` flags live in the CLI reference; the CLAUDE.md/AGENTS.md load order lives in the memory page. |
| Settings / config | [settings](https://code.claude.com/docs/en/settings#available-settings) | `~/.claude/settings.json` is produced by chezmoi's `modify_settings.json` from `chezmoi/lib/claude-settings-authoritative.json`: repo-owned keys win, live/runtime keys that should survive (`permissions.allow`/`deny`/`ask`/`additionalDirectories`, `enabledPlugins`, `extraKnownMarketplaces`) are preserved or intentionally reasserted, and unknown live key paths fail sync until classified. See [[../operations/claude-dotfiles-ownership]]. |
| Skills | [skills](https://code.claude.com/docs/en/skills#frontmatter-reference) | `skills/` (local, copied) + `_registry.yaml` (external, `npx skills add`) → `~/.claude/skills/`. |

## Isolated settings (`ap` isolated launch)

Claude is the **only** harness where `ap launch` builds a closed world with Claude-native CLI flags. An isolated `profiles/<name>/profile.yaml` (`isolated: true`) renders to ephemeral flags (`overlay.py:build_isolated_flags`):

- `--strict-mcp-config --mcp-config <tmp .mcp.json>` — only the profile's MCPs.
- `--setting-sources ""` — strips the inherited user `settings.json`.
- `--tools <csv>` — hard tool whitelist, **only emitted when the profile declares `tools`** (`overlay.py:281` — `if manifest.tools:`).
- `--append-system-prompt-file <profile>/CLAUDE.md` — if `system_prompt` declared.
- `--settings <tmp settings.json>` — `permissions` + `enabledPlugins`.

Gotcha: `--setting-sources ""` closes the **MCP world and inherited settings** (no inherited allowlist), but **not** the built-in tool surface. A profile with **no `tools` key omits `--tools` entirely**, so claude keeps its full default built-in tools (Bash, Read, …) — the closed world is the MCPs + settings, not the tools. Declaring `tools` narrows to exactly that whitelist + `permissions_deny`; leaving it out keeps everything (`todo` does this deliberately, adding `--dangerously-skip-permissions`; `mgmt` leaves it out with default prompting). This is why CLI-based access works inside a closed world: `mgmt` reaches GitHub planning through the `gh` CLI + `/gh` skill over Bash rather than a GitHub MCP — Bash is available, non-allowlisted calls just prompt. Shipped isolated profiles: `review`, `todo`, `fe`, `spec`, `mgmt`, `rtkonly`, `plugin`.

## Quirks

- Docs host is `code.claude.com/docs`, not `docs.claude.com` (that's the API/Agent-SDK surface).
- Agents render **shared-only** to `.claude/agents/<n>.md` (user-scoped, priority 4) — the renderer no longer writes a plugin-scoped (priority 5) copy. Writing both produced duplicate `global:<agent>` entries in Claude's roster (the plugin namespace) for zero benefit, since the user-scoped file already wins precedence and is the cross-harness surface. Body-less agents therefore emit no Claude file (the shared writer is body-guarded); every real registry agent has a `body_path`, so none are dropped.
- `worktree-guard.js` and other pre-tool hooks are Claude-specific (`claude/hooks/`), separate from the harness-agnostic `agents/hooks/` registry.
