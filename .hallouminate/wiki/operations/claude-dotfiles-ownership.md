# Claude Code Dotfiles Ownership

Treat `~/.claude/` as a mutable runtime tree with repo-owned inputs, not as a mirrored dotfiles directory. Claude Code mixes declarative settings, plugins, MCP state, memory, and session/runtime files under the same user directory, so this repo manages only the portable sources and lets live state stay live.

## Scope model

Claude Code's official settings scopes are user (`~/.claude/settings.json`), project (`.claude/settings.json`), and local (`.claude/settings.local.json`). Project settings are for shared team policy; local settings are personal and gitignored when Claude creates them. Arrays such as `permissions.allow` merge across scopes, while scalar values follow precedence.[^claude-settings]

`CLAUDE.md` and auto memory are context, not enforcement. CLAUDE.md is loaded into every session; auto memory is Claude-written, per repository, and shared across worktrees. Use hooks or settings for hard enforcement.[^claude-memory]

## This repo's ownership split

- **Repo-owned sources**: `chezmoi/lib/claude-settings-authoritative.json`, `chezmoi/dot_claude/modify_settings.json`, `claude/{commands,hooks,reference,workflows}`, agent/skill/MCP registries, profile YAML, and plugin payloads.
- **Rendered/copied targets**: `~/.claude/{commands,hooks,reference,workflows}` are one-way copied; `agents/`, MCP servers, and skills are rendered through `ap`; the live `~/.claude/settings.json` is produced by chezmoi's `modify_settings.json`. The profile-aware renderer merge (`_merge_root_settings`) runs only for an isolated `ap launch`, not on the live `dots sync` path.
- **Live/runtime state**: `~/.claude.json`, `~/.claude/projects/*/memory`, `~/.claude/settings.local.json`, repo-local `.claude/`, sessions, worktrees, plugin cache/data, marketplace cache, approvals/trust state, OAuth/session state, and app-created sticky state.

`claude/README.md:13-17` records why this matters: the repo stopped symlinking into `~/.claude/` because Claude runtime writes leaked back into the checkout. `.gitignore:49-50` ignores repo-local `.claude/` for the same reason.

## Settings merge policy

`chezmoi/dot_claude/modify_settings.json` owns the live settings boundary:

- Repo-owned keys (`model`, `effortLevel`, `env`, hooks, sandbox, theme, `editorMode`, `permissions.defaultMode`, spinner verbs, etc.) are overwritten from `chezmoi/lib/claude-settings-authoritative.json` on each apply (`chezmoi/dot_claude/modify_settings.json:7-11`).
- `permissions.allow`, `permissions.deny`, `permissions.ask`, `permissions.additionalDirectories`, `enabledPlugins`, and `extraKnownMarketplaces` are preserved from the live file and reasserted by chezmoi's `modify_settings.json` on each apply (`chezmoi/dot_claude/modify_settings.json:12-17`) — chezmoi is the single writer for the live install. `ap`'s `_merge_root_settings` also reasserts these, but only for an *isolated* `ap launch` (gated on `manifest.isolated`, `agent-profile/agent_profile/renderers/claude.py:613-687`); it does not run on the live `dots sync` path.
- Unknown live key paths fail the apply instead of being silently clobbered, forcing a classification decision when Claude Code introduces a sticky setting (`chezmoi/dot_claude/modify_settings.json:18-22`, `chezmoi/dot_claude/modify_settings.json:91-100`).

This is intentionally stricter than `create_` seed-once behavior: new settings either become repo-owned, become renderer-owned, or are explicitly left live-only.

## Destructive cleanup rule

Destructive changes must be provenance-aware, not wholesale deletes:

1. **Repo-owned key removed from source** → `modify_settings.json` removes it from live settings on the next chezmoi apply.
2. **Renderer-owned plugin/MCP removed from registries** → `ap` cleanup should remove only entries the prior manifest proves it owned; user-authored siblings survive. See [[../architecture/config-drift]] for dropped-MCP and legacy-hook reconciliation.
3. **App-introduced or user-authored key** → preserve unless a current source proves it is a stale repo remnant.
4. **Unknown sticky key** → fail, classify, then update source/merge policy; do not silently average repo intent and app drift.

## Chezmoi and destructive operations

