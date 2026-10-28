# Pi coding agent

Upstream Pi is a first-class global harness sibling. It is not an `ap` render target or an OMP alias. Chezmoi owns its native configuration, while Pi owns authentication and runtime state.

## Ownership

`chezmoi/.chezmoidata/pi.yaml` owns managed settings and package pins.

- `chezmoi/dot_pi/private_agent/modify_settings.json` authors `~/.pi/agent/settings.json` wholesale.
- The modifier preserves `lastChangelogVersion` and halts on unknown live key paths.
- `.chezmoiremove` removes `~/.pi/agent/models.json`; Pi has no managed local providers.
- `mcp.json` configures the MCP adapter and direct Tilth tools.
- `auth.json`, `trust.json`, `sessions/`, caches, and package stores remain Pi-owned.

Pi reads shared skills directly from `~/.agents/skills`. Chezmoi does not copy a Pi-specific skill tree.

## Packages

Pi uses pinned mainstream packages:

- `pi-subagents` for isolated child sessions;
- `pi-web-access` for web search and extraction;
- `@gotgenes/pi-permission-system` for deterministic tool and path gates;
- `pi-vim` for modal prompt editing.

`sync_pi_packages` runs `pi update --extensions` after chezmoi applies the managed settings. Exact package sources remain pinned. Renovate owns package updates in `pi.yaml`.

The permission configuration replaces a harness-specific secret guard. It denies secret-bearing paths across built-in tools, Bash, MCP, and extension tools while allowing known public companion files. Its `mcp` rules explicitly allow `mcp__tilth__tilth_write`. Global `yoloMode` auto-approves `ask` decisions, but explicit `deny` rules still block access.

## MCP

Pi uses its built-in MCP support (Pi 0.99 and later). `~/.pi/agent/mcp.json` lists the servers. Tilth's search, read, and write tools have `direct` exposure. Other tools use the default `codemode` exposure. Pi names each tool `mcp__<server>__<tool>`, the same as Claude.

The repo retired `pi-mcp-adapter` in October 2026. Pi 1.0 built-in MCP covers direct exposure, OAuth, and resources. The adapter also caused drift: it wrote `"-builtin:mcp"` to `settings.json`, and its Pi peer range lagged Pi releases. The registry sets `extensions: []`, which removes that live entry. Its `toolPrefix: none` naming has no built-in equivalent.

## Compaction

`chezmoi/.chezmoidata/pi.yaml` sets `compaction.reserveTokens: 16384` and `keepRecentTokens: 20000`.

Pi 1.4.0 changes the meaning of `reserveTokens`. In 1.3.0, the value also capped the summary output. Reasoning-heavy summaries could fail with "generation hit the token cap". In 1.4.0, compaction and branch summaries use the model's output limit. The value now sets only the context headroom at which compaction starts.

The repo needs no change. Summary failures of the token-cap kind stop after the upgrade. Raise `reserveTokens` only if long compactions near the context limit overflow.

## Shared resources

`run_onchange_after_install-agents-doc.sh.tmpl` installs `agents/AGENTS.md` as `~/.pi/agent/AGENTS.md`.

Pi also receives:

- a compact `APPEND_SYSTEM.md` for native tools and package capabilities;
- the chocolate-donut theme;
- the cheese-flair extension.

These resources do not depend on OMP runtime state.

## Installation and validation

`packages/packages.yaml` pins `@earendil-works/pi-coding-agent`. The npm installer disables lifecycle scripts.

`.sync` checks the installed Pi version before and after the final chezmoi apply. `tests/pi-config.bats` covers settings ownership, package pins, MCP configuration, path protection, and shared-skill discovery. Session analytics reads Pi's native JSONL alongside OMP through one Pi-family normalizer.

Related: [[index]], [[../architecture/agents-dir]], [[../operations/sync-and-chezmoi]].
