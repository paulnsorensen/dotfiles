# dotfiles by @paulnsorensen (with a lot of copying from others)

export DOTFILES_DIR="${DOTFILES_DIR:-$HOME/Dev/dotfiles}"
export DEV_DIR="${DEV_DIR:-$HOME/Dev}"

if [[ -z "${DOTFILES_OS:-}" ]]; then
  case "$OSTYPE" in
    darwin*) export DOTFILES_OS="macos" ;;
    linux*) export DOTFILES_OS="linux" ;;
  esac
fi

# Source zsh configuration files in order
source "$DOTFILES_DIR/zsh/core.zsh"
source "$DOTFILES_DIR/zsh/colors.zsh"    # Chocolate Donut palette (must come before fzf/prompt)
source "$DOTFILES_DIR/zsh/aliases.zsh"
source "$DOTFILES_DIR/zsh/completion.zsh"
source "$DOTFILES_DIR/zsh/fzf.zsh"
source "$DOTFILES_DIR/zsh/tools.zsh"     # zoxide, atuin, yazi (after fzf — atuin takes Ctrl+R)
source "$DOTFILES_DIR/zsh/zellij.zsh"    # Zellij aliases and helpers

# Source local customizations early (sets DOTFILES_PROMPT, etc.)
[[ -f "$HOME/.zshrc.local" ]] && source "$HOME/.zshrc.local"

# Prompt selection — set DOTFILES_PROMPT=starship in ~/.zshrc.local to use starship
if [[ "$DOTFILES_PROMPT" == "starship" ]] && command -v starship &>/dev/null; then
  eval "$(starship init zsh)"
else
  source "$DOTFILES_DIR/zsh/prompt.zsh"
fi

source "$DOTFILES_DIR/zsh/claude.zsh"

clear
