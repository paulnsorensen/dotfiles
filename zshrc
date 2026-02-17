# dotfiles by @paulnsorensen (with a lot of copying from others)

# Platform detection (used by modules for OS-specific behavior)
case "$OSTYPE" in
  darwin*)  export DOTFILES_OS="macos" ;;
  linux*)   export DOTFILES_OS="linux" ;;
esac

# Source zsh configuration files in order
source "$HOME/Dev/dotfiles/zsh/core.zsh"
source "$HOME/Dev/dotfiles/zsh/colors.zsh"    # Deuterawarm palette (must come before fzf/prompt)
source "$HOME/Dev/dotfiles/zsh/aliases.zsh"
source "$HOME/Dev/dotfiles/zsh/completion.zsh"
source "$HOME/Dev/dotfiles/zsh/fzf.zsh"
source "$HOME/Dev/dotfiles/zsh/prompt.zsh"
source "$HOME/Dev/dotfiles/zsh/claude.zsh"

# Source local customizations if they exist
[ -f $HOME/.zshrc.local ] && source $HOME/.zshrc.local

clear

[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh
export PATH="$HOME/.local/bin:$PATH"
