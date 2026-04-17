#!/bin/bash
# Shared sync helpers sourced by .sync-with-rollback.
# Logging, skip-list dispatch, per-entry sync, and bootstrap installers.
#
# Variables provided by the sourcing script: dir, olddir
# shellcheck disable=SC2154

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Directory names that are never symlinked or dispatched to.
# Documented in CLAUDE.md — keep these in sync.
SYNC_SKIP_LIST=(".git" ".local" ".worktrees" "reference" "packages" "packages.yaml" "brew" "apt")

is_skipped() {
    local name="$1"
    local skip
    for skip in "${SYNC_SKIP_LIST[@]}"; do
        [[ "$name" == "$skip" ]] && return 0
    done
    return 1
}

# Parse run_sync arguments into exported env vars
parse_sync_args() {
    export DOTFILES_DEV=false
    export QUICK_SYNC=false

    for ARG in "$@"; do
      case $ARG in
         dev)
              echo "Setting dev=true"
              export DOTFILES_DEV=true
              ;;
         q)
              echo "Setting quick_sync=true"
              export QUICK_SYNC=true
              ;;
         refresh|r)
              echo "Setting force_packages=true"
              export FORCE_PACKAGES=true
              ;;
         rollback)
              rollback "${2:-}"
              exit 0
              ;;
         list-backups)
              list_backups
              exit 0
              ;;
      esac
    done
}

# Upgrade uv-managed tools
upgrade_uv_tools() {
    command -v uv &>/dev/null || return 0
    log_info "Upgrading uv-managed tools..."
    uv tool upgrade --all 2>&1 | while read -r line; do
      log_info "  $line"
    done
}

# Symlink a single file/dir, or dispatch to its .sync script if present
sync_entry() {
    local file="$1"

    is_skipped "$file" && return 0

    # Directories with .sync scripts manage their own setup (e.g. claude/.sync
    # symlinks items INTO ~/.claude without replacing the whole directory)
    if [[ -d "$dir/$file" ]] && [[ -f "$dir/$file/.sync" ]]; then
        log_info "Running .sync for $file."
        bash "$dir/$file/.sync" || log_warning "sync for $file failed (non-fatal)"
        return 0
    fi

    if [[ -h ~/."$file" ]]; then
        log_info "Removing old link to $file"
        rm ~/."$file"
    fi
    if [[ -f ~/."$file" || -d ~/."$file" ]]; then
        log_info "Moving existing $file from ~ to $olddir"
        rm -rf "$olddir/.$file" 2>/dev/null || true
        mv ~/."$file" "$olddir"
    fi

    log_info "Creating symlink to $file in home directory."
    ln -s "$dir/$file" ~/."$file"
}

# Dispatch hidden directories that own a .sync script (e.g. .copilot/).
# Globbing skips hidden dirs by default, so we iterate them explicitly.
sync_hidden_dirs() {
    local entry name
    for entry in "$dir"/.*/; do
        [[ -d "$entry" ]] || continue
        name="$(basename "$entry")"
        [[ "$name" == "." || "$name" == ".." ]] && continue
        is_skipped "$name" && continue
        [[ -f "$entry.sync" ]] || continue

        log_info "Running .sync for $name."
        bash "$entry.sync" || log_warning "sync for $name failed (non-fatal)"
    done
}

# Install TPM (tmux plugin manager) + its plugins if not present
install_tpm() {
    command -v tmux &>/dev/null || return 0
    [[ -d "$HOME/.tmux/plugins/tpm" ]] && return 0

    log_info "Installing TPM (tmux plugin manager)..."
    git clone https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm" 2>&1 | while read -r line; do
      log_info "  $line"
    done
    log_info "Installing tmux plugins..."
    "$HOME/.tmux/plugins/tpm/bin/install_plugins" 2>&1 | while read -r line; do
      log_info "  $line"
    done
}

# Install prek pre-commit hooks (clears conflicting core.hooksPath first)
install_prek_hooks() {
    if ! command -v prek &>/dev/null; then
        log_warning "prek not installed, skipping pre-commit hooks"
        return 0
    fi

    if git config --local core.hooksPath &>/dev/null; then
      log_info "Unsetting local core.hooksPath (conflicts with prek)..."
      git config --local --unset core.hooksPath
    fi
    log_info "Installing prek pre-commit hooks..."
    prek install 2>&1 | while read -r line; do
      log_info "  $line"
    done
}
