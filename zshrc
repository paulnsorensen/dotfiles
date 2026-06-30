# dotfiles by @paulnsorensen (with a lot of copying from others)

# Platform detection (used by modules for OS-specific behavior)
case "$OSTYPE" in
  darwin*)  export DOTFILES_OS="macos" ;;
  linux*)   export DOTFILES_OS="linux" ;;
esac

# Source zsh configuration files in order
export DOTFILES_DIR="${${(%):-%N}:A:h}"
source "$DOTFILES_DIR/zsh/core.zsh"
source "$DOTFILES_DIR/zsh/colors.zsh"    # Chocolate Donut palette (must come before fzf/prompt)
source "$DOTFILES_DIR/zsh/aliases.zsh"
source "$DOTFILES_DIR/zsh/completion.zsh"
source "$DOTFILES_DIR/zsh/fzf.zsh"
source "$DOTFILES_DIR/zsh/tools.zsh"     # zoxide, atuin, yazi (after fzf — atuin takes Ctrl+R)
source "$DOTFILES_DIR/zsh/tmux.zsh"      # sesh shell-prompt session picker (Alt-s)

# Source local customizations early
[ -f $HOME/.zshrc.local ] && source $HOME/.zshrc.local

source "$DOTFILES_DIR/zsh/prompt.zsh"

source "$DOTFILES_DIR/zsh/claude.zsh"
source "$DOTFILES_DIR/zsh/skhd.zsh"

clear

# opencode
[ -d "$HOME/.opencode/bin" ] && export PATH="$HOME/.opencode/bin:$PATH"

# local-llm stack aliases (opt-in; absent on machines without the stack)
[ -f "$HOME/local-llm/scripts/aliases.sh" ] && source "$HOME/local-llm/scripts/aliases.sh"
