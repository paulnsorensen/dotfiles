# The `ap` Tool (`agent-profile/`)

`ap` is the engine that turns the declarative registries (see [[agents-dir]]) into the concrete per-harness config trees, and that owns the profile system. It's a uv-managed Python package (`agent-profile/agent_profile/`) invoked through the `agent-profile/ap` shim, which `exec`s `uv run --project <agent-profile> -m agent_profile`. The package is a behavioral port of an earlier bash CLI, so its golden tests assert string identity against the bash output.

The CLI surface (`agent_profile/cli.py`): `list`, `describe`, `path`, `install`, `uninstall`, `launch`. The user-facing entry is `dots profile <cmd>`.

## Profiles: what they are

A profile is a directory at `profiles/<name>/` (repo root) holding a `profile.yaml` plus optional payload (`CLAUDE.md` for isolated profiles). A `profile.yaml` declares item lists (`mcps`/`agents`/`skills`/`commands`/`hooks`) *or* a `registries:` directive that expands into them — plus, depending on profile kind, launch-overlay and install-overlay fields.

Profile resolution (`discover.py:find_profile_dir`) searches, first-match-wins:

1. `$AP_EXTRA_SEARCH_PATHS` (colon-separated)
2. `$PWD/.agent-profiles/<name>/` (per-repo, shadows global)
3. `$DOTFILES_DIR/profiles/<name>/` (global library; `DOTFILES_DIR` defaults to `~/Dev/dotfiles`)

### The `registries:` directive and ingest

`profiles/base/profile.yaml` is the *only* profile that reads the four registries:

```yaml
registries:
  mcps:    agents/mcp/registry.yaml
  agents:  agents/registry.yaml
  skills:  [skills/_registry.yaml, skills/]
  hooks:   agents/hooks/registry.yaml
  plugins: agents/plugins/registry.yaml
```

`ingest.py:expand_registries` reads each registry relative to the repo root, normalizes every entry into a profile *item* (a registry entry **is** a profile item — no translation layer), and stamps `_source_dir = <repo_root>` so payload files (`body_path`, hook `script`, skill `path`) resolve against the repo. The plugin registry is the exception: it resolves a marketplace root to a payload root and emits MCP, skill, agent, hook, and native-plugin items with `_source_dir` stamped at the payload root. Ingest also resolves inline `${VAR}` env refs from `$DOTFILES_DIR/.env` (`env.py`) and drops `optional` MCPs with unset credentials. Plugin `commands/` are intentionally not decomposed.

### `parse.py`: profile.yaml → `Manifest`

