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
  mcps:   agents/mcp/registry.yaml
  agents: agents/registry.yaml
  skills: [skills/_registry.yaml, skills/]
  hooks:  agents/hooks/registry.yaml
```

`ingest.py:expand_registries` reads each registry relative to the repo root, normalizes every entry into a profile *item* (a registry entry **is** a profile item — no translation layer), and stamps `_source_dir = <repo_root>` so payload files (`body_path`, hook `script`, skill `path`) resolve against the repo. Ingest also resolves inline `${VAR}` env refs from `$DOTFILES_DIR/.env` (`env.py`) and drops `optional` MCPs with unset credentials.

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

The base/global split exists for one reason: `ap install base` without `--target` writes the plugin tree into `$PWD`, which reads as confusing for "make my machine live". `global` makes operator intent legible — `ap install global` (no flags) targets `$HOME` *and* wires the rendered Claude plugin tree into `~/.claude/settings.json` so it actually loads.

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

For an **isolated** profile (`overlay.py:build_isolated_flags`): build the ccp-parity closed-world flags, inject the profile's `env`, and `execvp claude` — no install, no manifest. The flags reproduce the retired `ccp` zsh launcher:

```
--strict-mcp-config --mcp-config <ephemeral .mcp.json>   # only the profile's MCPs
--setting-sources ""                                      # strip inherited settings
--tools <csv>                                             # hard tool whitelist (if declared)
--append-system-prompt-file <profile>/CLAUDE.md           # if system_prompt declared
--settings <ephemeral settings.json>                      # permissions + enabledPlugins
<extra_args...>                                           # ${VAR}-expanded, verbatim
```

Isolation is **claude-only** — launching an isolated profile against any other harness fails loud, since the flags are Claude's. The closed `--setting-sources ""` means there's no inherited user allowlist, so a profile's tool surface is exactly its `tools` whitelist + `permissions` — the MCP's own tools must be in `tools` (or rely on the closed `--mcp-config`). `_server_record` supports both stdio (`command`/`args`/`env`) and HTTP (`type: http` + `url`, e.g. `notion`) MCP shapes.

### Target resolution (`cli._resolve_target`)

`explicit --target` > `profile.target_default` (env-expanded) > `Path.cwd()`. `${VAR}`/`$VAR`/`~` in `target_default` expand at use-time against the process env; an unset ref is left literal so the failure surfaces as "path doesn't exist" rather than a `KeyError`.

## The five renderers

Each renderer satisfies the `Renderer` protocol in `renderers/base.py`: `render(manifest, target) → list[str]` (relative paths of whole-file artifacts) and `clean(manifest, target) → None` (surgically un-merge this harness's entries from shared/merged files). `base.py` also holds shared helpers — `mcps_for`, `hooks_for`, `gate_blocks`, `mcp_server_entry`, `body_abs`, `copy_hook_shared_assets`.

Substrate rule (all five): stdlib `json` for JSON, `tomlkit` for TOML (round-trip, preserving user keys/comments/ordering). No `jq`/`yq`.

| Renderer | Module | Native output paths (under `target`) | Merged (un-merged in `clean`) |
|---|---|---|---|
| Claude | `renderers/claude.py` | `.claude/plugins/local/<profile>/` (plugin.json, `skills/`, `commands/`, `hooks/`, `.mcp.json`, `settings.json`) + shared `.claude/agents/<n>.md` (agents are shared-only — no plugin-scoped copy) | `.claude/settings.json` (`enabledPlugins`+`extraKnownMarketplaces`), local `marketplace.json` |
| Codex | `renderers/codex.py` | `.codex/agents/<n>.toml`, `.codex/hooks.json`, shared `.agents/skills/<n>/` | `.codex/config.toml` `[mcp_servers]` |
| opencode | `renderers/opencode.py` | `agents/<n>.md` (root-relative) | `opencode.json` (`mcp`+`permission.bash`) |
| Cursor | `renderers/cursor.py` | `.cursor/commands/`, `.cursor/hooks.json`, `.cursor/agents/<n>.md` | `.cursor/mcp.json` |
| Copilot | `renderers/copilot.py` | `.github/agents/<n>.agent.md`, `.github/skills/<n>/`, `.github/hooks/<n>.json` | `.copilot/mcp-config.json` |

### Why Claude's frontmatter is "full" on the shared file

The claude renderer writes each agent **once**, to the user-scoped shared file (`.claude/agents/<n>.md`, also read by Cursor). Claude resolves it at priority 4, so it must carry full metadata (`model`/`color`/`effort`/`skills`), not a neutral subset (`shared.claude_agent_frontmatter`). It does **not** also write a plugin-scoped copy (`.claude/plugins/local/<profile>/agents/<n>.md`, priority 5): that copy was pure redundancy — the user-scoped file already wins precedence — and surfaced every agent twice in Claude's roster as a duplicate `global:<agent>` (plugin-namespaced) entry, so the plugin-scoped agent write was dropped. The plugin tree still carries skills/commands/hooks/`.mcp.json` (only an empty `agents/` dir is left by the render mkdir loop, harmless). Consequence: a body-less agent now emits no Claude file at all (the shared writer is body-guarded); every real registry agent declares a `body_path`, so none are lost.

### Merged-file discipline + Codex env-scrub

Merged files (`opencode.json`, `config.toml`, `.cursor/mcp.json`, `.copilot/mcp-config.json`, live `.claude/settings.json`) hold user-owned config alongside profile-managed entries. They are deliberately **not** in the install manifest — they're surgically un-merged in `clean` (own-your-keys, `pop`/`del`), unlinked only when reduced to empty / a bare schema stub. A corrupt merged file raises `MergedConfigError` → clean stderr + exit 1, not a traceback.

Codex scrubs env keys present in `$DOTFILES_DIR/.env` from the rendered `[mcp_servers.*.env]` table: `zsh/core.zsh` exports `.env` into the interactive shell, so codex children already inherit those credentials — re-baking them as plaintext in `~/.codex/config.toml` just duplicates secrets on disk. Render-time per-harness vars (e.g. `SERENA_MUX_HARNESS`) stay baked. Disable with `AP_CODEX_INHERIT_ENV=0`. The codex renderer also one-time-migrates away legacy `[[hooks.<event>]]` blocks the retired `agents/hooks/sync.sh` wrote, to avoid double-firing.

## The `global` install: marketplace + plugin wiring

`global`'s install-overlay fields (`profiles/global/profile.yaml`) make the rendered Claude plugin *live*. The claude renderer's `_merge_root_settings` and `_write_local_marketplace`:

- Register `marketplaces: {local: $HOME/.claude/plugins/local}` as a `directory` source in `~/.claude/settings.json`'s `extraKnownMarketplaces`.
- Merge `enabled_plugins: {global@local: true}` into `enabledPlugins`, preserving user siblings.
- Write a `marketplace.json` at `.claude/plugins/local/.claude-plugin/` listing the profile as a plugin — without it, a `directory` marketplace has no `plugins[]` to resolve and the `global@local` enablement silently drops, so the bundled `.mcp.json` and SessionStart hook never load.

Three names must agree (`claude.py:_LOCAL_MARKETPLACE`): the marketplace key (`local`), the `marketplace.json` `name`, and the on-disk plugin dir. The plugin id is `<profile_name>@<marketplace>` — renaming the profile means updating both the YAML name and the `enabled_plugins` key.

## Manifest + ref-counted uninstall

`manifest.py` tracks `<target>/.agent-profile/manifest.json`: per profile, a sorted+deduped `files` list and a `merged_json` snapshot. Uninstall (`cli.cmd_uninstall`) runs *every* harness's `clean` (shared/merged files cross harness boundaries) and removes tracked files — but only when **no other installed profile claims the same path** (`other_profiles_claim_file`). A selective re-install (`--harness <subset>`) only orphans files whose path prefix maps to an in-scope harness (`_path_owners`).

## The chezmoi drive path

On `dots sync`, `run_onchange_after_install-base-profile.sh.tmpl` exports `DOTFILES_DIR`, skips on a fresh box if `uv`/`npx` is missing, and forks to `chezmoi/lib/install-base-profile.sh`, which runs two installs handling a path asymmetry:

- `HOME=$target ap install global --harness claude,codex,cursor,copilot` — the four dot-dir harnesses write under `$HOME`; `global` carries the marketplace + plugin enablement.
- `ap install base --target $HOME/.config/opencode --harness opencode` — opencode writes `opencode.json` at the *target root*, with no marketplace/plugin surface, so plain `base` suffices.

The run_onchange hash spans `profiles/base`, `profiles/global`, all four registries, the hook scripts + shared-asset libs, `skills/`, *and* `agent-profile/agent_profile/**`. Sibling scripts: `install-agent-profile` (warms the uv env), `install-prompts` + `install-agents-doc` (the non-`ap` agent content — preamble + AGENTS.md, see [[agents-dir]]).