| Surface | Manage with chezmoi? | Destructive path |
|---|---|---|
| `~/.claude/settings.json` | Yes, but either full-file ownership or `modify_` partial ownership. This repo uses `modify_` so unknown/personal keys can be classified instead of clobbered.[^chezmoi-modify] | Remove repo-owned keys from the authoritative source. Do not hand-edit the live target. |
| `~/.claude.json` | No. Claude docs place user/local MCP configs, per-project state, trust/approval/session-ish data, and other runtime state here; it is not a stable declarative API.[^claude-settings][^claude-mcp] | Use `claude mcp remove <name>` for manual user/local MCPs. |
| Project MCP | Yes, when project-owned. | Edit `.mcp.json`; it is the supported project config surface.[^claude-mcp] |
| Plugin-provided MCPs | No separate MCP ownership. | Disable/uninstall the plugin; plugin MCPs are lifecycle-managed through plugins, not `/mcp` commands.[^claude-plugins] |
| Plugins | Manage desired enablement in settings, but treat install/cache/data cleanup as Claude-owned runtime. | Use `claude plugin uninstall <plugin>@<marketplace> --scope <user\|project\|local>`; add `--prune` for auto-installed dependencies, `--keep-data` only when intentionally preserving plugin data.[^claude-plugins] |
| Marketplaces | Settings can declare known marketplaces, but installed marketplace state is runtime. | Use `/plugin marketplace remove <marketplace>` when the marketplace and plugins from it should be removed.[^claude-marketplaces] |
| Whole `~/.claude/` tree | No. Do not `exact_` the root; Claude writes cache/data/runtime files there. | Use `exact_`, `remove_`, or `.chezmoiremove` only for paths fully owned by the repo; preview with `chezmoi apply --dry-run --verbose` and inspect `chezmoi unmanaged` first.[^chezmoi-targets][^chezmoi-remove] |

## Operational checks

- Run `chezmoi --source $DOTFILES/chezmoi diff` before applying template changes.
- Run `chezmoi apply --dry-run --verbose` before destructive changes.
- Run `chezmoi unmanaged` before deciding whether a live file is stale, expected-local, or a repo bug.[^chezmoi-unmanaged]
- Run `dots sync` to apply chezmoi plus `ap` render/merge.
- If `dots sync` stops on an unknown Claude settings key, classify that path before retrying.
- Use `claude /status` or `claude doctor` to inspect active setting sources and validation errors.[^claude-settings]
- Use `/hooks`, `/mcp`, and `/plugin list` / plugin UI after destructive changes to confirm runtime state, because deleting declarative settings alone is not documented as equivalent to uninstalling plugins or removing manual MCPs.[^claude-plugins][^claude-mcp]

*Source: Claude dotfiles / OMP isolation research plus Claude+chezmoi destructive-management briesearch · Updated: 2026-07-01 · Supersedes: seeded-once-only descriptions in older wiki rows.*

[^claude-settings]: Claude Code settings docs, retrieved 2026-07-01: <https://docs.anthropic.com/en/docs/claude-code/settings>
[^claude-memory]: Claude Code memory docs, retrieved 2026-07-01: <https://docs.anthropic.com/en/docs/claude-code/memory>
[^claude-mcp]: Claude Code MCP docs, retrieved 2026-07-01: <https://docs.anthropic.com/en/docs/claude-code/mcp>
[^claude-plugins]: Claude Code plugins reference, retrieved 2026-07-01: <https://docs.anthropic.com/en/docs/claude-code/plugins-reference>
[^claude-marketplaces]: Claude Code plugin marketplace docs, retrieved 2026-07-01: <https://docs.anthropic.com/en/docs/claude-code/discover-plugins>
[^chezmoi-modify]: chezmoi manage different file types docs, retrieved 2026-07-01: <https://www.chezmoi.io/user-guide/manage-different-types-of-file/>
[^chezmoi-targets]: chezmoi target types docs, retrieved 2026-07-01: <https://www.chezmoi.io/reference/target-types/>
[^chezmoi-remove]: chezmoi `.chezmoiremove` docs, retrieved 2026-07-01: <https://www.chezmoi.io/reference/special-files/chezmoiremove/>
[^chezmoi-unmanaged]: chezmoi unmanaged command docs, retrieved 2026-07-01: <https://www.chezmoi.io/reference/commands/unmanaged/>
