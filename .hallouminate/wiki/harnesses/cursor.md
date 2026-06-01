# Cursor

The Cursor AI code editor (cursor.com). Unlike the other four, Cursor is an **IDE plugin surface, not a CLI harness** — but it's a full `ap` render target (`renderers/cursor.py`) plus a chezmoi-deployed plugin tree, so it carries the same six capabilities. Docs root: [cursor.com/docs](https://cursor.com/docs).

Two deploy paths feed Cursor:

- **MCP** flows through the harness-agnostic `agents/mcp/registry.yaml` like every other harness — the `ap` cursor renderer (`renderers/cursor.py`) writes `~/.cursor/mcp.json` via Python stdlib `json` (no jq), using the `mcpServers` schema (identical to Claude Desktop's). `CURSOR_CONFIG` overrides the target for tests.
- **Everything else** ships as a **Cursor 2.x plugin** under `cursor/plugins/local/<name>/` (the shipping one is `cheese-grok`). chezmoi's `install-cursor-plugin.sh` deploys its `skills/`, `rules/`, `commands/`, `hooks/` into `~/.cursor/{skills,rules,commands,hooks}/` and jq-merges `hooks.json` + `modes.json`. Per-collection `.dotfiles-managed-<plugin>` manifests track ownership so dropped items are pruned without touching user files.

## Capabilities, docs, and repo wiring

| Capability | Official doc | This repo |
|---|---|---|
| Hooks | [hooks](https://cursor.com/docs/agent/hooks) | `cursor/plugins/local/<plugin>/hooks/*.sh` + `hooks.json` → `~/.cursor/hooks/*.sh` (executable) and merged into `~/.cursor/hooks.json`. Entries tagged `_plugin: "<name>"` so re-deploys strip stale ones. Lifecycle events (`beforeShellExecution`, `afterFileEdit`, `beforeMCPExecution`, `stop`, …) with a 4-level location precedence incl. `~/.cursor/hooks.json`. |
| Sub-agents | [subagents](https://cursor.com/docs/context/subagents) | Cursor 2.x agents live in `.cursor/agents/` + `~/.cursor/agents/` (markdown + YAML: `name`, `description`, `model: inherit`, `readonly`, `is_background`). This repo currently deploys the legacy **custom-modes** surface (`modes/<name>.json` → merged into `~/.cursor/modes.json` under `.modes.<name>`). |
| MCP | [mcp](https://cursor.com/docs/context/mcp) | `agents/mcp/registry.yaml` → `ap` cursor renderer writes `~/.cursor/mcp.json` via stdlib `json` (`mcpServers`). stdio / SSE / Streamable-HTTP transport; project `.cursor/mcp.json` vs global `~/.cursor/mcp.json` scope; `env` / `envFile` / `${env:NAME}` interpolation. |
| Rules (system prompt) | [rules](https://cursor.com/docs/context/rules) | `cursor/plugins/local/<plugin>/rules/*.mdc` → `~/.cursor/rules/*.mdc`. Four rule types (Always / Apply Intelligently / Apply to Specific Files via glob / Apply Manually), `alwaysApply` / `description` / `globs` frontmatter, `AGENTS.md` support (incl. nested), precedence Team → Project → User. |
| Settings / config | [plugin manifest](https://cursor.com/docs/plugins/building) · [permissions](https://cursor.com/docs/reference/permissions) | `.cursor-plugin/plugin.json` manifest (required `name`; optional `version`/`author`/`description` + component paths) drives folder-based auto-discovery. `permissions.json` holds auto-run allowlists. |
| Skills / commands | [skills](https://cursor.com/docs/skills) · [slash commands](https://cursor.com/docs/cli/reference/slash-commands) | `cursor/plugins/local/<plugin>/skills/<name>/SKILL.md` → `~/.cursor/skills/<name>/` (frontmatter `name` + `description`, optional `paths`). `commands/*.md` → `~/.cursor/commands/*.md` — **Cursor commands carry NO frontmatter**, unlike Claude. |

## Isolated settings

Not available. Cursor is an IDE, not a launchable CLI — there are no closed-world launch flags; `ap` isolated launches are Claude-only.

## Quirks

- **Canonical host is `cursor.com/docs`** — `docs.cursor.com/*` URLs redirect there. Cite the `cursor.com/docs` form.
- **"Custom modes" is dead.** `cursor.com/docs/chat/custom-modes` 404s; the schema reference is now [Subagents](https://cursor.com/docs/context/subagents). The repo's `modes/<name>.json` deploy targets the legacy `~/.cursor/modes.json` surface — migrate to `.cursor/agents/` when convenient. `cursor.com/docs/agent/modes` documents only the built-in Plan Mode, not custom agents.
- **Commands have no frontmatter** — a Cursor `commands/*.md` is plain markdown; a Claude command's YAML frontmatter must be stripped when porting.
- **Skills + agents read cross-harness dirs.** Cursor discovers skills/agents from `.claude/` and `.codex/` trees too (with its own `.cursor/` taking precedence), so some shared dirs are picked up without a Cursor-specific copy.
- Every Cursor doc page has a raw-markdown twin at `<url>.md` (e.g. `cursor.com/docs/hooks.md`) for unstyled source.

See also [[index]] for the capability matrix and `AGENTS.md` § Cursor Plugins for the full deploy-target table. Wiring details: [[../architecture/agent-profile]].
