#!/bin/bash
############################
# packages/bootstrap-linux.sh
# One-shot Linux provisioner: brings a fresh box up to parity with the
# packages.yaml registry, preferring Homebrew over apt.
#
# Flow:
#   1. bootstrap_yq_linux      — Mike Farah yq (registry queries need it)
#   2. bootstrap_brew_deps_linux — system C toolchain Homebrew builds against
#   3. bootstrap_brew          — Homebrew (the one sudo step; print-and-pause)
#   4. bootstrap_rustup        — Rust toolchain via rustup.rs (no sudo)
#   5. install_brew_packages   — taps + brew formulae derived from packages.yaml
#   6. hand off to packages/sync.sh for cargo/npm/uv/gh, which already work
#      identically on Linux once the toolchains exist.
#
# Steps 1-2 and the linuxbrew PATH sourcing reuse packages/sync.sh's helpers
# (packages/lib-linux-bootstrap.sh) rather than duplicating them.
#
# Steady-state `dots sync` is unchanged. This is a deliberate one-shot — run it
# once on a new machine via `dots bootstrap`.
############################

set -uo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE%/*}" && pwd)"
PACKAGES_FILE="${PACKAGES_FILE:-$SCRIPT_DIR/packages.yaml}"
PLATFORM="$(uname)"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

FAILED=()

log_info()    { echo -e "${BLUE}[bootstrap]${NC} $1"; }
log_success() { echo -e "${GREEN}[bootstrap]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[bootstrap]${NC} $1" >&2; }
log_error()   { echo -e "${RED}[bootstrap]${NC} $1" >&2; }

# Shared Linux helpers: bootstrap_brew_deps_linux, linuxbrew_shellenv,
# bootstrap_yq_linux. They rely on the log_*, PLATFORM, and FAILED defined
# above being in scope.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib-linux-bootstrap.sh"

########## Registry queries (brew names — distinct from sync.sh's apt names)

# Brew formulae for Linux: bare scalars (default source brew) + maps that are
# brew-sourced, non-dev, not mac-only, and NOT carrying an apt_install command
# (those entries opt out of brew on Linux — e.g. tailscale, which uses its own
# apt source so the install goes through systemd. See packages.yaml).
# Uses .key (the brew formula name).
get_bootstrap_brew_pkgs() {
    yq -r '.packages[] | select(kind == "scalar")' "$PACKAGES_FILE" 2>/dev/null
    yq -r '.packages[] | select(kind == "map") | to_entries[0] | select((.value.source // "brew") == "brew" and (.value.dev // false) == false and (.value.platform // "") != "mac" and (.value.apt_install // null) == null) | .key' "$PACKAGES_FILE" 2>/dev/null
}

# Homebrew taps (source: tap). Harmless to tap all on Linux even when a tap
# only provides mac-only formulae (e.g. koekeishiya/formulae → skhd).
get_bootstrap_taps() {
    yq -r '.packages[] | select(kind == "map") | to_entries[0] | select(.value.source == "tap") | .key' "$PACKAGES_FILE" 2>/dev/null
}

########## Bootstrap steps

# Homebrew. The installer needs sudo (creates /home/linuxbrew), which this
# process can't assume — so print the command and pause for the user to run it
# in a shell with sudo, then continue once brew is on PATH.
bootstrap_brew() {
    if command -v brew &>/dev/null; then
        log_info "Homebrew already installed"
        return 0
    fi
    # An installed-but-unsourced linuxbrew isn't on PATH until shellenv runs.
    linuxbrew_shellenv
    if command -v brew &>/dev/null; then
        log_info "Homebrew found and sourced onto PATH"
        return 0
    fi

    log_warning "Homebrew is not installed. Its installer needs sudo (creates /home/linuxbrew)."
    echo
    echo "  Run this in a shell with sudo access:" >&2
    echo >&2
    # shellcheck disable=SC2016  # literal command for the user to run — must not expand
    echo '    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' >&2
    echo >&2

    if [[ ! -t 0 ]]; then
        log_error "No TTY to pause on. Install Homebrew with the command above, then re-run 'dots bootstrap'."
        return 1
    fi
    read -r -p "Press Enter once Homebrew is installed (or Ctrl-C to abort)... " _

    linuxbrew_shellenv
    if ! command -v brew &>/dev/null; then
        log_error "brew still not on PATH — aborting."
        return 1
    fi
    log_success "Homebrew ready"
}

# Rust toolchain via rustup (no sudo; installs to ~/.rustup + ~/.cargo).
bootstrap_rustup() {
    if command -v cargo &>/dev/null; then
        log_info "Rust toolchain already present"
        return 0
    fi
    log_info "Installing Rust toolchain via rustup (no sudo)..."
    if ! curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y; then
        log_error "rustup install failed"
        return 1
    fi
    # shellcheck disable=SC1091
    [[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
    if ! command -v cargo &>/dev/null; then
        log_error "cargo still not found after rustup"
        return 1
    fi
    log_success "Rust toolchain ready"
}

install_brew_packages() {
    local taps formulae
    taps="$(get_bootstrap_taps)"
    formulae="$(get_bootstrap_brew_pkgs)"

    if [[ -n "$taps" ]]; then
        log_info "Tapping Homebrew taps..."
        while IFS= read -r tap; do
            [[ -z "$tap" ]] && continue
            brew tap "$tap" </dev/null || FAILED+=("tap:$tap")
        done <<< "$taps"
    fi

    if [[ -n "$formulae" ]]; then
        log_info "Installing brew formulae (already-installed are skipped)..."
        # One invocation: brew installs what it can and skips satisfied formulae.
        # Record the failure so the bootstrap exits non-zero and the final
        # summary lists it — silently logging a warning let "Bootstrap complete"
        # print after formulae had failed.
        # shellcheck disable=SC2086  # intentional word-splitting of the list
        if ! brew install $formulae </dev/null; then
            log_error "one or more brew formulae failed (see above)"
            FAILED+=("brew-install")
        fi
    fi
}

########## Main

main() {
    if [[ "$PLATFORM" != "Linux" ]]; then
        log_error "bootstrap-linux.sh is Linux-only (use 'dots sync' on macOS)."
        return 1
    fi
    # yq up front — the registry queries below all need Mike Farah's Go yq,
    # which isn't in Ubuntu's apt. Reuses sync.sh's bootstrap_yq_linux.
    command -v yq &>/dev/null || bootstrap_yq_linux || return 1

    # Homebrew's build toolchain first (sudo prompt lands up front), then brew,
    # rustup, and the derived formula set.
    bootstrap_brew_deps_linux
    bootstrap_brew   || return 1
    bootstrap_rustup || return 1
    install_brew_packages

    # Hand cargo/npm/uv/gh to the existing sync (works identically on Linux).
    # FORCE_PACKAGES bypasses the hash cache so the sync runs on the fresh box.
    log_info "Handing off to packages/sync.sh for cargo/npm/uv/gh..."
    FORCE_PACKAGES=true bash "$SCRIPT_DIR/sync.sh" || FAILED+=("sync.sh")

    if ((${#FAILED[@]})); then
        echo
        log_error "bootstrap finished with failures: ${FAILED[*]}"
        return 1
    fi
    log_success "Bootstrap complete — restart your shell (zrl) to pick up brew on PATH."
}

# Only run when executed directly, so tests can source the functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
