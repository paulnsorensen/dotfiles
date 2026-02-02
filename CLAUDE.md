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
- `dots test` - Run test suite

### Shell Configuration
- `zrl` - Reload zsh configuration after changes
- `source ~/.zshrc` - Alternative way to reload configuration

### Claude Code & MCP Management
- `cc` - Alias for `claude`
- `ccc` - Continue last conversation (`claude --continue`)
- `ccr` - Resume conversation (`claude --resume`)
- `mcp-sync` - Sync MCPs from registry.yaml to Claude Code
- `mcp-sync-dry` - Preview MCP sync changes without applying
- `mcp-edit` - Edit MCP registry.yaml
- `mcp-ls` - List currently configured MCPs

### Plugin Management
- `plugin-sync` - Sync plugins from registry.yaml to Claude Code
- `plugin-sync-dry` - Preview plugin sync changes without applying
- `plugin-edit` - Edit plugin registry.yaml
- `plugin-ls` - List currently installed plugins

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
│   ├── commands/           # Slash commands (/cheese, /curdle, etc.)
│   ├── hooks/              # Pre-tool hooks
│   └── plugins/            # Plugin registry and sync script
├── fonts/                  # Font installation (.sync script)
├── gitconfig               # Git configuration
├── githooks/               # Git hooks (pre-commit checks)
├── iterm2/                 # iTerm2 preferences
├── nixpkgs/                # Nix Home Manager config
├── reference/              # Reference docs (gitignored)
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
  security-guidance@claude-plugins-official:
    description: Security best practices hooks
    scope: user
```

**Prerequisites:**
Marketplaces must be added first:
```bash
claude plugin marketplace add anthropics/claude-plugins-official
claude plugin marketplace add boostvolt/claude-code-lsps
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
- Pre-commit hooks check for secrets, validate shell scripts

### Claude Code Integration
- Cheese-themed agents (Gouda Explorer, Brie Architect, etc.)
- Custom slash commands (`/cheese`, `/curdle` for workflows)
- Pre-tool hooks (block-install.js, phantom-file-check.js)
- Serena MCP for semantic code analysis

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
