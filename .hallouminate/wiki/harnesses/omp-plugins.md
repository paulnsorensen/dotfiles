---
status: reviewed
last_verified: 2026-08-13
confidence: high
sources:
  - chezmoi/.chezmoidata/omp.yaml
  - renovate.json5
  - .sync-lib.sh (sync_omp_plugins)
  - .sync (run_sync wiring)
  - tests/omp-plugins.bats
  - .cheese/research/oh-my-pi-plugins/oh-my-pi-plugins.md
  - https://github.com/sysid/pi-extensions/tree/main/packages/vim-editor
---
# OMP Native Plugins

Milknado and hallouminate install as native OMP marketplace plugins; `@sysid/pi-vim` installs as a pinned npm extension. `sync_omp_plugins` reconciles both classes from `chezmoi/.chezmoidata/omp.yaml` on every `dots sync`. The marketplace cutover replaced hand-wired MCP entries and vendored OMP skill copies; the npm leg adds modal prompt editing without copying third-party source into chezmoi.

## Why CLI reconcile, not declarative files

OMP (verified at 17.2.12) has no declarative install-list config key: plugin state lives under `~/.omp/marketplaces.json` and `~/.omp/plugins/`, and only the CLI can populate its package tree and lock state safely. The reconcile therefore drives `omp plugin`. It is idempotent, exact-owns marketplace entries and their removal, installs or upgrades pinned `omp.npmPlugins`, and preserves unlisted npm plugins.

## Why the mcp.json cutover is mandatory

Plugin-owned MCP servers must NOT also appear in `dot_omp/private_agent/mcp.json` — OMP would expose both `server` and `plugin:server` namespaces (documented hazard in `omp.yaml`'s header). Going native for milknado/hallouminate therefore required removing their direct MCP entries in the same change.

## OMP CLI gotchas (verified live, 17.2.12)

- **Re-running `marketplace add` / `plugin install` on a present entry exits 1** ("already exists"/"already installed") — the reconcile must check current state first; it cannot lean on CLI idempotency.
- **`--dry-run` is broken for `marketplace remove` and `uninstall`** — it actually mutates state. Never use it in the reconcile.
- `omp plugin marketplace list --json` prints plain text (not JSON) when empty; `omp plugin list --json` is clean JSON always: `{"npm":[], "marketplace":[{"id":"name@marketplace", "scope":"user", "entries":[...]}]}`.
- `~/.omp/marketplaces.json` schema: `{version:1, marketplaces:[{name, sourceType, sourceUri, catalogPath, addedAt, updatedAt}]}`. The reconcile guards its jq parse — a malformed file degrades to "no marketplaces" with a warning instead of aborting the whole sync under `set -e` (regression-tested in `tests/omp-plugins.bats`).
- OMP marketplaces are **Claude-compatible**: `marketplace add` accepts `owner/repo` / git URL / local path and falls back to `.claude-plugin/marketplace.json` when `.omp-plugin/marketplace.json` is absent — so the same milknado/hallouminate repos serve claude and omp.
- Marketplace and npm packages may expose extension modules through their package manifests. Chezmoi-deployed local extensions remain a separate resource class under `~/.omp/agent/extensions/`.

## Scope decisions

The registry manages the milknado and hallouminate marketplaces plus the pinned `@sysid/pi-vim` npm extension. Other npm plugins remain user-owned. cheese-flow's skills reach OMP through the easy-cheese vendor leg in `skills/_registry.yaml`; a native cheese-flow install would duplicate them. todoist-flow and vaudeville remain excluded.

Related: [[omp]] (Todo→Milknado cutover, extensions), [[operations/sync-and-chezmoi]] (deploy mechanics).
