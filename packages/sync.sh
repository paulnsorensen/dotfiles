#!/bin/bash
############################
# packages/sync.sh
# Unified package sync — brew, cargo, apt
# Reads from packages.yaml, uses hash cache to skip when unchanged
############################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PACKAGES_FILE="$REPO_DIR/packages.yaml"
CACHE_DIR="${HOME}/.local/state/dotfiles"
CACHE_FILE="$CACHE_DIR/packages.hash"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[packages]${NC} $1"; }
log_success() { echo -e "${GREEN}[packages]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[packages]${NC} $1"; }

########## Cache layer

check_cache() {
    if [[ "${FORCE_PACKAGES:-false}" == "true" ]]; then
        log_info "FORCE_PACKAGES set, skipping cache"
        return 1
    fi

    if [[ ! -f "$CACHE_FILE" ]]; then
        return 1
    fi

    local current_hash stored_hash
    current_hash=$(shasum -a 256 "$PACKAGES_FILE" | cut -d' ' -f1)
    stored_hash=$(cat "$CACHE_FILE")

    if [[ "$current_hash" == "$stored_hash" ]]; then
        return 0
    fi
    return 1
}

save_cache() {
    mkdir -p "$CACHE_DIR"
    shasum -a 256 "$PACKAGES_FILE" | cut -d' ' -f1 > "$CACHE_FILE"
}

########## Brew

sync_brew_taps() {
    local tapped
    tapped=$(brew tap)

    for tap in $(yq -r '.brew.taps[]' "$PACKAGES_FILE" 2>/dev/null); do
        if echo "$tapped" | grep -q "^${tap}$"; then
            echo "  + $tap (tapped)"
        else
            echo "  Installing tap $tap..."
            brew tap "$tap"
        fi
    done
}

# Batch-check a section of brew formulae
# Usage: sync_brew_section <yq_path> <label> [--cask]
sync_brew_section() {
    local yq_path="$1" label="$2" cask_flag="${3:-}"
    local list_flag="--formulae"
    local install_flag=""

    if [[ "$cask_flag" == "--cask" ]]; then
        list_flag="--cask"
        install_flag="--cask"
    fi

    # Check if section exists
    if ! yq -e "$yq_path" "$PACKAGES_FILE" > /dev/null 2>&1; then
        return 0
    fi

    echo -e "\n${GREEN}${label}:${NC}"

    # One call to get all installed packages
    local installed
    installed=$(brew list $list_flag 2>/dev/null || true)

    for package in $(yq -r "${yq_path}[]" "$PACKAGES_FILE" 2>/dev/null); do
        if echo "$installed" | grep -qx "$package"; then
            echo "  + $package"
        else
            echo "  Installing $package..."
            brew install $install_flag "$package"
        fi
    done
}

sync_brew() {
    if ! command -v brew &>/dev/null; then
        log_info "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi

    log_info "Syncing brew packages"

    # Taps
    if yq -e '.brew.taps' "$PACKAGES_FILE" > /dev/null 2>&1; then
        echo -e "\n${GREEN}Taps:${NC}"
        sync_brew_taps
    fi

    # Core formulae
    sync_brew_section '.brew.formulae' 'Core formulae'

    # Core casks
    sync_brew_section '.brew.casks' 'Casks' --cask

    # Dev packages (only when DOTFILES_DEV=true)
    if [[ "${DOTFILES_DEV:-false}" == "true" ]]; then
        sync_brew_section '.brew.dev_formulae' 'Dev formulae'
        sync_brew_section '.brew.dev_casks' 'Dev casks' --cask
    fi

    log_success "Brew sync complete"
}

########## Cargo

sync_cargo() {
    if ! yq -e '.cargo' "$PACKAGES_FILE" > /dev/null 2>&1; then
        return 0
    fi

    if ! command -v cargo &>/dev/null; then
        log_warning "cargo not found, skipping cargo packages"
        return 0
    fi

    log_info "Syncing cargo packages"

    local installed
    installed=$(cargo install --list 2>/dev/null | grep -E '^\S' | cut -d' ' -f1 || true)

    local count
    count=$(yq -r '.cargo | length' "$PACKAGES_FILE")

    for i in $(seq 0 $((count - 1))); do
        local name git_url
        name=$(yq -r ".cargo[$i].name" "$PACKAGES_FILE")
        git_url=$(yq -r ".cargo[$i].git // \"\"" "$PACKAGES_FILE")

        if echo "$installed" | grep -qx "$name"; then
            echo "  + $name"
        else
            if [[ -n "$git_url" ]]; then
                echo "  Installing $name from $git_url..."
                cargo install --git "$git_url"
            else
                echo "  Installing $name..."
                cargo install "$name"
            fi
        fi
    done

    log_success "Cargo sync complete"
}

########## APT

sync_apt() {
    if ! command -v apt-get &>/dev/null; then
        return 0
    fi

    log_info "Checking apt packages"

    # yq fallback for bootstrapping
    parse_apt_list() {
        local key="$1"
        if command -v yq &>/dev/null; then
            yq -r ".apt.${key}[]" "$PACKAGES_FILE" 2>/dev/null
        else
            sed -n "/^  ${key}:/,/^  [^ #]/p" "$PACKAGES_FILE" | grep '^ *-' | sed 's/^ *- *//; s/ *#.*//'
        fi
    }

    local missing=()

    echo -e "\n${GREEN}Core packages:${NC}"
    for package in $(parse_apt_list "packages"); do
        if [[ "$package" == "yq" ]]; then
            if command -v yq &>/dev/null; then
                echo "  + $package"
            else
                echo "  * $package (snap — install with: sudo snap install yq)"
            fi
            continue
        fi
        if dpkg -s "$package" &>/dev/null 2>&1; then
            echo "  + $package"
        else
            echo "  * $package (missing)"
            missing+=("$package")
        fi
    done

    if [[ "${DOTFILES_DEV:-false}" == "true" ]]; then
        echo -e "\n${GREEN}Dev packages:${NC}"
        for package in $(parse_apt_list "dev_packages"); do
            if dpkg -s "$package" &>/dev/null 2>&1; then
                echo "  + $package"
            else
                echo "  * $package (missing)"
                missing+=("$package")
            fi
        done
    fi

    if [[ ${#missing[@]} -eq 0 ]]; then
        log_success "All apt packages installed"
    else
        log_warning "Missing packages: ${missing[*]}"
        echo -e "  Run: sudo apt-get install -y ${missing[*]}"
    fi
}

########## Main

main() {
    if [[ "${QUICK_SYNC:-false}" == "true" ]]; then
        log_info "Quick sync, skipping packages"
        exit 0
    fi

    if [[ ! -f "$PACKAGES_FILE" ]]; then
        log_warning "packages.yaml not found at $PACKAGES_FILE"
        exit 0
    fi

    # Cache check
    if check_cache; then
        log_success "packages.yaml unchanged, skipping (use FORCE_PACKAGES=true to override)"
        exit 0
    fi

    # Dispatch by platform
    if [[ "$(uname)" == "Darwin" ]]; then
        sync_brew
    elif [[ "$(uname)" == "Linux" ]]; then
        sync_apt
    fi

    # Cargo runs on all platforms
    sync_cargo

    # Save cache on success
    save_cache
    log_success "Package sync complete"
}

main "$@"
