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
source "$HOME/Dev/dotfiles/zsh/tmux.zsh"      # sesh shell-prompt session picker (Alt-s)

# Source local customizations early
[ -f $HOME/.zshrc.local ] && source $HOME/.zshrc.local

source "$HOME/Dev/dotfiles/zsh/prompt.zsh"

source "$HOME/Dev/dotfiles/zsh/claude.zsh"
source "$HOME/Dev/dotfiles/zsh/skhd.zsh"

clear

# opencode
[ -d "$HOME/.opencode/bin" ] && export PATH="$HOME/.opencode/bin:$PATH"

# local-llm stack aliases (opt-in; absent on machines without the stack)
[ -f "$HOME/local-llm/scripts/aliases.sh" ] && source "$HOME/local-llm/scripts/aliases.sh"
