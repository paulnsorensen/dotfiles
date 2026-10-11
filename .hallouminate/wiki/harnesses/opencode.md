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
| `instructions` | `~/.config/opencode/preamble.md` | Loads the shared execution preamble. Custom work-agent prompts replace native tool guidance. The loader expands `~/`. |
| `mcp` | tilth (`--mcp --edit`), context7, tavily, milknado, hallouminate | The same server set as Codex and Pi. Secret-bearing servers use the broker sockets. |
| `permission` | `*` allow; secret-path `read` denies; `sudo`/`rm -rf`/`security`/`bws` bash denies | Mirrors Claude `permissions.deny` and the Pi permission system. |

The native Tilth plugin hides and rejects `read`, `edit`, `write`, `apply_patch`, `grep`, `glob`, and `list`. It retains nonnative tools.[^tilth-plugin]

**Why two hooks:** `chat.message` removes native file tools from model requests. `tool.execute.before` rejects them if another path exposes them.[^tilth-plugin]

Legacy `tools.read=false` is insufficient on v1.18.33. Explicit `permission.read` rules override converted tool permissions. Keep the secret-path and dangerous-bash maps unchanged.[^tilth-precedence]

OpenCode does not path-gate MCP tools such as `tilth_tilth_read`. Tilth owns its file-access policy.

[^tilth-plugin]: chezmoi/dot_config/opencode/plugins/tilth-only.js:1-31; tests/opencode-plugin.bats:16-65
[^tilth-precedence]: OpenCode v1.18.33, packages/opencode/src/config/config.ts:524-535; packages/opencode/src/session/llm/request.ts:193-199

## Shared resources

`build`, `plan`, `general`, and `explore` use explicit prompts that direct them to the shared preamble.[^work-prompts]
Shared specialists already use their role bodies as custom prompts.

**Why explicit prompts:** global instructions append to the native provider prompt; they do not replace it.
A nonempty `agent.prompt` replaces provider guidance while keeping environment and project instructions.[^prompt-selection]
This removes native file-tool advice without changing Tilth or permission guards.
Plan and explore prompts retain their read-only direction.
Internal title, summary, and compaction prompts remain native.

[^work-prompts]: chezmoi/.chezmoidata/opencode.yaml; tests/opencode-agents.bats
[^prompt-selection]: [OpenCode v1.18.33 request preparation](https://github.com/anomalyco/opencode/blob/v1.18.33/packages/opencode/src/session/llm/request.ts#L50-L103); [native agent overrides](https://github.com/anomalyco/opencode/blob/v1.18.33/packages/opencode/src/agent/agent.ts#L257-L283)

- `run_onchange_after_install-agents-doc.sh.tmpl` copies `agents/AGENTS.md` to `~/.config/opencode/AGENTS.md`. That file wins over the `~/.claude/CLAUDE.md` fallback.
- `chezmoi/lib/install-prompts.sh` copies `agents/preamble.md` to `~/.config/opencode/preamble.md`.
- OpenCode discovers skills natively from `~/.config/opencode/skills`, `~/.claude/skills`, `~/.agents/skills`, and project `.claude`/`.agents`/`.opencode` skill dirs. Chezmoi copies no skill tree.

**Duplicate skills:** most skills exist in both `~/.claude/skills` and `~/.agents/skills`. OpenCode logs a `duplicate skill name` warning and keeps one copy; the `~/.agents/skills` copy won in a 2026-09-28 check (119 skills loaded). Set `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1` only if the warnings matter; that also hides the Claude-only synced skills.

### Specialist policy

OpenCode uses the existing shared role bodies. The registry contains 13 roles; the planning count of 12 is stale.[^shared-agents]

**Why native composition:** `ap` does not accept OpenCode harness membership. Per-harness model metadata does not change other renderers.[^shared-agents]

The root and six Sol specialists use `gpt-6.1-sol`. Narrow roles retain Luna. Review, judgment, and advice retain Astra.[^native-agents]

Each specialist denies Task launches. Its step limit follows the shared registry. Native Task passes the dispatch prompt, not the parent transcript.[^task-context]

The advisor accepts a concise contract and evidence packet. Four steps bound its work. A default-deny policy allows only Tilth read and search.[^native-agents]

The hidden Luna checker has one step and no tools. It classifies checkpoint policy; it cannot change the repository.[^native-agents]

Explicit model entries keep the selected IDs discoverable on the pinned binary. Their token limits match the official OpenAI model pages.[^model-limits]

[^shared-agents]: agents/registry.yaml; .sync-lib.sh:756-801; agent-profile/agent_profile/harnesses.py:8-35
[^native-agents]: chezmoi/.chezmoidata/opencode.yaml:13-53; tests/opencode-agents.bats:14-58
[^task-context]: OpenCode v1.18.33, packages/opencode/src/tool/task.ts:144-195
[^model-limits]: [Luna](https://developers.openai.com/api/docs/models/gpt-6-luna), [Sol 6.1](https://developers.openai.com/api/docs/models/gpt-6.1-sol), [Astra](https://developers.openai.com/api/docs/models/gpt-6-astra)

## Installation

`chezmoi/dot_config/mise/config.toml` pins `aqua:anomalyco/opencode`. `packages/sync.sh` removes a Homebrew `opencode` formula and a stale `~/.local/bin/opencode` so the mise shim wins. Crush stays retired.

## Gaps

- No hook parity. OpenCode exposes lifecycle events only through JS/TS plugins.
- Claude Pro/Max subscriptions do not work in third-party harnesses. Use ChatGPT, Copilot, API keys, or OpenCode Zen through `/connect`.
- Live OpenAI inference requires operator authentication through `/connect`. Sync never reads or copies authentication.

## Validation

`tests/opencode-config.bats` covers rendering, drift handling, MCP wiring, permissions, and the chezmoi apply. `opencode debug config` on v1.18.33 accepted the rendered file, and `opencode mcp list` showed all five servers connected.

Related: [[index]], [[pi]], [[../operations/sync-and-chezmoi]], [[../architecture/config-drift]].
