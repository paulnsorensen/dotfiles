# OpenCode

OpenCode (`anomalyco/opencode`, docs at [opencode.ai/docs](https://opencode.ai/docs/)) is a native chezmoi harness, like Pi. It is not an `ap` render target. Chezmoi owns its global configuration; OpenCode owns authentication and runtime state. The pinned release is OpenCode v2.

## History

PR #696 (2026-08-13) retired OpenCode together with Crush, its `ap` renderer, and its local-LLM paths. OpenCode returned on 2026-09-28 as a native sibling. The `ap` renderer stays retired: a Pi-style registry plus a modify script needs no renderer code.

On 2026-10-11 the harness moved from v1.18.33 to v2.0.26. Renovate PR #1249 tried an aqua bump, but v2 has no GitHub release assets. The v2 port (PR #1251) changed the install backend, both plugins, the Tilth MCP entry, and the CLI config file.

## Ownership

`chezmoi/.chezmoidata/opencode.yaml` holds the full `opencode.config` document.

- `chezmoi/dot_config/opencode/modify_opencode.json` writes `~/.config/opencode/opencode.json` from the registry.
- The modifier replaces the complete MCP subtree from the registry. It preserves unrelated unknown live keys with a warning.[^mcp-authority]
- `chezmoi/modify_opencode.json.tmpl` removes MCP overrides from `~/opencode.json` and preserves all other settings.[^home-mcp]
- `lib/opencode-config-retired.txt` deletes retired keys outside the MCP subtree.
- `cli.json` and `themes/*.json` deploy as plain files. `.chezmoiremove` deletes the v1 `tui.json`.
- `~/.local/share/opencode/` (auth, database, logs) stays OpenCode-owned.

**Why MCP authority needs home cleanup:** OpenCode searches ancestor directories, so a home config can override the managed global config.[^ancestor-config]
Removing home MCP overrides prevents retired servers and credentials from returning. Project-local overrides remain outside this ownership boundary.

**Why a modify script, not a plain file:** OpenCode writes to its global config at runtime. A plugin install writes `package.json`, `node_modules/`, and `.gitignore` into `~/.config/opencode/`. For this reason the directory is never an `exact_` target.

**Why v1 config syntax stays:** v2 normalizes v1 keys on load (`autoupdate` to `update`, `mcp` to `mcp.servers`, `permission` maps to ordered `permissions`, `bash` to `shell`, `task` to `subagent`). Supported v1 functionality outside plugins, the server API, and `tui.json` stays compatible.[^migrate] Do not mix v1 and v2 fields inside one agent or provider.

**Exception: a v2-only field needs the v2 shape.** v2 decodes each v1-shaped `mcp.<name>` entry with the v1 schema and drops fields that schema lacks, such as `codemode`.[^mcp-normalize] Tilth therefore uses `mcp.servers.tilth`. The other servers stay v1-shaped; v2 merges both shapes.

[^migrate]: OpenCode v2.0.26, services/www/src/docs/content/migrate-v1.mdx:8-19
[^mcp-normalize]: OpenCode v2.0.26, packages/core/src/config/normalize.ts:264-297; packages/core/src/v1/config/migrate.ts:80-105

## Settings

| Key | Value | Why |
|---|---|---|
| `autoupdate` | `false` | mise pins the binary; Renovate bumps the pin. v2 reads it as `update: disable`. |
| `share` | `disabled` | Keep sessions local. |
| `formatter` | `true` | Built-in formatters run after edits. The schema disables them when the key is absent. |
| `compaction.auto` | `true` | v2 ignores `compaction.prune` with a warning, so the key is retired. |
| `instructions` | `~/.config/opencode/preamble.md` | Loads the shared execution preamble. Custom work-agent prompts replace native tool guidance. |
| `mcp` | `servers.tilth` (`--mcp --edit`, `codemode: false`); context7, tavily, milknado, hallouminate | The same server set as Codex and Pi. Secret-bearing servers use the broker sockets. |
| `permission` | `*` allow; secret-path `read` denies; `sudo`/`rm -rf`/`security`/`bws` bash denies | Mirrors Claude `permissions.deny` and the Pi permission system. |

v2 runs no language servers. It accepts `lsp` but produces no diagnostics, so the key is retired.[^lsp]

**Why `codemode: false` on Tilth:** v2 puts MCP tools behind a Code Mode `execute` tool by default. Native file tools are removed, so Tilth must stay on the native tool list.[^codemode] An agent with a `"*": deny` default also denies `execute`; behind Code Mode, such an agent would have no file access.

[^lsp]: OpenCode v2.0.26, services/www/src/docs/content/migrate-v1.mdx:415-416
[^codemode]: OpenCode v2.0.26, services/www/src/docs/content/mcp-servers.mdx:322-338; packages/schema/src/mcp.ts:26-39

## Tilth-only plugin

The plugin removes `read`, `edit`, `write`, `patch`, `grep`, and `glob` from the tool set. Its `execute.before` hook also rejects those IDs.[^tilth-plugin]

**Why two layers:** `ctx.tool.transform` removes the built-ins from every model request. The hook rejects them if another path registers them again.

v2 renamed `apply_patch` to `patch` and has no `list` tool; `read` also lists directories.

Only the native `read` tool checks the `read` permission map. The plugin removes that tool, so the secret-path denies apply only if the plugin does not load.[^authorize-read] OpenCode does not path-gate MCP tools such as `tilth_tilth_read`. Tilth owns its file-access policy.

**Why a plain object export:** local plugins load from `~/.config/opencode/plugins/` with no `node_modules`. `Plugin.define` is an identity function, so `export default { id, setup }` behaves the same.[^define]

[^tilth-plugin]: chezmoi/dot_config/opencode/plugins/tilth-only.js; tests/opencode-plugin.bats
[^authorize-read]: OpenCode v2.0.26, packages/core/src/tool/plugin/read.ts:55,66
[^define]: OpenCode v2.0.26, packages/plugin/src/promise/plugin.ts:56-65; packages/core/src/plugin/module.ts:78-133

## Shared resources

`build`, `plan`, `general`, and `explore` use explicit prompts that direct them to the shared preamble.[^work-prompts]
Shared specialists already use their role bodies as custom prompts.

**Why explicit prompts:** global instructions append to the native provider prompt; they do not replace it.
Plan and explore prompts retain their read-only direction.
Internal title, summary, and compaction prompts remain native.

[^work-prompts]: chezmoi/.chezmoidata/opencode.yaml; tests/opencode-agents.bats

- `run_onchange_after_install-agents-doc.sh.tmpl` copies `agents/AGENTS.md` to `~/.config/opencode/AGENTS.md`. v2 has no `CLAUDE.md` fallback.
- `chezmoi/lib/install-prompts.sh` copies `agents/preamble.md` to `~/.config/opencode/preamble.md`.
- OpenCode discovers skills natively from its config `skill`/`skills` directories and the `.claude`/`.agents` roots. Chezmoi copies no skill tree.

### Specialist policy

OpenCode uses the existing shared role bodies from `agents/registry.yaml`.[^shared-agents]

**Why native composition:** `ap` does not accept OpenCode harness membership. Per-harness model metadata does not change other renderers.[^shared-agents]

The root and six Sol specialists use `gpt-6.1-sol`. Narrow roles retain Luna. Review, judgment, and advice retain Astra.[^native-agents]

Each specialist denies Task launches. Its step limit follows the shared registry.

The advisor accepts a concise contract and evidence packet. Four steps bound its work. A default-deny policy allows only Tilth read and search.[^native-agents]

[^shared-agents]: agents/registry.yaml; .sync-lib.sh `_cz_opencode_agents_json`
[^native-agents]: chezmoi/.chezmoidata/opencode.yaml; tests/opencode-agents.bats

## Post-idle checkpoint plugin (retired)

The `wheypoint-idle.js` plugin is gone since PR #1267. `.chezmoiremove` deletes the deployed plugin and its library. See [[wheypoint-stop-hook]].

## Installation

`chezmoi/dot_config/mise/config.toml` pins `npm:@opencode/cli` with `allow_builds = ["@opencode/cli"]`.

**Why npm, not aqua:** v2 publishes only to npm. Its GitHub tags have no release assets, so the aqua backend returns 404.

**Why `allow_builds`:** mise's npm installer skips lifecycle scripts by default. The package `postinstall` links the platform binary; without it, `opencode` exits with "postinstall script was not run".

`packages/sync.sh` removes a Homebrew `opencode` formula and a stale `~/.local/bin/opencode` so the mise shim wins. `retire_harnesses` uninstalls the old `aqua:anomalyco/opencode` install and keeps Crush retired.

## Gaps

- v2 has no `doom_loop` guard. The v1 prompt for repeated identical tool calls is gone, and `build`, `plan`, `general`, and `explore` set no `steps`, so v2 does not bound their turns.[^doom-loop] The operator chose to keep this unbounded.
- Claude Pro/Max subscriptions do not work in third-party harnesses. Use ChatGPT, Copilot, API keys, or OpenCode Zen.
- Live inference requires operator authentication. Sync never reads or copies authentication.

[^doom-loop]: OpenCode v2.0.26, services/www/src/docs/content/permissions.mdx:136; packages/core/src/session/runner/llm.ts:223

## Validation

`tests/opencode-config.bats` covers rendering, drift handling, retired keys, MCP wiring, permissions, `cli.json`, the mise pin, and the chezmoi apply. When OpenCode v2 is installed, it also runs `opencode debug config` in a sandboxed `HOME` on a private service port and checks that Tilth keeps `codemode: false` after normalization.

On 2026-10-11, OpenCode v2.0.26 ran in a sandboxed `HOME` against the rendered config. `debug config` and `debug agents` accepted it, and `mcp list` connected all five servers. Both plugins reported `active`, and no native file tool remained in `ctx.tool.list()`. That first run used the v1-shaped Tilth entry, and `debug config` showed that v2 dropped `codemode`; PR #1251 review found this, and the `mcp.servers` shape fixed it.

Related: [[index]], [[pi]], [[../operations/sync-and-chezmoi]], [[../architecture/config-drift]].

[^mcp-authority]: chezmoi/dot_config/opencode/modify_opencode.json:67-82; tests/opencode-config.bats:49-56
[^home-mcp]: chezmoi/modify_opencode.json.tmpl:1-8; chezmoi/lib/opencode-config.sh:1-16; tests/opencode-config.bats:58-83
[^ancestor-config]: <https://opencode.ai/v2/docs/config#locations>
