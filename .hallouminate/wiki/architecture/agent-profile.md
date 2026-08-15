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
| **isolated** (closed world) | `review`, `todo`, `fe`, `spec`, `mgmt`, `rtkonly`, `plugin` | `isolated: true` + launch-overlay | ccp-parity closed-world launches |

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

For an **isolated** profile (`overlay.py:build_isolated_launch`): build the closed-world `(flags, env)`, inject the profile's `env`, and `execvp <harness>` — no install, no manifest. Isolation is dispatched through `_ISOLATION_BUILDERS` for Claude and Codex; Cursor and Copilot have no runtime-isolation lever, so an isolated launch against them fails loud (`IsolationError` → `CliError`).

### Per-harness closed-world matrix

| Capability | claude (`_build_isolated_claude`) | codex (`_build_isolated_codex`) |
|---|---|---|
| Closed MCP world | `--strict-mcp-config --mcp-config <ephemeral .mcp.json>` | `[mcp_servers.<n>]` tables in generated `<CODEX_HOME>/config.toml` |
| Ignore inherited config | `--setting-sources ""` | redirected `CODEX_HOME` with a fresh `config.toml` |
| Auth preservation | uses real `~/.claude` | symlink `<CODEX_HOME>/auth.json` → `~/.codex/auth.json` for File auth-storage mode |
| Ephemeral session | n/a | the per-launch `CODEX_HOME` temp dir is the ephemeral store |
| System prompt | `--append-system-prompt-file <profile>/<sp>` | `model_instructions_file = <sp abs path>` |
| Tool/permission restriction | `--tools <csv>` + `--settings` | unavailable; ignored fields warn |
| Per-profile env | injected | injected alongside `CODEX_HOME` |

The `(flags, env)` contract is uniform even though Claude carries isolation in flags and Codex carries it in `CODEX_HOME`. `${VAR}` MCP references bake-resolve from `.env` at launch and fail loud when unset.

`extra_args` and `enabled_plugins` are Claude-only. Codex ignores them with a warning; `tools` and `permissions_deny` also warn because Codex has no equivalent per-launch built-in-tool whitelist.

**Caveats:**

- **Codex tool restriction is unavailable.** An isolated Codex profile gets the closed MCP world and redirected `CODEX_HOME`, but not a built-in tool whitelist.
- **Codex auth preservation is File-mode only.** Keyring users must provide `CODEX_ACCESS_TOKEN`.
- **System `/etc/codex/config.toml` still loads.** A machine-level config can inject servers or approvals outside the redirected user layer.

The Claude and Codex MCP record builders support stdio and HTTP servers.

### Target resolution (`cli._resolve_target`)

`explicit --target` > `profile.target_default` (env-expanded) > `Path.cwd()`. `${VAR}`/`$VAR`/`~` in `target_default` expand at use-time against the process env; an unset ref is left literal so the failure surfaces as "path doesn't exist" rather than a `KeyError`.

## The four renderers

Each renderer satisfies the `Renderer` protocol in `renderers/base.py`: `render(manifest, target) → list[str]` and `clean(manifest, target) → None`. The base module holds shared MCP, hook, gate, body-path, and hook-asset helpers.

Substrate rule (all four): stdlib `json` for JSON, `tomlkit` for TOML. No `jq`/`yq`.

| Renderer | Module | Native output paths (under `target`) | Harness-global settings ownership |
|---|---|---|---|
| Claude | `renderers/claude.py` | `.claude/plugins/local/<profile>/` (plugin.json, `skills/`, `commands/`, `hooks/`, `.mcp.json`, profile `settings.json`) + shared `.claude/agents/<n>.md` (agents are shared-only — no plugin-scoped copy) | Non-isolated installs do not mutate root `.claude/settings.json`; isolated renders still merge launch-scoped root settings (`renderers/claude.py:94-114`, `renderers/claude.py:195-204`, `renderers/claude.py:516-540`). |
| Codex | `renderers/codex.py` | `.codex/agents/<n>.toml`, `.codex/hooks.json`, shared `.agents/skills/<n>/` | Non-isolated installs do not write `.codex/config.toml`; isolated renders still write MCP/tool-scope config (`renderers/codex.py:90-113`). |
| Cursor | `renderers/cursor.py` | `.cursor/commands/`, `.cursor/hooks.json`, `.cursor/agents/<n>.md` | Non-isolated installs do not write `.cursor/mcp.json`; isolated renders/cleans MCP entries (`renderers/cursor.py:78-93`). |
| Copilot | `renderers/copilot.py` | `.github/agents/<n>.agent.md`, `.github/skills/<n>/`, `.github/hooks/<n>.json` | Non-isolated installs do not write `.copilot/mcp-config.json`; isolated renders MCP config only (`renderers/copilot.py:162-172`). |

### Why Claude's frontmatter is "full" on the shared file

