# Antigravity CLI (`agy`)

Antigravity CLI (`agy`) is a native chezmoi harness sibling, like Pi and OpenCode.
It is not an `ap` render target.
Chezmoi owns its global settings, MCP config, shared-skill discovery, and global instructions.
`agy` owns authentication, conversations, brain artifacts, caches, and runtime UI keys.

## Ownership

`chezmoi/.chezmoidata/agy.yaml` is the single source of truth for managed `agy` configuration.

- `chezmoi/dot_gemini/antigravity-cli/modify_private_settings.json` authors `~/.gemini/antigravity-cli/settings.json`.
  It preserves runtime-owned keys (`trustedWorkspaces`, `model`, `gcp`) via `chezmoi/lib/agy-settings-ignore.txt`.
  Unknown live keys stay with a drift warning through `chezmoi/lib/drift-gate.sh`.
- `chezmoi/dot_gemini/config/modify_private_mcp_config.json` authors `~/.gemini/config/mcp_config.json`.
  It replaces `.mcpServers` wholesale so removed servers do not linger.
- `chezmoi/dot_gemini/config/skills.json` points `agy` at `~/.agents/skills`.
  `agy` reads the shared skills cache directly with no copied tree.
- `run_onchange_after_install-agents-doc.sh.tmpl` deploys `agents/AGENTS.md` to `~/.gemini/config/AGENTS.md`.
- `~/.gemini/antigravity-cli/` and `~/.gemini/config/` are never `exact_` trees.
  `agy` stores `antigravity-oauth-token`, `conversations/`, `brain/`, `config.json`, and caches there.

## Auto mode and permissions

`agy.yaml` sets `agentMode: auto`, `enableTerminalSandbox: true`, `toolPermission: proceed-in-sandbox`, and `editorMode: vim`.
Explicit `permissions.{allow,ask,deny}` rules apply in every mode, including `auto`, with `deny > ask > allow`.
The modifier expands `${HOME}` in permission strings at apply time.

**Linux AppArmor gotcha:** `agy` requires unprivileged Linux user namespaces for its terminal sandbox.
When `kernel.apparmor_restrict_unprivileged_userns = 1` blocks `agy`, `agy` logs `Terminal sandbox unavailable` and falls back to `default` mode.
Saved `settings.json` keys stay intact and take effect once the host allows user namespaces.
`auto` mode also requires a personal Google account.

## MCP servers and native plugins

`mcp_config.json` wires `tilth` (`--mcp --edit`) plus `context7` and `tavily` through the root-owned `agent-secret-proxy` sockets.
No plaintext credentials live in `~/.gemini/config/mcp_config.json`.

`sync_agy_plugins` (`.sync-lib.sh`, calling `chezmoi/lib/agy-plugin-reconcile.sh`) reconciles `agy.plugins` via `agy plugin install` and `agy plugin uninstall`.
A manifest at `~/.gemini/config/.chezmoi-plugin-manifest` scopes removals to repo-owned plugins, so built-in plugins (`swarm`) and manual installs stay untouched.

- `milknado`: installs cleanly through `agy`'s Claude Code plugin converter (`3` skills and `1` MCP server).
  It is therefore omitted from `mcp_config.json`.
- `hallouminate`: `plugins/hallouminate/plugin.json` triggers native Antigravity mode, which ignores `.mcp.json`, `plugin.json`'s `mcpServers`, and `hooks/hooks.json`.
  Tracked in `paulnsorensen/hallouminate#812`.
  Until that issue lands, `agy.yaml` installs the plugin for its 7 wiki skills and keeps a temporary `hallouminate` server in `mcp_config.json`.

## Deliberate exclusions and gaps

- **Tilth shell-guard hook**: `tilth hook --host` supports `claude`, `copilot`, `cursor`, and `windsurf`, not `antigravity`.
  We punt on Tilth reroute hooks for `agy` until `tilth` adds an Antigravity host adapter.
- **Version pin gate**: `mise` pins `aqua:google-antigravity/antigravity-cli`, and Renovate bumps it.
  `agy` ships a built-in self-updater that can advance the binary ahead of the mise pin, so `verify_harness_versions` omits `agy` (same as Claude).
- **Hooks, subagents, preamble, and analytics**: deferred to follow-up slices (`~/.gemini/config/hooks.json`, `~/.gemini/config/agents/`, `~/.gemini/config/rules/preamble.md`, and a `session-analytics` adapter).

## Validation

`tests/agy-config.bats` tests settings rendering, `${HOME}` expansion, drift preservation, retired-key deletion, MCP authority, `skills.json`, plugin reconciliation, and sandboxed chezmoi apply.
`tests/install-agents-doc.bats` verifies `~/.gemini/config/AGENTS.md` deployment.

Related: [[index]], [[pi]], [[opencode]], [[../operations/sync-and-chezmoi]].
