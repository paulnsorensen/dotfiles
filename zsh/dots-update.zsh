# Pull and deploy the active dotfiles clone without changing the shell directory.
dps() {
  local changes

  changes=$(git -C "$DOTFILES_DIR" status --porcelain) || return 1
  if [[ -n "$changes" ]]; then
    print -ru2 -- "Dotfiles has uncommitted changes. Commit or stash them before dps."
    print -ru2 -- "$changes"
    return 1
  fi

  git -C "$DOTFILES_DIR" pull --ff-only || return 1
  "$DOTFILES_DIR/bin/dots" sync || return 1

  changes=$(git -C "$DOTFILES_DIR" status --porcelain) || return 1
  if [[ -n "$changes" ]]; then
    print -ru2 -- "Dotfiles has uncommitted changes after sync:"
    print -ru2 -- "$changes"
    return 1
  fi
}
