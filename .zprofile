export DOTFILES_DIR="${DOTFILES_DIR:-$HOME/Dev/dotfiles}"

source "$DOTFILES_DIR/zsh/profile.zsh"

[[ -f "$HOME/.zprofile.local" ]] && source "$HOME/.zprofile.local"
