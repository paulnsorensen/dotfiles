# aliases.zsh - All aliases and simple functions
# Consolidated from git.zsh, navigation.zsh, misc.zsh, macos.zsh

# =============================================================================
# Git Aliases (from git.zsh)
# =============================================================================
# Based on oh-my-zsh git plugin
alias ga='git add'
alias gb='git branch'
alias gco='git checkout'
alias gcb='git checkout -b'
alias gc='git commit -v'
alias gcm='git commit -m'
alias gd='git diff'
alias gdn='git diff --name-only'
alias gf='git fetch'
alias gl='git pull'
alias gp='git push'
alias gst='git status'

# Remove files that match .gitignore
alias gri='git rm --cached "$(git ls-files -i -X .gitignore)"'

# Log only your commits
alias glc='git config user.email | xargs git log --author'

# Rebase from main
alias grb='git pull -r origin main'

# Checkout main and pull
alias gcom='git checkout main && git pull'

# =============================================================================
# Navigation & Directory Shortcuts
# =============================================================================
# Simple navigation without context switching complexity
cdd() {
    if [[ -z "$1" ]]; then
        cd "$DEV_DIR"
    else
        cd "$DEV_DIR/$1"
    fi
}

alias cddot='cd $DOTFILES_DIR'

# =============================================================================
# Utilities
# =============================================================================
# UUID generator (lowercase, copied to clipboard)
if [[ "$DOTFILES_OS" == "macos" ]]; then
  alias uuidg="/usr/bin/uuidgen | tr 'A-Z' 'a-z' | tee /dev/stderr | tr -d '\n' | pbcopy"
else
  alias uuidg="uuidgen | tr 'A-Z' 'a-z' | tee /dev/stderr | tr -d '\n' | xclip -sel clip"
fi

# VS Code shortcut - opens current directory, reuses window if already open
alias c="code -r ."

# Shell reload
alias zrl="source ~/.zshrc"

# Tmux reload
alias trl='tmux source-file ~/.tmux.conf && echo "tmux config reloaded"'

# =============================================================================
# Search and Find (using ripgrep)
# =============================================================================
# Basic ripgrep shortcuts
alias rg='rg --smart-case'                    # Smart case by default
alias rga='rg --hidden --no-ignore'           # Search ALL files (including hidden/ignored)

# Code searching
alias rgf='rg --files-with-matches'           # Show only filenames with matches
alias rgc='rg --count'                        # Show match counts per file
alias rgl='rg --files-without-match'          # Show files WITHOUT matches

# Common developer searches
alias todos='rg "TODO|FIXME|HACK|NOTE" -n'    # Find all todos/fixmes

# =============================================================================
# Theme Management
# =============================================================================
alias theme-edit='${EDITOR:-vim} $DOTFILES_DIR/theme/config.yaml'
alias theme-ls='ls $DOTFILES_DIR/theme/schemes/'

# =============================================================================
# File Listing (using eza for modern ls replacement)
# =============================================================================
# Enable colored output
export CLICOLOR=1

# eza aliases (modern ls replacement)
if command -v eza &> /dev/null; then
  alias ls='eza'
  alias ll='eza -lh'
  alias la='eza -lah'
  alias l='eza -F'
  alias tree='eza --tree'
else
  # Fallback to ls if eza not installed
  if [[ "$DOTFILES_OS" == "macos" ]]; then
    alias ls='ls -G'
    alias ll='ls -lhG'
    alias la='ls -lahG'
    alias l='ls -CFG'
  else
    alias ls='ls --color=auto'
    alias ll='ls -lh --color=auto'
    alias la='ls -lah --color=auto'
    alias l='ls -CF --color=auto'
  fi
fi

# =============================================================================
# Modern CLI Tools
# =============================================================================
# bat - cat with syntax highlighting
if command -v bat &> /dev/null; then
  alias cat='bat'
  alias catn='bat --number'  # with line numbers
fi

# delta - syntax-aware diff
if command -v delta &> /dev/null; then
  alias diff='delta'
fi

# ast-grep - AST-based code search
if command -v ast-grep &> /dev/null; then
  alias sg='ast-grep'
fi

# =============================================================================
# Rust Replacements (modern coreutils)
# =============================================================================
# bottom - system monitor (keeps htop for process management)
if command -v btm &>/dev/null; then
    alias top='btm'
fi

# dust - disk usage with tree visualization
if command -v dust &>/dev/null; then
    alias du='dust'
fi

# procs - process viewer with keyword filtering
if command -v procs &>/dev/null; then
    alias ps='procs'
fi

# tokei - code statistics by language
if command -v tokei &>/dev/null; then
    alias loc='tokei'
fi
