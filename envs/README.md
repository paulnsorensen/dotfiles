# envs/

A **routine env** is a named bundle of Claude Code plugins + MCP servers + skill packs, defined once
as data and rendered into a setup-script body by the `routine-env` skill (`skills/routine-env/`).

This directory is consumed **only** by that skill. It is not wired into `ap`, `profiles/base`, the
`agents/` registries, or `dots sync` — an env defn is not a rendered artifact.

## Why a routine env, not just committed `.claude/`

A "routine env" targets **Claude Cloud** (Claude Code on the web, `claude.ai/code`), a different
product from Managed Agents (`ant beta:environments`). Per
`.cheese/research/routine-env-provisioning/routine-env-provisioning.md`:

- Claude Cloud's per-environment setup script is **UI-configured** — plain bash typed into the
  environment dialog, not a repo-committed file, and there is **no CLI to push it from git**
  (`<certain>`, addendum A1/A5). It runs once per build cache-miss and persists into every session
  from that cached container until invalidated (addendum A2).
- Separately, a repo's committed `.claude/settings.json` (`enabledPlugins`/`extraKnownMarketplaces`)
  auto-installs at cloud session start, and `.claude/skills/` loads with the clone — zero install step
  (addendum A1). That is the git-native alternative path when you don't need the setup-script route.

Because there is no push API for the Claude Cloud setup script, `envs/*.yaml` is the source of truth
and the `routine-env` skill **renders** an idempotent bash body from it — the user pastes that body
into the Claude Cloud environment dialog (or runs it locally via `apply-local`).

## Schema

```yaml
name: cheese-core
description: <one line>
marketplaces:                 # → claude plugin marketplace add <ref>
  - ref: paulnsorensen/hallouminate     # owner/repo or URL the CLI accepts
plugins:                      # → claude plugin install <id>
  - id: hallouminate@hallouminate       # <plugin>@<marketplace-id>; CONFIRM id via `claude plugin marketplace list`
mcp:                          # npx-launched MCP servers (NOT plugins)
  - name: tilth
    package: "@paulnsorensen/tilth-nightly"
skills:                       # skill packs via the skills CLI
  - pack: paulnsorensen/easy-cheese
    args: "--all --global"    # per easy-cheese README: npx skills@latest add paulnsorensen/easy-cheese --all --global
```

`plugins[].id` marketplace coordinates come from `agents/plugins/registry.yaml` (the cross-harness
plugin registry) — do not invent new coordinates here; that registry is the source of truth for which
plugin lives at which marketplace. Every `plugins[].id` carries an inline comment that the exact id
must be confirmed via `claude plugin marketplace list` before use, since the marketplace's `.name`
field in its `marketplace.json` is not assumed by this file.

## Env defns

- `cheese-core.yaml` — hallouminate wiki MCP/plugin + tilth-nightly MCP + easy-cheese review skills.
- `milknado.yaml` — milknado Mikado execution plugin + easy-cheese review skills (skills list has an
  open `TODO(confirm)` for additional packs).

## Consumption

The `routine-env` skill (`skills/routine-env/SKILL.md`) reads an `envs/<name>.yaml` and:

- `render <env>` — emits one idempotent bash setup-script body to paste into the Claude Cloud UI.
- `apply-local <env>` — runs the same commands on the current machine.
- `update <env>` — re-renders after bumping plugin/skill versions.
- `new <name>` — scaffolds a fresh `envs/<name>.yaml` from this schema.

See that skill for the full flow and the "what it never does" boundary.
