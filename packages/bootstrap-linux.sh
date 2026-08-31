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
#   4. install_brew_packages   — brew remainder derived from packages.yaml
#   5. hand off to packages/sync.sh for exact mise/custom-registry convergence.
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
# brew-sourced, non-dev, and not mac-only. Uses .key (the brew formula name).
get_bootstrap_brew_pkgs() {
    yq -r '.packages[] | select(kind == "scalar")' "$PACKAGES_FILE"
    yq -r '.packages[] | select(kind == "map") | to_entries[0] | select((.value.source // "brew") == "brew" and (.value.dev // false) == false and (.value.platform // "") != "mac") | .key' "$PACKAGES_FILE"
}

# Homebrew taps (source: tap). Harmless to tap all on Linux even when a tap
# only provides mac-only formulae.
get_bootstrap_taps() {
    yq -r '.packages[] | select(kind == "map") | to_entries[0] | select(.value.source == "tap") | .key' "$PACKAGES_FILE"
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
    local vault_policy_status
    if [[ "$PLATFORM" != "Linux" ]]; then
        log_error "bootstrap-linux.sh is Linux-only (use 'dots sync' on macOS)."
        return 1
    fi
    # yq up front — the registry queries below all need Mike Farah's Go yq,
    # which isn't in Ubuntu's apt. Reuses sync.sh's bootstrap_yq_linux.
    command -v yq &>/dev/null && yq_is_mikefarah || bootstrap_yq_linux || return 1
    # bootstrap_yq_linux drops yq in ~/.local/bin, which isn't on a fresh box's
    # PATH; extend it before any registry query (mirrors bin/linux-install).
    export PATH="$HOME/.local/bin:$PATH"
    if ! command -v yq &>/dev/null; then
        log_error "yq unavailable after bootstrap — registry queries would return empty; aborting."
        return 1
    fi

    # Homebrew's build toolchain first (sudo prompt lands up front), then brew
    # and the remaining formula set. packages/sync.sh installs the exact mise
    # toolchain before processing pinned custom-registry packages.
    bootstrap_brew_deps_linux
    bootstrap_brew || return 1
    install_brew_packages

    # Keep the direct bootstrap path aligned with .sync's provider-aware cargo
    # gate before handing the registry to packages/sync.sh.
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/../bin/lib/vault.sh" || {
        log_error "vault policy unavailable; refusing package convergence"
        return 1
    }
    if vault_disables_bitwarden_install; then
        BITWARDEN_DISABLED=true
    else
        vault_policy_status=$?
        if [[ "$vault_policy_status" -eq 1 ]]; then
            BITWARDEN_DISABLED=false
        else
            log_error "invalid vault provider policy; refusing package convergence"
            return "$vault_policy_status"
        fi
    fi
    export BITWARDEN_DISABLED

    # FORCE_PACKAGES bypasses the cache on the fresh box.
    log_info "Handing off to packages/sync.sh for manifest convergence..."
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
