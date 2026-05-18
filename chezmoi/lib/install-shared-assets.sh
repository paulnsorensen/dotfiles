#!/bin/bash
# install-shared-assets.sh — copy a single source file to one or more
# harness-specific target paths.
#
# Mirrors chezmoi/lib/install-agents-doc.sh but with no assumptions about
# the file kind (shell script, lib, markdown bank). The first argument is
# the source; the rest are target paths. Each target replaces any
# pre-existing symlink, gets its parent dir created, and inherits the
# source file's executable bit if set.
#
# Usage:
#   install-shared-assets.sh <source_file> <target_file> [<target_file>...]

set -euo pipefail

if (( $# < 2 )); then
    echo "Usage: $0 <source_file> <target_file> [<target_file>...]" >&2
    exit 2
fi

source_file="$1"; shift

if [[ ! -f "$source_file" ]]; then
    echo "install-shared-assets.sh: source not found: $source_file" >&2
    exit 1
fi

source_is_exec=false
[[ -x "$source_file" ]] && source_is_exec=true

for target in "$@"; do
    mkdir -p "$(dirname "$target")"
    if [[ -L "$target" ]]; then
        rm -- "$target"
    fi
    cp -f "$source_file" "$target"
    if $source_is_exec; then
        chmod +x "$target"
    fi
    echo "  Copied $(basename "$source_file") -> $target"
done
