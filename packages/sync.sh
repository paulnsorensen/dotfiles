#!/bin/bash
############################
# packages/sync.sh
# Unified package sync from flat packages.yaml
# Uses SHA-256 hash cache to skip when unchanged
############################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PACKAGES_FILE="${PACKAGES_FILE:-$REPO_DIR/packages.yaml}"
CACHE_DIR="${CACHE_DIR:-${HOME}/.local/state/dotfiles}"
CACHE_FILE="${CACHE_FILE:-$CACHE_DIR/packages.hash}"
PLATFORM="$(uname)"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

FAILED=()

log_info()    { echo -e "${BLUE}[packages]${NC} $1"; }
log_success() { echo -e "${GREEN}[packages]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[packages]${NC} $1" >&2; }
log_error()   { echo -e "${RED}[packages]${NC} $1" >&2; }

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
    stored=$(<"$CACHE_FILE")
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
# Entry format: bare string OR single-key map (key = name, value = overrides)
# Map queries use: to_entries[0] | .key = name, .value.* = properties

# Platform package names (brew on mac, apt on linux)
# Usage: get_platform_pkgs [--dev]
get_platform_pkgs() {
    local want_dev="${1:-}"
    local skip_platform name_expr
    if [[ "$PLATFORM" == "Darwin" ]]; then
        skip_platform="linux"
        name_expr=".key"
    else
        skip_platform="mac"
        name_expr="(.value.apt // .key)"
    fi

    if [[ -z "$want_dev" ]]; then
        {
            yq -r ".packages[] | select(kind == \"scalar\")" "$PACKAGES_FILE" 2>/dev/null
            yq -r ".packages[] | select(kind == \"map\") | to_entries[0] | select((.value.source // \"brew\") == \"brew\" and (.value.dev // false) == false and (.value.platform == \"$skip_platform\" | not)) | $name_expr" "$PACKAGES_FILE" 2>/dev/null
        }
    else
        yq -r ".packages[] | select(kind == \"map\") | to_entries[0] | select((.value.source // \"brew\") == \"brew\" and .value.dev == true and (.value.platform == \"$skip_platform\" | not)) | $name_expr" "$PACKAGES_FILE" 2>/dev/null
    fi
}

# Explicit source names (tap, cask)
# Usage: get_source_pkgs <source> [--dev]
get_source_pkgs() {
    local source="$1" want_dev="${2:-}"
    if [[ -z "$want_dev" ]]; then
        yq -r ".packages[] | select(kind == \"map\") | to_entries[0] | select(.value.source == \"$source\" and (.value.dev // false) == false) | .key" "$PACKAGES_FILE" 2>/dev/null
    else
        yq -r ".packages[] | select(kind == \"map\") | to_entries[0] | select(.value.source == \"$source\" and .value.dev == true) | .key" "$PACKAGES_FILE" 2>/dev/null
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
            # shellcheck disable=SC2086  # cask_flag intentionally unquoted
            if ! brew install $cask_flag "$pkg" </dev/null; then
                log_error "Failed to install $pkg"
                FAILED+=("$pkg")
            fi
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
                if ! brew tap "$tap" </dev/null; then
                    log_error "Failed to tap $tap"
                    FAILED+=("tap:$tap")
                fi
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
    cargo_pkgs=$(yq -r '.packages[] | select(kind == "map") | to_entries[0] | select(.value.source == "cargo") | [.key, (.value.git // "")] | @tsv' "$PACKAGES_FILE" 2>/dev/null)
    [[ -z "$cargo_pkgs" ]] && return 0

    if ! command -v cargo &>/dev/null; then
        # Bootstrap toolchain if rustup is installed but no toolchain yet
        if command -v rustup &>/dev/null; then
            log_info "Bootstrapping Rust stable toolchain..."
            if ! rustup default stable; then
                log_error "Failed to bootstrap Rust toolchain"
                FAILED+=("rustup-bootstrap")
                return 0
            fi
            # Brew-installed rustup keeps cargo proxies in opt/rustup/bin
            local rustup_bin
            rustup_bin="$(brew --prefix rustup 2>/dev/null)/bin"
            if [[ -d "$rustup_bin" ]]; then
                export PATH="$rustup_bin:$PATH"
            elif [[ -f "$HOME/.cargo/env" ]]; then
                # shellcheck disable=SC1091
                source "$HOME/.cargo/env"
            fi
        fi
        if ! command -v cargo &>/dev/null; then
            log_error "cargo not found (install rustup first)"
            FAILED+=("cargo")
            return 0
        fi
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
            if ! cargo install --git "$git_url" "$name" </dev/null; then
                log_error "Failed to install $name"
                FAILED+=("$name")
            fi
        else
            echo "  Installing $name..."
            if ! cargo install "$name" </dev/null; then
                log_error "Failed to install $name"
                FAILED+=("$name")
            fi
        fi
    done <<< "$cargo_pkgs"

    log_success "Cargo sync complete"
}

########## NPM

sync_npm() {
    local npm_pkgs
    npm_pkgs=$(yq -r '.packages[] | select(kind == "map") | to_entries[0] | select(.value.source == "npm") | [.key, (.value.pkg // .key)] | @tsv' "$PACKAGES_FILE" 2>/dev/null)
    [[ -z "$npm_pkgs" ]] && return 0

    if ! command -v npm &>/dev/null; then
        log_error "npm not found (install node first)"
        FAILED+=("npm")
        return 0
    fi

    log_info "Syncing npm packages"
    local installed
    installed=$(npm ls -g --json 2>/dev/null | jq -r '.dependencies // {} | keys[]' || true)

    while IFS=$'\t' read -r name pkg; do
        [[ -z "$name" ]] && continue
        if echo "$installed" | grep -qx "$pkg"; then
            echo "  + $name"
        else
            echo "  Installing $pkg..."
            if ! npm install -g "$pkg" </dev/null; then
                log_error "Failed to install $pkg"
                FAILED+=("$pkg")
            fi
        fi
    done <<< "$npm_pkgs"

    log_success "NPM sync complete"
}

########## APT

apt_check_pkg() {
    local pkg="$1"
    # shellcheck disable=SC2178  # nameref to caller's array
    local -n _missing="$2"
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
        _missing+=("$pkg")
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
if [[ "$PLATFORM" == "Darwin" ]] && ! command -v yq &>/dev/null; then
    if command -v brew &>/dev/null; then
        log_info "Bootstrapping yq..."
        brew install yq
    else
        log_warning "yq not found and brew not available"
        exit 1
    fi
fi

if [[ "$PLATFORM" == "Darwin" ]]; then
    sync_brew
elif [[ "$PLATFORM" == "Linux" ]]; then
    sync_apt
fi

sync_cargo
sync_npm

if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo ""
    log_error "Failed to install ${#FAILED[@]} package(s): ${FAILED[*]}"
    exit 1
fi

save_cache
log_success "Package sync complete"
