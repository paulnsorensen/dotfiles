# AGENTS.md

Project instructions for any coding agent working in this repository — Claude Code, Cursor, Codex, Copilot CLI, Antigravity, and friends. The root `CLAUDE.md` imports this file via `@AGENTS.md`, so harnesses that key off `CLAUDE.md` still pick it up.

## Repository Overview

This is a personal dotfiles repository that configures a vim-centric, terminal-based development environment for macOS. The configuration focuses on zsh shell, iTerm2, VS Code with vim bindings, comprehensive git setup, and Claude Code integration.

## Key Commands

### Dotfiles Management

- `dots sync` - Sync dotfiles (symlinks, packages, fonts) with rollback support
- `dots sync refresh` - Force re-check all packages (bypass cache)
- `dots upgrade` (or `dots up`) - Upgrade installed packages (brew/cargo/npm/uv tools)
- `dots update` - Pull latest changes and run sync
- `dots status` - Show git status of dotfiles
- `dots rollback [id]` - Rollback to a previous state
- `dots backups` - List available backups
- `dots doctor` - Run health checks and profile shell
- `dots test` - Run test suite (validates shell loading, git hooks, symlinks, and Claude config sync)

### Shell Configuration

- `zrl` - Reload zsh configuration after changes
- `source ~/.zshrc` - Alternative way to reload configuration

### Claude Code & MCP Management

- `cc` - Launch claude (pass-through to `claude`)
- `ccc` - Continue last conversation (`claude --continue`)
- `ccr` - Resume conversation (`claude --resume`)
- `ccp <name>` - Launch a scoped profile from `claude/profiles/<name>/`. Run `ccp` with no args to list available profiles.
- `ccw <slug>` - Create isolated git worktree and launch Claude inside it (sandboxed)
- `ccw-init <slug>` - Create/resume a worktree (used by ccw and /worktree skill)
- `ccw-ls` - List git worktrees
- `ccw-sweep` - Scan ~/Dev for stale worktrees with safety checks (dry-run, auto-clean modes)
- `ccw-clean` - Clean stale worktrees in current repo only (delegates to ccw-sweep)
- `wt-git <path> <cmd>` - Run git commands in a worktree without cd (avoids safety heuristics)
- `ccfresh` - Continue last conversation with MCPs primed
- `claude-settings` - Edit ~/.claude/settings.json
- `mcp-sync` - Sync MCPs from registry.yaml to Claude Code
- `mcp-sync-dry` - Preview MCP sync changes without applying
- `mcp-edit` - Edit MCP registry.yaml
- `mcp-ls` - List currently configured MCPs
- `mcp-add <name> <cmd> [args...]` - Add a user-scoped MCP
- `claude-json-prune` - Preview stale project entries in ~/.claude.json (dry run)
- `claude-json-prune --apply` - Remove stale entries (creates timestamped backup first)

### GitHub Helpers

- `gh-pr-review <PR#>` - Bundle PR metadata, diff, and checks for review
- `gh-pr-prep` - Bundle PR prep context (commits, diff stats, upstream status)
- `gh-issue-context <issue#>` - Bundle issue metadata and comments
- `gh-pr-batch <PR#> [PR# ...]` - Batch status (title, state, mergeable, files) for multiple PRs
- `gh-pr-checks-batch <PR#> [PR# ...]` - Batch CI checks for multiple PRs

### Plugin Management

- `plugin-sync` - Sync plugins from registry.yaml to Claude Code
- `plugin-sync-dry` - Preview plugin sync changes without applying
- `plugin-edit` - Edit plugin registry.yaml
- `plugin-ls` - List currently installed plugins
- `cf-refresh` - Rebuild the cheese-flow plugin cache from `~/Dev/cheese-flow` (use after editing the plugin in-place)
- `plugin-refresh <plugin> [marketplace]` - Generic version of cf-refresh for any local plugin (defaults to cheese-flow@local)

### Agent Skill Management (`gh skill install`)

Harness-agnostic — installs into each agent listed in `SKILL_HARNESSES` (`.env`). Auto-runs as part of `dots sync` via `skills-install/.sync` (skipped when `gh skill` is unavailable).

- `skill-sync` - Install skills from `skills-install/registry.yaml` into each configured harness (also fires during `dots sync`)
- `skill-sync-dry` - Preview skill installs without making changes
- `skill-edit` - Edit skill install registry
- `skill-ls` - Check installed skills for updates (`gh skill update --all --dry-run`)

### Session Monitoring

