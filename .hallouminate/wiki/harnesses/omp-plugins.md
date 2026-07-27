---
status: reviewed
last_verified: 2026-07-24
confidence: high
sources:
  - chezmoi/.chezmoidata/omp.yaml
  - .sync-lib.sh (sync_omp_plugins)
  - .sync (run_sync wiring)
  - tests/omp-plugins.bats
  - .cheese/research/oh-my-pi-plugins/oh-my-pi-plugins.md
---
# OMP Native Plugins

milknado and hallouminate install as **native OMP marketplace plugins**, reconciled from the `.omp.plugins` subtree of `chezmoi/.chezmoidata/omp.yaml` by `sync_omp_plugins` (`.sync-lib.sh`) on every `dots sync`. This replaced two hand-wired legs: their MCP entries in `dot_omp/private_agent/mcp.json` (now context7-only) and the `harnesses: [omp]` vendored-skill entries in `skills/_registry.yaml` (both deleted).

## Why CLI reconcile, not declarative files

OMP (verified at 17.0.9) has **no declarative install-list config key** — plugin state lives in imperatively-mutated files (`~/.omp/marketplaces.json`, `~/.omp/plugins/installed_plugins.json`, plus a lockfile), and marketplace payloads land in a version-stamped cache dir only the CLI can populate. chezmoi-templating those state files therefore cannot work; the reconcile must drive the CLI. It runs in `run_sync()` after `reconcile_claude_mcps`, is idempotent (converged machine → zero mutating `omp` calls), and propagates removals: de-listed registry entries are `plugin uninstall`ed and their marketplaces `marketplace remove`d. npm-installed OMP plugins (`.npm[]`) are never touched.

## Why the mcp.json cutover is mandatory

Plugin-owned MCP servers must NOT also appear in `dot_omp/private_agent/mcp.json` — OMP would expose both `server` and `plugin:server` namespaces (documented hazard in `omp.yaml`'s header). Going native for milknado/hallouminate therefore required removing their direct MCP entries in the same change.

## OMP CLI gotchas (verified live, 17.0.9)

- **Re-running `marketplace add` / `plugin install` on a present entry exits 1** ("already exists"/"already installed") — the reconcile must check current state first; it cannot lean on CLI idempotency.
- **`--dry-run` is broken for `marketplace remove` and `uninstall`** — it actually mutates state. Never use it in the reconcile.
- `omp plugin marketplace list --json` prints plain text (not JSON) when empty; `omp plugin list --json` is clean JSON always: `{"npm":[], "marketplace":[{"id":"name@marketplace", "scope":"user", "entries":[...]}]}`.
- `~/.omp/marketplaces.json` schema: `{version:1, marketplaces:[{name, sourceType, sourceUri, catalogPath, addedAt, updatedAt}]}`. The reconcile guards its jq parse — a malformed file degrades to "no marketplaces" with a warning instead of aborting the whole sync under `set -e` (regression-tested in `tests/omp-plugins.bats`).
- OMP marketplaces are **Claude-compatible**: `marketplace add` accepts `owner/repo` / git URL / local path and falls back to `.claude-plugin/marketplace.json` when `.omp-plugin/marketplace.json` is absent — so the same milknado/hallouminate repos serve claude and omp.
- Marketplace installs load skills/agents/commands/hooks/MCP but **never `.ts` extension modules** — extensions stay chezmoi-deployed (`dot_omp/private_agent/extensions/`), unaffected by plugin installs.

## Scope decisions

Only milknado + hallouminate are registry-managed. cheese-flow's skills reach OMP via the easy-cheese vendor leg in `skills/_registry.yaml` (a native cheese-flow install would double them); todoist-flow and vaudeville are gated, claude-shaped, and stay out.

Related: [[omp]] (Todo→Milknado cutover, extensions), [[operations/sync-and-chezmoi]] (deploy mechanics).
