#!/bin/bash
############################
# packages/sync.sh
# Unified package sync from flat packages.yaml
# Uses SHA-256 hash cache to skip when unchanged
############################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PACKAGES_FILE="$REPO_DIR/packages.yaml"
CACHE_DIR="${HOME}/.local/state/dotfiles"
CACHE_FILE="$CACHE_DIR/packages.hash"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[packages]${NC} $1"; }
log_success() { echo -e "${GREEN}[packages]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[packages]${NC} $1"; }

if [[ "${QUICK_SYNC:-false}" == "true" ]]; then
    log_info "Quick sync, skipping packages"
    exit 0
fi

if [[ ! -f "$PACKAGES_FILE" ]]; then
    log_warning "packages.yaml not found"
    exit 0
fi

########## Cache

check_cache() {
    if [[ "${FORCE_PACKAGES:-false}" == "true" ]]; then
        log_info "FORCE_PACKAGES set, bypassing cache"
        return 1
    fi
    [[ -f "$CACHE_FILE" ]] || return 1
    local current stored
    current=$(shasum -a 256 "$PACKAGES_FILE" | cut -d' ' -f1)
    stored=$(cat "$CACHE_FILE")
    [[ "$current" == "$stored" ]]
}

save_cache() {
    mkdir -p "$CACHE_DIR"
    shasum -a 256 "$PACKAGES_FILE" | cut -d' ' -f1 > "$CACHE_FILE"
}

if check_cache; then
    log_success "packages.yaml unchanged (cached), skipping"
    exit 0
fi

########## Query helpers

# Platform package names (brew on mac, apt on linux)
# Bare strings + maps with default source, respecting platform + dev filters
# On linux, uses .apt field for name override
# Usage: get_platform_pkgs [--dev]
get_platform_pkgs() {
    local want_dev="${1:-}"
    local skip_platform name_expr
    if [[ "$(uname)" == "Darwin" ]]; then
        skip_platform="linux"
        name_expr=".name"
    else
        skip_platform="mac"
        name_expr="(.apt // .name)"
    fi

    if [[ -z "$want_dev" ]]; then
        {
            yq -r ".packages[] | select(kind == \"scalar\")" "$PACKAGES_FILE" 2>/dev/null
            yq -r ".packages[] | select(kind == \"map\" and (.source // \"brew\") == \"brew\" and (.dev // false) == false and (.platform == \"$skip_platform\" | not)) | $name_expr" "$PACKAGES_FILE" 2>/dev/null
        }
    else
        yq -r ".packages[] | select(kind == \"map\" and (.source // \"brew\") == \"brew\" and .dev == true and (.platform == \"$skip_platform\" | not)) | $name_expr" "$PACKAGES_FILE" 2>/dev/null
    fi
}

# Explicit source names (tap, cask)
# Usage: get_source_pkgs <source> [--dev]
get_source_pkgs() {
    local source="$1" want_dev="${2:-}"
    if [[ -z "$want_dev" ]]; then
        yq -r ".packages[] | select(kind == \"map\" and .source == \"$source\" and (.dev // false) == false) | .name" "$PACKAGES_FILE" 2>/dev/null
    else
        yq -r ".packages[] | select(kind == \"map\" and .source == \"$source\" and .dev == true) | .name" "$PACKAGES_FILE" 2>/dev/null
    fi
}

########## Brew

# Install brew packages from a list, skipping already-installed ones
# Usage: brew_install_pkgs <label> <pkg_list> <installed_list> [--cask]
brew_install_pkgs() {
    local label="$1" pkg_list="$2" installed="$3" cask_flag="${4:-}"
    [[ -z "$pkg_list" ]] && return 0

    echo -e "\n${GREEN}${label}:${NC}"
    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue
        if echo "$installed" | grep -qx "$pkg"; then
            echo "  + $pkg"
        else
            echo "  Installing $pkg..."
            # shellcheck disable=SC2086  # cask_flag intentionally unquoted (empty or --cask)
            brew install $cask_flag "$pkg"
        fi
    done <<< "$pkg_list"
}

