#!/bin/bash
# install-local.sh — copy dotfiles-owned skills into a harness skills dir.
#
# Harness-agnostic: source is a flat tree of skill subdirs (SKILL.md per
# the agentskills.io spec); target is whatever skills dir the harness reads
# from (~/.claude/skills, etc.).
#
# Coexistence rules:
#   - Skills installed by other tools (e.g. `gh skill install`) land as real
#     directories in the target. This installer never touches a subdir it
#     didn't put there — ownership is tracked via <target>/.dotfiles-managed.
#   - Legacy per-skill symlinks at the target are migrated to real copies.
#   - Skills dropped from the dotfiles source are removed from the target on
#     the next run, but only if the manifest claims them.
#
# Bash 3.2 compatible (macOS /bin/bash).
#
# Usage:
#   install-local.sh <source_dir> <target_dir>

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <source_dir> <target_dir>" >&2
    exit 2
fi

source_dir="$1"
target_dir="$2"
manifest="$target_dir/.dotfiles-managed"

if [[ ! -d "$source_dir" ]]; then
    echo "install-local.sh: source directory not found: $source_dir" >&2
    exit 1
fi

mkdir -p "$target_dir"

old_managed=""
if [[ -f "$manifest" ]]; then
    old_managed=$(cat "$manifest")
fi

is_old_managed() {
    [[ -n "$old_managed" ]] || return 1
    printf '%s\n' "$old_managed" | grep -Fxq "$1"
}

new_names=()
for src in "$source_dir"/*/; do
    [[ -d "$src" ]] || continue
    new_names+=("$(basename "$src")")
done

is_new_managed() {
    local needle="$1" name
    for name in ${new_names[@]+"${new_names[@]}"}; do
        [[ "$name" == "$needle" ]] && return 0
    done
    return 1
}

shopt -s nullglob
for entry in "$target_dir"/*; do
    base=${entry##*/}
    [[ "$base" == ".dotfiles-managed" ]] && continue

    if [[ -L "$entry" && ! -e "$entry" ]]; then
        rm -- "$entry"
        echo "  Removed stale symlink: $base"
        continue
    fi

    if is_old_managed "$base" && ! is_new_managed "$base"; then
        rm -rf -- "$entry"
        echo "  Removed (dropped from dotfiles): $base"
    fi
done
shopt -u nullglob

for name in ${new_names[@]+"${new_names[@]}"}; do
    src="$source_dir/$name"
    dst="$target_dir/$name"

    if [[ -d "$dst" && ! -L "$dst" ]] && ! is_old_managed "$name"; then
        echo "  WARN: $dst is unmanaged (gh-installed?); skipping"
        continue
    fi

    [[ -L "$dst" ]] && rm -- "$dst"
    [[ -d "$dst" ]] && rm -rf -- "$dst"
    cp -R "$src" "$dst"
done

if ((${#new_names[@]})); then
    printf '%s\n' ${new_names[@]+"${new_names[@]}"} | LC_ALL=C sort > "$manifest"
else
    : > "$manifest"
fi
