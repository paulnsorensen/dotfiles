#!/bin/bash
# skills-sync.sh — per-subdir symlink sync for ~/.claude/skills.
#
# `~/.claude/skills/` is a real directory holding symlinks to each
# dotfiles-owned skill. `gh skill install` (run by `skill-sync`) writes its
# own real subdirs alongside, so dotfiles and external skills coexist
# without the dotfiles repo ever seeing gh-installed files.
#
# This file is sourced by claude/.sync and by tests. It defines the
# function only — no top-level side effects.

# Symlink each subdirectory of <source_dir> into <target_dir>:
#   - migrates a legacy directory-symlink at <target_dir> to a real dir
#   - preserves real directories already present (gh-installed skills)
#   - cleans up stale symlinks pointing at skills no longer in source
sync_skills_per_subdir() {
    local source_dir="$1"
    local target_dir="$2"

    [[ -d "$source_dir" ]] || return 0

    # Migrate from legacy directory symlink to a real directory
    if [[ -L "$target_dir" ]]; then
        rm "$target_dir"
        echo "  Migrated $target_dir from directory symlink to per-skill symlinks"
    fi
    mkdir -p "$target_dir"

    local src name link
    for src in "$source_dir"/*/; do
        [[ -d "$src" ]] || continue
        name="$(basename "$src")"
        link="$target_dir/$name"

        # Real directory already at target name (e.g. gh-installed skill).
        # Don't overwrite — leave it for the user to resolve.
        if [[ -e "$link" && ! -L "$link" ]]; then
            echo "  WARN: $link is a real directory (likely gh-installed); skipping dotfiles symlink"
            continue
        fi

        [[ -L "$link" ]] && rm "$link"
        ln -s "${src%/}" "$link"
    done

    # Drop dangling symlinks for skills that no longer exist in dotfiles
    local entry
    for entry in "$target_dir"/*; do
        [[ -L "$entry" ]] || continue
        [[ -e "$entry" ]] && continue
        rm "$entry"
        echo "  Removed stale skill symlink: $(basename "$entry")"
    done
}
