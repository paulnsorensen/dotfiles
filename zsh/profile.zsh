# profile.zsh - Login shell environment

path_prepend() {
  local dir="$1"

  [[ -d "$dir" ]] || return 0
  path=("${(@)path:#$dir}")
  path=("$dir" $path)
}

export DOTFILES_DIR="${DOTFILES_DIR:-$HOME/Dev/dotfiles}"
export DEV_DIR="${DEV_DIR:-$HOME/Dev}"
export PREK_HOME="${PREK_HOME:-$HOME/Dev/.prek}"

case "$OSTYPE" in
  darwin*) export DOTFILES_OS="macos" ;;
  linux*) export DOTFILES_OS="linux" ;;
esac

if [[ "$DOTFILES_OS" == "macos" ]]; then
  path_prepend "/opt/homebrew/bin"
  _brew_prefix="$(brew --prefix 2>/dev/null)"
  path_prepend "${_brew_prefix}/opt/openssl/bin"
  path_prepend "${_brew_prefix}/opt/rustup/bin"
  unset _brew_prefix
fi

# Start with dotfiles/bin first; pyenv init below may reorder PATH.
path_prepend "$DOTFILES_DIR/bin"
path_prepend "$HOME/.local/bin"
path_prepend "$HOME/.cargo/bin"

export EDITOR="${EDITOR:-$(command -v vim)}"
export VISUAL="${VISUAL:-$EDITOR}"
export PAGER="${PAGER:-less}"
export LESS="${LESS:--i -M -R}"

if command -v pyenv 1>/dev/null 2>&1; then
  eval "$(pyenv init -)"
  # pyenv prepends its shims; move dotfiles/bin back to the front.
  path_prepend "$DOTFILES_DIR/bin"
fi

if [[ -f "$DOTFILES_DIR/.env" ]]; then
  while IFS='=' read -r key val; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    export "$key=$val"
  done < "$DOTFILES_DIR/.env"
fi
export DOTFILES_PROFILE_LOADED=1
