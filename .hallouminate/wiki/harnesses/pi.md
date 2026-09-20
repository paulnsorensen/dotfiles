# Pi coding agent

Upstream Pi is a first-class global harness sibling. It is not an `ap` render target or an OMP alias. Chezmoi owns its native configuration, while Pi owns authentication and runtime state.

## Ownership

`chezmoi/.chezmoidata/pi.yaml` owns managed settings, package pins, and the optional local-model catalog.

- `chezmoi/dot_pi/private_agent/modify_settings.json` authors `~/.pi/agent/settings.json` wholesale.
- The modifier preserves `lastChangelogVersion` and halts on unknown live key paths.
- `models.json.tmpl` emits local models only when the machine enables `localLLM`.
- `mcp.json` configures the MCP adapter and direct Tilth tools.
- `auth.json`, `trust.json`, `sessions/`, caches, and package stores remain Pi-owned.

Pi reads shared skills directly from `~/.agents/skills`. Chezmoi does not copy a Pi-specific skill tree.

## Packages

Pi uses pinned mainstream packages:

- `pi-mcp-adapter` for token-efficient MCP access;
- `pi-subagents` for isolated child sessions;
- `pi-web-access` for web search and extraction;
- `@gotgenes/pi-permission-system` for deterministic tool and path gates;
- `pi-vim` for modal prompt editing.

`sync_pi_packages` runs `pi update --extensions` after chezmoi applies the managed settings. Exact package sources remain pinned. Renovate owns package updates in `pi.yaml`.

The permission configuration replaces a harness-specific secret guard. It denies secret-bearing paths across built-in tools, Bash, MCP, and extension tools while allowing known public companion files. Global `yoloMode` auto-approves `ask` decisions, but explicit `deny` rules still block access.

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
