# MCP secret handling — `${VAR}` passthrough per harness

## Why secrets are NOT baked at ingest

`ap` carries MCP `env` values as the **literal `${VAR}`** from ingest all the
way to each renderer, instead of resolving the secret at sync time. The goal:
keep real API keys out of the rendered config files on disk
(`~/.claude.json`, `~/.cursor/mcp.json`, `~/.config/opencode/opencode.json`,
`~/.copilot/mcp-config.json`). Each harness expands the placeholder itself at
launch from its process env (zsh exports every `.env` key on shell init, so
shell-launched CLIs already have the vars).

Before this change, `ingest._expand_mcps` called `resolve_item_env`, so every
renderer received the resolved secret and wrote it to disk — the keys sat in
plaintext.

## The ingest split: validate without substituting

`ingest.py:_expand_mcps` decouples **validation** from **substitution**:

- `optional` MCP with an unset `${VAR}` → dropped non-fatally (protects against
  rendering a server whose credential the user definitely lacks).
- non-`optional` MCP with an unset `${VAR}` → **fails loud** at ingest (catches
  a typo'd var name) — but WITHOUT substituting the value.
- otherwise → the item is appended with its env block **untouched** (the literal
  `${VAR}` rides through).

The fail-loud has a real blast radius on **claude**: an unset referenced var
with no default makes Claude fail to parse the *entire* `~/.claude.json`, so
every MCP dies. The `optional`-drop is what prevents this for credential-gated
servers (e.g. `todoist` without `TODOIST_API_KEY`). context7/tavily are
non-optional, so a fresh box with no `.env` will fail the base-profile render
until the keys are populated — intended, not a bug.

## Per-harness placeholder syntax (they diverge)

The hard part: the `${VAR}` runtime-expansion syntax is **not** uniform.

| Harness | Expands at runtime? | Placeholder emitted | Where written |
|---|---|---|---|
| **claude** | yes | `${VAR}` (literal) | `claude mcp add -e K='${VAR}'` (user scope) / plugin `.mcp.json` |
| **codex** | n/a — inherits shell env | — (scrubbed) | `~/.codex/config.toml` |
| **opencode** | yes | `{env:VAR}` | `opencode.json` `mcp.*.environment` |
| **cursor** | yes, but GUI-launched | `envFile` → abs `.env` | `~/.cursor/mcp.json` |
| **copilot** | yes (fragile) | `${VAR}` (literal) | chezmoi template, NOT the `ap` renderer |

### claude — literal passthrough, no code change

`_register_user_mcps` / `mcp_server_entry` already pass `entry["env"]` through;
with the literal flowing in, the CLI stores `${VAR}` verbatim and Claude expands
it at launch. Empirically verified: `claude mcp add probe -e PROBE_KEY='${FAKE}'`
stores `"${FAKE}"` literally.

### codex — scrub-by-keyname, unchanged

`codex.py` drops any env key present in `$DOTFILES_DIR/.env` from the rendered
TOML (zsh already exports them; codex is terminal-launched so its MCP children
inherit at runtime). The registry shape is `KEY: "${KEY}"` (key == varname), so
the scrub stays correct regardless of whether the value is the literal `${VAR}`
or a resolved secret. Neither the placeholder nor a secret lands in
`config.toml`.

### opencode — rewrite `${VAR}` → `{env:VAR}`

opencode does **not** understand `${VAR}` — it passes it through verbatim and
breaks (unset → silent empty string). `opencode._to_opencode_env` rewrites every
`${VAR}` occurrence to opencode's own `{env:VAR}` token; plain literals (e.g.
`SERENA_MUX_HARNESS`, a render-time per-harness value, not a secret) pass
through untouched.

### cursor — drop `${VAR}`, add `envFile`

Cursor's `${env:VAR}` resolves against Cursor's *process* env, but a Finder/Dock
launch inherits **no** shell `.env`. So `_cursor_mcp_entry` splits env into
`${VAR}`-referencing entries vs plain literals: literals stay in `env`; if any
`${VAR}`-ref existed, the entry drops those keys and gains an `envFile` field
pointing at the absolute `.env` (stdio servers only — all ours are stdio).
The abs path resolves `${DOTFILES_DIR}/.env` via `os.path.expandvars` with the
`~/Dev/dotfiles` fallback (the `discover.py` pattern). A machine-specific abs
path in user config is acceptable — same precedent as the marketplace path in
`claude.py`'s `_merge_root_settings`.

### copilot — chezmoi template, not the renderer

copilot is **excluded** from the `ap` MCP default membership
(`_COPILOT_MCP_DEFAULT = (claude, codex)`), so the `ap` copilot renderer writes
nothing for context7/tavily. The live `~/.copilot/mcp-config.json` is written by
the chezmoi template `private_dot_copilot/mcp-config.json.tmpl`, which emits the
literal `${CONTEXT7_API_KEY}` / `${TAVILY_API_KEY}` and always emits the servers
(the old unset-var warnf + empty-`mcpServers` stub branch is gone — there is no
apply-time key to resolve now). Copilot's `${VAR}` expansion regressed in CLI
v0.0.407 (gh#1403) and is thinly documented — if env passthrough breaks on a CLI
upgrade, that template is where to revisit.

## What was intentionally left alone

- **codex stays on scrub** (already clean — never wrote secrets in the
  shell-inherited common case).
- **`overlay.py` (isolated-launch path)** still resolves `${VAR}` to the secret
  in its **ephemeral** scratch `.mcp.json` — that file is passed directly to the
  launched `claude` via `--mcp-config` and discarded, never a persistent config.
  This is `ccp` parity (the retired `gen-profile-mcp.sh` resolved too).
- **Legacy bash `agents/mcp/lib.sh`** (`mcp_cursor_add` et al.) still bakes
  secrets at sync time, but that native-CLI path no longer runs on `dots sync`
  (superseded by the `ap` renderers). Dormant; not in scope.

See also [[agent-profile]] for the renderer architecture, [[cursor]],
[[opencode]], [[copilot]] for the per-harness config surfaces.
