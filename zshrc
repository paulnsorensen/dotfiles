# dotfiles by @paulnsorensen (with a lot of copying from others)

# Platform detection (used by modules for OS-specific behavior)
case "$OSTYPE" in
  darwin*)  export DOTFILES_OS="macos" ;;
  linux*)   export DOTFILES_OS="linux" ;;
esac

# Source zsh configuration files in order
source "$HOME/Dev/dotfiles/zsh/core.zsh"
source "$HOME/Dev/dotfiles/zsh/colors.zsh"    # Chocolate Donut palette (must come before fzf/prompt)
source "$HOME/Dev/dotfiles/zsh/aliases.zsh"
source "$HOME/Dev/dotfiles/zsh/completion.zsh"
source "$HOME/Dev/dotfiles/zsh/fzf.zsh"
source "$HOME/Dev/dotfiles/zsh/tools.zsh"     # zoxide, atuin, yazi (after fzf — atuin takes Ctrl+R)
source "$HOME/Dev/dotfiles/zsh/zellij.zsh"    # Zellij aliases and helpers

# Prompt selection — set DOTFILES_PROMPT=starship in ~/.zshrc.local to use starship
if [[ "$DOTFILES_PROMPT" == "starship" ]] && command -v starship &>/dev/null; then
  eval "$(starship init zsh)"
else
  source "$HOME/Dev/dotfiles/zsh/prompt.zsh"
fi

source "$HOME/Dev/dotfiles/zsh/claude.zsh"

# Source local customizations if they exist
[ -f $HOME/.zshrc.local ] && source $HOME/.zshrc.local

clear
