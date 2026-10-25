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

## Package bump gotchas

Renovate bumps Pi packages often. Two traps recur in `green-harvest` issues. Read them before you merge a bump.

### The pin test duplicates the pins

`tests/pi-config.bats` ("pi registry pins the selected mainstream packages") compares the whole `packages` array to a literal. A Renovate PR edits only `chezmoi/.chezmoidata/pi.yaml`. The test then fails in CI. Update the literal and the registry pin in the same change. Do not weaken the test.

### Children may lose the Pi addendum

Per the `pi-subagents` 0.79.2 changelog, as reported in the `green-harvest` issues, children started with `systemPromptMode: replace` no longer receive `APPEND_SYSTEM.md`. This covers every builtin agent except `delegate`. The repo pins 0.77.0, so the change is pending until a bump merges.

The file holds two kinds of rules:

- Tool routing (native file tools, Tilth direct tools, `codemode`, `web_search`): children need these.
- Delegation rules: only the parent needs these.

Children also skip the global `~/.pi/agent/AGENTS.md`. If children need the routing, put it in the agent prompts or in an `agentOverrides` system prompt. Otherwise accept that the addendum applies only to the parent. <speculative> The repo has not yet chosen between these options. </speculative>

### Compaction trigger headroom

Since Pi 1.4.0, `compaction.reserveTokens` (16384 in `pi.yaml`) only sets when compaction starts. It no longer caps summary size. The key stays valid, so the drift gate in `modify_settings.json` sees no change.

Related: [[index]], [[../architecture/agents-dir]], [[../operations/sync-and-chezmoi]].
