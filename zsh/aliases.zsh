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

alias cddot='cd $HOME/Dev/dotfiles'

# =============================================================================
# Utilities
# =============================================================================
# UUID generator (lowercase, copied to clipboard)
alias uuidg="/usr/bin/uuidgen | tr 'A-Z' 'a-z' | tee /dev/stderr | tr -d '\n' | pbcopy"

# VS Code shortcut - opens current directory, reuses window if already open
alias c="code -r ."

# Shell reload
alias zrl="source ~/.zshrc"

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
alias theme-edit='${EDITOR:-vim} ~/Dev/dotfiles/theme/config.yaml'
alias theme-ls='ls ~/Dev/dotfiles/theme/schemes/'

# =============================================================================
# File Listing
# =============================================================================
# Enable colored ls output
export CLICOLOR=1

# ls aliases with color support
alias ls='ls -G'
alias ll='ls -lhG'
alias la='ls -lahG'
alias l='ls -CFG'