`parse_manifest` resolves a profile into a `Manifest` dataclass. It DFS-walks the `include:` graph (`_parse_with_includes`, cycle-detecting on the resolution stack so a diamond DAG is legal), concatenates item arrays (includes first so the outer profile's items append last), and deep-merges `settings` (with `permissions_allow` unioned + sorted).

Crucial asymmetry: **item lists merge from includes; overlay fields don't.** `name`, `description`, and every launch/install-overlay field (`isolated`, `system_prompt`, `tools`, `permissions_deny/allow`, `enabled_plugins`, `env`, `extra_args`, `target_default`, `marketplaces`) come from the *outermost* profile only. Isolation is a property of the profile you launch, not of what it includes.

## The base / global / specialized / isolated taxonomy

| Profile kind | Example | Shape | Purpose |
|---|---|---|---|
| **base** (render primitive) | `base` | `registries:` only, no overlay | The registry union. `ap install base` renders it to `$PWD` — useful for staging/inspection; does **not** touch live config |
| **global** (install overlay) | `global` | `include: [base]` + install-overlay | The live install. Wraps base with `target_default: $HOME`, the `local` marketplace, and `enabled_plugins: {global@local: true}` |
| **specialized** | `fe`, `spec`, `plugin`, `review`, … | `registries:` / `include` + overlay | Task-shaped sessions, often closed worlds |
| **isolated** (closed world) | `review`, `todo`, `fe`, `spec`, `notion`, `rtkonly`, `plugin` | `isolated: true` + launch-overlay | ccp-parity closed-world launches |

The base/global split exists for one reason: `ap install base` without `--target` writes the plugin tree into `$PWD`, which reads as confusing for "make my machine live". `global` makes operator intent legible — `ap install global` (no flags) targets `$HOME` and renders the shared/plugin artifacts there, but it no longer mutates harness-global settings files; those live settings move to chezmoi/user ownership.

## `ap install` vs `ap launch`

### `install` (`cli.cmd_install`)

Renders a profile into a target directory and records a manifest for surgical uninstall:

1. Parse the profile → `Manifest`.
2. Resolve target (precedence below). Refuses to install into a git working tree when no `--target` and no `target_default` are given — otherwise it'd dump `.codex/`, `.cursor/`, `manifest.json` into the repo.
3. `manifest_init(target)`.
4. For each in-scope harness, call `renderer.render(manifest, target)`, collecting the relative paths written.
5. Fetch `source:` skills via `npx skills add`.
6. Record the file list + resolved `merged_json` into `<target>/.agent-profile/manifest.json`.

### `launch` (`cli.cmd_launch`)

For a **non-isolated** profile: `install` for the single named harness, then `os.execvp` the bare harness CLI with passthrough args.

For an **isolated** profile (`overlay.py:build_isolated_launch`): build the closed-world `(flags, env)`, inject the profile's `env`, and `execvp <harness>` — no install, no manifest. Isolation is dispatched per harness via `_ISOLATION_BUILDERS` (`{claude, codex, opencode}`); each harness reaches the same closed world by a *different mechanism* behind the one `(flags, env)` contract. cursor/copilot/crush have no runtime-isolation lever, so an isolated launch against them fails loud (`IsolationError` → `CliError`).

### Per-harness closed-world matrix

| Capability | claude (`_build_isolated_claude`) | codex (`_build_isolated_codex`) | opencode (`_build_isolated_opencode`) |
|---|---|---|---|
| Closed MCP world | `--strict-mcp-config --mcp-config <ephemeral .mcp.json>` | `[mcp_servers.<n>]` tables in a generated `<CODEX_HOME>/config.toml` (no whole-file `--mcp-config` flag exists; HTTP MCPs carry `url`/`type`/`http_headers`) | `OPENCODE_CONFIG_CONTENT.mcp` = profile servers + inherited servers `enabled:false` |
| Ignore inherited config | `--setting-sources ""` | redirected `CODEX_HOME` → a fresh dir whose `config.toml` is the only user-layer config (codex 0.135.0 has **no** top-level `--ignore-user-config`; it's a `codex exec`-only flag) | inline highest-layer override (suppresses the global-config seed write) + per-server disable |
| Auth preservation | (n/a — uses real `~/.claude`) | symlink `<CODEX_HOME>/auth.json` → `~/.codex/auth.json` (`File` auth-storage mode only) | (n/a) |
| Ephemeral session | (n/a) | (no interactive flag; the per-launch `CODEX_HOME` tmp dir is the ephemeral store — `--ephemeral` is `codex exec`-only) | (no env equivalent — documented gap) |
| System prompt | `--append-system-prompt-file <profile>/<sp>` | `model_instructions_file = <sp abs path>` in the generated `config.toml` (codex's `instructions` key is reserved/noop — `model_instructions_file` is the documented lever) | `OPENCODE_CONFIG_CONTENT.instructions:[<sp abs path>]` (additive) |
| Tool/permission restriction | `--tools <csv>` + `--settings` (`permissions`+`enabledPlugins`) | **dropped** — codex has no per-launch built-in-tool whitelist (caveat + follow-up ticket) | `OPENCODE_PERMISSION` from `permissions_deny` (`Edit`/`Write`→`edit:deny`, `Read`/`Grep`/`Glob`/`Bash`→key, `mcp__*` verbatim) + `OPENCODE_DISABLE_PROJECT_CONFIG=true` |
| Per-profile env | injected | injected (alongside `CODEX_HOME`) | injected alongside the two `OPENCODE_*` vars |

The `(flags, env)` contract is uniform: claude carries isolation in `flags`, codex and opencode carry it in `env` (`flags == []` for both — codex's `CODEX_HOME`, opencode's `OPENCODE_*`); `_launch_isolated` injects `env` into `os.environ` then execs `harness + flags + exec_args` identically for all three. `${VAR}` MCP-env resolution differs by harness: **claude and codex bake-resolve** from `.env` at launch and **fail loud** on an unset reference (D4); **opencode does not** — it rewrites `${VAR}` to opencode's `{env:VAR}` placeholder and defers expansion to opencode's runtime (which reads the shell-exported `.env`), so a missing var surfaces only when opencode expands it, not as a launch-time error.

**Field handling (D3):** `extra_args` (raw claude flags) and `enabled_plugins` (claude marketplace) are claude-only — on codex/opencode they print `field <x> ignored for harness <y>` and proceed (never fail, never silently drop). codex additionally ignores-with-warning `tools` / `permissions_deny`.

**Caveats:**

- **codex tool restriction dropped** — an isolated codex profile gets the closed MCP world + a redirected `CODEX_HOME` but **not** built-in tool-set restriction. Tracked in `feat(ap): revisit codex tool restriction for isolated profiles`.
- **codex auth.json symlink is File-mode only** — login is preserved by symlinking `<CODEX_HOME>/auth.json` → `~/.codex/auth.json`, which works for `File` auth-storage mode (`codex doctor` → `auth storage mode: File`). Keyring users must set `CODEX_ACCESS_TOKEN` instead — known limitation.
- **codex `/etc/codex/config.toml`** (system config) still loads regardless of `CODEX_HOME` (separate load path); a system config can inject servers/approvals. Out of scope. A project `.codex/config.toml` is loaded but inert — the fresh `config.toml` trusts no projects.
- **opencode can't suppress project `AGENTS.md`/`CLAUDE.md` auto-load** — the system prompt is *appended* via `instructions`; not a fully-closed instruction world.
- **opencode `mcp__*` deny keys** are syntactically accepted as `OPENCODE_PERMISSION` freeform keys but enforcement is unconfirmed — best-effort.

`_server_record` (claude) and `_mcp_server_record` (opencode, reused from the renderer) support both stdio (`command`/`args`/`env`) and HTTP (`type: http` + `url`, e.g. `notion`) MCP shapes.

### Target resolution (`cli._resolve_target`)

`explicit --target` > `profile.target_default` (env-expanded) > `Path.cwd()`. `${VAR}`/`$VAR`/`~` in `target_default` expand at use-time against the process env; an unset ref is left literal so the failure surfaces as "path doesn't exist" rather than a `KeyError`.

## The five renderers

Each renderer satisfies the `Renderer` protocol in `renderers/base.py`: `render(manifest, target) → list[str]` (relative paths of whole-file artifacts) and `clean(manifest, target) → None` (surgically un-merge this harness's entries from shared/merged files). `base.py` also holds shared helpers — `mcps_for`, `hooks_for`, `gate_blocks`, `mcp_server_entry`, `body_abs`, `copy_hook_shared_assets`.

Substrate rule (all five): stdlib `json` for JSON, `tomlkit` for TOML (round-trip, preserving user keys/comments/ordering). No `jq`/`yq`.

| Renderer | Module | Native output paths (under `target`) | Harness-global settings ownership |
|---|---|---|---|
| Claude | `renderers/claude.py` | `.claude/plugins/local/<profile>/` (plugin.json, `skills/`, `commands/`, `hooks/`, `.mcp.json`, profile `settings.json`) + shared `.claude/agents/<n>.md` (agents are shared-only — no plugin-scoped copy) | Non-isolated installs do not mutate root `.claude/settings.json`; isolated renders still merge launch-scoped root settings (`renderers/claude.py:94-114`, `renderers/claude.py:195-204`, `renderers/claude.py:516-540`). |
| Codex | `renderers/codex.py` | `.codex/agents/<n>.toml`, `.codex/hooks.json`, shared `.agents/skills/<n>/` | Non-isolated installs do not write `.codex/config.toml`; isolated renders still write MCP/tool-scope config (`renderers/codex.py:90-113`). |
| opencode | `renderers/opencode.py` | `agents/<n>.md` (root-relative), `skills/<n>/` | Non-isolated installs do not write `opencode.json`; isolated renders merge `mcp` + `permission` and clean those keys (`renderers/opencode.py:182-224`, `renderers/opencode.py:297-305`). |
| Cursor | `renderers/cursor.py` | `.cursor/commands/`, `.cursor/hooks.json`, `.cursor/agents/<n>.md` | Non-isolated installs do not write `.cursor/mcp.json`; isolated renders/cleans MCP entries (`renderers/cursor.py:78-93`). |
| Copilot | `renderers/copilot.py` | `.github/agents/<n>.agent.md`, `.github/skills/<n>/`, `.github/hooks/<n>.json` | Non-isolated installs do not write `.copilot/mcp-config.json`; isolated renders MCP config only (`renderers/copilot.py:162-172`). |
| Crush | `renderers/crush.py` | none for non-isolated global install | Non-isolated installs do not write `.config/crush/crush.json`; isolated renders/cleans `crush.json` (`renderers/crush.py:54-78`). |

### Why Claude's frontmatter is "full" on the shared file

The claude renderer writes each agent **once**, to the user-scoped shared file (`.claude/agents/<n>.md`, also read by Cursor). Claude resolves it at priority 4, so it must carry full metadata (`model`/`color`/`effort`/`skills`), not a neutral subset (`shared.claude_agent_frontmatter`). It does **not** also write a plugin-scoped copy (`.claude/plugins/local/<profile>/agents/<n>.md`, priority 5): that copy was pure redundancy — the user-scoped file already wins precedence — and surfaced every agent twice in Claude's roster as a duplicate `global:<agent>` (plugin-namespaced) entry, so the plugin-scoped agent write was dropped. The plugin tree still carries skills/commands/hooks/`.mcp.json` (only an empty `agents/` dir is left by the render mkdir loop, harmless). Consequence: a body-less agent now emits no Claude file at all (the shared writer is body-guarded); every real registry agent declares a `body_path`, so none are lost.

### Global settings disconnect + merged-file discipline

Non-isolated installs no longer read-modify-write harness-global settings files. The disconnected live paths are `.claude/settings.json`, `.codex/config.toml`, `opencode.json`, `.cursor/mcp.json`, `.copilot/mcp-config.json`, and `.config/crush/crush.json`; `compiled_types.py` keeps `MERGED_SETTINGS_BY_HARNESS` empty so compiled manifests record no user-owned merged config paths (`agent-profile/agent_profile/compiled_types.py:17-20`).

Isolated profiles still use renderer-level merges for their target roots because the profile is explicitly asking for a closed/temporary config world. Those merged files stay out of the install manifest and are surgically un-merged in `clean` (own-your-keys, `pop`/`del`), unlinked only when reduced to empty / a bare schema stub. A corrupt merged file raises `MergedConfigError` → clean stderr + exit 1, not a traceback.

Migration safety: `ap apply-compiled` preserves disconnected legacy global-settings paths from prior apply-state snapshots, so removing them from the new manifest does not delete a user's live settings file (`agent-profile/agent_profile/merged_settings_preservation.py:31-42`, `agent-profile/agent_profile/apply_compiled.py:151-171`). Codex env-scrub now matters only for isolated generated `config.toml`: `.env` keys inherited from the shell are not duplicated into `[mcp_servers.*.env]`; render-time per-harness vars stay baked.

## The `global` install: plugin rendering only

`global`'s install-overlay fields (`profiles/global/profile.yaml`) still name the live profile and its local marketplace, but the renderer no longer enables that plugin by mutating root `.claude/settings.json`. Non-isolated `render()` writes the plugin tree and shared artifacts; root settings enablement belongs to the chezmoi-managed settings source (`renderers/claude.py:94-114`, `renderers/claude.py:195-204`).

`_write_local_marketplace` still writes `marketplace.json` at `.claude/plugins/local/.claude-plugin/`, listing the profile as a directory-marketplace plugin. Chezmoi must keep `extraKnownMarketplaces.local = $HOME/.claude/plugins/local` and `enabledPlugins["global@local"] = true`; without both, the rendered plugin tree exists on disk but Claude will not load the bundled `.mcp.json` or SessionStart hook.

Three names must agree (`claude.py:_LOCAL_MARKETPLACE`): the marketplace key (`local`), the `marketplace.json` `name`, and the on-disk plugin dir. The plugin id is `<profile_name>@<marketplace>` — renaming the profile means updating both the YAML name and the chezmoi-owned `enabledPlugins` key.

## Manifest + ref-counted uninstall

`manifest.py` tracks `<target>/.agent-profile/manifest.json`: per profile, a sorted+deduped `files` list and a `merged_json` snapshot. Uninstall (`cli.cmd_uninstall`) runs *every* harness's `clean` (shared/merged files cross harness boundaries) and removes tracked files — but only when **no other installed profile claims the same path** (`other_profiles_claim_file`). A selective re-install (`--harness <subset>`) only orphans files whose path prefix maps to an in-scope harness (`_path_owners`).

## The chezmoi drive path

On `dots sync`, `run_onchange_after_install-base-profile.sh.tmpl` exports `DOTFILES_DIR`, skips on a fresh box if `uv`/`npx` is missing, and forks to `chezmoi/lib/install-base-profile.sh`, which runs two installs handling a path asymmetry:

- `HOME=$target ap install global --harness claude,codex,cursor,copilot` — the four dot-dir harnesses write under `$HOME`; `global` carries the marketplace + plugin enablement.
- `HOME=$target ap install opencode-global --harness opencode` — opencode writes `opencode.json` at the *target root*; the wrapper carries `_permissions` plus `target_default: $HOME/.config/opencode` without pulling in Claude's marketplace/plugin fields, and omitting `--target` keeps external `source:` skill fetch on the live path.
- `HOME=$target ap install global --harness claude,codex,cursor,copilot` — the four dot-dir harnesses write generated/shared artifacts under `$HOME`; global settings files are not mutated by `ap`.
- `HOME=$target ap install opencode-global --harness opencode` — opencode writes generated `agents/` + `skills/` under `$HOME/.config/opencode`; `opencode.json` is not mutated by non-isolated `ap`.
