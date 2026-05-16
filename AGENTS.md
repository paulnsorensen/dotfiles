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

Harness-agnostic — installs into each agent listed in `SKILL_HARNESSES` (`.env`). Auto-runs as part of `dots sync` via chezmoi's `run_onchange_install-claude-skills.sh.tmpl`, which invokes `chezmoi/lib/install-external.sh` (skipped silently when `gh skill` is unavailable).

- `skill-sync` - Install external skills from `skills/_registry.yaml` into each configured harness (also fires during `dots sync` via chezmoi)
- `skill-sync-dry` - Preview skill installs without making changes
- `skill-edit` - Edit `skills/_registry.yaml`
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
├── agents/                 # Harness-agnostic agent config (shared by Claude + Codex)
│   ├── AGENTS.md           # Global coding-agent preferences. Copied to ~/.claude/CLAUDE.md AND ~/.codex/AGENTS.md by chezmoi.
│   ├── RTK.md              # RTK proxy reference (Claude only — copied to ~/.claude/RTK.md by chezmoi).
│   └── mcp/
│       ├── registry.yaml   # MCP source of truth (per-entry `harnesses: [claude, codex]`)
│       └── sync.sh         # Declarative MCP sync — loops over harnesses, calls native `<harness> mcp add/list/remove`.
├── claude/                 # Claude Code-specific configuration
│   ├── agents/             # Cheese-themed specialist agents
│   ├── commands/           # Slash commands (/fromage, /fromagerie, /spec, etc.)
│   ├── hooks/              # Pre-tool hooks
│   ├── profiles/           # Scoped sessions (fe, plugin, review, rtkonly, spec, todo) — launched via `ccp <name>`
│   └── plugins/            # Plugin registry; `plugins/local/` holds in-repo plugins (cheese-flow, todoist-flow)
├── codex/                  # OpenAI Codex CLI-specific configuration
│   └── config.toml         # Base ~/.codex/config.toml — copied on first install only, then user-owned (MCP entries written by sync.sh).
├── skills/                 # Single source of truth for skills — flat tree of skill dirs plus `_registry.yaml` for external (`gh skill install`) sources. Copied to ~/.claude/skills/ by chezmoi.
├── chezmoi/                # chezmoi source dir. Wires `~/.config/chezmoi/chezmoi.toml` and runs run_onchange scripts: install-claude-skills (skills/ → ~/.claude/skills/), install-agents-doc (agents/AGENTS.md → both harnesses, agents/RTK.md → Claude), install-codex (codex/config.toml → ~/.codex/ first-time only), install-mcp (drives agents/mcp/sync.sh --force).
├── packages.yaml           # Flat package registry (brew, cargo, apt)
├── packages/
│   └── sync.sh             # Package sync with hash cache
├── fonts/                  # Font installation (.sync script)
├── gitconfig               # Git configuration
├── prek.toml               # Pre-commit hooks config (prek)
├── iterm2/                 # iTerm2 preferences
├── skhd/                   # skhd hotkey daemon config
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
│   └── skhd.zsh            # skhd reload alias
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
- **Declarative MCP Management**: Single YAML registry at `agents/mcp/registry.yaml`, applied to every installed harness (Claude, Codex) via their native `mcp add/remove` CLIs
- **Rollback Support**: Sync creates backups and manifests for easy rollback
- **Scoped Profiles**: `claude/profiles/<name>/` bundles a CLAUDE.md + `settings-merge.json` for task-shaped sessions (frontend, spec, review, rtk-only, plugin, todo). `ccp <name>` launches with profile-merged settings, enabling per-profile LSP gating and tool restrictions.

## MCP (Model Context Protocol) Management

MCPs are managed declaratively via `agents/mcp/registry.yaml`. One registry, multiple harnesses:

```yaml
mcps:
  context7:
    command: npx
    args: ["-y", "@upstash/context7-mcp"]
    scope: user                       # claude-only — codex ignores
    harnesses: [claude, codex]        # optional; default is both
    gate_unless: CHEESE_FLOW          # claude-only — skip install when plugin provides it
    description: Documentation context for libraries and frameworks
```

**Per-entry fields:**

