# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a personal dotfiles repository that configures a vim-centric, terminal-based development environment for macOS. The configuration focuses on zsh shell, iTerm2, VS Code with vim bindings, comprehensive git setup, and Claude Code integration.

## Key Commands

### Dotfiles Management
- `dots sync` - Sync dotfiles (symlinks, homebrew, fonts) with rollback support
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
- `cc` - Alias for `claude`
- `ccc` - Continue last conversation (`claude --continue`)
- `ccr` - Resume conversation (`claude --resume`)
- `ccp` - Print mode (`claude --print`)
- `ccw <slug>` - Create isolated git worktree and launch Claude inside it (sandboxed)
- `ccw-ls` - List git worktrees
- `ccw-sweep` - Scan ~/Dev for stale worktrees with safety checks (dry-run, auto-clean modes)
- `ccw-clean` - Clean stale worktrees in current repo only (delegates to ccw-sweep)
- `ccfresh` - Continue last conversation with MCPs primed
- `claude-settings` - Edit ~/.claude/settings.json
- `mcp-sync` - Sync MCPs from registry.yaml to Claude Code
- `mcp-sync-dry` - Preview MCP sync changes without applying
- `mcp-edit` - Edit MCP registry.yaml
- `mcp-ls` - List currently configured MCPs
- `mcp-add <name> <cmd> [args...]` - Add a user-scoped MCP

### GitHub Helpers
- `gh-pr-review <PR#>` - Bundle PR metadata, diff, and checks for review
- `gh-pr-prep` - Bundle PR prep context (commits, diff stats, upstream status)
- `gh-issue-context <issue#>` - Bundle issue metadata and comments

### Plugin Management
- `plugin-sync` - Sync plugins from registry.yaml to Claude Code
- `plugin-sync-dry` - Preview plugin sync changes without applying
- `plugin-edit` - Edit plugin registry.yaml
- `plugin-ls` - List currently installed plugins

### LSP Management (local-only)
- `/lsp` - Auto-detect project languages and enable matching LSPs (Claude skill)
- `/lsp --all` - Enable all LSPs regardless of project
- `/lsp --list` - Preview which LSPs would be enabled (dry run)
- `/lsp --disable` - Remove all LSP entries from local settings
- `lsp-sync` - Install and enable ALL LSP plugins locally (bash, no detection)
- `lsp-sync-dry` - Preview LSP sync changes without applying
- `lsp-disable` - Remove LSP plugins from local settings
- `lsp-ls` - Show which LSPs are enabled locally
- `lsp-edit` - Edit lsp-registry.yaml

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
├── claude/                 # Claude Code configuration
│   ├── mcp/
│   │   ├── registry.yaml   # MCP source of truth
│   │   └── sync.sh         # Declarative MCP sync script
│   ├── agents/             # Cheese-themed specialist agents
│   ├── commands/           # Slash commands (/fromage, /spec, etc.)
│   ├── hooks/              # Pre-tool hooks
│   ├── skills/             # Reusable skill definitions
│   └── plugins/            # Plugin registry and sync script
├── fonts/                  # Font installation (.sync script)
├── gitconfig               # Git configuration
├── prek.toml               # Pre-commit hooks config (prek)
├── iterm2/                 # iTerm2 preferences
├── nixpkgs/                # Nix Home Manager config
├── reference/              # Reference docs (gitignored)
├── .claude/
│   ├── specs/              # Tabled feature specs (.claude/specs/<slug>.md)
│   └── hookify.*.local.md  # Active hookify rules (gitignored)
├── vim/                    # Vim configuration
├── vimrc                   # Vim settings
├── zsh/                    # Modular zsh configuration
│   ├── aliases.zsh         # Shell aliases
│   ├── claude.zsh          # Claude Code & MCP aliases
│   ├── colors.zsh          # Chocolate Donut color palette
│   ├── completion.zsh      # Zsh completion system
│   ├── core.zsh            # Core environment setup
│   ├── fzf.zsh             # Fuzzy finder setup
│   └── prompt.zsh          # Custom powerline prompt
├── zshrc                   # Main zsh entry point
├── .sync-with-rollback     # Main sync script with state management
├── .brew                   # Homebrew package installation
└── CLAUDE.md               # This file
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

## MCP (Model Context Protocol) Management

MCPs are managed declaratively via `claude/mcp/registry.yaml`:

```yaml
mcps:
  octocode:
    command: npx
    args: [octocode-mcp@latest]
    scope: user
    description: GitHub code search and repository tools
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
  hookify@claude-plugins-official:
    description: Create hooks to prevent unwanted behaviors by analyzing conversation patterns
    scope: user
```

**Prerequisites:**
Marketplaces must be added first:
```bash
claude plugin marketplace add anthropics/claude-plugins-official
claude plugin marketplace add boostvolt/claude-code-lsps
claude plugin marketplace add upstash/context7
```

**Workflow:**
1. Edit registry: `plugin-edit`
2. Preview changes: `plugin-sync-dry`
3. Apply changes: `plugin-sync`
4. Restart Claude Code for changes to take effect

Note: Unlike MCP, the plugins directory is NOT symlinked to ~/.claude because
Claude Code uses that location for plugin cache storage.

## Sync System

The `.sync-with-rollback` script provides:
- **Automatic backups** before changes (stored in `~/.local/state/dotfiles/backups/`)
- **Manifest tracking** of all symlinks
- **Rollback capability** to any previous state
- **Per-directory .sync scripts** for custom setup (fonts, iterm2, nixpkgs)

