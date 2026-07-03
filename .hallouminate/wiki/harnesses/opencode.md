# opencode

The sst/opencode CLI. Config lives under `~/.config/opencode/`, centred on `opencode.json`. Docs root: [opencode.ai/docs](https://opencode.ai/docs).

Unlike the dot-dir harnesses, opencode writes config at the *target root* (`~/.config/opencode/`), not a `.opencode/` subdir. So chezmoi drives it with a dedicated live wrapper profile: `ap install opencode-global --harness opencode`. The installer forwards `HOME`, and the wrapper carries `_permissions` plus `target_default: $HOME/.config/opencode`, so the shipped path lands at `~/.config/opencode/` without passing `--target`. That keeps external `source:` skills on the normal live `npx skills add` path. `opencode.json` is seeded once (chezmoi `create_opencode.json`) then the renderer merges the `mcp` plus full `permission` object via Python stdlib `json` (read-modify-write, no jq).

## Capabilities, docs, and repo wiring

| Capability | Official doc | This repo |
|---|---|---|
| Hooks | <https://opencode.ai/docs/plugins/> | No first-class hooks — lifecycle events are exposed only via the plugin API (JS/TS, 25+ events). opencode has **no hook renderer** in `ap`, so the repo's harness-agnostic hooks (`agents/hooks/`) are never rendered for opencode. |
| Sub-agents | <https://opencode.ai/docs/agents/> | `agents/registry.yaml` → root-relative `agents/<n>.md`. Read-only agents get `permission.edit: deny` derived from their tool list. |
| MCP | <https://opencode.ai/docs/mcp-servers/> | `agents/mcp/registry.yaml` → `opencode.json` `mcp` key (local + remote). |
| System prompt | [rules](https://opencode.ai/docs/rules/) · [precedence](https://opencode.ai/docs/rules/#precedence) | `agents/preamble.md` → `~/.config/opencode/agents/build.md` (the build-agent prompt, `install-prompts`). Also honors `AGENTS.md` rules + the `instructions` config key (file paths/globs/remote URLs, 5s fetch timeout). |
| Settings / config | <https://opencode.ai/docs/config/> | `~/.config/opencode/opencode.json`. `tui.json` (theme `chocolate-donut`, `editor_open` → `ctrl+o`) and `themes/chocolate-donut.json` are always-managed by chezmoi. |
| Skills | <https://opencode.ai/docs/skills/> | `skills/` → loaded via the native `skill` tool; opencode also reads Claude/`.agents` skill dirs. |

## Local LLM provider + the `opencode-lean` launcher

When the `localLLM` flag is on, `chezmoi/lib/install-local-llm.sh` jq-merges a `local-llm` provider into `opencode.json` (`Local (LiteLLM)`, `http://127.0.0.1:4000/v1`, key `sk-local`), exposing the stack's models as `local-llm/<name>`. The `opencode-lean` shell alias is the intended launch path — it sets `OPENCODE_CONFIG` to a lean overlay that disables the heavy MCP servers so a small local context window survives. Full detail (launch syntax, cold-load behavior, known rough edges #297–#300): [[operations/local-llm]] § *Using the stack from opencode*.

## Isolated settings

Available through `ap`'s env-based isolated opencode launch. The closed-world config is injected via `OPENCODE_CONFIG_CONTENT`, `OPENCODE_PERMISSION`, and `OPENCODE_DISABLE_PROJECT_CONFIG=true` rather than CLI flags. Caveats: opencode still auto-loads project `AGENTS.md` / `CLAUDE.md`, and there is no ephemeral-session equivalent.

## Quirks

- **No non-interactive MCP CLI**: opencode has no `mcp add` command, so the renderer edits `opencode.json` directly via Python stdlib `json` (read-modify-write, no jq). `OPENCODE_CONFIG` overrides the target path (used by tests, and by `opencode-lean` for the lean overlay).
- **`.json` not `.jsonc`**: the scaffold writes `opencode.json`. If migrating from a hand-rolled `opencode.jsonc`, merge into `opencode.json` and delete the `.jsonc` (opencode reads either; having both is confusing).
- No native modal vim editing in the input box — the `ctrl+o` rebind pops the textbox out to `$EDITOR` (vim) as the closest workflow.
