# Cursor

The Cursor AI code editor (cursor.com). Unlike the other four, Cursor is an **IDE plugin surface, not a CLI harness** — but it's a full `ap` render target (`renderers/cursor.py`) plus a chezmoi-deployed plugin tree, so it carries the same six capabilities. Docs root: [cursor.com/docs](https://cursor.com/docs). (It *does* also ship a `cursor-agent` CLI with its own declarative config — see the permissions note below — but the repo currently drives only the IDE plugin surface.)

Two deploy paths feed Cursor:

- **MCP** registry entries still describe Cursor-capable servers, but non-isolated `ap install global` no longer mutates live `~/.cursor/mcp.json`. Keep durable global MCP defaults in chezmoi/user config; use renderer-owned targets only for generated/isolated surfaces. `CURSOR_CONFIG` still overrides the path in tests.
- **Everything else** ships as a **Cursor 2.x plugin** under `cursor/plugins/local/<name>/` (the shipping one is `cheese-grok`). chezmoi's `install-cursor-plugin.sh` deploys its `skills/`, `rules/`, `commands/`, `hooks/` into `~/.cursor/{skills,rules,commands,hooks}/` and jq-merges `hooks.json` + `modes.json`. Per-collection `.dotfiles-managed-<plugin>` manifests track ownership so dropped items are pruned without touching user files.

## Capabilities, docs, and repo wiring

| Capability | Official doc | This repo |
|---|---|---|
| Hooks | [hooks](https://cursor.com/docs/agent/hooks) | `cursor/plugins/local/<plugin>/hooks/*.sh` + `hooks.json` → `~/.cursor/hooks/*.sh` (executable) and merged into `~/.cursor/hooks.json`. Entries tagged `_plugin: "<name>"` so re-deploys strip stale ones. Lifecycle events (`beforeShellExecution`, `afterFileEdit`, `beforeMCPExecution`, `stop`, …) with a 4-level location precedence incl. `~/.cursor/hooks.json`. |
| Sub-agents | [subagents](https://cursor.com/docs/context/subagents) | Cursor 2.x agents live in `.cursor/agents/` + `~/.cursor/agents/` (markdown + YAML: `name`, `description`, `model: inherit`, `readonly`, `is_background`). This repo currently deploys the legacy **custom-modes** surface (`modes/<name>.json` → merged into `~/.cursor/modes.json` under `.modes.<name>`). |
| MCP | [mcp](https://cursor.com/docs/context/mcp) | Live `~/.cursor/mcp.json` / project `.cursor/mcp.json` are user/chezmoi-owned. `agents/mcp/registry.yaml` remains the cross-harness source for renderer-owned targets, but non-isolated `ap install global` does not mutate Cursor's live MCP file. Cursor supports stdio / SSE / Streamable-HTTP transport and `env` / `envFile` / `${env:NAME}` interpolation. |
| Rules (system prompt) | [rules](https://cursor.com/docs/context/rules) | `cursor/plugins/local/<plugin>/rules/*.mdc` → `~/.cursor/rules/*.mdc`. Four rule types (Always / Apply Intelligently / Apply to Specific Files via glob / Apply Manually), `alwaysApply` / `description` / `globs` frontmatter, `AGENTS.md` support (incl. nested), precedence Team → Project → User. |
| Settings / config | [cli permissions](https://cursor.com/docs/cli/reference/permissions) · [cli configuration](https://cursor.com/docs/cli/reference/configuration) | **Permissions are split** — see [[../architecture/harness-permissions]]. The **IDE** allowlist (Run Mode + command/MCP approval) is UI-only (Settings → Agents). The **`cursor-agent` CLI** is declarative: `~/.cursor/cli-config.json` (global: `version`, `editor.vimMode`, `permissions.allow`/`deny`) and project `<project>/.cursor/cli.json` (only `permissions`, precedence over global). Tokens: `Shell()`/`Read()`/`Write()`/`WebFetch()`/`Mcp()`; **deny wins**. `~/.cursor/sandbox.json` is a separate sandbox network/fs policy. `ap` does **not** render any of these today (warn-and-drop) — planned via `.cheese/specs/ap-cursor-cli-permissions.md`. |
| Skills / commands | [skills](https://cursor.com/docs/skills) · [slash commands](https://cursor.com/docs/cli/reference/slash-commands) | `cursor/plugins/local/<plugin>/skills/<name>/SKILL.md` → `~/.cursor/skills/<name>/` (frontmatter `name` + `description`, optional `paths`). `commands/*.md` → `~/.cursor/commands/*.md` — **Cursor commands carry NO frontmatter**, unlike Claude. |

## Isolated settings

Not available for Cursor. Cursor's IDE is not a launchable closed-world CLI. (The separate `cursor-agent` CLI has headless flags — `-p`/`--print`, `--force`, `--approve-mcps` — but `ap` doesn't drive it.)

## Quirks

- **Canonical host is `cursor.com/docs`** — `docs.cursor.com/*` URLs redirect there. Cite the `cursor.com/docs` form.
- **Permissions are not UI-only** — a long-standing assumption corrected: only the *IDE* allowlist is UI-only; the `cursor-agent` CLI reads a declarative `cli-config.json`. See [[../architecture/harness-permissions]] § Cursor.
- **"Custom modes" is dead.** `cursor.com/docs/chat/custom-modes` 404s; the schema reference is now [Subagents](https://cursor.com/docs/context/subagents). The repo's `modes/<name>.json` deploy targets the legacy `~/.cursor/modes.json` surface — migrate to `.cursor/agents/` when convenient. `cursor.com/docs/agent/modes` documents only the built-in Plan Mode, not custom agents.
- **Commands have no frontmatter** — a Cursor `commands/*.md` is plain markdown; a Claude command's YAML frontmatter must be stripped when porting.
- **Skills + agents read cross-harness dirs.** Cursor discovers skills/agents from `.claude/` and `.codex/` trees too (with its own `.cursor/` taking precedence), so some shared dirs are picked up without a Cursor-specific copy.
- Every Cursor doc page has a raw-markdown twin at `<url>.md` (e.g. `cursor.com/docs/hooks.md`) for unstyled source.

See also [[index]] for the capability matrix, [[../architecture/harness-permissions]] for the permission model, and `AGENTS.md` § Cursor Plugins for the full deploy-target table. Wiring details: [[../architecture/agent-profile]].
