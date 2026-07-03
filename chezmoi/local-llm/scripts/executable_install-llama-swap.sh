#!/usr/bin/env bash
#
# install-llama-swap.sh — install the pinned llama-swap release binary.
#
# Manual install like install-npu.sh / download-models.sh — never run by
# `dots sync`. Re-run after bumping LLAMA_SWAP_VERSION; no-op otherwise.
#
# Source-safe by design: functions are defined at top level WITHOUT enabling
# errexit, so bats can `source` this file and call the functions directly with
# faked `curl` / `tar` on PATH. `set -euo pipefail` lives inside main().

# Pinned release (https://github.com/mostlygeek/llama-swap/releases).
LLAMA_SWAP_VERSION="${LLAMA_SWAP_VERSION:-224}"
LLAMA_SWAP_BIN_DIR="${LLAMA_SWAP_BIN_DIR:-$HOME/local-llm/bin}"

# llama_swap_asset [machine] — release tarball name for this CPU architecture.
llama_swap_asset() {
    local machine="${1:-$(uname -m)}"
    case "$machine" in
        x86_64)  echo "llama-swap_${LLAMA_SWAP_VERSION}_linux_amd64.tar.gz" ;;
        aarch64) echo "llama-swap_${LLAMA_SWAP_VERSION}_linux_arm64.tar.gz" ;;
        *)       echo "Error: unsupported arch for llama-swap: $machine" >&2; return 1 ;;
    esac
}

# llama_swap_installed_version — version stamp of the installed binary ("" if absent).
llama_swap_installed_version() {
    [[ -x "$LLAMA_SWAP_BIN_DIR/llama-swap" ]] || return 0
    cat "$LLAMA_SWAP_BIN_DIR/llama-swap.version" 2>/dev/null || true
}

install_llama_swap() {
    if [[ "$(llama_swap_installed_version)" == "$LLAMA_SWAP_VERSION" ]]; then
        echo "✓ llama-swap v${LLAMA_SWAP_VERSION} already installed ($LLAMA_SWAP_BIN_DIR/llama-swap)"
        return 0
    fi

    local asset url tmp
    asset=$(llama_swap_asset) || return 1
    url="https://github.com/mostlygeek/llama-swap/releases/download/v${LLAMA_SWAP_VERSION}/${asset}"
    tmp=$(mktemp -d)

    echo "Downloading llama-swap v${LLAMA_SWAP_VERSION}…"
    if ! curl -fsSL "$url" -o "$tmp/$asset"; then
        echo "Error: download failed: $url" >&2
        rm -rf "$tmp"; return 1
    fi
    if ! tar -xzf "$tmp/$asset" -C "$tmp"; then
        echo "Error: extract failed: $tmp/$asset" >&2
        rm -rf "$tmp"; return 1
    fi
    mkdir -p "$LLAMA_SWAP_BIN_DIR"
    if ! install -m 0755 "$tmp/llama-swap" "$LLAMA_SWAP_BIN_DIR/llama-swap"; then
        echo "Error: could not install to $LLAMA_SWAP_BIN_DIR" >&2
        rm -rf "$tmp"; return 1
    fi
    echo "$LLAMA_SWAP_VERSION" > "$LLAMA_SWAP_BIN_DIR/llama-swap.version"
    rm -rf "$tmp"
    echo "✓ llama-swap v${LLAMA_SWAP_VERSION} → $LLAMA_SWAP_BIN_DIR/llama-swap"
}

main() {
    set -euo pipefail
    install_llama_swap "$@"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
