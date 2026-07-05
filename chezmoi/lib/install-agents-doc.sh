#!/bin/bash
# install-agents-doc.sh — copy a single agents-doc source file to one or more
# harness-specific target paths.
#
# Coding agents look for their global instructions at different filenames
# (Claude wants ~/.claude/CLAUDE.md, Codex wants ~/.codex/AGENTS.md). This
# installer copies one source to every target, replacing pre-existing symlinks
# (the legacy claude/.sync layout used to symlink them).
#
# Usage:
#   install-agents-doc.sh <source_file> <target_file> [<target_file>...]

set -euo pipefail

if (( $# < 2 )); then
    echo "Usage: $0 <source_file> <target_file> [<target_file>...]" >&2
    exit 2
fi

source_file="$1"; shift

if [[ ! -f "$source_file" ]]; then
    echo "install-agents-doc.sh: source not found: $source_file" >&2
    exit 1
fi

for target in "$@"; do
    mkdir -p "$(dirname "$target")"
    # Replace legacy symlink, if present, with a real copy.
    if [[ -L "$target" ]]; then
        rm -- "$target"
    fi
    cp -f "$source_file" "$target"
    echo "  Copied $(basename "$source_file") -> $target"
done
