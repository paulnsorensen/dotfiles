# OpenCode

OpenCode (`anomalyco/opencode`, docs at [opencode.ai/docs](https://opencode.ai/docs/)) is a native chezmoi harness, like Pi. It is not an `ap` render target. Chezmoi owns its global configuration; OpenCode owns authentication and runtime state.

## History

PR #696 (2026-08-13) retired OpenCode together with Crush, its `ap` renderer, and its local-LLM paths. OpenCode returned on 2026-09-28 as a native sibling. The `ap` renderer stays retired: a Pi-style registry plus a modify script needs no renderer code.

## Ownership

`chezmoi/.chezmoidata/opencode.yaml` holds the full `opencode.config` document.

- `chezmoi/dot_config/opencode/modify_opencode.json` writes `~/.config/opencode/opencode.json` from the registry.
- The modifier uses the shared drift gate (`chezmoi/lib/drift-gate.sh`). It keeps unknown live keys with a warning and records them in `harness-drift/opencode-config`.
- `lib/opencode-config-retired.txt` deletes the legacy `tools` map. OpenCode v1.1.1 replaced that map with `permission`.
- `tui.json` and `themes/chocolate-donut.json` deploy as plain files.
- `~/.local/share/opencode/auth.json`, sessions, state, and caches stay OpenCode-owned.

**Why a modify script, not a plain file:** OpenCode writes to its global config at runtime. `Config.updateGlobal` (the global config HTTP API) patches `opencode.json`. The loader also inserts `$schema` when it is missing. A plugin install writes `package.json`, `node_modules/`, and `.gitignore` into `~/.config/opencode/`. For this reason the directory is never an `exact_` target. Source: `packages/opencode/src/config/config.ts`.

## Settings

| Key | Value | Why |
|---|---|---|
| `autoupdate` | `false` | mise pins the binary; Renovate bumps the pin. |
| `share` | `disabled` | Keep sessions local. |
| `lsp` | `true` | OpenCode feeds LSP diagnostics back after each native edit. The schema disables LSP when the key is absent. |
| `formatter` | `true` | Built-in formatters run after native edits. The schema disables them when the key is absent. |
| `compaction.prune` | `true` | Drop old tool outputs before a full compaction (default `false`). |
| `instructions` | `~/.config/opencode/preamble.md` | Appends the shared preamble to OpenCode's own system prompt. The loader expands `~/`. |
| `mcp` | tilth (`--mcp --edit`), context7, tavily, milknado, hallouminate | The same server set as Codex and Pi. Secret-bearing servers use the broker sockets. |
| `permission` | `*` allow; secret-path `read` denies; `sudo`/`rm -rf`/`security`/`bws` bash denies | Mirrors Claude `permissions.deny` and the Pi permission system. |

Native `read`, `edit`, `grep`, and `glob` stay enabled, as in Claude and Codex; the preamble steers file work to Tilth. The `read` denies gate only OpenCode's native tools. MCP tools such as `tilth_read` are not path-gated by OpenCode.

## Shared resources

- `run_onchange_after_install-agents-doc.sh.tmpl` copies `agents/AGENTS.md` to `~/.config/opencode/AGENTS.md`. That file wins over the `~/.claude/CLAUDE.md` fallback.
- `chezmoi/lib/install-prompts.sh` copies `agents/preamble.md` to `~/.config/opencode/preamble.md`.
- OpenCode discovers skills natively from `~/.config/opencode/skills`, `~/.claude/skills`, `~/.agents/skills`, and project `.claude`/`.agents`/`.opencode` skill dirs. Chezmoi copies no skill tree.

**Duplicate skills:** most skills exist in both `~/.claude/skills` and `~/.agents/skills`. OpenCode logs a `duplicate skill name` warning and keeps one copy; the `~/.agents/skills` copy won in a 2026-09-28 check (119 skills loaded). Set `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1` only if the warnings matter; that also hides the Claude-only synced skills.

## Installation

`chezmoi/dot_config/mise/config.toml` pins `aqua:anomalyco/opencode`. `packages/sync.sh` removes a Homebrew `opencode` formula and a stale `~/.local/bin/opencode` so the mise shim wins. Crush stays retired.

## Gaps

- No sub-agent definitions render for OpenCode. It uses its built-in `general` and `explore` subagents. The preamble's named specialists (`coder`, `reviewer`) do not exist there.
- No hook parity. OpenCode exposes lifecycle events only through JS/TS plugins.
- Claude Pro/Max subscriptions do not work in third-party harnesses. Use ChatGPT, Copilot, API keys, or OpenCode Zen through `/connect`.
- `model` stays unset. A hand-set `model` shows as drift until it is folded into the registry.

## Validation

`tests/opencode-config.bats` covers rendering, drift handling, MCP wiring, permissions, and the chezmoi apply. `opencode debug config` on v1.18.33 accepted the rendered file, and `opencode mcp list` showed all five servers connected.

Related: [[index]], [[pi]], [[../operations/sync-and-chezmoi]], [[../architecture/config-drift]].
