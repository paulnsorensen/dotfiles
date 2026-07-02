# opencode

The sst/opencode CLI. Config lives under `~/.config/opencode/`, centred on `opencode.json`. Docs root: [opencode.ai/docs](https://opencode.ai/docs).

Unlike the dot-dir harnesses, opencode stores live config at `~/.config/opencode/opencode.json`, not a `.opencode/` subdir. Chezmoi seeds that file once (`create_opencode.json`) and owns adjacent always-managed UI files (`tui.json`, themes). Non-isolated `ap install opencode-global --harness opencode` now writes generated `agents/<n>.md` and `skills/<n>/` under `~/.config/opencode/` but does **not** merge live `opencode.json`; isolated `ap launch opencode <profile>` injects its closed-world config through env vars instead.

## Capabilities, docs, and repo wiring

| Capability | Official doc | This repo |
|---|---|---|
| Hooks | <https://opencode.ai/docs/plugins/> | No first-class hooks — lifecycle events are exposed only via the plugin API (JS/TS, 25+ events). opencode has **no hook renderer** in `ap`, so the repo's harness-agnostic hooks (`agents/hooks/`) are never rendered for opencode. |
| Sub-agents | <https://opencode.ai/docs/agents/> | `agents/registry.yaml` → root-relative `agents/<n>.md`. Read-only agents get `permission.edit: deny` derived from their tool list. |
| MCP | <https://opencode.ai/docs/mcp-servers/> | Isolated profiles render `mcp` into generated config content; non-isolated live `opencode.json` is chezmoi/user-owned, not mutated by `ap install opencode-global`. |
| System prompt | [rules](https://opencode.ai/docs/rules/) · [precedence](https://opencode.ai/docs/rules/#precedence) | `agents/preamble.md` → `~/.config/opencode/agents/build.md` (the build-agent prompt, `install-prompts`). Also honors `AGENTS.md` rules + the `instructions` config key (file paths/globs/remote URLs, 5s fetch timeout). |
| Settings / config | <https://opencode.ai/docs/config/> | `~/.config/opencode/opencode.json`. `tui.json` (theme `chocolate-donut`, `editor_open` → `ctrl+o`) and `themes/chocolate-donut.json` are always-managed by chezmoi. |
| Skills | <https://opencode.ai/docs/skills/> | `skills/` → loaded via the native `skill` tool; opencode also reads Claude/`.agents` skill dirs. |

## Local LLM provider + the `opencode-lean` launcher

When the `localLLM` flag is on, `chezmoi/lib/install-local-llm.sh` jq-merges a `local-llm` provider into `opencode.json` (`Local (LiteLLM)`, `http://127.0.0.1:4000/v1`, key `sk-local`), exposing the stack's models as `local-llm/<name>`. The `opencode-lean` shell alias is the intended launch path — it sets `OPENCODE_CONFIG` to a lean overlay that disables the heavy MCP servers so a small local context window survives. Full detail (launch syntax, cold-load behavior, known rough edges #297–#300): [[operations/local-llm]] § *Using the stack from opencode*.

## Isolated settings

Available through `ap`'s env-based isolated opencode launch. The closed-world config is injected via `OPENCODE_CONFIG_CONTENT`, `OPENCODE_PERMISSION`, and `OPENCODE_DISABLE_PROJECT_CONFIG=true` rather than CLI flags. Caveats: opencode still auto-loads project `AGENTS.md` / `CLAUDE.md`, and there is no ephemeral-session equivalent.

## Quirks

- **No non-interactive MCP CLI**: opencode has no `mcp add` command. `ap` therefore only renders MCP config when it owns the generated/isolated config surface; live `opencode.json` is left to chezmoi/user ownership. `OPENCODE_CONFIG` overrides the target path (used by lean overlays/tests), and isolated profiles inject `OPENCODE_CONFIG_CONTENT`.
- **`.json` not `.jsonc`**: the scaffold writes `opencode.json`. If migrating from a hand-rolled `opencode.jsonc`, merge into `opencode.json` and delete the `.jsonc` (opencode reads either; having both is confusing).
- No native modal vim editing in the input box — the `ctrl+o` rebind pops the textbox out to `$EDITOR` (vim) as the closest workflow.
