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
  _brew_prefix="$(brew --prefix 2>/dev/null)"
  [[ -d "${_brew_prefix}/opt/openssl/bin" ]] && export PATH="${_brew_prefix}/opt/openssl/bin:$PATH"
  [[ -d "${_brew_prefix}/opt/rustup/bin" ]] && export PATH="${_brew_prefix}/opt/rustup/bin:$PATH"
  unset _brew_prefix
fi

# Add dotfiles bin to PATH
export PATH="$DOTFILES_DIR/bin:$PATH"

# Add local bin to PATH
export PATH="$HOME/.local/bin:$PATH"

# cargo install puts binaries in ~/.cargo/bin
[[ -d "$HOME/.cargo/bin" ]] && export PATH="$HOME/.cargo/bin:$PATH"

# prek cache/logs — use TMPDIR so sandbox environments can write the log
export PREK_HOME="${TMPDIR:-/tmp}/prek"

# Editor configuration
export EDITOR="$(which vim)"
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
  # Re-prepend dotfiles/bin so dotfiles scripts stay ahead of pyenv shims
  export PATH="$DOTFILES_DIR/bin:$PATH"
fi

# Source .env file if it exists (key=value only, no command execution)
if [[ -f "$DOTFILES_DIR/.env" ]]; then
    while IFS='=' read -r key val; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        export "$key=$val"
    done < "$DOTFILES_DIR/.env"
fi

# Vi mode cursor shapes (orthogonal to prompt choice — works with any prompt)
function zle-line-init zle-keymap-select {
  if [[ $KEYMAP == vicmd ]]; then
    echo -ne '\e[2 q' # Solid block — normal mode
  elif [[ $KEYMAP == main ]] \
    || [[ $KEYMAP == viins ]] \
    || [[ $KEYMAP = '' ]]; then
    echo -ne '\e[5 q' # Blinking beam — insert mode (matches native vim)
  fi
  zle reset-prompt
  zle -R
}
zle -N zle-line-init
zle -N zle-keymap-select
