# Dev Environment

The local developer-experience tooling that isn't agent config: git diff/merge tooling, pre-commit hooks, and Claude marketplace plugins.

## Git tooling

- **Default email** is templated via chezmoi (`{{ .email }}`); override per-repo with `git config user.email` (the `cpersonal` alias is a shortcut).
- **difftastic** — AST-aware structural diff (Tree-sitter, 700+ languages). The `gds` alias is `GIT_EXTERNAL_DIFF=difft git diff` (inline structural output, *not* `difftool`). For side-by-side, use `git difftool -t difftastic` (the registered `[difftool "difftastic"]` entry). Composes with delta (delta pages log/show/blame; difftastic outputs directly).
- **mergiraf** — AST-aware merge driver, registered globally via `gitattributes` for all supported languages. Auto-resolves structural conflicts (import reorders, independent additions) and falls back to standard merge otherwise. Works transparently with merge/rebase/cherry-pick.
- **Conflict-resolution chain:** mergiraf (auto-resolve structural) → rerere (replay remembered manual resolutions) → kdiff3 (manual). The `/melt` skill drives this cascade.
- `grb` rebases from `main` (not `master`).

## Pre-commit hooks (prek)

Managed by [prek](https://prek.j178.dev/) via `prek.toml`. Hooks run on commit: trailing-whitespace, secret detection, shellcheck, large-file checks, and a **claude-config-sync check**.

**Always `dots sync` before committing** — the sync check blocks the commit if `~/.claude/` (settings, agents, commands, hooks, skills) is out of sync with the repo. `git commit --no-verify` overrides, but only for rare temporary cases; fix the underlying issue (e.g. a detected secret) instead. Run `prek install` after cloning to set up the hooks.

## Gotcha: easy-cheese `/cut` (red-gate) cannot snapshot this repo (2026-09-05)

`red-gate begin` walks the whole project root and refuses every **directory symlink** (`phase-entry project tree does not support directory symlink`); its only exclusions are `.git`, `.cheese`, and cache dirs. This repo tracks five directory symlinks under `profiles/skills-doctor/skills/<name> -> ../../../skills/<name>` (git mode 120000), so the halt reproduces in every worktree, not only in a checkout with `.venv/lib64` or nested `.worktrees/`. Consequence: no Cut receipt is possible here until easy-cheese honours symlinks or a snapshot exclude list. Fallback used for `shared-agents-skills-exact`: `/cook --auto` without a receipt (user decision). Follow-up draft: `.cheese/issues/shared-agents-skills-exact-002.md`. Halt handoff: `.cheese/cut/shared-agents-skills-exact.md`.

## Claude marketplace plugins

Distinct from the `agents/` registry system (see [[../architecture/agents-dir]]) and from the `global@local` plugin that `ap` wires (see [[../architecture/agent-profile]]): these are third-party plugins from external marketplaces, managed declaratively via `claude/plugins/registry.yaml`.

- Marketplaces must be added first: `claude plugin marketplace add <owner/repo>`.
- Workflow: `plugin-edit` → `plugin-sync` (apply) → restart Claude Code.
- An LSP server is just a plugin entry with `load: true` (servers start lazily).
- Unlike MCP, the plugins directory is **not** symlinked to `~/.claude` — Claude Code uses that location for plugin cache storage.
- If a plugin provides MCP tools, add `mcp__plugin_<name>__*` to `permissions.allow`.
- **A local/unpublished plugin's bundled MCP must run from its source, not PyPI.** When a `path:` entry points at an out-of-repo clone (e.g. `milknado@milknado` → `~/Dev/milknado`), the plugin's own `.mcp.json` cannot use a bare `uvx <pkg>` — that resolves against PyPI and fails to connect for an unpublished package (`× <pkg> was not found in the package registry`). Point it at the clone: `uvx --from <abs-path> <script>` (or `uv run --project <abs-path> <script>`). Verify with `claude mcp list` (look for `✗ Failed to connect`). Tradeoff: the absolute path is machine-specific, so the marketplace isn't portable until the package is published — then revert to bare `uvx <pkg>`.
- **A local marketplace must be registered with the CLI, not just jq-written into settings.** `claude/plugins/sync.sh`'s `sync_local_marketplaces` keeps `extraKnownMarketplaces` in the **live `~/.claude/settings.json`** (the committed `claude/settings.json` is retired — see `claude/.sync`; the `CLAUDE_SETTINGS_FILE` env var is the test seam for that hardcoded path). But writing that JSON entry is **not sufficient** — `claude plugin install <name>@<mp>` can only resolve a marketplace the CLI has actually fetched/registered. The entry won't show in `claude plugin marketplace list` and has no `~/.claude/plugins/marketplaces/<name>/` cache dir until you run `claude plugin marketplace add <abs-path>` (idempotent: fetches when missing, "already on disk" no-op when present). So sync runs `marketplace add` per auto-managed local marketplace (`mp_name == plugin_name`); without it a freshly-added local plugin like milknado fails to install on first sync, and the failure is swallowed by the install step's `2>/dev/null`. Symptom: sync prints `Installing <plugin>... failed` but the plugin never lands in `claude plugin list`.

## skhd (removed 2026-08)

skhd is removed from this repo and this machine. The `skhdrc` was an empty skeleton after the yabai removal, so nothing used it. A stray `asmvik/formulae` tap also shipped `skhd`, which made the bare name ambiguous and broke the `dots up` brew-upgrade leg. The removal deleted `skhd/`, `zsh/skhd.zsh`, the `packages.yaml` entry, and the `koekeishiya/formulae` tap entry. If skhd returns, install it with the fully-qualified name `koekeishiya/formulae/skhd` and grant Accessibility access manually.