- `harnesses` (optional) — list of harness names to install into. Default: `[claude, codex]`.
- `scope` (claude-only) — `user`, `project`, or `local`. Codex has no scopes.
- `gate_unless` (claude-only) — skip install when env var equals `"true"` (defer to a plugin's bundled MCP).

**Workflow:**

1. Edit registry: `mcp-edit`
2. Preview changes: `mcp-sync-dry`
3. Apply changes: `mcp-sync` (interactive removal prompts) or let `dots sync` drive it via chezmoi's `run_onchange_install-mcp.sh.tmpl` (uses `--force` non-interactively).

`agents/mcp/sync.sh` loops over harnesses, calling native `claude mcp add/list/remove` and `codex mcp add/list/remove` per entry. A missing harness CLI is skipped silently.

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

- `.git`, `.local`, `.worktrees`, `reference`, `packages`, `packages.yaml`, `brew`, `apt`, `agents`, `codex`

**Hidden directory dispatch**: visible dirs are iterated by `for file in *` (glob), hidden dirs (starting with `.`) are iterated separately by `sync_hidden_dirs`. Both use the same rule: if `$dir/.sync` exists, run it. This is how `.copilot/.sync` is reached despite being hidden.

## Shell Scripts: Functions Need Tests

**Rule:** every shell function that does real work needs a bats test. `.sync` (and any orchestrator) should fork out to tested functions instead of nesting untestable logic inline.

**Why:** `.sync` runs on every `dots sync`, so a regression there breaks the whole environment. Inline logic inside `.sync` is impossible to exercise without running the full sync against a real `$HOME` — which is slow, destructive, and hard to assert against. Tested helper functions can be invoked from bats with mocked dependencies and asserted on directly.

**How to apply:**

- New shell logic goes into a named function in a sourced library (e.g. `.sync-lib.sh`, `claude/lib/sync-common.sh`, `chezmoi/lib/install-external.sh`), not as a free-floating block inside a `.sync` script.
- The function takes its inputs as arguments (no hidden globals beyond logging colors and explicitly-documented env vars).
- A corresponding `tests/<area>.bats` file exercises every branch the function can take. Mock external commands (`gh`, `claude`, `yq`, `jq`) by putting fakes earlier on `$PATH` — see `tests/copilot-sync.bats` and `tests/skills-external.bats` for the pattern.
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

Full agent/skill catalog is in `agents/AGENTS.md` (copied to `~/.claude/CLAUDE.md` by chezmoi). Key project-level details:

- Pre-tool hooks: `phantom-file-check.js`, `write-guard.js`, `review-reply-guard.js` (`worktree-guard.js` exists but is currently disengaged)
- Compaction hooks: `pre-compact.sh` saves context, `post-compact.sh` restores with `/trace` suggestion
- Session hooks: `post-fresh-start.sh` (suggests `/trace`), `on-session-end.sh` (detects partings)
- `ccw` worktrees are OS-sandboxed (Seatbelt/macOS) with `autoAllowBashIfSandboxed: true`

### Hotkey Daemon (skhd)

Hotkey daemon for macOS, installed from the `koekeishiya/formulae` brew tap and started as a background service by `skhd/.sync`. Config lives at `skhd/skhdrc` and is symlinked to `~/.skhdrc`. Yabai was removed; the file is intentionally an empty skeleton — add bindings as needed.

- **Reload**: `skr` (alias) or `skhd --restart-service` after editing `skhd/skhdrc`.
- **First-time setup**: grant Accessibility to `skhd` in System Settings → Privacy & Security after `dots sync`.
- **Syntax reference**: <https://github.com/koekeishiya/skhd>. Hotkeys can run any shell command via `$SHELL -c`, support modal/chord modes, application-specific bindings, and key synthesis (`-k`).

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
| MCP | `agents/mcp/registry.yaml` | `mcp-sync` (or `dots sync`) | Restart Claude / Codex after; entries flow to both harnesses by default |
| Plugin | `claude/plugins/registry.yaml` | `plugin-sync` | Add `mcp__plugin_<name>__*` to `permissions.allow` if it provides MCP tools |
| LSP | `claude/plugins/registry.yaml` (with `load: true`) | `plugin-sync` | Servers start lazily |
| Package | `packages.yaml` (repo root) | `dots sync` | Use `dots sync refresh` to force re-check |
| Skill | `skills/` (dirs + `_registry.yaml` for external sources) | `dots sync` (or `skill-sync` for the external-only fast path) | chezmoi's `run_onchange_install-claude-skills.sh.tmpl` invokes `chezmoi/lib/install-local.sh` (copies each `skills/<name>/` into `~/.claude/skills/<name>/`) and, when `gh skill` is present, `chezmoi/lib/install-external.sh` (runs `gh skill install` per harness from `SKILL_HARNESSES`). Ownership tracked via `~/.claude/skills/.dotfiles-managed`; gh-installed dirs are left untouched. |

## Important Gotchas

1. **Use `dots sync`**: Don't manually symlink - use the sync script for rollback support
2. **Work-Specific Config**: Git configuration includes Uber-specific settings
3. **macOS Specific**: Paths and some utilities assume macOS environment
4. **Vi Mode**: Shell is in vi mode by default
5. **MCP Scope**: Use `user` scope for dev tools, `project` for team-shared MCPs
6. **Reference Folder**: Put reference docs in `reference/` (gitignored, not symlinked)
7. **zsh Loading Order**: Files in `zsh/` are sourced in the order they appear in `zshrc`. If you add a new config file, edit `zshrc` to source it at the right point. For example, completions must load before `fzf.zsh` or keybindings might conflict.
8. **Pre-Commit Hook Failures**: If prek blocks a commit (e.g., detected secrets), fix the issue before retrying. Only use `--no-verify` for temporary overrides. Check `prek.toml` to understand what's being checked.
