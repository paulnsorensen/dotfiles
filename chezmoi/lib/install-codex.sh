#!/bin/bash
# install-codex.sh — scaffold ~/.codex/ from the dotfiles codex/ source.
#
# config.toml is copied only when ~/.codex/config.toml does not exist yet, so
# user edits in $HOME survive — and `codex mcp add` (driven by
# agents/mcp/sync.sh) can mutate that same file without chezmoi clobbering its
# changes on the next sync. Re-bootstrap with `rm ~/.codex/config.toml && dots sync`.
#
# Usage:
#   install-codex.sh <source_dir>

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <source_dir>" >&2
    exit 2
fi

source_dir="$1"
codex_home="${CODEX_HOME:-$HOME/.codex}"

if [[ ! -d "$source_dir" ]]; then
    echo "install-codex.sh: source directory not found: $source_dir" >&2
    exit 1
fi

mkdir -p "$codex_home"

src_config="$source_dir/config.toml"
dst_config="$codex_home/config.toml"

if [[ -f "$src_config" ]]; then
    if [[ ! -e "$dst_config" ]]; then
        cp "$src_config" "$dst_config"
        echo "  Scaffolded ~/.codex/config.toml"
    else
        echo "  Skipped ~/.codex/config.toml (already exists; user-owned)"
    fi
fi