sync_brew() {
    if ! command -v brew &>/dev/null; then
        log_info "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi

    log_info "Syncing brew packages"

    # Taps first (other packages may depend on them)
    local taps
    taps=$(get_source_pkgs "tap")
    if [[ -n "$taps" ]]; then
        echo -e "\n${GREEN}Taps:${NC}"
        local tapped
        tapped=$(brew tap)
        while IFS= read -r tap; do
            [[ -z "$tap" ]] && continue
            if echo "$tapped" | grep -qx "$tap"; then
                echo "  + $tap"
            else
                echo "  Installing tap $tap..."
                brew tap "$tap"
            fi
        done <<< "$taps"
    fi

    local installed_formulae installed_casks
    installed_formulae=$(brew list --formulae 2>/dev/null || true)
    installed_casks=$(brew list --cask 2>/dev/null || true)

    brew_install_pkgs "Formulae" "$(get_platform_pkgs)" "$installed_formulae"
    brew_install_pkgs "Casks" "$(get_source_pkgs "cask")" "$installed_casks" --cask

    if [[ "${DOTFILES_DEV:-false}" == "true" ]]; then
        brew_install_pkgs "Dev formulae" "$(get_platform_pkgs "--dev")" "$installed_formulae"
        brew_install_pkgs "Dev casks" "$(get_source_pkgs "cask" "--dev")" "$installed_casks" --cask
    fi

    log_success "Brew sync complete"
}

########## Cargo

sync_cargo() {
    local cargo_pkgs
    cargo_pkgs=$(yq -r '.packages[] | select(kind == "map" and .source == "cargo") | [.name, (.git // "")] | @tsv' "$PACKAGES_FILE" 2>/dev/null)
    [[ -z "$cargo_pkgs" ]] && return 0

    if ! command -v cargo &>/dev/null; then
        log_warning "cargo not found, skipping cargo packages"
        return 0
    fi

    log_info "Syncing cargo packages"
    local installed
    installed=$(cargo install --list 2>/dev/null | grep -E '^\S' | cut -d' ' -f1 || true)

    while IFS=$'\t' read -r name git_url; do
        [[ -z "$name" ]] && continue
        if echo "$installed" | grep -qx "$name"; then
            echo "  + $name"
        elif [[ -n "$git_url" ]]; then
            echo "  Installing $name from $git_url..."
            cargo install --git "$git_url" "$name"
        else
            echo "  Installing $name..."
            cargo install "$name"
        fi
    done <<< "$cargo_pkgs"

    log_success "Cargo sync complete"
}

########## APT

apt_check_pkg() {
    local pkg="$1" missing_ref="$2"
    if [[ "$pkg" == "yq" ]]; then
        if command -v yq &>/dev/null; then
            echo "  + $pkg"
        else
            echo "  $pkg (snap — install with: sudo snap install yq)"
        fi
        return
    fi
    if dpkg -s "$pkg" &>/dev/null; then
        echo "  + $pkg"
    else
        echo "  - $pkg (missing)"
        eval "$missing_ref+=(\"\$pkg\")"
    fi
}

sync_apt() {
    command -v apt-get &>/dev/null || return 0

    log_info "Checking apt packages"
    local missing=()

    echo -e "\n${GREEN}Packages:${NC}"
    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue
        apt_check_pkg "$pkg" missing
    done <<< "$(get_platform_pkgs)"

    if [[ "${DOTFILES_DEV:-false}" == "true" ]]; then
        echo -e "\n${GREEN}Dev packages:${NC}"
        while IFS= read -r pkg; do
            [[ -z "$pkg" ]] && continue
            apt_check_pkg "$pkg" missing
        done <<< "$(get_platform_pkgs "--dev")"
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo ""
        log_warning "Missing packages: ${missing[*]}"
        echo "  sudo apt-get install -y ${missing[*]}"
    fi
}

########## Main

# Bootstrap yq if needed (macOS only)
if [[ "$(uname)" == "Darwin" ]] && ! command -v yq &>/dev/null; then
    if command -v brew &>/dev/null; then
        log_info "Bootstrapping yq..."
        brew install yq
    else
        log_warning "yq not found and brew not available"
        exit 1
    fi
fi

if [[ "$(uname)" == "Darwin" ]]; then
    sync_brew
elif [[ "$(uname)" == "Linux" ]]; then
    sync_apt
fi

sync_cargo

save_cache
log_success "Package sync complete"
