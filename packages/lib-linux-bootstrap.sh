#!/bin/bash
############################
# packages/lib-linux-bootstrap.sh
# Linux Homebrew/yq bootstrap helpers shared by packages/sync.sh (steady-state
# sync) and packages/bootstrap-linux.sh (one-shot fresh-box provision).
#
# Contract: the sourcing script must already define log_info/log_warning/
# log_error, the $PLATFORM string (uname), and the FAILED array. Both callers
# do. These functions are behaviour-identical to their previous inline homes
# in sync.sh — extracted here so bootstrap-linux can reuse them rather than
# duplicate them.
############################

# Homebrew on Linux builds/bottles formulae with a system C toolchain plus a
# few utilities; its installer assumes they're present and fails midway
# without them. Install them up front so the sudo password prompt lands at the
# very start of the sync instead of buried inside the brew bootstrap. No-op on
# macOS and when the toolchain is already present (so no sudo prompt then).
# shellcheck disable=SC2086  # $sudo_cmd is intentionally unquoted (empty = run as root)
bootstrap_brew_deps_linux() {
    [[ "$PLATFORM" == "Linux" ]] || return 0
    if command -v gcc &>/dev/null && command -v make &>/dev/null \
        && command -v git &>/dev/null && command -v curl &>/dev/null \
        && command -v file &>/dev/null; then
        return 0
    fi

    local sudo_cmd=""
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        if command -v sudo &>/dev/null; then
            sudo_cmd="sudo"
        else
            log_warning "Homebrew build deps are missing, but not root and sudo is unavailable."
            log_warning "Install them manually: https://docs.brew.sh/Homebrew-on-Linux#requirements"
            return 0
        fi
    fi

    log_info "Installing Homebrew build dependencies (you may be prompted for your password)..."
    local ok=true
    if command -v apt-get &>/dev/null; then
        $sudo_cmd apt-get update && $sudo_cmd apt-get install -y build-essential procps curl file git || ok=false
    elif command -v dnf &>/dev/null; then
        $sudo_cmd dnf install -y @development-tools procps-ng curl file git || ok=false
    elif command -v yum &>/dev/null; then
        $sudo_cmd yum groupinstall -y 'Development Tools' && $sudo_cmd yum install -y procps-ng curl file git || ok=false
    elif command -v pacman &>/dev/null; then
        $sudo_cmd pacman -Sy --needed --noconfirm base-devel procps-ng curl file git || ok=false
    elif command -v zypper &>/dev/null; then
        $sudo_cmd zypper install -y -t pattern devel_basis && $sudo_cmd zypper install -y procps curl file git || ok=false
    else
        log_warning "No supported package manager (apt/dnf/yum/pacman/zypper) found."
        log_warning "Install Homebrew's prerequisites manually: https://docs.brew.sh/Homebrew-on-Linux#requirements"
        return 0
    fi

    if ! $ok; then
        log_error "Failed to install Homebrew build dependencies"
        FAILED+=("brew-deps")
    fi
}

# Source an already-installed linuxbrew into PATH. Linux installs to
# /home/linuxbrew/.linuxbrew (or ~/.linuxbrew) and isn't on PATH until
# `brew shellenv` runs; macOS lands in /opt/homebrew, already on PATH via
# zsh/core.zsh. Best-effort: a missing brew is not a failure here (the
# installer path handles that), so this always returns 0.
linuxbrew_shellenv() {
    [[ "$PLATFORM" == "Linux" ]] || return 0
    local brew_bin
    for brew_bin in /home/linuxbrew/.linuxbrew/bin/brew "$HOME/.linuxbrew/bin/brew"; do
        if [[ -x "$brew_bin" ]]; then
            eval "$("$brew_bin" shellenv)"
            return 0
        fi
    done
    return 0
}

# Bootstrap Mike Farah's Go yq into ~/.local/bin on Linux.
#
# Linux note: Ubuntu's apt yq is kislyuk/yq (a jq wrapper using jq syntax),
# NOT Mike Farah's Go yq that this codebase is written against. Skip apt
# and download the Go binary release into ~/.local/bin instead.
bootstrap_yq_linux() {
    local dest="$HOME/.local/bin/yq"
    local arch
    case "$(uname -m)" in
        x86_64)  arch=amd64 ;;
        aarch64) arch=arm64 ;;
        *)
            log_error "Unsupported architecture for yq bootstrap: $(uname -m)"
            return 1
            ;;
    esac
    mkdir -p "$HOME/.local/bin"
    local url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch}"
    log_info "Downloading Mike Farah yq → $dest"
    if ! curl -fsSL "$url" -o "$dest.tmp"; then
        log_error "Failed to download yq from $url"
        rm -f "$dest.tmp"
        return 1
    fi
    chmod +x "$dest.tmp"
    mv "$dest.tmp" "$dest"
    hash -r 2>/dev/null || true
}
