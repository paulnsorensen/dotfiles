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
if command -v difft &>/dev/null; then
  alias gds='GIT_EXTERNAL_DIFF=difft git diff'
fi
alias gdn='git diff --name-only'
alias gf='git fetch'
alias gp='git push'
alias gpl='git pull'
alias gst='git status'

# Pretty commit graph (recent 20)
alias gl='git log --oneline --graph --decorate -20'

# Undo last commit, keep the changes staged
alias gundo='git reset --soft HEAD~1'

# Remove files that match .gitignore
alias gri='git rm --cached "$(git ls-files -i -X .gitignore)"'

# Log only your commits
alias glc='git config user.email | xargs git log --author'

# Rebase from main; continue / abort an in-progress rebase
alias grb='git pull -r origin main'
alias grbc='git rebase --continue'
alias grba='git rebase --abort'

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

# Deploy dotfiles (symlinks, packages, chezmoi, base-profile render)
alias ds='dots sync'

# Tmux reload
alias trl='tmux source-file ~/.tmux.conf && echo "tmux config reloaded"'

# =============================================================================
# Remote access (Tailscale + mosh + tmux)
# =============================================================================
# Canonical resilient remote shell: mosh keeps the connection alive across
# network changes / sleep; tmux keeps the session alive across disconnects.
# Usage: mtmux <host> [session]   (host = MagicDNS name or Tailscale IP)
mtmux() {
    local host="$1" session="${2:-main}"
    if [[ -z "$host" ]]; then
        echo "usage: mtmux <host> [session]" >&2
        return 2
    fi
    mosh "$host" -- tmux new -A -s "$session"
}

# Tailscale shortcuts
alias tss='tailscale status'
alias tsip='tailscale ip -4'

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

# opencode - terminal AI coding agent
if command -v opencode &> /dev/null; then
  alias oc='opencode'
fi

# Oh My Pi - isolated native config with managed prompt addendum
if command -v omp &> /dev/null; then
  omp() {
    command omp --append-system-prompt "$HOME/.omp/agent/APPEND_SYSTEM.md" "$@"
  }

  ompt() {
    PI_CONFIG_DIR=.omp-tight omp "$@"
  }
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

# cargo-nextest - faster parallel test runner
if command -v cargo-nextest &>/dev/null; then
    alias cn='cargo nextest run'
    alias cnf='cargo nextest run --failure-output immediate-final'
fi

# =============================================================================
# Agent Skills — `skills/_registry.yaml` (external sources) + the local
# `skills/` tree are the EDIT surface (skill-edit). For claude, `dots sync`
# selects local skills via chezmoi/.chezmoidata/claude.yaml, vendors external
# sources, and deploys them as chezmoi exact_ dirs (removals propagate).
# Other harnesses are frozen pending their migration spec.
# =============================================================================
alias skill='npx --yes skills'
alias skill-ls='npx --yes skills list --global'
alias skill-edit='${EDITOR:-vim} $DOTFILES_DIR/skills/_registry.yaml'

# =============================================================================
# Cheatsheet
# =============================================================================
# Print categorized shortcut reference: git, claude, worktrees, tmux, bin/
# ZLE binding: no clean vi-mode-safe key found (Ctrl+R owned by atuin/fzf,
# Ctrl+T by fzf, Ctrl+\\  risks SIGQUIT on some terminals). Use the alias.
alias cheat='$DOTFILES_DIR/bin/cheatsheet'
