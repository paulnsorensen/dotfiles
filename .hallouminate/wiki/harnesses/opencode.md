# opencode

The sst/opencode CLI. Config lives under `~/.config/opencode/`, centred on `opencode.json`. Docs root: [opencode.ai/docs](https://opencode.ai/docs).

Unlike the dot-dir harnesses, opencode writes config at the *target root* (`~/.config/opencode/`), not a `.opencode/` subdir. So chezmoi drives it with a separate `ap install base --target ~/.config/opencode --harness opencode` (not `global` — there's no marketplace/plugin surface to enable). `opencode.json` is seeded once (chezmoi `create_opencode.json`) then the renderer jq-merges only the `mcp` + `permission.bash` keys.

## Capabilities, docs, and repo wiring

| Capability | Official doc | This repo |
|---|---|---|
| Hooks | <https://opencode.ai/docs/plugins/> | No first-class hooks — lifecycle events are exposed only via the plugin API (JS/TS, 25+ events). opencode has **no hook renderer** in `ap`, so the repo's harness-agnostic hooks (`agents/hooks/`) are never rendered for opencode. |
| Sub-agents | <https://opencode.ai/docs/agents/> | `agents/registry.yaml` → root-relative `agents/<n>.md`. Read-only agents get `permission.edit: deny` derived from their tool list. |
| MCP | <https://opencode.ai/docs/mcp-servers/> | `agents/mcp/registry.yaml` → `opencode.json` `mcp` key (local + remote). |
| System prompt | <https://opencode.ai/docs/rules/> | `agents/preamble.md` → `~/.config/opencode/agents/build.md` (the build-agent prompt, `install-prompts`). Also honors `AGENTS.md` rules + `instructions` field. |
| Settings / config | <https://opencode.ai/docs/config/> | `~/.config/opencode/opencode.json`. `tui.json` (theme `chocolate-donut`, `editor_open` → `ctrl+o`) and `themes/chocolate-donut.json` are always-managed by chezmoi. |
| Skills | <https://opencode.ai/docs/skills/> | `skills/` → loaded via the native `skill` tool; opencode also reads Claude/`.agents` skill dirs. |

## Isolated settings

Not available. opencode has no closed-world launch flags; `ap` isolated launches are Claude-only.

## Quirks

- **No non-interactive MCP CLI**: opencode has no `mcp add` command, so the renderer jq-edits `opencode.json` directly. `OPENCODE_CONFIG` overrides the target path (used by tests).
- **`.json` not `.jsonc`**: the scaffold writes `opencode.json`. If migrating from a hand-rolled `opencode.jsonc`, merge into `opencode.json` and delete the `.jsonc` (opencode reads either; having both is confusing).
- No native modal vim editing in the input box — the `ctrl+o` rebind pops the textbox out to `$EDITOR` (vim) as the closest workflow.