The claude renderer writes each agent **once**, to the user-scoped shared file (`.claude/agents/<n>.md`, also read by Cursor). Claude resolves it at priority 4, so it must carry full metadata (`model`/`color`/`effort`/`skills`), not a neutral subset (`shared.claude_agent_frontmatter`). It does **not** also write a plugin-scoped copy (`.claude/plugins/local/<profile>/agents/<n>.md`, priority 5): that copy was pure redundancy — the user-scoped file already wins precedence — and surfaced every agent twice in Claude's roster as a duplicate `global:<agent>` (plugin-namespaced) entry, so the plugin-scoped agent write was dropped. The plugin tree still carries skills/commands/hooks/`.mcp.json` (only an empty `agents/` dir is left by the render mkdir loop, harmless). Consequence: a body-less agent now emits no Claude file at all (the shared writer is body-guarded); every real registry agent declares a `body_path`, so none are lost.

### Global settings disconnect + merged-file discipline

Non-isolated installs no longer read-modify-write harness-global settings files. The disconnected live paths are `.claude/settings.json`, `.codex/config.toml`, `.cursor/mcp.json`, and `.copilot/mcp-config.json`; `MERGED_SETTINGS_BY_HARNESS` stays empty so compiled manifests record no user-owned merged config paths.

Isolated profiles still use renderer-level merges for their target roots because the profile is explicitly asking for a closed/temporary config world. Those merged files stay out of the install manifest and are surgically un-merged in `clean` (own-your-keys, `pop`/`del`), unlinked only when reduced to empty / a bare schema stub. A corrupt merged file raises `MergedConfigError` → clean stderr + exit 1, not a traceback.

Migration safety: `ap apply-compiled` preserves disconnected legacy global-settings paths from prior apply-state snapshots, so removing them from the new manifest does not delete a user's live settings file (`agent-profile/agent_profile/merged_settings_preservation.py:31-42`, `agent-profile/agent_profile/apply_compiled.py:151-171`). Codex env-scrub now matters only for isolated generated `config.toml`: `.env` keys inherited from the shell are not duplicated into `[mcp_servers.*.env]`; render-time per-harness vars stay baked.

## The `global` install: plugin rendering only

`global`'s install-overlay fields (`profiles/global/profile.yaml`) still name the live profile and its local marketplace, but the renderer no longer enables that plugin by mutating root `.claude/settings.json`. Non-isolated `render()` writes the plugin tree and shared artifacts; root settings enablement belongs to the chezmoi-managed settings source (`renderers/claude.py:94-114`, `renderers/claude.py:195-204`).

`_write_local_marketplace` still writes `marketplace.json` at `.claude/plugins/local/.claude-plugin/`, listing the profile as a directory-marketplace plugin. Chezmoi must keep `extraKnownMarketplaces.local = $HOME/.claude/plugins/local` and `enabledPlugins["global@local"] = true`; without both, the rendered plugin tree exists on disk but Claude will not load the bundled `.mcp.json` or SessionStart hook.

Three names must agree (`claude.py:_LOCAL_MARKETPLACE`): the marketplace key (`local`), the `marketplace.json` `name`, and the on-disk plugin dir. The plugin id is `<profile_name>@<marketplace>` — renaming the profile means updating both the YAML name and the chezmoi-owned `enabledPlugins` key.

## Manifest + ref-counted uninstall

`manifest.py` tracks `<target>/.agent-profile/manifest.json`: per profile, a sorted+deduped `files` list and a `merged_json` snapshot. Uninstall (`cli.cmd_uninstall`) runs *every* harness's `clean` (shared/merged files cross harness boundaries) and removes tracked files — but only when **no other installed profile claims the same path** (`other_profiles_claim_file`). A selective re-install (`--harness <subset>`) only orphans files whose path prefix maps to an in-scope harness (`_path_owners`).

## RETIRED: the chezmoi drive path (live installs)

**`ap` no longer drives live machine convergence** (see [[adr-chezmoi-authoritative-claude]]). The former onchange path that ran `ap install global` was deleted; `dots sync` now converges native live surfaces through chezmoi and harness-specific reconcilers.

- Claude settings, payloads, and MCPs converge from `claude.yaml`, `dot_claude/`, and the manifest-tracked CLI reconcile.
- Codex config and payloads converge from `codex.yaml` and `private_dot_codex/`; Cursor and Copilot use their dedicated chezmoi/plugin installers.
- OMP and Pi are outside `ap`; their native registries and source trees are assembled directly before chezmoi applies.
- Manual `ap install` remains useful for explicit targets and generated artifacts. `ccp <name>` / `dots profile launch` still own Claude and Codex isolated launches; `ap copilot-flags` supports the Copilot wrapper.

Sibling scripts that survive: `install-agent-profile` (warms the uv env for `ccp`), `install-prompts` + `install-agents-doc` (the non-`ap` agent content — preamble + AGENTS.md, see [[agents-dir]]).