- `ccm` - Run Claude session monitor standalone (shows metrics for current directory's session)
- `ccm --cwd DIR` - Monitor a specific directory's session
- `ccm --once` - Print metrics once and exit (for scripting)
- `zjclaude` - Launch zellij with Claude layout (main pane + monitor bar)

### Common Development Tasks

- `lb` - Open daily logbook (creates markdown file at `~/psorensen/logbook/[date].md`)
- `uuidg` - Generate UUID and copy to clipboard
- `cdd` - Navigate to ~/Dev directory
- `hms` - Run home-manager switch (for Nix package updates)

## Architecture & Structure

```
dotfiles/
├── bin/                    # CLI tools (dots command)
├── chezmoi/                # Chezmoi-managed templates (gitconfig, .copilot/mcp-config.json)
├── claude/                 # Claude Code configuration
│   ├── mcp/
│   │   ├── registry.yaml   # MCP source of truth
│   │   └── sync.sh         # Declarative MCP sync script
│   ├── agents/             # Cheese-themed specialist agents
│   ├── commands/           # Slash commands (/fromage, /fromagerie, /spec, etc.)
│   ├── hooks/              # Pre-tool hooks
│   ├── skills/             # Dotfiles-owned skill sources (per-skill symlinked into ~/.claude/skills/)
│   ├── profiles/           # Scoped sessions (fe, plugin, review, rtkonly, spec, todo) — launched via `ccp <name>`
│   └── plugins/            # Plugin registry; `plugins/local/` holds in-repo plugins (cheese-flow, todoist-flow)
├── skills-install/         # `gh skill install` registry + sync (harness-agnostic — see SKILL_HARNESSES in .env)
├── packages.yaml           # Flat package registry (brew, cargo, apt)
├── packages/
│   └── sync.sh             # Package sync with hash cache
├── fonts/                  # Font installation (.sync script)
├── gitconfig               # Git configuration
├── prek.toml               # Pre-commit hooks config (prek)
├── iterm2/                 # iTerm2 preferences
├── yabai/                  # yabai + skhd window manager config
├── reference/              # Reference docs (gitignored)
├── .claude/
│   └── specs/              # Tabled feature specs (.claude/specs/<slug>.md)
├── vim/                    # Vim configuration
├── vimrc                   # Vim settings
├── zsh/                    # Modular zsh configuration
│   ├── aliases.zsh         # Shell aliases
│   ├── claude.zsh          # Claude Code & MCP aliases
│   ├── colors.zsh          # Chocolate Donut color palette
│   ├── completion.zsh      # Zsh completion system
│   ├── core.zsh            # Core environment setup
│   ├── fzf.zsh             # Fuzzy finder setup
│   ├── prompt.zsh          # Custom powerline prompt
│   └── yabai.zsh           # Yabai/skhd reload alias
├── zshrc                   # Main zsh entry point
├── .sync-with-rollback     # Main sync script with state management
├── AGENTS.md               # This file — agent instructions for the repo
└── CLAUDE.md               # One-line `@AGENTS.md` import for Claude Code
```

### Configuration Hierarchy

1. **zshrc** - Main entry point that sources all zsh modules
2. **zsh/** - Modular configuration files, each handling specific functionality
3. **claude/** - Claude Code configuration (agents, commands, hooks, MCP)

### Key Design Patterns

- **Modular Configuration**: Each aspect of the shell is in its own file for maintainability
- **Theme Consistency**: Chocolate Donut theme managed via tinty across terminal, git, and iTerm2
- **Performance Optimization**: Git prompt uses caching to avoid slowdowns
- **Declarative MCP Management**: Single YAML registry synced via native `claude mcp` commands
- **Rollback Support**: Sync creates backups and manifests for easy rollback
- **Scoped Profiles**: `claude/profiles/<name>/` bundles a CLAUDE.md + `settings-merge.json` for task-shaped sessions (frontend, spec, review, rtk-only, plugin, todo). `ccp <name>` launches with profile-merged settings, enabling per-profile LSP gating and tool restrictions.

## MCP (Model Context Protocol) Management

MCPs are managed declaratively via `claude/mcp/registry.yaml`:

```yaml
mcps:
  context7:
    command: npx
    args: ["-y", "@upstash/context7-mcp"]
    scope: user
    description: Documentation context for libraries and frameworks
```

**Scopes:**

- `user` - Available in all projects (recommended for dev tools)
- `project` - Stored in .mcp.json, shared with team
- `local` - Machine-specific, gitignored

**Workflow:**

1. Edit registry: `mcp-edit`
2. Preview changes: `mcp-sync-dry`
3. Apply changes: `mcp-sync`

The sync script uses native `claude mcp add/remove` commands, not direct JSON manipulation.

## Plugin Management

Plugins are managed declaratively via `claude/plugins/registry.yaml`:

```yaml
plugins:
  claude-md-management@claude-plugins-official:
    description: Audit and improve CLAUDE.md files
    scope: user
```

**Prerequisites:**
Marketplaces must be added first:

```bash
claude plugin marketplace add anthropics/claude-plugins-official
claude plugin marketplace add boostvolt/claude-code-lsps
claude plugin marketplace add upstash/context7
claude plugin marketplace add jarrodwatts/claude-hud
```

**Workflow:**

1. Edit registry: `plugin-edit`
2. Preview changes: `plugin-sync-dry`
3. Apply changes: `plugin-sync`
4. Restart Claude Code for changes to take effect

Note: Unlike MCP, the plugins directory is NOT symlinked to ~/.claude because
Claude Code uses that location for plugin cache storage.

## Profile System

Profiles are scoped sessions at `claude/profiles/<name>/`:

- `CLAUDE.md` — profile-specific instructions (auto-discovered when `ccp <name>` launches inside it)
- `settings-merge.json` — overlay merged onto the user `settings.json` (permissions, denied tools, LSP gating)

**Existing profiles:** `fe` (frontend + shadcn/Playwright), `plugin` (plugin dev), `review` (read-only PR review), `rtkonly` (experimental — route file I/O through rtk), `spec` (discovery dialogue), `todo` (Todoist-only).

**Launch:** `ccp <name>` — loads profile dir, merges settings, scopes tool surface.
**Discover:** `ccp` with no args lists available profiles.
**Add new:** create `claude/profiles/<name>/`, drop in `CLAUDE.md` + optional `settings-merge.json`, run `dots sync`.

**Gotcha:** if your profile relies on an MCP (e.g. tilth in `rtkonly`), add `mcp__<name>__*` to the profile `settings-merge.json` allowlist — otherwise each call prompts even though the server is running.

## Sync System

The `.sync-with-rollback` script provides:

- **Automatic backups** before changes (stored in `~/.local/state/dotfiles/backups/`)
- **Manifest tracking** of all symlinks
- **Rollback capability** to any previous state
- **Per-directory .sync scripts** for custom setup (fonts, iterm2, .copilot)

**Skip list** (not symlinked to ~, canonical source is `SYNC_SKIP_LIST` in `.sync-lib.sh`, which is sourced by `.sync-with-rollback`):

- `.git`, `.local`, `.worktrees`, `reference`, `packages`, `packages.yaml`, `brew`, `apt`, `chezmoi`

**Hidden directory dispatch**: visible dirs are iterated by `for file in *` (glob), hidden dirs (starting with `.`) are iterated separately by `sync_hidden_dirs`. Both use the same rule: if `$dir/.sync` exists, run it. This is how `.copilot/.sync` is reached despite being hidden.

## Chezmoi-Managed Files

A subset of dotfiles is rendered by [chezmoi](https://chezmoi.io/) instead of symlinked. Chezmoi handles per-machine templating (work vs personal git email), per-OS branching, and secret injection — things plain symlinks can't do. The rest of the repo continues to use the symlink + `.sync` system.

**Source:** `chezmoi/` subdirectory of this repo. Currently manages:

- `~/.gitconfig` — `chezmoi/private_dot_gitconfig.tmpl` (templated email, work-only `[url]` redirects)
- `~/.copilot/mcp-config.json` — `chezmoi/private_dot_copilot/mcp-config.json.tmpl` (env-rendered API keys, fails fast if unset)

**First-init (interactive):** `dots sync` invokes `chezmoi init --source ~/dotfiles/chezmoi` if `~/.config/chezmoi/chezmoi.toml` is missing. The `.chezmoi.toml.tmpl` prompts for: `email`, `work`, `personal`, `dev`, `cheese_flow`, `vaudeville`, `todoist`. Answers persist to `~/.config/chezmoi/chezmoi.toml` and aren't re-prompted.

**Subsequent runs:** `dots sync` calls `chezmoi --source ~/dotfiles/chezmoi apply`. Non-interactive.

**Inspect / debug:**

```bash
chezmoi --source ~/dotfiles/chezmoi diff              # what would change
chezmoi --source ~/dotfiles/chezmoi data              # dump rendered template namespace
chezmoi --source ~/dotfiles/chezmoi execute-template < FILE.tmpl
chezmoi doctor                                        # health check
```

**Re-prompt:** delete `~/.config/chezmoi/chezmoi.toml` and re-run `dots sync` (or `chezmoi init --source ~/dotfiles/chezmoi` directly).

**Adding a file:** drop a templated source under `chezmoi/` using the [chezmoi naming attributes](https://chezmoi.io/reference/source-state-attributes/) (`private_`, `dot_`, `executable_`, `encrypted_`, `.tmpl`). Reference data via `{{ .email }}`, `{{ .work }}`, etc. — see the existing templates for patterns. Add a corresponding test to `tests/chezmoi.bats`.

**Secrets upgrade path:** `mcp-config.json.tmpl` uses `{{ env "..." }}` today. Swap to `{{ onepasswordRead "op://<vault>/<item>/credential" }}` once 1Password CLI is set up; remove the corresponding `.env` entries.

**Hard rules** (from the chezmoi skill):

1. Never commit plaintext secrets to `chezmoi/`. Use `encrypted_` or `{{ env }}` / `{{ onepasswordRead }}`.
2. Never edit chezmoi-managed source files via the target path. Use `chezmoi edit ~/.gitconfig` so templating round-trips correctly.
3. Always `chezmoi --source ~/dotfiles/chezmoi diff` before applying when you've changed templates.

## Shell Scripts: Functions Need Tests

**Rule:** every shell function that does real work needs a bats test. `.sync` (and any orchestrator) should fork out to tested functions instead of nesting untestable logic inline.

**Why:** `.sync` runs on every `dots sync`, so a regression there breaks the whole environment. Inline logic inside `.sync` is impossible to exercise without running the full sync against a real `$HOME` — which is slow, destructive, and hard to assert against. Tested helper functions can be invoked from bats with mocked dependencies and asserted on directly.

**How to apply:**

- New shell logic goes into a named function in a sourced library (e.g. `.sync-lib.sh`, `claude/lib/sync-common.sh`, `skills-install/sync.sh`), not as a free-floating block inside a `.sync` script.
- The function takes its inputs as arguments (no hidden globals beyond logging colors and explicitly-documented env vars).
- A corresponding `tests/<area>.bats` file exercises every branch the function can take. Mock external commands (`gh`, `claude`, `yq`, `jq`) by putting fakes earlier on `$PATH` — see `tests/copilot-sync.bats` and `tests/skills-install.bats` for the pattern.
- `.sync` and the top-level orchestrators stay thin: parse args, source the library, dispatch to functions. If a `.sync` script grows logic that can't be invoked from a test, refactor it into a function first.
- Add new test files to `tests/run-tests.sh` so `dots test` runs them.

## Important Implementation Details

### Git Integration

- Work email: <paul.sorensen@uber.com>
- Aliases follow oh-my-zsh conventions for familiarity
- Custom `grb` alias rebases from main (not master)
- Kdiff3 configured as merge/diff tool
- **difftastic**: AST-aware structural diff via Tree-sitter (700+ languages). Use `gds` alias for structural diffs, or `git difftool -t difftastic` for side-by-side. Composes with delta (delta handles pager for log/show/blame, difftastic outputs directly to terminal).
- **mergiraf**: AST-aware merge driver. Registered globally via `gitattributes` for all supported languages. Auto-resolves structural conflicts (import reorders, independent additions) and falls back to standard merge for anything it can't handle. Works transparently with merge/rebase/cherry-pick.
- **Merge conflict resolution chain**: mergiraf (auto-resolve structural) → rerere (replay remembered manual resolutions) → kdiff3 (manual)
- Pre-commit hooks via prek (secrets, shellcheck, large files, claude sync)
- **Skipping hooks**: Use `git commit --no-verify` if prek blocks a commit and you need to override (rare)

### Claude Code Integration

Full agent/skill catalog is in `claude/CLAUDE.md` (auto-discovered). Key project-level details:

- Pre-tool hooks: `phantom-file-check.js`, `write-guard.js`, `review-reply-guard.js` (`worktree-guard.js` exists but is currently disengaged)
- Compaction hooks: `pre-compact.sh` saves context, `post-compact.sh` restores with `/trace` suggestion
- Session hooks: `post-fresh-start.sh` (suggests `/trace`), `on-session-end.sh` (detects partings)
- `ccw` worktrees are OS-sandboxed (Seatbelt/macOS) with `autoAllowBashIfSandboxed: true`

### Window Management (yabai + skhd)

Tiling window manager + hotkey daemon for macOS, installed from the `koekeishiya/formulae` brew tap and started as background services by `yabai/.sync`. Configs live at `yabai/yabairc` and `yabai/skhdrc` and are symlinked to `~/.yabairc` / `~/.skhdrc`.

- **Modifier ladder**: `ctrl+alt` for focus/layout, `ctrl+alt+shift` for swap/move, `cmd+alt` for resize, `ctrl+cmd+alt` for SizeUp-style window/space ops.
- **Vim navigation**: `ctrl+alt+hjkl` focus, `ctrl+alt+shift+hjkl` swap, `cmd+alt+hjkl` resize.
- **Spaces**: `ctrl+alt+1..4` focus, `ctrl+alt+shift+1..4` move-and-follow. macOS spaces must be created manually in Mission Control first — yabai cannot create them with SIP enabled.
- **Snap-to-grid for floating windows**: `ctrl+alt+arrows` for halves, `ctrl+alt+u/i/n/m` for quarters, `ctrl+alt+return` for fullscreen. Auto-floats a tiled window before snapping.
- **SizeUp chords**: `ctrl+cmd+alt+m` toggles zoom-fullscreen (window covers display, others hide underneath), `ctrl+cmd+alt+n` rotates the BSP tree 90°.
- **Reload**: `ctrl+alt+shift+r` restarts both services after config edits.
- **First-time setup**: grant Accessibility (and optionally Screen Recording) to `yabai` and `skhd` in System Settings → Privacy & Security after `dots sync`.
- **SIP**: opacity, removing title bars, and cross-space window movement require SIP partially disabled. The basic tile/focus/swap loop works with SIP on.

## Pre-Commit Hooks (prek)

Pre-commit hooks are managed by [prek](https://prek.j178.dev/) via `prek.toml`. Hooks run automatically on commit and include: trailing whitespace, secret detection, shellcheck, large file checks, and a claude config sync check. Run `prek install` after cloning to set up hooks.

**Always run `dots sync` before committing.** The pre-commit hook verifies that Claude config is synced to `~/.claude/` — if not, the commit will be blocked with a reminder to run `dots sync`. This ensures `~/.claude/settings.json`, agents, commands, hooks, and skills stay in sync with the repo.

## Development Notes

### When Modifying Shell Configuration

1. Changes to prompt require careful testing of git status display
2. The KEYTIMEOUT=1 setting is crucial for vi mode responsiveness
3. Path configurations at the top of zshrc are macOS-specific
4. Run `dots sync` after changes to ensure symlinks are correct

### When Adding New Aliases or Functions

1. Claude/MCP-related items go in `zsh/claude.zsh`
2. General utilities go in `zsh/aliases.zsh`
3. Tool-specific configs get their own file

### When Adding New MCPs, Plugins, LSPs, Packages, or Skills

| Type | Registry | Sync command | Notes |
|------|----------|--------------|-------|
| MCP | `claude/mcp/registry.yaml` | `mcp-sync` | Restart Claude Code after |
| Plugin | `claude/plugins/registry.yaml` | `plugin-sync` | Add `mcp__plugin_<name>__*` to `permissions.allow` if it provides MCP tools |
| LSP | `claude/plugins/registry.yaml` (with `load: true`) | `plugin-sync` | Servers start lazily |
| Package | `packages.yaml` (repo root) | `dots sync` | Use `dots sync refresh` to force re-check |
| Skill | `skills-install/registry.yaml` | `dots sync` (or `skill-sync`) | Set `SKILL_HARNESSES` in `.env`. Harness-agnostic: `gh skill install` writes to each agent's skills dir; for claude-code, lands in `~/.claude/skills/` alongside dotfiles' per-skill symlinks. Auto-runs via `skills-install/.sync`. |

## Important Gotchas

1. **Use `dots sync`**: Don't manually symlink - use the sync script for rollback support
2. **Work-Specific Config**: Git configuration includes Uber-specific settings
3. **macOS Specific**: Paths and some utilities assume macOS environment
4. **Vi Mode**: Shell is in vi mode by default
5. **MCP Scope**: Use `user` scope for dev tools, `project` for team-shared MCPs
6. **Reference Folder**: Put reference docs in `reference/` (gitignored, not symlinked)
7. **zsh Loading Order**: Files in `zsh/` are sourced in the order they appear in `zshrc`. If you add a new config file, edit `zshrc` to source it at the right point. For example, completions must load before `fzf.zsh` or keybindings might conflict.
8. **Pre-Commit Hook Failures**: If prek blocks a commit (e.g., detected secrets), fix the issue before retrying. Only use `--no-verify` for temporary overrides. Check `prek.toml` to understand what's being checked.
