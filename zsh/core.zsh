# core.zsh - Essential environment and settings
# This file sets up the foundation for the shell environment

# Essential directories
export DOTFILES_DIR="$HOME/Dev/dotfiles"
export DEV_DIR="$HOME/Dev"

# PATH configuration (matching zshrc)
if [[ $OSTYPE == darwin* ]]; then
  path=(
    /opt/homebrew/bin
    $path
  )
  export PATH=$(brew --prefix openssl)/bin:$PATH
fi

# Add dotfiles bin to PATH
export PATH="$HOME/Dev/dotfiles/bin:$PATH"

# Add local bin to PATH
export PATH="$HOME/.local/bin:$PATH"

# fpath for completions
fpath=(
  $fpath
)

# Editor configuration
export EDITOR=$(which vim)
export VISUAL=$EDITOR
export PAGER=less
export LESS='-i -M -R'  # case insensitive searching, status line, and colors

# Shell behavior
setopt VI                    # Vi editing mode
setopt NO_BEEP              # Never ever beep. Ever
KEYTIMEOUT=1                # Fast escape key timeout for vi mode (1/100th of a second)
MAILCHECK=0                 # disable mail checking

# History configuration
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt HIST_IGNORE_ALL_DUPS # Remove older duplicate entries
setopt HIST_IGNORE_SPACE    # Don't record commands starting with space
setopt SHARE_HISTORY        # Share history between sessions
setopt HIST_VERIFY          # Show command with history expansion before running

# Key bindings for vi mode
bindkey -v
autoload -U edit-command-line
zle -N edit-command-line
bindkey -M vicmd v edit-command-line

# init pyenv if it exists
if command -v pyenv 1>/dev/null 2>&1; then
  eval "$(pyenv init -)"
fi

# init rbenv
eval "$(rbenv init - zsh)"

# Source .env file if it exists to load CLAUDE_SETUP_DIR
if [ -f "$HOME/Dev/dotfiles/.env" ]; then
    source "$HOME/Dev/dotfiles/.env"
fi