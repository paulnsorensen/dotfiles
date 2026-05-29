#!/bin/bash
# packages/lib-bootstrap-yq.sh
# Shared yq bootstrapper: ensure yq (mikefarah v4) is on PATH before any
# yq-driven registry parsing. Sourced by both packages/sync.sh (steady-state
# sync) and packages/bootstrap-linux.sh (fresh-box one-shot), so both paths
# can run from a machine where yq isn't yet installed.
#
# macOS: brew install yq.
# Linux: download the static binary to $YQ_INSTALL_DIR (default ~/.local/bin)
#        — no sudo (yq is a snap on apt, which we can't assume is available
#        non-interactively).
#
# Callers must provide log_info / log_warning. PLATFORM (Darwin|Linux) is
# read from the parent env; if unset, falls back to `uname`.

bootstrap_yq() {
    command -v yq &>/dev/null && return 0

    local platform="${PLATFORM:-$(uname)}"

    if [[ "$platform" == "Darwin" ]]; then
        if command -v brew &>/dev/null; then
            log_info "Bootstrapping yq..."
            brew install yq
        else
            log_warning "yq not found and brew not available"
            return 1
        fi
    elif [[ "$platform" == "Linux" ]]; then
        local arch yq_arch dest
        arch="$(uname -m)"
        case "$arch" in
            x86_64) yq_arch="amd64" ;;
            aarch64|arm64) yq_arch="arm64" ;;
            *) log_warning "yq not found and no prebuilt binary for arch $arch"; return 1 ;;
        esac
        dest="${YQ_INSTALL_DIR:-$HOME/.local/bin}"
        log_info "Bootstrapping yq (downloading yq_linux_${yq_arch})..."
        mkdir -p "$dest"
        if curl -fsSL -o "$dest/yq" "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${yq_arch}"; then
            chmod +x "$dest/yq"
            export PATH="$dest:$PATH"
        else
            log_warning "Failed to download yq"
            return 1
        fi
    fi
}
