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
- `chezmoi/dot_gemini/config/skills.json.tmpl` renders an absolute `<home>/.agents/skills` path, because `agy` does not expand `~`.
  `agy` reads the shared skills cache directly with no copied tree. `agy` 1.5.16+ also discovers `~/.agents/skills` natively.
- `run_onchange_after_install-agents-doc.sh.tmpl` deploys `agents/AGENTS.md` to `~/.gemini/config/AGENTS.md`.
  It also symlinks `~/.gemini/AGENTS.md` to `config/AGENTS.md` so T3 Code finds the global rules while standalone `agy` deduplicates both paths.
- `~/.gemini/antigravity-cli/` and `~/.gemini/config/` are never `exact_` trees.
  `agy` stores `antigravity-oauth-token`, `conversations/`, `brain/`, `config.json`, and caches there.

## Auto mode and permissions

`agy.yaml` sets `agentMode: auto`, `enableTerminalSandbox: true`, `toolPermission: proceed-in-sandbox`, and `editorMode: vim`.
Explicit `permissions.{allow,ask,deny}` rules apply in every mode, including `auto`, with `deny > ask > allow`.
The modifier expands `${HOME}` in permission strings at apply time.
The registry owns the permission lists. The modifier drops a live entry that the registry lacks and warns with its name.
File rules take no globs, so `read_file(.env)` covers only a workspace-root `.env`.
Use absolute `${HOME}/...` paths for home secrets. Denying `read_file` also denies `write_file`.
`agy` checks each part of a pipeline or `&&`/`||`/`;` chain against the rules on its own.
A `$(...)` or backtick substitution turns off prefix matching, so that command asks.
The `command(...)` allow list mirrors Claude's list without the broad code runners (`python3`, `node`, `npx`, `uv`, `npm run`, `gh`, `dots`) and without the shell file readers.
`agy` has no shell-level secret guard, so the shell file readers (`cat`, `head`, `tail`, `jq`, `yq`, `rg`, `cp`, `duckdb`, `fd`, `sd`, `mv`) stay out of `allow` until `agy` hooks exist.
The `command(git)` entry stays for parity with Claude's `Bash(git:*)`. `git` can still read files and run code, so the shell guard stays partial.

**Linux AppArmor gotcha:** `agy` requires unprivileged Linux user namespaces for its terminal sandbox.
When `kernel.apparmor_restrict_unprivileged_userns = 1` blocks `agy`, its log says `auto mode is unavailable because the terminal sandbox is unavailable, falling back to default`.
Default mode then asks before each command that no `command(...)` rule allows.
`bin/linux-install` fixes this through `bin/lib/agy-apparmor.sh`.
It renders `services/apparmor/antigravity` for every mise-installed `antigravity` binary and loads it as `/etc/apparmor.d/antigravity`.
Like Ubuntu's `code` and `chrome` profiles, the profile is unconfined and only grants `userns`.
Restart `agy` after the load.
`dots sync` warns when the profile is missing or stale. It never runs `sudo`; run `bin/linux-install` to fix it.
The attach path lies under `$HOME`, so any process of this user can get user namespaces there.
`auto` mode is not available for business or enterprise accounts.

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

## T3 Code ACP integration

T3 Code runs `agy acp --gemini-dir <profile> --app-data-dir antigravity-acp` with `GEMINI_HOME=<profile>`.
Before each spawn, T3 overwrites `<profile>/antigravity-acp/settings.json` with `auth` and optional `gcp` keys only.
T3 links skills, `~/.gemini/AGENTS.md`, `GEMINI.md`, and `config/skills.json` into `<profile>/`, but omits `config/mcp_config.json` and `config/plugins`.

`chezmoi/.chezmoidata/t3.yaml` points `providerInstances.antigravity.config.binaryPath` at `$DOTFILES/bin/dotsagy/agy`.
The `dotsagy/` directory keeps the basename `agy` (required by T3 `AntigravityInstallation`) without shadowing the mise shim on interactive `PATH`.
On `acp` launches, `bin/lib/agy-wrapper.sh` prepares `<profile>` before `exec`ing the mise `agy` shim:

- Links `<profile>/config/mcp_config.json`, `<profile>/config/plugins`, and `<profile>/config/AGENTS.md` to `~/.gemini/config/`.
  It replaces an empty 0-byte `mcp_config.json` that `agy` seeds on first boot, while leaving non-empty profile files intact.
- Merges `enableTerminalSandbox` and `permissions` (adding `mcp(t3-code/*)` to `permissions.allow`) from `~/.gemini/antigravity-cli/settings.json` into `<profile>/antigravity-acp/settings.json`, preserving T3's `auth` and `gcp` keys.
  It copies the full `allow` list on purpose, so approval prompts do not block a T3 thread.
  It skips `toolPermission`, so the T3 runtime mode controls prompts.
- `exec`s the mise `agy` shim so `/etc/apparmor.d/antigravity` still attaches to the resolved `antigravity` binary.

**Verified `agy` 1.5.18 / T3 0.1.13 caveats:**

- `agy` 1.5.18 ACP `server.loadSettings` reads `enableTerminalSandbox`, `toolPermission`, `allowNonWorkspaceAccess`, and `includeDefaultCustomizations`, but ignores `permissions.{allow,ask,deny}`.
  Its `settingsProvider.GetGlobalPermissionGrants` returns `nil`, and `PermissionGrants` passes an empty grant set.
  T3's `antigravityPermissionDisposition` already auto-allows `t3-code/*` MCP calls in `auto` and `auto-accept-edits` modes.
  Merging `permissions` keeps the profile ready when upstream `agy` ACP adds permission-rule support.
- T3's `isAntigravityTextGenerationAvailable` disables Antigravity title generation when `<profile>/config/mcp_config.json` defines non-empty `mcpServers`.
  Because `t3.yaml` keeps Codex as the default system model, title generation stays unaffected.
- `agy` splits MCP tools into eager and lazy sets through `SplitEnabledToolsByEagerLazy` under `customization_token_budget`.
  Global `AGENTS.md` uses the separate 20,000-token `defaultRulesBudget`.

## Deliberate exclusions and gaps

- **Tilth shell-guard hook**: `tilth hook --host` supports `claude`, `copilot`, `cursor`, and `windsurf`, not `antigravity`.
  The repo does not install Tilth reroute hooks for `agy`. Add them when `tilth` gets an Antigravity host adapter.
- **Version pin gate**: `mise` pins `aqua:google-antigravity/antigravity-cli`, and Renovate bumps it.
  `agy` ships a built-in self-updater that can advance the binary ahead of the mise pin, so `verify_harness_versions` omits `agy` (same as Claude).
- **Hooks, subagents, preamble, and analytics**: deferred to follow-up slices (`~/.gemini/config/hooks.json`, `~/.gemini/config/agents/`, `~/.gemini/config/rules/preamble.md`, and a `session-analytics` adapter).

## Validation

`tests/agy-config.bats` tests settings rendering, `${HOME}` expansion, drift preservation, retired-key deletion, MCP authority, `skills.json`, plugin reconciliation, and sandboxed chezmoi apply.
`tests/install-agents-doc.bats` verifies `~/.gemini/config/AGENTS.md` deployment and the `~/.gemini/AGENTS.md` symlink.
`tests/dots-wrappers.bats` and `tests/t3-config.bats` verify `bin/dotsagy/agy`, `bin/lib/agy-wrapper.sh`, and T3 `binaryPath` wiring.

Related: [[index]], [[pi]], [[opencode]], [[../architecture/t3-code-launch]], [[../operations/sync-and-chezmoi]].