**Skip list** (not symlinked to ~):
- `.git`, `.local`, `reference`

## Important Implementation Details

### Prompt System (zsh/prompt.zsh)
- Uses a caching mechanism for git status to improve performance
- Implements vi mode cursor shape changes
- Shows time since last commit in git repositories
- Color codes match Chocolate Donut theme

### Git Integration
- Work email: paul.sorensen@uber.com
- Aliases follow oh-my-zsh conventions for familiarity
- Custom `grb` alias rebases from main (not master)
- Kdiff3 configured as merge/diff tool
- Pre-commit hooks via prek (secrets, shellcheck, large files, claude sync)
- **Skipping hooks**: Use `git commit --no-verify` if prek blocks a commit and you need to override (rare)

### Claude Code Integration
- Fromage pipeline (`/fromage` — adapts to task complexity, replaces `/cheese` and `/curdle`)
- Review/analysis agents use universal 0-100 confidence scoring (>= 75 to surface)
- Specialist agents: fromage-age (code review), fromage-press (adversarial testing), fromage-pasteurize (security+deps audit), cheese-factory (codebase orientation), roquefort-wrecker (standalone tests), ricotta-reducer (simplification), whey-drainer (test runner), research (multi-source research), worktree-triage (stale worktree analysis)
- `/wreck` — adversarial test writer (roquefort-wrecker), writes and runs tests outside /fromage
- `/age` — Staff Engineer code review of recent changes (fromage-age, focused mode)
- `/audit` — security and dependency health audit (fromage-pasteurize)
- `/test` — run existing tests via whey-drainer, returns concise summary
- `/notebook <area>` — guided codebase review with persistent note-taking
- `/move-my-cheese <PR#>` — take over a PR: merge main, diagnose CI failures, fix tests/conflicts, push
- Pre-tool hooks (block-install.js, phantom-file-check.js, block-file-write.js)
- Compaction hooks (pre-compact.sh saves context, post-compact.sh re-primes Serena)
- Fresh session hook (post-fresh-start.sh injects /go reminder on non-compact starts)
- Session-end hook (on-session-end.sh detects parting language → injects /park reminder)
- `/agents` command — control panel listing all agents and skills
- `/go` command to re-prime MCPs after compaction or at session start
- Hookify rules in `.claude/hookify.*.local.md` — active immediately, no restart needed
- `ccw` worktrees are OS-sandboxed (Seatbelt/macOS) with `autoAllowBashIfSandboxed: true`

### MCP Usage Guidelines
- **Serena**: Prefer `find_symbol` and `get_symbols_overview` over reading full files. Use `write_memory`/`read_memory` to persist discoveries across compaction. Always activate the project at conversation start.
- **Context7**: Use when working with third-party library APIs to get version-specific docs.
- **After compaction**: Run `/go` or manually activate Serena (`activate_project`), read Serena memories, and check onboarding. The post-compact hook does this automatically but `/go` is there as a manual fallback.
- **Fresh vs Continued sessions**: Continued sessions (`ccc`, `ccr`) preserve context; fresh sessions call the session-start hook which runs `/go` automatically. If MCPs seem stale, always run `/go` to re-prime them.

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

### When Adding New MCPs
1. Add entry to `claude/mcp/registry.yaml`
2. Run `mcp-sync` to install
3. Restart Claude Code for changes to take effect

### When Adding New Plugins
1. Add entry to `claude/plugins/registry.yaml`
2. Run `plugin-sync` to install
3. Restart Claude Code for changes to take effect
4. Add `mcp__plugin_<name>__*` to `permissions.allow` in `claude/settings.json` if the plugin provides MCP tools

### When Adding New LSPs
1. Add entry to `claude/plugins/lsp-registry.yaml`
2. Run `lsp-sync` to install and enable locally
3. Restart Claude Code for changes to take effect
4. LSPs are local-only (stored in `~/.claude/settings.local.json`, not committed) to avoid overhead in headless/CI sessions

### Dependencies (Homebrew)
Managed in `.brew`:
- `yq` - YAML parsing for MCP sync
- `jq` - JSON processing

### Dependencies Not Managed by This Repo
- Nix Home Manager (configuration in nixpkgs/home.nix)
- VS Code extensions (list in vscode/settings.json)
- Pyenv and Conda
- iTerm2 application

## Important Gotchas

1. **Use `dots sync`**: Don't manually symlink - use the sync script for rollback support
2. **Work-Specific Config**: Git configuration includes Uber-specific settings
3. **macOS Specific**: Paths and some utilities assume macOS environment
4. **Vi Mode**: Shell is in vi mode by default
5. **MCP Scope**: Use `user` scope for dev tools, `project` for team-shared MCPs
6. **Reference Folder**: Put reference docs in `reference/` (gitignored, not symlinked)
7. **zsh Loading Order**: Files in `zsh/` are sourced in the order they appear in `zshrc`. If you add a new config file, edit `zshrc` to source it at the right point. For example, completions must load before `fzf.zsh` or keybindings might conflict.
8. **Pre-Commit Hook Failures**: If prek blocks a commit (e.g., detected secrets), fix the issue before retrying. Only use `--no-verify` for temporary overrides. Check `prek.toml` to understand what's being checked.
