# core.zsh - Essential environment and settings
# This file sets up the foundation for the shell environment

# Essential directories
export DOTFILES_DIR="${DOTFILES_DIR:-$HOME/Dev/dotfiles}"
export DEV_DIR="$HOME/Dev"

# PATH configuration (matching zshrc)
if [[ $OSTYPE == darwin* ]]; then
  path=(
    /opt/homebrew/bin
    $path
  )
  # Fork-free prefix: honor HOMEBREW_PREFIX (set statically in ~/.zprofile on
  # Apple Silicon), else pick the arch's install dir by existence — /opt/homebrew
  # (Apple Silicon) or /usr/local (Intel). Avoids a `brew --prefix` fork.
  if [[ -n $HOMEBREW_PREFIX ]]; then
    _brew_prefix=$HOMEBREW_PREFIX
  elif [[ -d /opt/homebrew ]]; then
    _brew_prefix=/opt/homebrew
  else
    _brew_prefix=/usr/local
  fi
  [[ -d "${_brew_prefix}/opt/openssl/bin" ]] && export PATH="${_brew_prefix}/opt/openssl/bin:$PATH"
  [[ -d "${_brew_prefix}/opt/rustup/bin" ]] && export PATH="${_brew_prefix}/opt/rustup/bin:$PATH"
  unset _brew_prefix
elif [[ $OSTYPE == linux* ]]; then
  # Homebrew on Linux installs to /home/linuxbrew/.linuxbrew (or ~/.linuxbrew);
  # brew shellenv puts its bin/sbin on PATH and sets HOMEBREW_* vars.
  for _brew_bin in /home/linuxbrew/.linuxbrew/bin/brew "$HOME/.linuxbrew/bin/brew"; do
    [[ -x "$_brew_bin" ]] && eval "$("$_brew_bin" shellenv)" && break
  done
  unset _brew_bin
fi

# Add dotfiles bin to PATH
export PATH="$DOTFILES_DIR/bin:$PATH"

# Add local bin to PATH
export PATH="$HOME/.local/bin:$PATH"

# cargo install puts binaries in ~/.cargo/bin
[[ -d "$HOME/.cargo/bin" ]] && export PATH="$HOME/.cargo/bin:$PATH"

# .NET SDK + global tools (dotnet tool install, e.g. godotenv) live under ~/.dotnet
if [[ -d "$HOME/.dotnet" ]]; then
  export DOTNET_ROOT="$HOME/.dotnet"
  export PATH="$DOTNET_ROOT:$DOTNET_ROOT/tools:$PATH"
fi

# prek cache/logs — persistent location writable by Claude sandbox
export PREK_HOME="$HOME/Dev/.prek"

# Editor configuration
export EDITOR="$(which vim)"
export VISUAL=$EDITOR
export PAGER=less
export LESS='-i -M -R'  # case insensitive, status line, and colors

# Shell behavior
setopt VI
setopt NO_BEEP
KEYTIMEOUT=1
MAILCHECK=0

# History configuration
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_IGNORE_SPACE
setopt SHARE_HISTORY
setopt HIST_VERIFY

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

# init mise if it exists — re-prepend its shims dir ahead of pyenv/native
# copies so a mise-managed tool (e.g. claude, codex) resolves before any
# stale native/brew install still on PATH from before migration.
if command -v mise 1>/dev/null 2>&1; then
  eval "$(mise activate zsh)"
fi

# Load only the documented non-secret .env settings. Never source the file,
# consult a vault cache, or pass retired credentials to child processes.
for _dotfiles_secret in \
  GH_TOKEN \
  GITHUB_PERSONAL_ACCESS_TOKEN \
  GITHUB_APP_PRIVATE_KEY \
  CONTEXT7_API_KEY \
  TAVILY_API_KEY \
  SERPER_API_KEY \
  TODOIST_API_KEY; do
  unset "$_dotfiles_secret"
done
rm -f -- "${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles/secrets.env"

_dotfiles_env_file="$DOTFILES_DIR/.env"
if [[ -f "$_dotfiles_env_file" ]]; then
  while IFS= read -r _dotfiles_line || [[ -n "$_dotfiles_line" ]]; do
    [[ "$_dotfiles_line" =~ ^[[:space:]]*$ || "$_dotfiles_line" =~ ^[[:space:]]*# ]] && continue
    [[ "$_dotfiles_line" == *=* ]] || continue
    _dotfiles_key="${_dotfiles_line%%=*}"
    _dotfiles_value="${_dotfiles_line#*=}"
    case "$_dotfiles_key" in
      CLAUDE_SETUP_DIR|DOTFILES_VAULT_PROVIDER|DOTFILES_OP_ITEM|BWS_PROJECT_ID|\
      DOTFILES_DEV|CHEESE_FLOW|VAUDEVILLE|TODOIST|SKILL_HARNESSES)
        if [[ "$_dotfiles_value" == \"*\" && "$_dotfiles_value" == *\" ]]; then
          _dotfiles_value="${_dotfiles_value[2,-2]}"
        fi
        export "$_dotfiles_key=$_dotfiles_value"
        ;;
    esac
  done < "$_dotfiles_env_file"
fi
unset _dotfiles_secret _dotfiles_env_file _dotfiles_line _dotfiles_key _dotfiles_value

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
