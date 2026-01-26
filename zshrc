# dotfiles by @paulnsorensen (with a lot of copying from others)

# Source simplified zsh configuration
# core.zsh handles all environment setup

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
